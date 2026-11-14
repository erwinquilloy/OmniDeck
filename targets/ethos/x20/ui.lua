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
    3 MSGS  - status messages; scroll with the wheel or by dragging. In the cycle for ArduPilot
              (setting "Messages page": Auto = ArduPilot only, On, Off)
    4 SUMMARY - last flight; opens on disarm. In the cycle only with "Flight stats page" On
    5 CHECK - sensor check; in the cycle only with "Sensor check page" On
    6 PARAMS - ArduPlane parameters over S.Port / F.Port (params.lua); only with "Params page" On
]]

local VERSION = "0.4.test"

local function need(name) return assert(loadfile((OD_DIR or "") .. name))() end
local T = need("telem.lua")
local MAP = need("map.lua")
local HUD = need("hud.lua")
local TL = need("tiles.lua")
-- OpenTX: no missions (no route on the map, no INAV mission download). OpenTX gives a widget
-- half of EdgeTX's Lua budget, and the route was the heaviest part of its map page; the two
-- modules are not loaded there at all, which also saves their memory. The next waypoint from
-- ArduPilot's telemetry (marker and WP line) is drawn by map.lua and stays.
local MI, MSPC
if OD_OTX then
  local nop = function() end
  MI = { init = nop, update = nop, setInav = nop, loadFile = nop, clearLearned = nop,
         current = function() return nil, nil end, listFiles = function() return {} end,
         fileError = function() return nil end }
  MSPC = { wakeup = nop, restart = nop, state = function() return "off" end, active = function() return nil end,
           waypoints = function() return {} end, debug = function() return "" end }
else
  MI = need("mission.lua")
  MSPC = need("mspclient.lua")
end
local FS = need("summary.lua")
local AU = need("audio.lua")
MI.init(T)
-- PARAMS page: params.lua and its list are loaded the first time the page is opened, so a
-- radio that never uses it carries none of it
local PR = nil
local paramsErr, paramsRetryAt = nil, 0   -- the last failed load of params.lua (see params())
local perf = { p = 0, pAll = 0, w = 0, wAll = 0, at = 0 }   -- paint / wakeup ms (perfNote, page 5)
local function params()
  -- params.txt (one shared file next to the widget) adds rows to the built-in list
  if not PR then
    -- kept only once it is fully set up: a load or init that fails (a file, the radio's Lua
    -- memory) is tried again next time and shows its own error, not a half-made module's
    -- (X20S 2026-11-14: "params.lua:770 attempt to index a nil value (upvalue 'T')")
    -- A failure is kept and raised again (shown on the red error line by the page that asked)
    -- and the load is tried again only every 10 s: reloading a large file on every update
    -- could stall the radio.
    if paramsErr and os.clock() < paramsRetryAt then error(paramsErr, 0) end
    local ok, p = pcall(function()
      local m = need("params.lua")
      m.init(T, need("plist.lua"), (OD_ROOT or "/scripts/omnideck/") .. "params.txt")
      m.onMission = MI.setAp   -- ArduPilot mission download (Stratos firmware) -> the map
      return m
    end)
    if not ok then
      paramsErr, paramsRetryAt = "params load: " .. tostring(p), os.clock() + 10
      error(paramsErr, 0)
    end
    PR, paramsErr = p, nil
  end
  return PR
end
local ED = nil   -- mission editor (medit.lua), see editor() below COL

-- the module, with this widget's "Edit in flight" choice (1 = gains and trim)
local function paramsFor(w)
  local p = params()
  p.flightEdit = w.flightEdit == 1
  p.missionOn = w.apMission == 1
  return p
end

local PAGE_SUMMARY = 4
local SUM_SHOW_S = 15    -- the flight summary opened by the disarm closes to main after this
local PAGE_CHECK = 5     -- sensor check: what each telemetry lookup returns on this radio
local PAGE_PARAMS = 6    -- parameters (S.Port / F.Port to ArduPilot)
local ORIENT = { [0] = "north", [1] = "heading" }

-- round to a pixel; where Lua time is short (EdgeTX) the radio's own floor() is used directly
-- a NaN or infinite value (bad sensor data) would stop paint() on Ethos: drawn at 0 instead
-- test41: Ethos too. The rounding helper this was (floor, then NaN and infinity tests) was half of
-- the main page's Lua time on an X18; bad telemetry is now checked once per update where it comes
-- in (H.draw), and coordinates floor straight away as EdgeTX's always did (at most 1 px apart)
local I = math.floor
-- displayed numbers: rounded to the nearest whole number on Ethos (NaN/inf shown as 0), as I() did
-- before test41; EdgeTX/OpenTX floor them as they always did. A few calls per update, so not I().
local R = OD_LITE and math.floor or function(v) v = math.floor(v + 0.5) if v ~= v or v == math.huge or v == -math.huge then return 0 end return v end

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

-- the unit helpers for the current settings, built again only when a unit setting changes
local function unitsBuild(w)
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
      return ft < 5279.5 and string.format("%dft", R(ft)) or string.format("%.2fmi", ft / 5280)
    end
    return m < 999.5 and string.format("%dm", R(m)) or string.format("%.2fkm", m / 1000)
  end
  local function altF(m)
    if m == nil then return "--" end
    if au.lbl == "ft" then return string.format("%dft", R(m * 3.28084)) end
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
local function units(w)
  local key = (w.spdUnit or 0) * 100 + (w.altUnit or 0) * 10 + (w.effUnit or 0)
  if w.unitsKey ~= key or w.unitsT == nil then w.unitsKey, w.unitsT = key, unitsBuild(w) end
  return w.unitsT
end

