-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck screen logic, shared by the Ethos widget (main.lua) and the EdgeTX widget
  (edgetx/WIDGETS/OmniDeck/main.lua). It uses the Ethos Lua API; on EdgeTX a small
  adapter (etx.lua) provides the same calls. Keep it valid Lua 5.2: EdgeTX runs 5.2.

  Pages (tap the screen or press ENTER to change):
    1 MAIN  - avionics with a minimap
    2 MAP   - full-screen map with zoom buttons
    3 MSGS  - status messages (ArduPilot); scroll with the wheel or by dragging
    4 SUMMARY - last flight; opens on disarm, and joins the page cycle once a flight has ended
]]

local VERSION = "0.2.0-test35"

local function need(name) return assert(loadfile(name))() end
local T = need("telem.lua")
local MAP = need("map.lua")
local HUD = need("hud.lua")
local TL = need("tiles.lua")
local MI = need("mission.lua")
local MSPC = need("mspclient.lua")
local FS = need("summary.lua")
local AU = need("audio.lua")
MI.init(T)

local PAGE_SUMMARY = 4
local PAGE_CHECK = 5     -- sensor check: what each telemetry lookup returns on this radio
local ORIENT = { [0] = "north", [1] = "heading" }

-- round to a pixel; where Lua time is short (EdgeTX) the radio's own floor() is used directly
-- a NaN or infinite value (bad sensor data) would stop paint() on Ethos: drawn at 0 instead
local I = OD_LITE and math.floor or function(v) v = math.floor(v + 0.5) if v ~= v or v == math.huge or v == -math.huge then return 0 end return v end

-- ---------------------------------------------------------------- units
local SPD_UNITS = {
  [0] = { lbl = "km/h", k = 3.6, step = 10 },
  [1] = { lbl = "m/s", k = 1, step = 5 },
  [2] = { lbl = "kt", k = 1.943844, step = 10 },
  [3] = { lbl = "mph", k = 2.236936, step = 10 },
}
local ALT_UNITS = {
  [0] = { lbl = "m", k = 1, step = 10 },
  [1] = { lbl = "ft", k = 3.28084, step = 50 },
}

-- k: per km -> per unit of distance
local EFF_UNITS = {
  [0] = { lbl = "Wh/km", wh = true, k = 1 },
  [1] = { lbl = "mAh/km", wh = false, k = 1 },
  [2] = { lbl = "Wh/mi", wh = true, k = 1.609344 },
  [3] = { lbl = "mAh/mi", wh = false, k = 1.609344 },
}
local EFF_MIN_MPS = 3      -- below this the figure is meaningless (hover, on the ground)

local function units(w)
  local su, au = SPD_UNITS[w.spdUnit] or SPD_UNITS[0], ALT_UNITS[w.altUnit] or ALT_UNITS[0]
  local e = EFF_UNITS[w.effUnit] or EFF_UNITS[0]
  -- number in the chosen unit; Wh needs the voltage as well
  local function effVal(mahPerKm, volts)
    if not mahPerKm or (e.wh and not volts) then return "--" end
    if e.wh then return string.format("%.2f", mahPerKm / 1000 * volts * e.k) end
    return string.format("%.2f", mahPerKm * e.k)
  end
  -- data blocks and the flight summary: whole metres up to 999 m, then km to 2 places
  -- (feet: whole up to a mile, then miles to 2 places). The HUD and map keep their own formats.
  local function distF(m)
    if m == nil then return "--" end
    if au.lbl == "ft" then
      local ft = m * 3.28084
      return ft < 5279.5 and string.format("%dft", I(ft)) or string.format("%.2fmi", ft / 5280)
    end
    return m < 999.5 and string.format("%dm", I(m)) or string.format("%.2fkm", m / 1000)
  end
  local function altF(m)
    if m == nil then return "--" end
    if au.lbl == "ft" then return string.format("%dft", I(m * 3.28084)) end
    return distF(m)
  end
  return {
    spd = function(v) return v * su.k end, spdLbl = su.lbl, spdStep = su.step,
    spdPpu = function(h) return h / (su.step * 6) end,
    alt = function(v) return v * au.k end, altLbl = au.lbl, altStep = au.step,
    altPpu = function(h) return h / (au.step * 6) end,
    distM = function(m)
      if au.lbl == "ft" then
        local ft = m * 3.28084
        return ft >= 5280 and string.format("%.1fmi", ft / 5280) or string.format("%dft", math.floor(ft + 0.5))
      end
      return MAP.fmtDist(m)
    end,
    k = su.k,
    effLbl = e.lbl, effVal = effVal, distF = distF, altF = altF,
    spdF = function(v) return v and string.format("%.1f", v * su.k) or "--" end,
    eff = function(f)
      local ok = f and f.effSpd and f.effSpd >= EFF_MIN_MPS
      return effVal(ok and f.effAmps * 1000 / (f.effSpd * 3.6) or nil, f and f.effVolts) .. " " .. e.lbl
    end,
  }
end

-- ---------------------------------------------------------------- helpers
local function srcOrNil(v)
  if v == nil then return nil end
  if type(v) == "userdata" then
    local ok, n = pcall(function() return v:name() end)
    if ok and n ~= nil and n ~= "---" then return v end
  end
  -- EdgeTX: a table with value() from the adapter (OmniDeck Setup > Map zoom control)
  if type(v) == "table" and type(v.value) == "function" then return v end
  return nil
end
local SEV_COLOR = {
  [0] = lcd.RGB(255, 60, 60), [1] = lcd.RGB(255, 60, 60), [2] = lcd.RGB(255, 60, 60), [3] = lcd.RGB(255, 80, 80),
  [4] = lcd.RGB(255, 190, 40), [5] = lcd.RGB(255, 255, 255), [6] = lcd.RGB(220, 220, 220), [7] = lcd.RGB(160, 160, 160),
}
local COL = {
  bar = lcd.RGB(12, 12, 12), txt = lcd.RGB(240, 240, 240), dim = lcd.RGB(150, 150, 150),
  ok = lcd.RGB(80, 220, 80), warn = lcd.RGB(255, 190, 40), bad = lcd.RGB(255, 70, 70),
  tile = lcd.RGB(28, 28, 28), arm = lcd.RGB(255, 70, 70), panel = lcd.RGB(0, 0, 0),
  home = lcd.RGB(80, 200, 255),
}

local function fontFor(h)
  if h >= 400 then return FONT_L, FONT_STD, FONT_XS end
  if h >= 300 then return FONT_STD, FONT_S, FONT_XXS end
  return FONT_S, FONT_XS, FONT_XXS
end

-- ---------------------------------------------------------------- widget state
local function create()
  T.checkModel()    -- another model selected: clean telemetry state
  return {
    modelName = T.modelName(),   -- top bar; widgets are re-created when another model is picked
    page = 1, level = 4,
    -- settings
    linkMode = T.LINK_AUTO, orient = 0, zoomMode = 0, zoomSource = nil,
    spdUnit = 0, altUnit = 0, startPage = 1, trail = 1,
    tileSet = "", tz = nil, missionFile = "", inavWp = 1, sumAuto = 1, voice = "off", batCap = 0, effUnit = 0, beep = 1,
    lowVolt = 0, critVolt = 0, cells = 0, lowAlt = 0,   -- alarms: V per cell x 100, cells (0 auto), altitude unit; 0 = off
    -- runtime
    btns = nil, lastPaint = 0, lastZoomSrc = nil, msgScroll = 0,
  }
end

-- ---------------------------------------------------------------- top bar
-- the radio's own battery (the system source the ETHOS Mapping Widget uses for its top bar)
local txSrc = nil
local function txVolts()
  if txSrc == nil then
    local ok, src = pcall(system.getSource, { category = CATEGORY_SYSTEM, member = MAIN_VOLTAGE })
    txSrc = (ok and src) or false
  end
  if not txSrc then return nil end
  local ok, v = pcall(function() return txSrc:value() end)
  return ok and v or nil
end