-- ---------------------------------------------------------------- helpers
local function srcOrNil(v)
  if v == nil then return nil end
  if type(v) == "userdata" or type(v) == "table" then   -- table: an EdgeTX/OpenTX source made by main.lua
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
-- OpenTX 2.3 (set by etx.lua): 10,000 Lua instructions per screen update, and filled shapes are
-- drawn in Lua there, so the main page is kept lighter (no minimap, outline arrows)
local OTX = OD_OTX

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
local freshStart   -- defined with the alarms below
local function create()
  -- another model selected: clean telemetry state, and the welcome again (as Yaapu). Ethos
  -- re-creates the widget when a model is picked, so the switch is seen here; the 1 s check in
  -- wakeup then finds nothing new, which is why test41 stayed silent after a switch
  if T.checkModel() then freshStart(nil) AU.greetAgain() end
  return {
    modelName = T.modelName(),   -- top bar; widgets are re-created when another model is picked
    page = 1, level = 4,
    -- settings
    linkMode = T.LINK_AUTO, orient = 0, zoomMode = 0, zoomSource = nil,
    spdUnit = 0, altUnit = 0, startPage = 1, trail = 1,
    tileSet = "", tz = nil, missionFile = "", inavWp = 0, sumAuto = 1, voice = "off", batCap = 0, effUnit = 0, beep = 1,
    logoFile = "omnideck.png",   -- main page logo (test41)
    topPanel = 0,                -- main page top-right panel: see panelMode() (test42)
    msgPage = 0, statsPage = 0, checkPage = 0, paramsPage = 0, flightEdit = 0, apMission = 0,   -- page cycle (test42): see pageOn()
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

-- INAV and Betaflight send no throttle in their telemetry (CRSF or S.Port: checked in both
-- crsf.c and smartport.c), so for them the THR block shows the radio's throttle stick, as iNav
-- LuaTelemetry reads it (getFieldInfo("thr")). It is the pilot's command, not the motor: in INAV's
-- automatic modes (RTH, cruise, launch, failsafe) the two differ. The label stays THR (user's
-- choice; "THR STK" crowded out the efficiency note on the X18). ArduPilot sends its real throttle
-- output in 0x5001 (VFR_HUD throttle = CTUN.ThO).
local thrSrc = nil
local function stickThr()
  if thrSrc == nil then
    local ok, src = pcall(system.getSource, "Throttle")
    if ok and src then
      -- a lookup by name can hand back another source (X18 + TBS gave the GPS): keep it only if
      -- its name says throttle
      local okN, n = pcall(function() return src:name() end)
      if not (okN and type(n) == "string" and string.find(string.lower(n), "thr", 1, true)) then src = nil end
    end
    thrSrc = (ok and src) or false
  end
  if not thrSrc then return nil end
  local ok, v = pcall(function() return thrSrc:value() end)
  if not ok or type(v) ~= "number" then return nil end
  return math.max(0, math.min(100, math.floor((v + 1024) / 20.48 + 0.5)))   -- -1024..1024 -> 0..100 %
end

local mid = {}   -- top bar middle layout, kept until its inputs change
local barTxt = {}                          -- top bar right side: texts kept until their values change
local barParts = { {}, {}, {}, {} }        -- and the (text, colour) slots, reused each update
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

  -- right side: GPS, link. Each text is made again only when its value changes, into tables
  -- kept from one update to the next
  local c = barTxt
  local fix, sats, plus = s.fix or 0, s.sats or 0, s.satsPlus == true
  if fix ~= c.fix or sats ~= c.sats or plus ~= c.plus then
    c.fix, c.sats, c.plus = fix, sats, plus
    c.gps = string.format("%s %d%s", fix >= 3 and "3D" or (fix == 2 and "2D" or "NoFix"), sats, plus and "+" or "")
  end
  local lq = s.lq and math.floor(s.lq)
  if lq ~= c.lq then c.lq = lq c.lqT = lq and string.format("LQ %d", lq) end
  local rs = s.rssi and math.floor(s.rssi)
  if rs ~= c.rs then c.rs = rs c.rsT = rs and string.format("RSSI %d", rs) end
  local parts, n = barParts, 0
  local function add(t, cl) n = n + 1 local p = parts[n] p[1], p[2] = t, cl end
  add(c.gps, fix >= 3 and COL.ok or COL.warn)
  if lq then add(c.lqT, lq >= 70 and COL.ok or (lq >= 40 and COL.warn or COL.bad)) end
  if rs then add(c.rsT, COL.txt) end
  if s.failsafe or s.ekfBad then add(s.ekfBad and "EKF" or "FS", COL.bad) end
  local rx = x + W - 6
  for i = n, 1, -1 do
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

-- OpenTX, over the bitmap of the fixed layer: only what changes (bar fill, note, value). The
-- full tile() above stays untouched, so EdgeTX and Ethos pay nothing for this.
-- Font heights and label widths never change, so they are measured once (OpenTX's text sizes
-- are estimates from the font anyway).
local fontH, labelW = {}, {}
local function lineH(f)
  local v = fontH[f]
  if v == nil then lcd.font(f) local _, h = lcd.getTextSize("0") v = h fontH[f] = v end
  return v
end
local function tileLive(x, y, w, h, label, value, color, fVal, fLbl, bar, note, inset)
  if bar then
    h = h - 7
    lcd.color(COL.dim)
    lcd.drawFilledRectangle(I(x + 4), I(y + h + 1), I((w - 8) * bar), 4)
  end
  local lh = lineH(fLbl)
  if note then
    lcd.font(fLbl)
    local lw = labelW[label]
    if lw == nil then lw = lcd.getTextSize(label) labelW[label] = lw end
    if lw + lcd.getTextSize(note) + 10 <= w then
      lcd.color(COL.dim)
      lcd.drawText(I(x + w - 4), I(y + 2), note, RIGHT)
    end
  end
  local vh = lineH(fVal)
  lcd.font(fVal)
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

-- live: OpenTX over the bitmap (no background or outline); outline: the export (only those)
local function battGauge(x, y, w, h, s, fVal, alarmV, live, outline)
  local pad, nubW = 6, math.max(4, I(w * 0.03))
  local bx, by, bw, bh = x + pad, y + pad, w - 2 * pad - nubW, h - 2 * pad
  if not live then   -- background and battery outline; OpenTX (live) has them in the bitmap
    lcd.color(COL.tile)
    lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
    lcd.color(COL.txt)
    lcd.drawRectangle(I(bx), I(by), I(bw), I(bh))
    lcd.drawFilledRectangle(I(bx + bw), I(by + bh * 0.3), I(nubW), I(bh * 0.4))
    if outline then return end
  end
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

local flightClock = { sec = nil, txt = "--" }   -- FLIGHT TIME text, remade when the second changes
-- OpenTX: the blocks' fixed layer (backgrounds, labels, bar tracks, battery outline) as one bitmap
-- per screen size and speed unit, made by tools/sim_edgetx.py --otx-panels from this same code;
-- one drawBitmap instead of about 20 drawing calls. Missing file: the blocks are drawn in full.
local panelBmps = {}
local function panelBitmap(u)
  local W, H = lcd.getWindowSize()
  local key = W .. "x" .. H .. "_" .. string.gsub(u.spdLbl, "[^%w]", "")
  local b = panelBmps[key]
  if b == nil then
    local ok, bmp = pcall(lcd.loadBitmap, (OD_ROOT or "") .. "otx/panel_" .. key .. ".png")
    b = (ok and bmp) or false
    panelBmps[key] = b
  end
  return b or nil
end
local blockItems = { {}, {}, {}, {}, { gauge = true }, {}, {}, {} }   -- the 8 blocks, refilled each update
-- OpenTX: six blocks, without ALT and AS / GS (the HUD has both): its Lua budget is
-- half of EdgeTX's, and the rest get taller blocks (2 x 3)
local otxBlocks = { blockItems[1], blockItems[2], blockItems[5], blockItems[6], blockItems[7], blockItems[8] }
-- layer: nil = all, "fixed" / "live" as for tile()
local function tiles(x, y, w, h, s, u, fVal, fLbl, layer)
  if OTX and layer == nil then
    local bmp = panelBitmap(u)
    if bmp then lcd.drawBitmap(I(x), I(y), bmp) layer = "live" end
  end
  -- flight in progress, or the last one until the next arming
  local f = FS.live()
  -- the block list is filled in place each update (no new tables)
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
  local items = blockItems
  local it = items[1]   -- HOME carries the total distance flown as its note (max distance from home is in the summary)
  it[1], it[2], it[3], it[4] = "HOME", u.distF(s.homeDist), COL.txt, nil
  it[5] = (f and f.dist) and ("TOT " .. u.distF(f.dist)) or nil
  it = items[2]
  it[1], it[2], it[3], it[4], it[5] = "FLIGHT TIME", fts, (ft and not running) and COL.dim or COL.txt, nil, nil
  if not OTX then
    it = items[3]
    it[1], it[2], it[3], it[4], it[5] = "ALT", s.alt and (string.format("%d", R(u.alt(s.alt))) .. u.altLbl) or "--", COL.txt, nil, nil
    it = items[4]
    if s.aspd then
      it[1] = "AS / GS " .. u.spdLbl
      it[2] = string.format("%d / %s", R(u.spd(s.aspd)), s.gspd and string.format("%d", R(u.spd(s.gspd))) or "--")
    else   -- no airspeed (no pitot over mLRS, Betaflight): groundspeed alone
      it[1] = "GS " .. u.spdLbl
      it[2] = s.gspd and string.format("%d", R(u.spd(s.gspd))) or "--"
    end
    it[3], it[4], it[5] = COL.txt, nil, nil
  end
  it = items[6]
  it[1], it[2] = "USED", s.mah and string.format("%dmAh", R(s.mah)) or "--"
  it[3], it[4], it[5] = (s.cap and s.cap > 0 and s.mah and s.mah > 0.8 * s.cap) and COL.warn or COL.txt, nil, nil
  it = items[7]
  it[1], it[2], it[3], it[4] = "CURR", s.curr and string.format("%.1fA", s.curr) or "--", COL.txt, nil
  it[5] = (f and f.maxCurr) and string.format("MAX %.1fA", f.maxCurr) or nil
  it = items[8]
  it[1], it[2], it[3] = "THR", s.thr and string.format("%d%%", s.thr) or "--", COL.txt
  it[4], it[5] = math.min(1, math.abs(s.thr or 0) / 100), u.eff(f)
  if OTX then items = otxBlocks end
  local cols = 2
  local rows = math.ceil(#items / cols)
  local gap = 3
  local tw, th = (w - gap) / cols, (h - (rows - 1) * gap) / rows
  for i, it in ipairs(items) do
    local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + c * (tw + gap), y + r * (th + gap)
    if it.gauge then
      if not layer then battGauge(tx, ty, tw, th, s, fVal, u.alarmV)
      elseif layer == "live" then battGauge(tx, ty, tw, th, s, fVal, u.alarmV, true)
      else battGauge(tx, ty, tw, th, s, fVal, nil, false, true) end   -- export: outline only
    else
      local inset = 0
      if not layer then tile(tx, ty, tw, th, it[1], it[2], it[3], fVal, fLbl, it[4], it[5], inset)
      elseif layer == "live" then tileLive(tx, ty, tw, th, it[1], it[2], it[3], fVal, fLbl, it[4], it[5], inset)
      else tile(tx, ty, tw, th, it[1], "", nil, fVal, fLbl, it[4] and 0, nil, 0) end   -- export
    end
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
local NO_LIST = not TL.canList()     -- OpenTX: tile sets are found by probing (wakeup)
local function activeTileSet(w)
  if w.tileSet == nil or w.tileSet == "" then return nil end
  if tileSets == nil then tileSets = TL.scan() end
  for _, ts in ipairs(tileSets) do if ts.label == w.tileSet then return ts end end
  return nil
end

-- last good GPS position, in memory only (test43): with no fix (GPS or link lost, the aircraft
-- switched off after landing) the map centres there and shows it as LAST, so the tile set still
-- shows. A model switch clears it (freshStart) and a radio restart starts without one: each boot
-- is a fresh script. test42 and earlier kept it in lastpos.txt, which is no longer read or written.
local lastPos = nil

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

local function rememberPos(s)
  if s.lat and (s.fix or 0) >= 3 then lastPos = { s.lat, s.lon } end
end

local function mapCenter()
  local s = T.s
  if s.lat then return nil end
  if lastPos then return lastPos end
  if s.homeLat then return { s.homeLat, s.homeLon } end
  return nil
end

-- mission editor (medit.lua): EdgeTX TX16S / MK3 and the X20 family only (big touch screens),
-- loaded the first time EDIT is tapped
local function editor()
  if not ED then ED = need("medit.lua") ED.init(MAP, params(), COL) end
  return ED
end
local function editAllowed(w, W, H)
  return w.apMission == 1 and T.s.fc == "ArduPilot" and W >= 480 and H >= 272
end

local function mapOpts(w, mini)
  local ts = activeTileSet(w)
  local mis = MI.current()
  return { level = w.level, orient = ORIENT[w.orient] or "north", mini = mini, trail = w.trail == 1,
           homeView = w.zoomMode == 1, windScale = units(w).k,
           home = (w.zoomMode == 1 and T.s.homeLat and not (ED and ED.active)) and { T.s.homeLat, T.s.homeLon } or nil,
           focus = (ED and ED.active) and ED.focus() or nil,   -- editing: centred on the selected item
           tiles = ts and TL or nil, tz = ts and w.tz or nil,
           mission = (not (ED and ED.active)) and mis or nil, activeWp = T.s.wpNum, center = mapCenter() }
end

-- A Lua error in paint() leaves the screen half drawn (Ethos shows nothing else). Each part runs
-- on its own, so one failing part leaves the rest of the screen, and the first error is shown
-- in red on the screen for a tester to photograph (EdgeTX/OpenTX also keep it in error.log).
-- Ethos: its per-update Lua limit ("Max instructions count reached") is raised as a Lua error to
-- stop the script. It is never caught here: re-raised at once, so Ethos ends the update the way
-- it expects (Yaapu and the INAV dashboard never catch it either; test39 drew on after it).
-- Nor is anything written to the SD card from paint on Ethos: a file call that stalls can't be
-- stopped by that limit, and an X18 froze (screen dead, RF working) after test39 had logged 88
-- errors, each one a write made in the middle of a screen update.
local ERR_FILE = (OD_ROOT or "/scripts/omnideck/") .. "error.log"
local paintErr, loggedErr = nil, {}
local limitHits = 0         -- Ethos limit hits this session (page 5)
local function safe(part, fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then return end
  if not OD_LITE and string.find(tostring(err), "Max instructions", 1, true) then
    limitHits = limitHits + 1
    paintErr = paintErr or (part .. ": Lua limit")
    error(err, 0)
  end
  local W, H = lcd.getWindowSize()
  lcd.setClipping(0, 0, W, H)          -- the map leaves its clipping on when it fails
  local msg = part .. ": " .. tostring(err)
  paintErr = paintErr or msg
  if OD_LITE and not loggedErr[msg] then
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

-- main page layout, shared with the OpenTX panel bitmap export so both line up exactly
local function mainLayout(W, H)
  local barH = R(H * 0.09)
  local msgH = R(H * 0.075)
  local bodyY, bodyH = barH, H - barH - msgH
  local hudW = R(W * 0.56)
  local rx, rw = hudW + 3, W - hudW - 3
  -- OpenTX: no minimap (the Map page has the map); the data blocks take the whole panel
  local mapH = OTX and 0 or math.min(rw, R(bodyH * 0.46))
  return barH, msgH, bodyY, bodyH, hudW, rx, rw, mapH
end

-- Ethos on a screen 480 px wide or less (X18): no minimap on the main page, a logo in its place.
-- The minimap was the part whose cost jumped from update to update (trail, home, arrow) and the
-- X18 ran out of its per-update Lua limit; the map page still has the full map. (test41)
-- The logo is a per-model setting (any PNG in logos/, "" = none), loaded in wakeup (a file read),
-- never in paint; a picture bigger than the panel is scaled down by the radio when it is drawn.
local LOGO_DIR = (OD_ROOT or "/scripts/omnideck/") .. "logos/"
local logo = { file = nil, bmp = nil, w = 0, h = 0 }
local function noMinimap(W) return not OD_LITE and W <= 480 end
local function logoFiles()
  if not (system and system.listFiles) then return {} end
  local ok, entries = pcall(system.listFiles, LOGO_DIR)
  if not ok or type(entries) ~= "table" then return {} end
  local out = {}
  for _, n in ipairs(entries) do
    if type(n) == "string" and string.match(string.lower(n), "%.png$") then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end
local function loadLogo(file)
  if file == logo.file then return end
  logo.file, logo.bmp, logo.w, logo.h = file, nil, 0, 0
  if file == nil or file == "" then return end
  local ok, bmp = pcall(lcd.loadBitmap, LOGO_DIR .. file)
  if ok and bmp then
    local okW, bw = pcall(function() return bmp:width() end)
    local okH, bh = pcall(function() return bmp:height() end)
    logo.bmp, logo.w, logo.h = bmp, okW and bw or 0, okH and bh or 0
  end
end
local function logoPanel(x, y, w, h)
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  local b = logo.bmp
  if not b or logo.w <= 0 or logo.h <= 0 then return end
  -- fitted to the panel's width and height (8 px margin), proportions kept: a wide logo such
  -- as stratos_title.png (196 x 115) uses the width instead of being sized to the height
  local k = math.min(1, (w - 16) / logo.w, (h - 16) / logo.h)
  local dw, dh = I(logo.w * k), I(logo.h * k)
  local bx, by = I(x + (w - dw) / 2), I(y + (h - dh) / 2)
  if k < 1 then
    if not pcall(lcd.drawBitmap, bx, by, b, dw, dh) then lcd.drawBitmap(bx, by, b) end
  else
    lcd.drawBitmap(bx, by, b)
  end
end

-- the panel above the data blocks (setting "Main page top-right panel", test42): 0 minimap,
-- 1 home arrow, 2 radar (as iNav LuaTelemetry's), 3 the OmniDeck logo, 4 the logo file picked in
-- the settings (Stratos, or the pilot's own PNG in /scripts/omnideck/logos/)
local function panelMode(w, W)
  local p = w.topPanel or 0
  if p == 1 then return "arrow" elseif p == 2 then return "radar"
  elseif p == 3 then return "omni" elseif p == 4 then return "logo" end
  return "map"
end
local radarO = {}
local function radarOpts(w, u)
  local f = FS.live()
  radarO.orient, radarO.distF = ORIENT[w.orient] or "north", u.distF
  radarO.maxDist = f and f.maxHome or nil
  return radarO
end

-- "Home arrow": the arrow of the OmniDeck mark (docs/logo/omnideck-mark.svg: tip 26 ahead of the
-- centre, wings 24 back and 18 out, notch 13 back), pointing to home relative to the nose (up =
-- home ahead). Before arming, or with no home yet, the OmniDeck logo itself.
local ARROW_FILL = lcd.RGB(242, 245, 248)
local function homePanel(x, y, w, h, s)
  if not (s.armed and s.homeBrg and s.yaw and s.homeDist and s.homeDist > 0) then
    logoPanel(x, y, w, h)
    return
  end
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  local k = math.min(w, h) * 0.8 / 52            -- the arrow is 50 units long
  local cx, cy = x + w / 2, y + h / 2
  local a = math.rad(s.homeBrg - s.yaw)
  local sa, ca = math.sin(a) * k, math.cos(a) * k
  -- (forward, side) in the mark's units, centred on the arrow's length (26 ahead, 24 back)
  local function px(f, sd) return cx + sa * (f - 1) + ca * sd end
  local function py(f, sd) return cy - ca * (f - 1) + sa * sd end
  lcd.color(ARROW_FILL)
  lcd.drawFilledTriangle(I(px(26, 0)), I(py(26, 0)), I(px(-24, -18)), I(py(-24, -18)), I(px(-13, 0)), I(py(-13, 0)))
  lcd.drawFilledTriangle(I(px(26, 0)), I(py(26, 0)), I(px(-13, 0)), I(py(-13, 0)), I(px(-24, 18)), I(py(-24, 18)))
end

local function pageMain(w, W, H, s, u)
  local fBig, fMid, fSmall = fontFor(H)
  local barH, msgH, bodyY, bodyH, hudW, rx, rw, mapH = mainLayout(W, H)
  -- map first: on EdgeTX a tile can hang over the map's edge, and what follows covers it
  local pm = panelMode(w, W)
  if pm == "arrow" then homePanel(rx, bodyY, rw, mapH, s)
  elseif pm == "logo" or pm == "omni" then logoPanel(rx, bodyY, rw, mapH)
  elseif pm == "radar" then safe("radar", MAP.radar, rx, bodyY, rw, mapH, s, radarOpts(w, u))
  elseif not OTX then safe("map", MAP.draw, rx, bodyY, rw, mapH, s, mapOpts(w, true)) end
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(hudW, bodyY, 3, bodyH)
  lcd.drawFilledRectangle(rx, bodyY + mapH, rw, bodyH - mapH)
  safe("bar", topBar, w, 0, 0, W, barH, s, u, H)
  safe("hud", HUD.draw, 0, bodyY, hudW, bodyH, s, u)
  if s.armed == false and T.alive() then safe("arm", HUD.armStatus, 0, bodyY, hudW, bodyH, s) end
  safe("tiles", tiles, rx, bodyY + mapH + 3, rw, bodyH - mapH - 3, s, u, fBig, fSmall)
  safe("msg", msgLine, 0, H - msgH, W, msgH, s, fMid)
end

-- tools/sim_edgetx.py --otx-panels: the blocks' fixed layer over the panel colour, at the main
-- page's position; returns the area to cut out as the bitmap
local function exportPanel(w, W, H)
  local fBig, fMid, fSmall = fontFor(H)
  local barH, msgH, bodyY, bodyH, hudW, rx, rw, mapH = mainLayout(W, H)
  local x, y, pw, ph = rx, bodyY + mapH + 3, rw, bodyH - mapH - 3
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(x, y, pw, ph)
  tiles(x, y, pw, ph, T.s, units(w), fBig, fSmall, "fixed")
  return x, y, pw, ph
end

-- the HUD's fixed layer alone, for the OpenTX overlay bitmap (tools/sim_edgetx.py --otx-panels);
-- returns the HUD box
local function exportHud(w, W, H)
  local barH, msgH, bodyY, bodyH, hudW = mainLayout(W, H)
  HUD.drawFixed(0, bodyY, hudW, bodyH)
  return 0, bodyY, hudW, bodyH
end

local function pageMap(w, W, H, s, u)
  local fBig, fMid, fSmall = fontFor(H)
  local barH = R(H * 0.09)
  -- bottom strip for the GPS position, below the map so it never covers it
  lcd.font(fMid)
  local _, ch = lcd.getTextSize("0")
  local stripH = ch + 6
  local mapH = H - barH - stripH
  -- editing: the map (and its zoom buttons) ends above the editor's tall button bar
  if ED and ED.active then mapH = H - barH - (math.max(ch + 10, math.floor(H * 0.14)) + 4) end
  w.btns = MAP.draw(0, barH, W, mapH, s, mapOpts(w, false))
  topBar(w, 0, 0, W, barH, s, u, H)
  if ED and ED.active then
    ED.paint(W, H, barH, s, u, fMid, fSmall)
    return
  end
  w.editBtn = nil
  if editAllowed(w, W, H) then
    lcd.font(fMid)
    local tw, th = lcd.getTextSize("EDIT")
    local bw, bh = tw + 20, th + 10
    -- left of the zoom buttons and clear of their enlarged tap area (a quarter of their size)
    local zx = (w.btns and w.btns.minus) and (w.btns.minus.x - math.floor(w.btns.minus.w / 4) - 6) or (W - 8)
    local bx, by = zx - bw, H - stripH - bh - 6
    lcd.color(COL.tile)
    lcd.drawFilledRectangle(bx, by, bw, bh)
    lcd.color(COL.home)
    lcd.drawRectangle(bx, by, bw, bh)
    lcd.drawText(bx + 10, by + 5, "EDIT")
    w.editBtn = { x = bx, y = by, w = bw, h = bh }
    if w.editMsg and os.clock() - (w.editMsgAt or 0) < 4 then
      local mw = lcd.getTextSize(w.editMsg)
      lcd.color(COL.panel)
      lcd.drawFilledRectangle(W - mw - 16, by - th - 8, mw + 12, th + 6)
      lcd.color(COL.warn)
      lcd.drawText(W - mw - 10, by - th - 5, w.editMsg)
    end
  end
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
    string.format("ALT %s", s.alt and string.format("%d%s", R(u.alt(s.alt)), u.altLbl) or "--"),
    string.format("%s %s", s.aspd and "AS" or "GS", (s.aspd or s.gspd) and string.format("%d%s", R(u.spd(s.aspd or s.gspd)), u.spdLbl) or "--"),
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
  local barH = R(H * 0.09)
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
-- Ethos: how long paint() and wakeup() take (ms), worst in the last 10 s and since power-up, for
-- page 5: a tester can tell how close the radio runs to its limit instead of waiting for it
local function perfNote(isPaint, t0)
  local now = os.clock()
  local ms = (now - t0) * 1000
  if now - perf.at >= 10 then perf.at, perf.p, perf.w = now, 0, 0 end
  if isPaint then
    if ms > perf.p then perf.p = ms end
    if ms > perf.pAll then perf.pAll = ms end
  else
    if ms > perf.w then perf.w = ms end
    if ms > perf.wAll then perf.wAll = ms end
  end
end

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
  if not OD_LITE then
    lcd.color(limitHits > 0 and COL.bad or COL.ok)
    lcd.drawText(4, y, string.format("Lua ms: draw %.0f (max %.0f)  bg %.0f (max %.0f)  limit hits %d",
      perf.p, perf.pAll, perf.w, perf.wAll, limitHits))
    y = y + th
  end
  lcd.color(COL.txt)
  lcd.drawText(4, y, T.rawCheck())
  y = y + th
  -- S.Port: passthrough frames per reader and app ID (X18 + R9 F.Port, test38)
  if T.sportDiag and s.link ~= "CRSF" then
    local d1, d2 = T.sportDiag()
    lcd.color(COL.home)
    lcd.drawText(4, y, d1) y = y + th
    if d2 then lcd.drawText(4, y, d2) y = y + th end
  end
  if PR then
    lcd.color(COL.home)
    lcd.drawText(4, y, PR.debug())   -- includes "mission: …" when the download is on
    y = y + th
  end
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
  -- rows that don't fit scroll (wheel, or drag); the header lines above stay put
  local top = y
  local fit = math.max(1, math.floor((H - top) / th))
  local maxOff = math.max(0, #rows - fit)
  w.chkScroll = math.max(0, math.min(maxOff, math.floor(w.chkScroll or 0)))
  w.chkMax, w.chkRowH = maxOff, th
  for i = w.chkScroll + 1, math.min(#rows, w.chkScroll + fit) do
    local r = rows[i]
    lcd.color(r.name == "not found" and COL.bad or COL.txt)
    lcd.drawText(cx[1], y, r.key)
    lcd.drawText(cx[2], y, r.query)
    lcd.drawText(cx[3], y, r.name)
    lcd.drawText(cx[4], y, r.value)
    lcd.drawText(cx[5], y, r.unit)
    y = y + th
  end
  if maxOff > 0 then
    -- scrollbar: thumb size = visible share, position = how far down the list
    local trackH = H - top - 2
    local thumbH = math.max(12, I(trackH * fit / #rows))
    local thumbY = top + I((trackH - thumbH) * w.chkScroll / maxOff)
    lcd.color(COL.dim)
    lcd.drawFilledRectangle(W - 5, top, 3, trackH)
    lcd.color(COL.txt)
    lcd.drawFilledRectangle(W - 6, thumbY, 5, thumbH)
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
  local barH = R(H * 0.09)
  topBar(w, 0, 0, W, barH, s, u, H)
  -- the flight in progress (the stats page is in the cycle with "Flight stats page" On, so it can
  -- be looked at in flight), else the last one; nothing yet before the first flight
  local f = FS.live()
  if not f then
    lcd.font(fMid)
    lcd.color(COL.dim)
    lcd.drawText(I(W / 2), I(H / 2), "No flight yet", CENTERED)
    return
  end
  local live = f ~= FS.last()
  if not live then f.shown = true end
  local dist, alt, spd = u.distF, u.altF, u.spdF
  -- average for the whole flight, unlike the live figure in the THR block
  local perKm = (f.used and f.dist > 100) and f.used / (f.dist / 1000) or nil
  local items = {
    { live and "FLIGHT TIME (NOW)" or "FLIGHT TIME", fmtTime(live and (FS.timer(os.clock()) or 0) or f.time) },
    { "DISTANCE", dist(f.dist) },
    { "MAX HOME", dist(f.maxHome) },
    { "MAX ALT", alt(f.maxAlt) },
    { "MAX GSPD " .. u.spdLbl, spd(f.maxGspd) },
    { "MAX AS " .. u.spdLbl, spd(f.maxAspd) },
    { "USED", f.used and string.format("%dmAh", R(f.used)) or "--",
      (s.cap and s.cap > 0 and f.used and f.used > 0.8 * s.cap) and COL.warn or nil },
    { u.effLbl, u.effVal(perKm, f.voltN and f.voltSum / f.voltN) },
    { "MIN VOLT", f.minVolt and string.format("%.1fV", f.minVolt) or "--" },
    { "MAX CURR", f.maxCurr and string.format("%.1fA", f.maxCurr) or "--" },
    { f.minLq and "MIN LQ" or "MIN RSSI", (f.minLq or f.minRssi) and string.format("%d", R(f.minLq or f.minRssi)) or "--" },
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

-- ---------------------------------------------------------------- flight log
-- Each flight long enough for the summary is saved as a file of its own in logs/ next to the
-- scripts, named as the radio names its telemetry logs: <model>-<YYYY-MM-DD>-<HHMMSS>.txt
-- (<model>-001.txt and up with no clock). It holds the summary's figures, home, the last
-- position (to find the model) and the last messages. One write per landing, from wakeup: no SD
-- writes from paint (see safe() above). logs/ comes in the package; if it is missing, os.mkdir
-- makes it where the radio has one, else the file goes next to the scripts.
local LOG_ROOT = OD_ROOT or "/scripts/omnideck/"
local LOG_DIR = LOG_ROOT .. "logs/"
local LOG_MSGS = 10
-- the radio's date and time as os.date("*t") gives it, or nil when there is no clock
local function nowDate()
  local ok, d = pcall(os.date, "*t")
  if ok and type(d) == "table" and d.year then return d end
  return nil
end
local function exists(path)
  local ok, f = pcall(io.open, path, "r")
  if ok and f then f:close() return true end
  return false
end
-- a free file name in logs/: never overwrites an earlier flight
local function logName(model, d)
  local m = string.gsub(model or "", [=[[\/:*?"<>|]]=], "_")   -- characters a file name cannot hold
  if m == "" then m = "model" end
  if d then
    local base = string.format("%s-%04d-%02d-%02d-%02d%02d%02d", m, d.year, d.month, d.day, d.hour, d.min, d.sec)
    if not exists(LOG_DIR .. base .. ".txt") then return base .. ".txt" end
    for i = 2, 99 do
      local n = base .. "-" .. i .. ".txt"
      if not exists(LOG_DIR .. n) then return n end
    end
    return base .. "-99.txt"
  end
  for i = 1, 999 do
    local n = string.format("%s-%03d.txt", m, i)
    if not exists(LOG_DIR .. n) then return n end
  end
  return m .. "-999.txt"
end
local function logFlight(w, s, f)
  if not f then return end
  local u = units(w)
  local d = nowDate()
  local when = d and string.format("%04d-%02d-%02d %02d:%02d:%02d", d.year, d.month, d.day, d.hour, d.min, d.sec)
    or "date unknown"
  local model = T.modelName() or "?"
  local function pos(la, lo)
    if la and lo then return string.format("%.6f, %.6f", la, lo) end
    return "--"
  end
  local function num(fmt, v) return v and string.format(fmt, v) or "--" end
  local perKm = (f.used and f.dist > 100) and f.used / (f.dist / 1000) or nil
  local L = {
    "OmniDeck " .. VERSION .. " flight log",
    "Model          " .. model,
    "Date           " .. when,
    string.format("FC             %s, link %s", tostring(s.fc or "?"), tostring(s.link or "?")),
    "",
    "Flight time    " .. fmtTime(f.time),
    "Distance       " .. u.distF(f.dist),
    "Max home       " .. u.distF(f.maxHome),
    "Max alt        " .. u.altF(f.maxAlt),
    "Max GSPD       " .. u.spdF(f.maxGspd) .. " " .. u.spdLbl,
    "Max AS         " .. u.spdF(f.maxAspd) .. " " .. u.spdLbl,
    "Used           " .. num("%dmAh", f.used and R(f.used)),
    "Efficiency     " .. u.effVal(perKm, f.voltN and f.voltSum / f.voltN) .. " " .. u.effLbl,
    "Min volt       " .. num("%.2fV", f.minVolt),
    "Avg volt       " .. num("%.2fV", f.voltN and f.voltSum / f.voltN),
    "Max curr       " .. num("%.1fA", f.maxCurr),
    (f.minLq and "Min LQ         " or "Min RSSI       ") .. num("%d", (f.minLq or f.minRssi) and R(f.minLq or f.minRssi)),
    "Link lost      " .. (f.lost > 0 and fmtTime(f.lost) or "none"),
    "",
    "Home           " .. pos(s.homeLat, s.homeLon),
    "Last position  " .. pos(s.lat or f.lat, s.lon or f.lon),
  }
  local m = s.msgs
  if m and #m > 0 then
    L[#L + 1] = ""
    L[#L + 1] = "Messages (last " .. math.min(#m, LOG_MSGS) .. "):"
    for i = math.max(1, #m - LOG_MSGS + 1), #m do L[#L + 1] = "  " .. tostring(m[i].text) end
  end
  local text = table.concat(L, "\n") .. "\n"
  pcall(function()
    local name = logName(model, d)
    local ok, fh = pcall(io.open, LOG_DIR .. name, "w")
    if not (ok and fh) and os.mkdir then   -- no logs/ folder
      pcall(os.mkdir, string.sub(LOG_DIR, 1, -2))
      ok, fh = pcall(io.open, LOG_DIR .. name, "w")
    end
    if not (ok and fh) then ok, fh = pcall(io.open, LOG_ROOT .. name, "w") end
    if ok and fh then fh:write(text) fh:close() end
  end)
end

-- ---------------------------------------------------------------- alarms
-- Voltage, per cell, in two stages: low ("Low voltage", again every VOLT_REPEAT_S) and
-- critical ("Critical voltage", every CRIT_REPEAT_S). Each needs VOLT_HOLD_S below its
-- setting, so a dip under load doesn't count; critical takes over from low. Low altitude ("Terrain, pull up"):
-- armed, and only after the aircraft has been above the setting once, so the take-off and
-- the landing approach from below don't count; again every ALT_REPEAT_S while low.
local VOLT_HOLD_S, VOLT_REPEAT_S, CRIT_REPEAT_S, ALT_REPEAT_S = 5, 30, 15, 15
local alarm = { lowSince = nil, critSince = nil, voltStage = 0, voltSaid = -100, altArmed = false, altSaid = -100, cells = 0 }

-- A model switch is a fresh start (test43): T.checkModel() has cleared the telemetry, messages
-- included; this clears the rest - the trail, the flight in progress and the last flight's
-- summary, the flight time, the mission (learned waypoints, INAV download), the alarms and the
-- last position - so nothing of the old model stays on any page. A power-on starts fresh anyway.
freshStart = function(w)
  MAP.reset()
  FS.reset()
  MI.clearLearned()
  MI.setInav(nil)
  MI.setAp(nil)
  if ED then ED.stop() end
  MSPC.restart()
  if PR then PR.reset() end
  alarm.lowSince, alarm.critSince, alarm.voltStage, alarm.voltSaid = nil, nil, 0, -100
  alarm.altArmed, alarm.altSaid, alarm.cells = false, -100, 0
  flightClock.sec, flightClock.txt = nil, "--"
  lastPos = nil
  if w then
    w.inavWpN, w.linkUpAt = nil, nil
    if w.page == PAGE_SUMMARY then w.page = w.homePage or 1 end
    lcd.invalidate()
  end
end

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

-- what the PARAMS page borrows from this file
local PR_CTX = { COL = COL, fontFor = fontFor, topBar = topBar }

local function paint(w)
  local t0 = os.clock()
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
  elseif w.page == PAGE_PARAMS then safe("params", function() paramsFor(w).paint(w, W, H, s, u, PR_CTX) end)
  else safe("main", pageMain, w, W, H, s, u) end
  lostFrame(W, H)
  errorBanner(W, H)
  if not OD_LITE then perfNote(true, t0) end
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
  local t0 = os.clock()
  -- Ethos: another model is noticed within a second, as Yaapu does. create() alone was not
  -- enough: Ethos builds the new model's widget before model.name() changes (the old name stayed
  -- 2 s on an X18), so the old model's state was kept. A switch is a fresh start, welcome included.
  if not OD_LITE and os.clock() - (w.modelAt or -10) >= 1 then
    w.modelAt = os.clock()
    if T.checkModel() then freshStart(w) AU.greetAgain() end
    local n = T.modelName()
    if n ~= w.modelName then w.modelName = n end
  end
  T.wakeup(w.linkMode)
  local s = T.s
  -- ArduPilot sends BATT_CAPACITY; INAV and Betaflight don't, so the pilot enters it
  if s.fc ~= "ArduPilot" then s.cap = w.batCap > 0 and w.batCap or nil end
  -- INAV / Betaflight: THR is the throttle stick (they send no throttle; see stickThr)
  if s.fc and s.fc ~= "ArduPilot" then s.thr = stickThr() end
  -- EdgeTX / OpenTX: voice, flight summary and alarms take turns, one per update, so no
  -- update carries all three (each still runs about 3 times a second). All three work from the
  -- time, not from how often they are called (the summary adds up distance from positions, a
  -- trig sum), so this only delays a call-out by a fraction of a second.
  local nowc = os.clock()
  local runAU, runFS, runAL = true, true, true
  if OD_LITE then
    local k = (w.slowK or 0) % 3 + 1
    w.slowK = k
    runAU, runFS, runAL = k == 1, k == 2, k == 3
  end
  local flight = nil
  if runAU then AU.update(s, T.alive(), nowc) end
  if runFS then flight = FS.update(s, T.alive(), nowc, T.distBrg) end
  if flight == "done" then logFlight(w, s, FS.last()) end
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
    w.page = PAGE_SUMMARY
    w.sumOpenedAt = nowc
    lcd.invalidate()
  end
  -- the summary opened by the disarm goes back to the main page after SUM_SHOW_S, whether or not
  -- the stats page is in the cycle. Moving to another page first cancels it; the stats page
  -- opened by hand (Flight stats page On) stays.
  if w.page ~= PAGE_SUMMARY then
    w.sumOpenedAt = nil
  elseif w.sumOpenedAt and nowc - w.sumOpenedAt >= SUM_SHOW_S then
    w.sumOpenedAt = nil
    w.page = w.homePage or 1
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
  -- tiles load here, never in paint(): a load is a handle (decoded at its first draw), so a time budget
  if ts then TL.process() end   -- test43: ~25 ms or 10 tiles per wakeup (TL.process)
  MI.update(s)
  -- INAV mission download: only on a native (non-passthrough) link, after the
  -- link has been up for a few seconds; the client stops by itself if the FC is not INAV
  if not OD_OTX and w.inavWp == 1 and s.fc == "INAV/BF" and T.alive() then   -- OpenTX: no missions
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
  if w.page == PAGE_PARAMS then
    -- ArduPilot only: another flight controller (INAV / Betaflight) leaves the page
    if s.fc and s.fc ~= "ArduPilot" then w.page = 1 lcd.invalidate()
    else paramsFor(w).wakeup(s) end
  elseif w.apMission == 1 and s.fc == "ArduPilot" and T.alive() then
    -- ArduPilot mission download (Stratos firmware, MAVlite) on every other page
    paramsFor(w).missionWakeup(s)
    w.apMissionUsed = true
  end
  -- setting switched Off: the downloaded mission leaves the map (a mission file shows again)
  -- ... and so does a flight controller other than ArduPilot (INAV / Betaflight after a swap)
  local notAp = s.fc ~= nil and s.fc ~= "ArduPilot"
  if (w.apMission ~= 1 or notAp) and w.apMissionUsed then
    w.apMissionUsed = nil
    MI.setAp(nil)
    if PR then PR.missionReset() end
  end
  -- the mission editor is ArduPilot only: another flight controller closes it (an unsent mission is dropped)
  if notAp and ED and ED.active then ED.stop() lcd.invalidate() end
  if s.lat then MAP.addTrail(s.lat, s.lon, MAP.LEVELS[w.level]) end
  rememberPos(s)
  if runAL then checkAlarms(w, s, nowc) end
  -- no folder listing (OpenTX): look for a tile set by its files at the map's position
  if NO_LIST and (w.tileSet == nil or w.tileSet == "") then
    local lat, lon = s.lat, s.lon
    if not lat then local c = mapCenter() if c then lat, lon = c[1], c[2] end end
    local ts = TL.probe(lat, lon, os.clock())
    if ts then tileSets = { ts } w.tileSet = ts.label end
  end
  if lcd.isVisible == nil or lcd.isVisible() then
    local t = os.clock()
    if t - w.lastPaint >= 0.1 then
      w.lastPaint = t
      lcd.invalidate()
    end
  end
  if not OD_LITE then
    local pm = panelMode(w, (lcd.getWindowSize()))
    if pm == "logo" then loadLogo(w.logoFile) elseif pm == "omni" or pm == "arrow" then loadLogo("omnideck.png") end
    perfNote(false, t0)
  end
end

-- which pages a tap cycles through (test42). Main and map always; messages for ArduPilot (INAV
-- and Betaflight send none) unless set On or Off; the flight stats and the sensor check only
-- when switched on. The summary still opens by itself on disarm ("Flight summary on disarm").
local function pageOn(w, p)
  if p == 3 then
    local m = w.msgPage or 0
    if m == 1 then return true elseif m == 2 then return false end
    return T.s.fc ~= "INAV/BF"
  end
  if p == PAGE_SUMMARY then return w.statsPage == 1 end   -- On: always, in flight too (live)
  if p == PAGE_CHECK then return w.checkPage == 1 end
  -- ArduPilot only (MAVlite); before the FC is known it stays out of the cycle too
  if p == PAGE_PARAMS then return w.paramsPage == 1 and T.s.fc == "ArduPilot" end
  return true
end
local function nextPage(w)
  local p = w.page
  for _ = 1, PAGE_PARAMS do
    p = p % PAGE_PARAMS + 1
    if pageOn(w, p) then break end
  end
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

-- sensor check page: wheel right = further down the list
local function chkScrollBy(w, d)
  w.chkScroll = math.max(0, math.min(w.chkMax or 0, (w.chkScroll or 0) + d))
  lcd.invalidate()
end

local TAP_PX = 12   -- a touch that moves less than this is a tap, more is a drag

-- Map +/-: which button a point belongs to (-1 zoom in, 1 zoom out, nil none). The squares are
-- drawn about 8.5 mm wide (X18 49 px, X20 73 px), less than a fingertip, and a near miss counted
-- as a tap on the map, which turns the page (tester, X18, 2026-11-11). Each button now also takes
-- a quarter of its size around it, and the gap between the two is split at its middle.
local function zoomBtnAt(b, x, y)
  if not (b and b.plus and b.minus and x and y) then return nil end
  local p, m = b.plus, b.minus
  local pad = math.floor(p.w / 4)
  if x < p.x - pad or x > p.x + p.w + pad then return nil end
  local mid = (p.y + p.h + m.y) / 2
  if y >= p.y - pad and y < mid then return -1 end
  if y >= mid and y <= m.y + m.h + pad then return 1 end
  return nil
end

local function event(w, category, value, x, y)
  if category == EVT_TOUCH then
    if value == TOUCH_START then
      w.touchX, w.touchY, w.touchScroll, w.dragged = x, y, w.msgScroll or 0, false
      w.touchChk = w.chkScroll or 0
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
      -- sensor check: drag up to see the rows further down (like a phone)
      if w.dragged and w.page == PAGE_CHECK and w.chkRowH then
        local rows = math.floor((w.touchY - y) / w.chkRowH + 0.5)
        w.chkScroll = math.max(0, math.min(w.chkMax or 0, (w.touchChk or 0) + rows))
        lcd.invalidate()
      end
      return true
    end
    if value ~= TOUCH_END then return true end
    local dragged = w.dragged or (w.touchY and math.abs(y - w.touchY) > TAP_PX)
    local sx, sy = w.touchX, w.touchY
    w.touchX, w.touchY, w.dragged = nil, nil, false
    if dragged then return true end
    if w.page == 2 and ED and ED.active and ED.onButton(x, y) then
      ED.tap(T.s, x, y, (lcd.getWindowSize()))   -- the editor's buttons first (Done sits near zoom -)
      lcd.invalidate()
      return true
    end
    if w.page == 2 and w.btns then
      -- where the finger pressed counts first, then where it lifted
      local d = zoomBtnAt(w.btns, sx, sy) or zoomBtnAt(w.btns, x, y)
      if d then zoomStep(w, d) lcd.invalidate() return true end
    end
    if w.page == 2 and ED and ED.active then
      ED.tap(T.s, x, y, (lcd.getWindowSize()))
      lcd.invalidate()
      return true   -- while editing a tap never turns the page (Done leaves the editor)
    end
    if w.page == 2 and inBox(w.editBtn, x, y) then
      local ok, why = editor().start(T.s)
      if not ok then w.editMsg, w.editMsgAt = why, os.clock() end
      lcd.invalidate()
      return true
    end
    if w.page == 3 and inBox(w.msgLatestBtn, x, y) then
      w.msgScroll = 0 lcd.invalidate() return true
    end
    if w.page == PAGE_PARAMS then
      local r = paramsFor(w).tap(T.s, x, y)
      lcd.invalidate()
      if r ~= "next" then return true end
    end
    nextPage(w)
    return true
  end
  if category == EVT_KEY and w.page == 2 and ED and ED.active then
    local k = (value == KEY_ENTER_BREAK and "enter") or (value == KEY_ROTARY_LEFT and "left")
      or (value == KEY_ROTARY_RIGHT and "right") or (KEY_RTN_BREAK and value == KEY_RTN_BREAK and "back") or nil
    if k then ED.key(T.s, k) lcd.invalidate() return true end
  end
  if category == EVT_KEY and w.page == PAGE_PARAMS then
    local k = (value == KEY_ENTER_BREAK and "enter") or (value == KEY_ROTARY_LEFT and "left")
      or (value == KEY_ROTARY_RIGHT and "right") or (KEY_RTN_BREAK and value == KEY_RTN_BREAK and "back") or nil
    if k then
      local r = paramsFor(w).key(T.s, k)
      lcd.invalidate()
      if r == "next" then nextPage(w) return true end
      return r == true
    end
  end
  if category == EVT_KEY then
    if value == KEY_ENTER_BREAK then
      nextPage(w)
      return true
    elseif w.page == PAGE_SUMMARY and (value == KEY_ROTARY_LEFT or value == KEY_ROTARY_RIGHT) then
      return true
    elseif value == KEY_ROTARY_LEFT then
      -- messages page: the wheel scrolls (left = older); elsewhere it zooms
      if w.page == 3 then msgScrollBy(w, 1)
      elseif w.page == PAGE_CHECK then chkScrollBy(w, -1)
      else zoomStep(w, 1) lcd.invalidate() end
      return true
    elseif value == KEY_ROTARY_RIGHT then
      if w.page == 3 then msgScrollBy(w, -1)
      elseif w.page == PAGE_CHECK then chkScrollBy(w, 1)
      else zoomStep(w, -1) lcd.invalidate() end
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------- exports
return {
  VERSION = VERSION, create = create, paint = paint, wakeup = wakeup, event = event, nextPage = nextPage,
  exportPanel = exportPanel, exportHud = exportHud,
  T = T, MAP = MAP, TL = TL, MI = MI, MSPC = MSPC, AU = AU, FS = FS, logoFiles = logoFiles,
  editor = function() return ED end,   -- test harness: the mission editor, once opened
  -- the settings list the tile sets on the card; the pages use the same list
  scanTiles = function() tileSets = TL.scan() return tileSets end,
}