local mid = {}   -- top bar middle layout, kept until its inputs change
local function topBar(w, x, y, W, h, s, u, H)
  local fBig, fMid, fSmall = fontFor(H)
  lcd.color(COL.bar)
  lcd.drawFilledRectangle(x, y, W, h)
  lcd.font(fBig)
  local _, th = lcd.getTextSize("0")
  local ty = y + (h - th) / 2
  local alive = T.alive()

  -- mode + armed
  -- telemetry heard before and now gone: say so instead of a stale mode
  local lost = s.fc ~= nil and not alive
  local mode = lost and "NO TELEMETRY" or (s.mode or (alive and "--" or "NO TELEM"))
  lcd.color(alive and COL.txt or COL.bad)
  lcd.drawText(x + 6, ty, mode)
  local mw = lcd.getTextSize(mode)
  local leftEnd = x + 6 + mw
  if s.armed ~= nil and not lost then
    local at = s.armed and "ARMED" or "DISARMED"
    lcd.color(s.armed and COL.arm or COL.dim)
    lcd.drawText(x + 14 + mw, ty, at)
    leftEnd = x + 14 + mw + lcd.getTextSize(at)
  end

  -- right side: GPS, link
  local parts = {}
  local fixTxt = (s.fix or 0) >= 3 and "3D" or ((s.fix or 0) == 2 and "2D" or "NoFix")
  parts[#parts + 1] = { string.format("%s %d", fixTxt, s.sats or 0), (s.fix or 0) >= 3 and COL.ok or COL.warn }
  if s.lq then parts[#parts + 1] = { string.format("LQ %d", math.floor(s.lq)), s.lq >= 70 and COL.ok or (s.lq >= 40 and COL.warn or COL.bad) } end
  if s.rssi then parts[#parts + 1] = { string.format("RSSI %d", math.floor(s.rssi)), COL.txt } end
  if s.failsafe or s.ekfBad then parts[#parts + 1] = { s.ekfBad and "EKF" or "FS", COL.bad } end
  local rx = x + W - 6
  for i = #parts, 1, -1 do
    local p = parts[i]
    lcd.color(p[2])
    lcd.drawText(rx, ty, p[1], RIGHT)
    rx = rx - lcd.getTextSize(p[1]) - 12
  end

  -- middle: the model name, then the transmitter battery. Centred and shifted to fit between
  -- both sides; short of room the TX battery goes first, then the name is shortened. Measured
  -- and placed only when its inputs change: EdgeTX's mission page has no Lua budget to spare.
  local tv = txVolts()
  local val = tv and string.format("TX %.1fV", tv) or nil
  local m = mid
  if m.val ~= val or m.left ~= leftEnd or m.rx ~= rx then   -- a new size or font moves rx too
    m.val, m.left, m.rx = val, leftEnd, rx
    local room = (rx - 2) - (leftEnd + 12)   -- rx sits 12 px left of the GPS figure
    local n = w.modelName
    if n == "" then n = nil end
    local nw, nh = 0, 0
    if n then lcd.font(fMid) nw, nh = lcd.getTextSize(n) end
    local v, tw = val, 0
    if v then lcd.font(fBig) tw = lcd.getTextSize(v) end
    local gap = (n and v) and 14 or 0
    if v and nw + gap + tw > room then v, tw, gap = nil, 0, 0 end
    if n and nw > room then
      local keep = math.floor(#n * room / nw) - 2
      if keep < 3 then n, nw = nil, 0
      else n = string.sub(n, 1, keep) .. ".." lcd.font(fMid) nw, nh = lcd.getTextSize(n) end
    end
    local gw = nw + gap + tw
    m.n, m.v = nil, nil
    if gw > 0 and gw <= room then
      local gx = math.max(leftEnd + 12, math.min(rx - 2 - gw, x + (W - gw) / 2))
      if n then m.n, m.nx, m.ny = n, I(gx), I(ty + (th - nh) / 2) end
      if v then m.v, m.vx = v, I(gx + nw + gap) end
    end
  end
  -- one text for the TX battery ("TX 6.8V"): every draw call costs Lua time on EdgeTX
  lcd.color(COL.txt)
  if m.v then lcd.drawText(m.vx, ty, m.v) end
  if m.n then
    lcd.font(fMid)
    lcd.drawText(m.nx, m.ny, m.n)
  end
end

-- ---------------------------------------------------------------- data tiles
-- bar: optional 0..1, drawn as a thin gauge along the bottom of the tile
-- note: optional small text on the label line, at the right
-- inset: optional width kept clear at the left (the HOME arrow); the value centres in what is left
local function tile(x, y, w, h, label, value, color, fVal, fLbl, bar, note, inset)
  lcd.color(COL.tile)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  if bar then
    h = h - 7
    lcd.color(COL.bar)
    lcd.drawFilledRectangle(I(x + 4), I(y + h + 1), I(w - 8), 4)
    lcd.color(COL.dim)
    lcd.drawFilledRectangle(I(x + 4), I(y + h + 1), I((w - 8) * bar), 4)
  end
  lcd.font(fLbl)
  local _, lh = lcd.getTextSize("A")
  lcd.color(COL.dim)
  lcd.drawText(I(x + 4), I(y + 2), label)
  -- the note is extra: on a narrow screen it is left out rather than run into the label
  if note and lcd.getTextSize(label) + lcd.getTextSize(note) + 10 <= w then
    lcd.drawText(I(x + w - 4), I(y + 2), note, RIGHT)
  end
  lcd.font(fVal)
  local _, vh = lcd.getTextSize("0")
  lcd.color(color or COL.txt)
  inset = inset or 0
  lcd.drawText(I(x + inset + (w - inset) / 2), I(y + lh + math.max(0, (h - lh - vh) / 2) - 1), value, CENTERED)
end

-- share of the pack left, 0..1. nil without a capacity, or when nothing shows a current sensor is
-- there: with no sensor mAh stays 0 and a gauge would read full for the whole flight.
local function battLeft(s)
  if not (s.cap and s.cap > 0 and s.mah) then return nil end
  if s.mah == 0 and (s.curr or 0) == 0 then return nil end
  return math.max(0, math.min(1, 1 - s.mah / s.cap))
end

-- darker than the status colours, so the white voltage on top stays easy to read
local BATT_FILL = { ok = lcd.RGB(35, 140, 60), warn = lcd.RGB(190, 130, 10), bad = lcd.RGB(190, 40, 40) }

local function battGauge(x, y, w, h, s, fVal, alarmV)
  lcd.color(COL.tile)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  local pad, nubW = 6, math.max(4, I(w * 0.03))
  local bx, by, bw, bh = x + pad, y + pad, w - 2 * pad - nubW, h - 2 * pad
  lcd.color(COL.txt)
  lcd.drawRectangle(I(bx), I(by), I(bw), I(bh))
  lcd.drawFilledRectangle(I(bx + bw), I(by + bh * 0.3), I(nubW), I(bh * 0.4))
  local left = battLeft(s)
  if left then
    lcd.color((s.battFs or left < 0.15) and BATT_FILL.bad or (left < 0.3 and BATT_FILL.warn or BATT_FILL.ok))
    lcd.drawFilledRectangle(I(bx + 2), I(by + 2), I((bw - 4) * left), I(bh - 4))
  end
  lcd.font(fVal)
  local _, th = lcd.getTextSize("0")
  HUD.outlined(bx + bw / 2, by + (bh - th) / 2, s.volt and string.format("%.1fV", s.volt) or "--", CENTERED,
    (alarmV == 2 and COL.bad) or (alarmV == 1 and COL.warn) or COL.txt)
end

-- arrow to home relative to the nose (up = home is ahead), in the left part of the HOME block
local function homeArrow(x, y, w, h, s, fLbl)
  if not (s.homeBrg and s.yaw and s.homeDist and s.homeDist > 0) then return end
  lcd.font(fLbl)
  local _, lh = lcd.getTextSize("A")
  local r = math.min(h - lh - 6, w * 0.3) / 2
  if r < 4 then return end
  local cx, cy = x + 6 + r, y + lh + 3 + (h - lh - 3) / 2
  local a = math.rad(s.homeBrg - s.yaw)
  local sa, ca = math.sin(a), math.cos(a)
  local function pt(fwd, side) return cx + sa * fwd + ca * side, cy - ca * fwd + sa * side end
  local tx, ty = pt(r, 0)
  local lx, ly = pt(-r, -r * 0.8)
  local nx, ny = pt(-r * 0.45, 0)
  local rx, ry = pt(-r, r * 0.8)
  lcd.color(COL.home)
  lcd.drawFilledTriangle(I(tx), I(ty), I(lx), I(ly), I(nx), I(ny))
  lcd.drawFilledTriangle(I(tx), I(ty), I(nx), I(ny), I(rx), I(ry))
end

local flightClock = { sec = nil, txt = "--" }   -- FLIGHT TIME text, remade when the second changes
local function tiles(x, y, w, h, s, u, fVal, fLbl)
  -- flight in progress, or the last one until the next arming
  local f = FS.live()
  local function maxSpd(label, v, now)
    return { "MAX " .. label .. " " .. u.spdLbl, u.spdF(v), COL.txt,
      (v and v > 0 and now) and math.min(1, now / v) or 0 }   -- bar: speed now against the max
  end
  -- flight time since arming (white); after the disarm the last flight's time, dimmed, until
  -- the next arming. The text is made once a second, not on every screen update.
  local ft, running = FS.timer(os.clock())
  local fts = "--"
  if ft then
    local sec = math.floor(ft)
    if sec ~= flightClock.sec then
      flightClock.sec = sec
      flightClock.txt = sec >= 3600
        and string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
        or string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
    end
    fts = flightClock.txt
  end
  local items = {
    -- HOME carries the total distance flown as its note (max distance from home is in the summary)
    { "HOME", u.distF(s.homeDist), COL.txt, nil,
      (f and f.dist) and ("TOTAL " .. u.distF(f.dist)) or nil },
    { "FLIGHT TIME", fts, (ft and not running) and COL.dim or COL.txt },
    maxSpd("AS", f and f.maxAspd, s.aspd),
    maxSpd("GS", f and f.maxGspd, s.gspd),
    { gauge = true },
    { "USED", s.mah and string.format("%dmAh", I(s.mah)) or "--", (s.cap and s.cap > 0 and s.mah and s.mah > 0.8 * s.cap) and COL.warn or COL.txt },
    { "CURR", s.curr and string.format("%.1fA", s.curr) or "--", COL.txt, nil,
      (f and f.maxCurr) and string.format("MAX %.1fA", f.maxCurr) or nil },
    { "THR", s.thr and string.format("%d%%", s.thr) or "--", COL.txt, math.min(1, math.abs(s.thr or 0) / 100), u.eff(f) },
  }
  local cols, rows = 2, 4
  local gap = 3
  local tw, th = (w - gap) / cols, (h - (rows - 1) * gap) / rows
  for i, it in ipairs(items) do
    local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + c * (tw + gap), y + r * (th + gap)
    if it.gauge then battGauge(tx, ty, tw, th, s, fVal, u.alarmV)
    else
      -- HOME: keep the value clear of the arrow (drawn in the left 6 px + up to 30 % of the tile)
      local inset = (i == 1 and s.homeBrg and s.yaw and s.homeDist and s.homeDist > 0) and (tw * 0.3 + 6) or 0
      tile(tx, ty, tw, th, it[1], it[2], it[3], fVal, fLbl, it[4], it[5], inset)
    end
    if i == 1 then homeArrow(tx, ty, tw, th, s, fLbl) end
  end
end

-- ---------------------------------------------------------------- message line
local function lastMsg(s, maxAge)
  local m = s.msgs[#s.msgs]
  if m and (os.clock() - m.t) < maxAge then return m end
  return nil
end

local function msgLine(x, y, w, h, s, font)
  local m = lastMsg(s, 15)
  lcd.color(COL.bar)
  lcd.drawFilledRectangle(x, y, w, h)
  if not m then return end
  lcd.font(font)
  local _, th = lcd.getTextSize("A")
  lcd.color(SEV_COLOR[m.sev] or COL.txt)
  lcd.drawText(x + 6, y + (h - th) / 2, m.text)
end

-- ---------------------------------------------------------------- pages
-- tile set picked in the settings, if it is still on the card
local tileSets = nil
local function activeTileSet(w)
  if w.tileSet == nil or w.tileSet == "" then return nil end
  if tileSets == nil then tileSets = TL.scan() end
  for _, ts in ipairs(tileSets) do if ts.label == w.tileSet then return ts end end
  return nil
end

-- last good GPS position, kept on the SD card: with no fix (bench, start-up) the map centres
-- there, so the tile set still shows
local POS_FILE = (OD_ROOT or "/scripts/omnideck/") .. "lastpos.txt"
local POS_SAVE_S = 60
local lastPos, lastPosRead, lastPosSaved = nil, false, -1000

-- whole file, a line at a time: Ethos rejects read("a") ("invalid format", X18 tester
-- 2026-11-03); "*l" is what b14ckyy's mapping widget uses on Ethos
local function readAll(f)
  local lines = {}
  for _ = 1, 5000 do
    local ok, l = pcall(f.read, f, "*l")
    if not ok or l == nil then break end
    lines[#lines + 1] = l
  end
  return table.concat(lines, "\n")
end

local function readLastPos()
  lastPosRead = true
  local ok, f = pcall(io.open, POS_FILE, "r")
  if not ok or not f then return end
  local text = readAll(f)
  f:close()
  local la, lo = string.match(text, "([%-%d%.]+)%s*,%s*([%-%d%.]+)")
  la, lo = tonumber(la), tonumber(lo)
  if la and lo and (la ~= 0 or lo ~= 0) then lastPos = { la, lo } end
end

local function rememberPos(s, now)
  if not (s.lat and (s.fix or 0) >= 3) then return end
  lastPos = { s.lat, s.lon }
  if now - lastPosSaved < POS_SAVE_S then return end
  lastPosSaved = now
  pcall(function()
    local f = io.open(POS_FILE, "w")
    if f then f:write(string.format("%.7f,%.7f\n", s.lat, s.lon)) f:close() end
  end)
end

local function mapCenter()
  local s = T.s
  if s.lat then return nil end
  if not lastPosRead then readLastPos() end
  if lastPos then return lastPos end
  if s.homeLat then return { s.homeLat, s.homeLon } end
  return nil
end

local function mapOpts(w, mini)
  local ts = activeTileSet(w)
  local mis = MI.current()
  return { level = w.level, orient = ORIENT[w.orient] or "north", mini = mini, trail = w.trail == 1,
           homeView = w.zoomMode == 1, windScale = units(w).k,
           home = (w.zoomMode == 1 and T.s.homeLat) and { T.s.homeLat, T.s.homeLon } or nil,
           tiles = ts and TL or nil, tz = ts and w.tz or nil,
           mission = mis, activeWp = T.s.wpNum, center = mapCenter() }
end

-- A Lua error in paint() leaves the screen half drawn (Ethos shows nothing else). Each part runs
-- on its own, so one failing part leaves the rest of the screen, and the first error is shown
-- in red on the screen (and kept in error.log) for a tester to photograph.
local ERR_FILE = (OD_ROOT or "/scripts/omnideck/") .. "error.log"
local paintErr, loggedErr = nil, {}
local function safe(part, fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then return end
  local W, H = lcd.getWindowSize()
  lcd.setClipping(0, 0, W, H)          -- the map leaves its clipping on when it fails
  local msg = part .. ": " .. tostring(err)
  paintErr = paintErr or msg
  if not loggedErr[msg] then
    loggedErr[msg] = true
    pcall(function()
      local f = io.open(ERR_FILE, "a")
      if f then f:write(VERSION .. " " .. msg .. "\n") f:close() end
    end)
  end
end
local function errorBanner(W, H)
  if not paintErr then return end
  lcd.font(FONT_S)
  local _, th = lcd.getTextSize("A")
  local text = VERSION .. " ERR " .. paintErr
  local lines, per = {}, math.max(20, math.floor(W / (lcd.getTextSize("W") * 0.8)))
  for i = 1, #text, per do lines[#lines + 1] = string.sub(text, i, i + per - 1) end
  local y = math.floor(H * 0.5)
  lcd.color(lcd.RGB(0, 0, 0))
  lcd.drawFilledRectangle(0, y, W, #lines * th + 4)
  lcd.color(lcd.RGB(255, 60, 60))
  for i, l in ipairs(lines) do lcd.drawText(4, y + 2 + (i - 1) * th, l) end
end

local function pageMain(w, W, H, s, u)
  local fBig, fMid, fSmall = fontFor(H)
  local barH = I(H * 0.09)
  local msgH = I(H * 0.075)
  local bodyY, bodyH = barH, H - barH - msgH
  local hudW = I(W * 0.56)
  local rx, rw = hudW + 3, W - hudW - 3
  local mapH = math.min(rw, I(bodyH * 0.46))
  -- map first: on EdgeTX a tile can hang over the map's edge, and what follows covers it
  safe("map", MAP.draw, rx, bodyY, rw, mapH, s, mapOpts(w, true))
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(hudW, bodyY, 3, bodyH)
  lcd.drawFilledRectangle(rx, bodyY + mapH, rw, bodyH - mapH)
  safe("bar", topBar, w, 0, 0, W, barH, s, u, H)
  safe("hud", HUD.draw, 0, bodyY, hudW, bodyH, s, u)
  if s.armed == false and T.alive() then safe("arm", HUD.armStatus, 0, bodyY, hudW, bodyH, s) end
  safe("tiles", tiles, rx, bodyY + mapH + 3, rw, bodyH - mapH - 3, s, u, fBig, fSmall)
  safe("msg", msgLine, 0, H - msgH, W, msgH, s, fMid)
end

local function pageMap(w, W, H, s, u)
  local fBig, fMid, fSmall = fontFor(H)
  local barH = I(H * 0.09)
  -- bottom strip for the GPS position, below the map so it never covers it
  lcd.font(fMid)
  local _, ch = lcd.getTextSize("0")
  local stripH = ch + 6
  local mapH = H - barH - stripH
  w.btns = MAP.draw(0, barH, W, mapH, s, mapOpts(w, false))
  topBar(w, 0, 0, W, barH, s, u, H)
  -- the aircraft's position in decimal degrees (about 0.1 m), for finding it after a landing
  -- out of sight; with no fix, the last good one, marked LAST
  lcd.color(COL.bar)
  lcd.drawFilledRectangle(0, H - stripH, W, stripH)
  lcd.font(fMid)
  local plat, plon, tag = s.lat, s.lon, nil
  if not plat then
    local c = mapCenter()
    if c then plat, plon, tag = c[1], c[2], "LAST" end
  end
  local cx = 6
  if tag then
    lcd.color(COL.warn)
    lcd.drawText(cx, H - stripH + 3, tag)
    cx = cx + lcd.getTextSize(tag) + 12
  end
  if plat then
    for _, part in ipairs({ { "Lat ", COL.dim }, { string.format("%.6f", plat), COL.txt },
                            { "     Lon ", COL.dim }, { string.format("%.6f", plon), COL.txt } }) do
      lcd.color(part[2])
      lcd.drawText(cx, H - stripH + 3, part[1])
      cx = cx + lcd.getTextSize(part[1])
    end
  else
    lcd.color(COL.dim)
    lcd.drawText(cx, H - stripH + 3, "Lat --     Lon --")
  end
  -- overlay: home distance/bearing, altitude, speed (top-left of the map)
  lcd.font(fBig)
  local _, th = lcd.getTextSize("0")
  local lines = {
    string.format("HOME %s", s.homeDist and u.distM(s.homeDist) or "--"),
    string.format("ALT %s", s.alt and string.format("%d%s", I(u.alt(s.alt)), u.altLbl) or "--"),
    string.format("%s %s", s.aspd and "AS" or "GS", (s.aspd or s.gspd) and string.format("%d%s", I(u.spd(s.aspd or s.gspd)), u.spdLbl) or "--"),
  }
  if s.wpNum and s.wpDist then lines[#lines + 1] = string.format("WP%d %s", s.wpNum, u.distM(s.wpDist)) end
  local ts = activeTileSet(w)
  if ts and w.tz then lines[#lines + 1] = string.format("%s z%d", ts.type, w.tz) end
  -- solid backing so the text stays readable over satellite tiles
  local boxW = 0
  for _, l in ipairs(lines) do boxW = math.max(boxW, (lcd.getTextSize(l))) end
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(0, barH, boxW + 12, #lines * (th + 1) + 7)
  lcd.color(COL.txt)
  for i, l in ipairs(lines) do
    lcd.drawText(6, barH + 4 + (i - 1) * (th + 1), l)
  end
  local m = lastMsg(s, 10)
  if m then
    lcd.font(fMid)
    local mw, mh = lcd.getTextSize(m.text)
    lcd.color(COL.panel)
    lcd.drawFilledRectangle(0, H - stripH - mh - 6, mw + 12, mh + 6)
    lcd.color(SEV_COLOR[m.sev] or COL.txt)
    lcd.drawText(6, H - stripH - mh - 4, m.text)
  end
end

local function pageMsgs(w, W, H, s, u)
  local fBig, fMid, fSmall = fontFor(H)
  local barH = I(H * 0.09)
  topBar(w, 0, 0, W, barH, s, u, H)
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(0, barH, W, H - barH)
  lcd.font(fMid)
  local _, th = lcd.getTextSize("A")
  local rowH = th + 2
  local n = #s.msgs
  if n == 0 then
    w.msgScroll = 0
    lcd.color(COL.dim)
    lcd.drawText(W / 2, barH + (H - barH) / 2, "no messages", CENTERED)
    return
  end

  -- scroll = how many messages the newest visible line sits above the newest one.
  -- While scrolled back, new arrivals push the offset up so the view stays put.
  local total = s.msgTotal or n
  if (w.msgScroll or 0) > 0 and w.msgSeen and total > w.msgSeen then
    w.msgScroll = w.msgScroll + (total - w.msgSeen)
  end
  w.msgSeen = total
  local rows = math.max(1, math.floor((H - barH - 6) / rowH))
  local maxScroll = math.max(0, n - rows)
  w.msgScroll = math.max(0, math.min(maxScroll, math.floor(w.msgScroll or 0)))
  w.msgRowH, w.msgMax = rowH, maxScroll

  -- newest at the bottom, each with how long ago it arrived
  local barW = maxScroll > 0 and 8 or 0
  local ageW = lcd.getTextSize("-00:00 ")
  local tnow = os.clock()
  local y = H - th - 4
  for i = n - w.msgScroll, 1, -1 do
    if y < barH + 2 then break end
    local m = s.msgs[i]
    local age = math.max(0, math.floor(tnow - m.t))
    lcd.color(COL.dim)
    lcd.drawText(6, y, string.format("-%02d:%02d", math.floor(age / 60), age % 60))
    lcd.color(SEV_COLOR[m.sev] or COL.txt)
    lcd.drawText(10 + ageW, y, m.text)
    y = y - rowH
  end

  w.msgLatestBtn = nil
  if maxScroll > 0 then
    -- scrollbar: thumb size = visible share, position = how far back we are
    local trackY, trackH = barH + 4, H - barH - 8
    local thumbH = math.max(16, trackH * rows / n)
    local thumbY = trackY + (trackH - thumbH) * (1 - w.msgScroll / maxScroll)
    lcd.color(COL.tile)
    lcd.drawFilledRectangle(W - barW - 2, trackY, barW, trackH)
    lcd.color(COL.dim)
    lcd.drawFilledRectangle(W - barW - 2, I(thumbY), barW, I(thumbH))
    if w.msgScroll > 0 then
      -- "newer below" tag; tapping it jumps back to the latest message
      lcd.font(FONT_S)
      local label = string.format("%d newer", w.msgScroll)
      local lw, lh = lcd.getTextSize(label)
      local bw, bh = lw + 26, lh + 8
      local bx, by = W - barW - bw - 8, H - bh - 4
      lcd.color(COL.warn)
      lcd.drawFilledRectangle(bx, by, bw, bh)
      lcd.color(COL.panel)
      lcd.drawText(bx + 6, by + 4, label)
      local ax, ay = bx + bw - 12, by + bh / 2
      lcd.drawFilledTriangle(I(ax - 5), I(ay - 3), I(ax + 5), I(ay - 3), I(ax), I(ay + 4))
      w.msgLatestBtn = { x = bx, y = by, w = bw, h = bh }
    end
  end
end

-- ---------------------------------------------------------------- sensor check page
-- One row per native sensor: the query that matched, the sensor's name on the radio, its raw
-- value and unit code. For testers: a photo of this page shows what the telemetry code reads.
local function pageCheck(w, W, H, s, u)
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(0, 0, W, H)
  lcd.font(H >= 400 and FONT_S or FONT_XS)
  local _, th = lcd.getTextSize("A")
  local rows = T.sensorCheck()
  local y = 2
  lcd.color(COL.txt)
  lcd.drawText(4, y, "OmniDeck " .. VERSION .. "  SENSOR CHECK")
  y = y + th + 1
  lcd.color(COL.warn)
  lcd.drawText(4, y, rows.header or "")
  y = y + th + 1
  -- EdgeTX: link statistics from the adapter (frames reaching the widget, updates per second)
  if OD_STATS then
    lcd.color(COL.ok)
    for _, l in ipairs(OD_STATS()) do lcd.drawText(4, y, l) y = y + th end
  end
  lcd.color(COL.txt)
  lcd.drawText(4, y, T.rawCheck())
  y = y + th
  -- INAV mission download: what the flight controller reported and what arrived
  if MSPC.state() ~= "off" then
    lcd.color(COL.home)
    lcd.drawText(4, y, MSPC.debug())
    y = y + th
  end
  y = y + 2
  local cx = { 4, I(W * 0.12), I(W * 0.36), I(W * 0.66), I(W * 0.90) }
  lcd.color(COL.dim)
  lcd.drawText(cx[1], y, "key") lcd.drawText(cx[2], y, "query") lcd.drawText(cx[3], y, "sensor")
  lcd.drawText(cx[4], y, "value") lcd.drawText(cx[5], y, "unit")
  y = y + th + 1
  for _, r in ipairs(rows) do
    if y + th > H then break end
    lcd.color(r.name == "not found" and COL.bad or COL.txt)
    lcd.drawText(cx[1], y, r.key)
    lcd.drawText(cx[2], y, r.query)
    lcd.drawText(cx[3], y, r.name)
    lcd.drawText(cx[4], y, r.value)
    lcd.drawText(cx[5], y, r.unit)
    y = y + th
  end
  if #rows == 0 then
    lcd.color(COL.bad)
    lcd.drawText(4, y, "no link found (no module on, no link sensor)")
  end
end

local function fmtTime(sec)
  sec = math.floor(sec + 0.5)
  if sec >= 3600 then return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60) end
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function pageSummary(w, W, H, s, u)
  local fBig, fMid, fSmall = fontFor(H)
  local barH = I(H * 0.09)
  topBar(w, 0, 0, W, barH, s, u, H)
  local f = FS.last()
  if not f then return end
  f.shown = true
  local dist, alt, spd = u.distF, u.altF, u.spdF
  -- average for the whole flight, unlike the live figure in the THR block
  local perKm = (f.used and f.dist > 100) and f.used / (f.dist / 1000) or nil
  local items = {
    { "FLIGHT TIME", fmtTime(f.time) },
    { "DISTANCE", dist(f.dist) },
    { "MAX HOME", dist(f.maxHome) },
    { "MAX ALT", alt(f.maxAlt) },
    { "MAX GSPD " .. u.spdLbl, spd(f.maxGspd) },
    { "MAX AS " .. u.spdLbl, spd(f.maxAspd) },
    { "USED", f.used and string.format("%dmAh", I(f.used)) or "--",
      (s.cap and s.cap > 0 and f.used and f.used > 0.8 * s.cap) and COL.warn or nil },
    { u.effLbl, u.effVal(perKm, f.voltN and f.voltSum / f.voltN) },
    { "MIN VOLT", f.minVolt and string.format("%.1fV", f.minVolt) or "--" },
    { "MAX CURR", f.maxCurr and string.format("%.1fA", f.maxCurr) or "--" },
    { f.minLq and "MIN LQ" or "MIN RSSI", (f.minLq or f.minRssi) and string.format("%d", I(f.minLq or f.minRssi)) or "--" },
    { "LINK LOST", f.lost > 0 and fmtTime(f.lost) or "none", f.lost > 0 and COL.warn or nil },
  }
  local fVal = H >= 400 and FONT_XL or fBig
  local fLbl = H >= 400 and FONT_S or FONT_XS
  local cols, gap = 3, 3
  local rows = math.ceil(#items / cols)
  local bodyY = barH + gap
  local tw, th = (W - (cols - 1) * gap) / cols, (H - bodyY - (rows - 1) * gap) / rows
  for i, it in ipairs(items) do
    local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
    tile(c * (tw + gap), bodyY + r * (th + gap), tw, th, it[1], it[2], it[3], fVal, fLbl)
  end
end

-- ---------------------------------------------------------------- alarms
-- Voltage, per cell, in two stages: low ("Low voltage", again every VOLT_REPEAT_S) and
-- critical ("Critical voltage", every CRIT_REPEAT_S). Each needs VOLT_HOLD_S below its
-- setting, so a dip under load doesn't count; critical takes over from low. Low altitude ("Terrain, pull up"):
-- armed, and only after the aircraft has been above the setting once, so the take-off and
-- the landing approach from below don't count; again every ALT_REPEAT_S while low.
local VOLT_HOLD_S, VOLT_REPEAT_S, CRIT_REPEAT_S, ALT_REPEAT_S = 5, 30, 15, 15
local alarm = { lowSince = nil, critSince = nil, voltStage = 0, voltSaid = -100, altArmed = false, altSaid = -100, cells = 0 }

local function checkAlarms(w, s, now)
  -- cell count: the setting, else the most cells the highest voltage seen could be (4.35 V max)
  if s.volt and s.volt > 0 then alarm.cells = math.max(alarm.cells, math.ceil(s.volt / 4.35)) end
  local cells = (w.cells or 0) > 0 and w.cells or alarm.cells
  local vLow, vCrit = (w.lowVolt or 0) / 100, (w.critVolt or 0) / 100
  local live = T.alive() and s.armed == true
  w.alarmV, w.alarmA = 0, false
  local cell = (live and s.volt and cells > 0) and s.volt / cells or nil
  if cell and vLow > 0 and cell < vLow then alarm.lowSince = alarm.lowSince or now else alarm.lowSince = nil end
  if cell and vCrit > 0 and cell < vCrit then alarm.critSince = alarm.critSince or now else alarm.critSince = nil end
  local stage = 0
  if alarm.critSince and now - alarm.critSince >= VOLT_HOLD_S then stage = 2
  elseif alarm.lowSince and now - alarm.lowSince >= VOLT_HOLD_S then stage = 1 end
  w.alarmV = stage
  if stage > 0 then
    local every = stage == 2 and CRIT_REPEAT_S or VOLT_REPEAT_S
    if stage > alarm.voltStage or now - alarm.voltSaid >= every then
      alarm.voltSaid = now
      AU.alert(stage == 2 and "critvolt" or "lowvoltage")   -- "critvolt": EdgeTX limits sound paths to 45 characters
    end
  end
  alarm.voltStage = stage
  local aLim = (w.lowAlt or 0) / (w.altUnit == 1 and 3.28084 or 1)   -- the setting is in the altitude unit
  if not s.armed then alarm.altArmed = false end
  if live and aLim > 0 and s.alt then
    if s.alt > aLim + 2 then alarm.altArmed = true end
    if alarm.altArmed and s.alt < aLim then
      w.alarmA = true
      if now - alarm.altSaid >= ALT_REPEAT_S then alarm.altSaid = now AU.alert("pullup") end
    end
  end
end

-- ---------------------------------------------------------------- lifecycle
-- telemetry lost after it was working: the screen edges flash red (as Yaapu does)
local LOST_EDGE = 5
local function lostFrame(W, H)
  if T.s.fc == nil or T.alive() or math.floor(os.clock() * 2) % 2 == 1 then return end
  lcd.color(COL.bad)
  lcd.drawFilledRectangle(0, 0, W, LOST_EDGE)
  lcd.drawFilledRectangle(0, H - LOST_EDGE, W, LOST_EDGE)
  lcd.drawFilledRectangle(0, 0, LOST_EDGE, H)
  lcd.drawFilledRectangle(W - LOST_EDGE, 0, LOST_EDGE, H)
end

local function paint(w)
  local W, H = lcd.getWindowSize()
  local s, u = T.s, units(w)
  u.alarmV, u.alarmA = w.alarmV, w.alarmA
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(0, 0, W, H)
  w.btns = nil
  if W < 300 or H < 150 then
    -- small widget slot: minimap only
    safe("map", MAP.draw, 0, 0, W, H, s, mapOpts(w, true))
    lostFrame(W, H)
    errorBanner(W, H)
    return
  end
  if w.page == 2 then safe("mappage", pageMap, w, W, H, s, u)
  elseif w.page == 3 then safe("msgs", pageMsgs, w, W, H, s, u)
  elseif w.page == PAGE_SUMMARY then safe("summary", pageSummary, w, W, H, s, u)
  elseif w.page == PAGE_CHECK then safe("check", pageCheck, w, W, H, s, u)
  else safe("main", pageMain, w, W, H, s, u) end
  lostFrame(W, H)
  errorBanner(W, H)
end

local function zoomFromSource(w)
  local src = srcOrNil(w.zoomSource)
  if not src then return end
  local ok, v = pcall(function() return src:value() end)
  if not ok or v == nil then return end
  -- -1024..1024 across all levels
  local n = #MAP.LEVELS
  local idx = math.max(1, math.min(n, 1 + math.floor((v + 1024) / 2048 * n)))
  local ts = activeTileSet(w)
  if ts then
    -- same source, mapped across the tile zoom levels on the card (up = closer)
    idx = ts.minZ + math.floor((v + 1024) / 2048 * (ts.maxZ - ts.minZ + 1))
    idx = math.max(ts.minZ, math.min(ts.maxZ, idx))
  end
  if idx ~= w.lastZoomSrc then
    w.lastZoomSrc = idx
    if ts then w.tz = idx else w.level = idx end
  end
end

local function wakeup(w)
  T.wakeup(w.linkMode)
  local s = T.s
  -- ArduPilot sends BATT_CAPACITY; INAV and Betaflight don't, so the pilot enters it
  if s.fc ~= "ArduPilot" then s.cap = w.batCap > 0 and w.batCap or nil end
  AU.update(s, T.alive(), os.clock())
  local flight = FS.update(s, T.alive(), os.clock(), T.distBrg)
  if flight == "armed" and w.page == PAGE_SUMMARY then
    -- arming always brings the main page back (an EdgeTX instance with a fixed Page: that page)
    w.page = w.homePage or 1
    lcd.invalidate()
  end
  -- a finished flight whose summary has not been drawn yet opens it, on any page. The flight
  -- is kept in summary.lua, so this also works when Ethos re-created the widget (another
  -- screen was up at disarm) and the moment the flight ended was missed.
  local done = FS.last()
  if done and not done.shown and w.sumAuto == 1 and s.armed ~= true and w.page ~= PAGE_SUMMARY then
    w.pageBefore = w.page
    w.page = PAGE_SUMMARY
    lcd.invalidate()
  end
  zoomFromSource(w)
  local ts = activeTileSet(w)
  if ts then
    TL.setSet(ts)
    if w.tz == nil then w.tz = ts.maxZ end
    w.tz = math.max(ts.minZ, math.min(ts.maxZ, w.tz))
  end
  -- Map view. Aircraft-centred (zoomMode 0): the pilot sets the zoom. Home-centred (1): the map
  -- stays on home and starts at the closest step when armed. It zooms out at once when the
  -- aircraft nears the edge, so the aircraft always stays on the map, and back in one step
  -- at a time (at most every ZOOM_IN_S) once the aircraft is well inside the closer range.
  if w.zoomMode == 1 then
    local ZOOM_IN_S = 2
    local now = os.clock()
    if flight == "armed" then
      w.level = 1
      if ts then w.tz = ts.maxZ end
    end
    local d = s.homeDist
    if d and s.homeLat then
      local slow = now - (w.zoomInAt or -100) >= ZOOM_IN_S
      if ts then
        local r = MAP.lastRadiusPx or 150
        local z = MAP.tileZFor(d, s.homeLat, r, ts.minZ, ts.maxZ, TL)
        if z < w.tz then
          w.tz = z
        elseif w.tz < ts.maxZ and slow and d <= MAP.ZOOM_IN_AT * MAP.EDGE * r * TL.mpp(s.homeLat, w.tz + 1) then
          w.tz, w.zoomInAt = w.tz + 1, now
        end
      else
        local l = MAP.levelFor(d)
        if l > w.level then
          w.level = l
        elseif w.level > 1 and slow and d <= MAP.ZOOM_IN_AT * MAP.EDGE * MAP.LEVELS[w.level - 1] then
          w.level, w.zoomInAt = w.level - 1, now
        end
      end
    end
  end
  -- tiles load here, never in paint(): ~14 ms each on an X20S, so two per wakeup
  if ts then TL.process(2) end
  MI.update(s)
  -- INAV mission download: only on a native (non-passthrough) link, after the
  -- link has been up for a few seconds; the client stops by itself if the FC is not INAV
  if w.inavWp == 1 and s.fc == "INAV/BF" and T.alive() then
    w.linkUpAt = w.linkUpAt or os.clock()
    if os.clock() - w.linkUpAt > 3 then
      MSPC.wakeup(s.link, s.armed)
      local n = #MSPC.waypoints()
      if n ~= w.inavWpN then w.inavWpN = n MI.setInav(MSPC.waypoints()) end
      if MSPC.state() == "done" then s.wpNum = MSPC.active() end
    end
  else
    w.linkUpAt = nil
  end
  if s.lat then MAP.addTrail(s.lat, s.lon, MAP.LEVELS[w.level]) end
  rememberPos(s, os.clock())
  checkAlarms(w, s, os.clock())
  if lcd.isVisible == nil or lcd.isVisible() then
    local t = os.clock()
    if t - w.lastPaint >= 0.1 then
      w.lastPaint = t
      lcd.invalidate()
    end
  end
end

-- the summary joins the cycle only once there is a flight to show
local function nextPage(w)
  -- main, map, messages, the summary once there is a flight, then the sensor check
  local p = w.page + 1
  if p == PAGE_SUMMARY and not FS.last() then p = PAGE_CHECK end
  if p > PAGE_CHECK then p = 1 end
  w.page = p
  lcd.invalidate()
end

local function inBox(b, x, y) return b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h end

-- d = -1 zooms in, +1 zooms out
local function zoomStep(w, d)
  local ts = activeTileSet(w)
  if ts then
    w.tz = math.max(ts.minZ, math.min(ts.maxZ, (w.tz or ts.maxZ) - d))
  else
    w.level = math.max(1, math.min(#MAP.LEVELS, w.level + d))
  end
end

local function msgScrollBy(w, d)
  w.msgScroll = math.max(0, math.min(w.msgMax or 0, (w.msgScroll or 0) + d))
  lcd.invalidate()
end

local TAP_PX = 12   -- a touch that moves less than this is a tap, more is a drag

local function event(w, category, value, x, y)
  if category == EVT_TOUCH then
    if value == TOUCH_START then
      w.touchX, w.touchY, w.touchScroll, w.dragged = x, y, w.msgScroll or 0, false
      return true
    end
    if value == TOUCH_MOVE then
      if w.touchY and math.abs(y - w.touchY) > TAP_PX then w.dragged = true end
      -- messages: drag down to read older lines (like a phone)
      if w.dragged and w.page == 3 and w.msgRowH then
        local rows = math.floor((y - w.touchY) / w.msgRowH + 0.5)
        w.msgScroll = math.max(0, math.min(w.msgMax or 0, w.touchScroll + rows))
        lcd.invalidate()
      end
      return true
    end
    if value ~= TOUCH_END then return true end
    local dragged = w.dragged or (w.touchY and math.abs(y - w.touchY) > TAP_PX)
    w.touchY, w.dragged = nil, false
    if dragged then return true end
    if w.page == 2 and w.btns then
      if inBox(w.btns.plus, x, y) then zoomStep(w, -1) lcd.invalidate() return true end
      if inBox(w.btns.minus, x, y) then zoomStep(w, 1) lcd.invalidate() return true end
      if inBox(w.btns.auto, x, y) then w.zoomMode = (w.zoomMode == 1) and 0 or 1 lcd.invalidate() return true end
    end
    if w.page == 3 and inBox(w.msgLatestBtn, x, y) then
      w.msgScroll = 0 lcd.invalidate() return true
    end
    nextPage(w)
    return true
  end
  if category == EVT_KEY then
    if value == KEY_ENTER_BREAK then
      nextPage(w)
      return true
    elseif w.page == PAGE_SUMMARY and (value == KEY_ROTARY_LEFT or value == KEY_ROTARY_RIGHT) then
      return true
    elseif value == KEY_ROTARY_LEFT then
      -- messages page: the wheel scrolls (left = older); elsewhere it zooms
      if w.page == 3 then msgScrollBy(w, 1) else zoomStep(w, 1) lcd.invalidate() end
      return true
    elseif value == KEY_ROTARY_RIGHT then
      if w.page == 3 then msgScrollBy(w, -1) else zoomStep(w, -1) lcd.invalidate() end
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------- exports
return {
  VERSION = VERSION, create = create, paint = paint, wakeup = wakeup, event = event, nextPage = nextPage,
  T = T, MAP = MAP, TL = TL, MI = MI, MSPC = MSPC, AU = AU, FS = FS,
  -- the settings list the tile sets on the card; the pages use the same list
  scanTiles = function() tileSets = TL.scan() return tileSets end,
}
