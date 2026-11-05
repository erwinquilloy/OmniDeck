--[[
  OmniDeck on EdgeTX: an Ethos-style API for the shared modules (ui.lua, telem.lua, ...).

  The shared code is written against the Ethos Lua API. Here it is loaded with its
  own environment in which lcd, system, crsf, sport, os and io are adapters over the
  EdgeTX calls, so the radio's real globals stay untouched for other scripts.

  EdgeTX differences handled here:
    - no clipping: lines, rectangles, triangles and text are clipped in Lua
    - one telemetry queue each for CRSF and S.Port: frames are sorted into a
      passthrough queue and an MSP queue, as Ethos does with separate sensors
    - native sensors are read by their EdgeTX names, with the unit each sensor
      is set to in the model
    - timing comes from getTime() (10 ms ticks)
  Lua 5.2: no integer division or bitwise operators.
]]

local ROOT = "/WIDGETS/OmniDeck/"

local E = setmetatable({}, { __index = _G })
E.OD_ROOT = ROOT
E.OD_TILES = "/IMAGES/ethosmaps/maps/"
E.OD_YAAPU_TILES = "/IMAGES/yaapu/maps/"
E.OD_LITE = true          -- one-pixel shadow behind ladder numbers instead of a full outline
E.OD_TRAIL_SEGS = 20      -- the map page draws twice this many trail segments (the main-page minimap none)
E.OD_MAX_CRSF = 3         -- CRSF frames read per screen update (main.lua lowers it on the main page)
E.OD_MAX_SPORT = 10       -- S.Port frames per update: one value each, so cheap but frequent
E.OD_MAX_WPS = 20         -- waypoints drawn on the map, from just before the active one

-- OD_DEBUGLOAD (set by SYS > Tools > OmniDeck Check): load from the .lua text ("T"), so an
-- error names its file and line; the radio's own compiled .luac copies carry no names.
-- A file that does not load stops here with its name, not later as a bare nil.
-- Not passed as loadScript's env argument: on EdgeTX 2.9 that leaves the chunk with _ENV = nil
-- (TX16S MK2 tester, 2026-11-03). Each shared module starts with "local _ENV = OD_ENV or _ENV".
OD_ENV = E
function E.loadfile(name)
  local chunk, err = loadScript(ROOT .. name, OD_DEBUGLOAD and "T" or "bt")
  if not chunk then error(name .. ": " .. tostring(err), 2) end
  return chunk
end

-- ---------------------------------------------------------------- time
local clockBase = getTime()
E.os = setmetatable({ clock = function() return (getTime() - clockBase) / 100 end }, { __index = os })

-- ---------------------------------------------------------------- io: Ethos-style file:read()
local rawio = io
E.io = {
  open = function(path, mode)
    local f = rawio.open(path, mode or "r")
    if not f then return nil end
    if mode == "w" or mode == "a" then
      return {
        write = function(self, text) rawio.write(f, text) end,
        close = function(self) rawio.close(f) end,
      }
    end
    return {
      -- the whole file on the first call (any format), nil after it, so a line loop ends
      read = function(self)
        if self.done then return nil end
        self.done = true
        local parts = {}
        while true do
          local chunk = rawio.read(f, 1024)
          if chunk == nil or chunk == "" then break end
          parts[#parts + 1] = chunk
        end
        return table.concat(parts)
      end,
      close = function(self) rawio.close(f) end,
    }
  end,
}

-- ---------------------------------------------------------------- constants the shared code uses
E.LEFT, E.CENTERED, E.RIGHT = 0, 1, 2
E.FONT_XXS, E.FONT_XS, E.FONT_S, E.FONT_STD, E.FONT_L, E.FONT_XL, E.FONT_XXL = 1, 2, 3, 4, 5, 6, 7
local FONTS = { TINSIZE or SMLSIZE, SMLSIZE, SMLSIZE, STDSIZE or 0, MIDSIZE, DBLSIZE, XXLSIZE }
E.OPTION_LATITUDE, E.OPTION_LONGITUDE = 1, 2
E.CATEGORY_SYSTEM, E.MAIN_VOLTAGE = 1001, 1002
E.EVT_TOUCH, E.EVT_KEY = 1, 2
E.TOUCH_START, E.TOUCH_MOVE, E.TOUCH_END = 1, 2, 3
E.KEY_ENTER_BREAK, E.KEY_ROTARY_LEFT, E.KEY_ROTARY_RIGHT = 1, 2, 3
-- telemetry units: the numbers of EdgeTX's TelemetryUnit list; ones EdgeTX lacks are never matched
E.UNIT_KNOT, E.UNIT_FOOT_PER_SECOND, E.UNIT_KILOMETER_PER_HOUR, E.UNIT_MILE_PER_HOUR = 4, 6, 7, 8
E.UNIT_FOOT, E.UNIT_RADIAN, E.UNIT_KILOMETER = 10, 21, 28
E.UNIT_CENTIMETER_PER_SECOND, E.UNIT_METER_PER_MINUTE, E.UNIT_FOOT_PER_MINUTE, E.UNIT_CENTIMETER = -1, -2, -3, -4

-- ---------------------------------------------------------------- lcd
-- Every Lua instruction here counts against EdgeTX's per-call limit, so the common
-- case (shape fully inside the clip box) takes a short path, the colour is only sent
-- when it changes, and coordinates go through unrounded (EdgeTX truncates them).
local L = {}
local rawlcd = lcd
local rawText, rawFRect, rawRect, rawLine, rawTri = rawlcd.drawText, rawlcd.drawFilledRectangle,
  rawlcd.drawRectangle, rawlcd.drawLine, rawlcd.drawFilledTriangle
local rawCircle, rawFCircle, rawSize, rawSetColor = rawlcd.drawCircle, rawlcd.drawFilledCircle,
  rawlcd.sizeText, rawlcd.setColor
-- EdgeTX's own clipped line and HUD ground fill (both since 2.4, absent on OpenTX): done in C,
-- they don't count against the Lua instruction limit.
local rawClipLine, rawHud = rawlcd.drawLineWithClipping, rawlcd.drawHudRectangle
-- Up to 2.10.x the colour-LCD API reads coordinates unsigned (luaL_checkunsigned), so a negative
-- one wraps into a huge number; 2.11.0 reads them as integers (api_colorlcd.cpp v2.10.5 / v2.11.0).
local negOk = false
if getVersion then
  local _, _, maj, minor = getVersion()
  maj, minor = tonumber(maj) or 0, tonumber(minor) or 0
  negOk = maj > 2 or (maj == 2 and minor >= 11)
end
local nativeAll = negOk and rawClipLine ~= nil
local CUSTOM, LINE = CUSTOM_COLOR, SOLID or 0
local ALIGN = { [1] = CENTER or 0, [2] = RIGHT or 0 }
local col, sent, fontFlag = 0, nil, 0
-- safety net: when an update nears EdgeTX's limit, the rest of its text and lines are
-- skipped, so a rare heavy update draws incomplete instead of the widget being stopped
local getUsage = getUsage
local STARVE_PCT = 90
local drawn, starved = 0, false
local W, H = LCD_W or 480, LCD_H or 272
local cx1, cy1, cx2, cy2 = 0, 0, W, H        -- clip box, x2/y2 exclusive
local min, max = math.min, math.max


-- start of a screen update: the window, and other code may have changed the colour slot
function L.setWindow(w, h) W, H = w, h cx1, cy1, cx2, cy2 = 0, 0, w, h sent = nil drawn, starved = 0, false end
function L.starved() return starved end
function L.getWindowSize() return W, H end
function L.RGB(r, g, b) return rawlcd.RGB(r, g, b) end
function L.color(c) col = c end
function L.font(f) fontFlag = FONTS[f] or 0 end
function L.invalidate() end
function L.isVisible() return true end
function L.setClipping(x, y, w, h) cx1, cy1, cx2, cy2 = x, y, x + w, y + h end

function L.getTextSize(text) return rawSize(text, fontFlag) end

function L.drawText(x, y, text, align)
  -- the budget is looked at every 8th text (inline: a function call here costs more than the check)
  drawn = drawn + 1
  if drawn >= 8 then drawn = 0 if getUsage and getUsage() >= STARVE_PCT then starved = true end end
  if starved then return end
  -- no clip area: EdgeTX keeps text inside the widget itself and does the alignment
  if cx1 == 0 and cy1 == 0 and cx2 == W and cy2 == H then
    if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
    rawText(x, y, text, CUSTOM + fontFlag + (ALIGN[align] or 0))
    return
  end
  local w, h = rawSize(text, fontFlag)
  if align == 1 then x = x - w / 2 elseif align == 2 then x = x - w end
  -- text can't be cut, so it is drawn only when it fits inside the clip box
  if x < cx1 or x + w > cx2 + 1 or y < cy1 or y + h > cy2 + 1 then return end
  if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
  rawText(x, y, text, CUSTOM + fontFlag)
end

function L.drawFilledRectangle(x, y, w, h)
  if x < cx1 then w = w - (cx1 - x) x = cx1 end
  if y < cy1 then h = h - (cy1 - y) y = cy1 end
  if x + w > cx2 then w = cx2 - x end
  if y + h > cy2 then h = cy2 - y end
  if w <= 0 or h <= 0 then return end
  if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
  rawFRect(x, y, w, h, CUSTOM)
end

-- Liang-Barsky, for lines that cross the clip box
local function clipT(p, q, t0, t1)
  if p == 0 then
    if q < 0 then return nil end
    return t0, t1
  end
  local t = q / p
  if p < 0 then
    if t > t1 then return nil end
    if t > t0 then t0 = t end
  else
    if t < t0 then return nil end
    if t < t1 then t1 = t end
  end
  return t0, t1
end

function L.drawLine(x1, y1, x2, y2)
  drawn = drawn + 1
  if drawn >= 8 then drawn = 0 if getUsage and getUsage() >= STARVE_PCT then starved = true end end
  if starved then return end
  -- 2.11+: EdgeTX clips every line itself (clip box max inclusive, like the Lua path below)
  if nativeAll then
    if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
    rawClipLine(x1, y1, x2, y2, cx1, cx2 - 1, cy1, cy2 - 1, LINE, CUSTOM)
    return
  end
  if x1 >= cx1 and x2 >= cx1 and x1 < cx2 and x2 < cx2 and y1 >= cy1 and y2 >= cy1 and y1 < cy2 and y2 < cy2 then
    if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
    rawLine(x1, y1, x2, y2, LINE, CUSTOM)
    return
  end
  -- both ends beyond the same side: nothing to draw
  if (x1 < cx1 and x2 < cx1) or (x1 >= cx2 and x2 >= cx2) or (y1 < cy1 and y2 < cy1) or (y1 >= cy2 and y2 >= cy2) then return end
  -- up to 2.10: EdgeTX clips it too, but only with no negative coordinate (they would wrap)
  if rawClipLine and x1 >= 0 and y1 >= 0 and x2 >= 0 and y2 >= 0 then
    if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
    rawClipLine(x1, y1, x2, y2, cx1, cx2 - 1, cy1, cy2 - 1, LINE, CUSTOM)
    return
  end
  local dx, dy = x2 - x1, y2 - y1
  local t0, t1 = clipT(-dx, x1 - cx1, 0, 1)
  if t0 then t0, t1 = clipT(dx, cx2 - 1 - x1, t0, t1) end
  if t0 then t0, t1 = clipT(-dy, y1 - cy1, t0, t1) end
  if t0 then t0, t1 = clipT(dy, cy2 - 1 - y1, t0, t1) end
  if not t0 then return end
  if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
  rawLine(x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy, LINE, CUSTOM)
end

function L.drawRectangle(x, y, w, h)
  if x >= cx1 and y >= cy1 and x + w <= cx2 and y + h <= cy2 then
    if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
    rawRect(x, y, w, h, CUSTOM)
    return
  end
  L.drawLine(x, y, x + w - 1, y)
  L.drawLine(x, y + h - 1, x + w - 1, y + h - 1)
  L.drawLine(x, y, x, y + h - 1)
  L.drawLine(x + w - 1, y, x + w - 1, y + h - 1)
end

-- Sutherland-Hodgman against one side of the clip box, between two reused buffers.
-- side 1: x >= v, 2: x <= v, 3: y >= v, 4: y <= v
local bufA, bufB = {}, {}
local function clipSide(src, n, dst, side, v)
  local m = 0
  local px, py = src[n - 1], src[n]
  local pin
  if side == 1 then pin = px >= v elseif side == 2 then pin = px <= v elseif side == 3 then pin = py >= v else pin = py <= v end
  for i = 1, n, 2 do
    local x, y = src[i], src[i + 1]
    local cin
    if side == 1 then cin = x >= v elseif side == 2 then cin = x <= v elseif side == 3 then cin = y >= v else cin = y <= v end
    if cin ~= pin then
      local ix, iy
      if side <= 2 then ix, iy = v, py + (y - py) * (v - px) / (x - px)
      else ix, iy = px + (x - px) * (v - py) / (y - py), v end
      dst[m + 1], dst[m + 2] = ix, iy
      m = m + 2
    end
    if cin then dst[m + 1], dst[m + 2] = x, y m = m + 2 end
    px, py, pin = x, y, cin
  end
  return m
end

function L.drawFilledTriangle(x1, y1, x2, y2, x3, y3)
  local xl, xh, yl, yh = min(x1, x2, x3), max(x1, x2, x3), min(y1, y2, y3), max(y1, y2, y3)
  if xl >= cx1 and xh < cx2 and yl >= cy1 and yh < cy2 then
    if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
    rawTri(x1, y1, x2, y2, x3, y3, CUSTOM)
    return
  end
  if xh < cx1 or xl >= cx2 or yh < cy1 or yl >= cy2 then return end
  bufA[1], bufA[2], bufA[3], bufA[4], bufA[5], bufA[6] = x1, y1, x2, y2, x3, y3
  local n = 6
  n = clipSide(bufA, n, bufB, 1, cx1) if n < 6 then return end
  n = clipSide(bufB, n, bufA, 2, cx2 - 1) if n < 6 then return end
  n = clipSide(bufA, n, bufB, 3, cy1) if n < 6 then return end
  n = clipSide(bufB, n, bufA, 4, cy2 - 1) if n < 6 then return end
  if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
  local f = CUSTOM
  local ax, ay = bufA[1], bufA[2]
  for i = 3, n - 3, 2 do rawTri(ax, ay, bufA[i], bufA[i + 1], bufA[i + 2], bufA[i + 3], f) end
end

-- the horizon's ground filled by EdgeTX in C (lcd.drawHudRectangle, the call Yaapu uses):
-- pitch is a pixel shift (the vertical part x1.85), the box is never negative
if rawHud then
  function L.drawHudGround(pitch, roll, x, y, w, h)
    if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
    -- roll + 0.001 as Yaapu does (drawlib.lua etxDrawHudRectangle): keeps EdgeTX off its separate
    -- roll == 0 branch, so level flight takes the same path as any bank
    rawHud(pitch, roll + 0.001, x, x + w, y, y + h, CUSTOM)
  end
end

-- a convex quad (the horizon's ground) clipped once, then filled as a fan
function L.drawFilledQuad(x1, y1, x2, y2, x3, y3, x4, y4)
  bufA[1], bufA[2], bufA[3], bufA[4], bufA[5], bufA[6], bufA[7], bufA[8] = x1, y1, x2, y2, x3, y3, x4, y4
  local n = 8
  n = clipSide(bufA, n, bufB, 1, cx1) if n < 6 then return end
  n = clipSide(bufB, n, bufA, 2, cx2 - 1) if n < 6 then return end
  n = clipSide(bufA, n, bufB, 3, cy1) if n < 6 then return end
  n = clipSide(bufB, n, bufA, 4, cy2 - 1) if n < 6 then return end
  if col ~= sent then rawSetColor(CUSTOM, col) sent = col end
  local ax, ay = bufA[1], bufA[2]
  for i = 3, n - 3, 2 do rawTri(ax, ay, bufA[i], bufA[i + 1], bufA[i + 2], bufA[i + 3], CUSTOM) end
end

function L.drawCircle(x, y, r)
  if x - r >= cx1 and x + r < cx2 and y - r >= cy1 and y + r < cy2 then if col ~= sent then rawSetColor(CUSTOM, col) sent = col end rawCircle(x, y, r, CUSTOM) end
end
function L.drawFilledCircle(x, y, r)
  if x - r >= cx1 and x + r < cx2 and y - r >= cy1 and y + r < cy2 then if col ~= sent then rawSetColor(CUSTOM, col) sent = col end rawFCircle(x, y, r, CUSTOM) end
end

function L.loadBitmap(path) return Bitmap.open(path) end
-- bitmaps can't be clipped; the shared code draws the map first so later drawing covers any overhang
function L.drawBitmap(x, y, bmp)
  if bmp == nil or x >= cx2 or y >= cy2 or x + 100 <= cx1 or y + 100 <= cy1 then return end
  rawlcd.drawBitmap(bmp, x, y)
end

E.lcd = L

-- ---------------------------------------------------------------- link statistics
-- For the sensor check page (page 5): what actually reaches the widget, so a tester's photo shows
-- whether frames are missing or the screen updates too slowly. Counted over 5 s windows.
local ST = { t0 = getTime(), upd = 0, raw = 0, pass = 0, sp = 0, drop = 0, lastData = nil, gap = 0, maxGap = 0,
             rate = nil }
local function stNow() return getTime() / 100 end
local function stData()
  local t = stNow()
  if ST.lastData then
    local g = t - ST.lastData
    if g > ST.gap then ST.gap = g end
  end
  ST.lastData = t
end
local function stRoll()
  local t = getTime()
  local dt = (t - ST.t0) / 100
  if dt < 5 then return end
  ST.rate = { upd = ST.upd / dt, raw = ST.raw / dt, pass = ST.pass / dt, sp = ST.sp / dt, drop = ST.drop,
              gap = ST.gap, maxGap = math.max(ST.maxGap, ST.gap) }
  ST.maxGap = ST.rate.maxGap
  ST.t0, ST.upd, ST.raw, ST.pass, ST.sp, ST.drop, ST.gap = t, 0, 0, 0, 0, 0, 0
end
function E.countUpdate() ST.upd = ST.upd + 1 stRoll() end
-- lines for the check page; nil until the first 5 s window is done
function E.OD_STATS()
  local r = ST.rate
  if not r then return { "link stats: measuring (5 s)..." } end
  local rssi = getRSSI and getRSSI() or -1
  return {
    string.format("upd %.1f/s  CRSF %.1f/s  passthru %.1f/s  S.Port %.1f/s", r.upd, r.raw, r.pass, r.sp),
    string.format("gap now %.1fs  max %.1fs  dropped %d  RSSI %s  CPU %s%%", r.gap, r.maxGap, r.drop,
      tostring(rssi), tostring(getUsage and getUsage() or "?")),
  }
end

-- ---------------------------------------------------------------- telemetry queues
-- CRSF: one pop serves both readers; MSP replies (0x7B) wait for mspclient, the rest for telem.
-- The radio's own queue is drained completely on every call: EdgeTX drops new frames once it is
-- full, and the shared code takes only a few frames per screen update. Kept here instead, the
-- newest PASS_MAX; older ones are dropped (and counted) if the screen falls behind.
local PASS_MAX = 24
local crsfPass, crsfMsp = {}, {}
local function crsfFill(want)
  local got = false
  for _ = 1, 32 do
    local cmd, data = crossfireTelemetryPop()
    if cmd == nil then break end
    ST.raw = ST.raw + 1
    if cmd == 0x7B then
      if #crsfMsp < 8 then crsfMsp[#crsfMsp + 1] = { cmd, data } end
    elseif cmd == 0x80 or cmd == 0x7F then
      ST.pass = ST.pass + 1
      got = true
      if #crsfPass >= PASS_MAX then table.remove(crsfPass, 1) ST.drop = ST.drop + 1 end
      crsfPass[#crsfPass + 1] = { cmd, data }
    end
  end
  if got then stData() end
end
local crsfSensor = {
  popFrame = function(self, lo, hi)
    crsfFill(lo)
    local q = lo == 0x7B and crsfMsp or crsfPass
    local f = table.remove(q, 1)
    if not f then return nil end
    return f[1], f[2]
  end,
  pushFrame = function(self, cmd, data) return crossfireTelemetryPush(cmd, data) end,
}
E.crsf = crossfireTelemetryPop and { getSensor = function() return crsfSensor end } or nil

-- S.Port: MSP replies (primId 0x32) wait for mspclient; passthrough and the rest go to telem
local spPass, spMsp = {}, {}
local function frameObj(physId, primId, appId, value)
  return {
    physId = function() return physId end, primId = function() return primId end,
    appId = function() return appId end, value = function() return value end,
  }
end
-- same for S.Port: drained completely, one value per frame, so more of them are kept
local SP_MAX = 60
local function sportFill(wantMsp)
  local got = false
  for _ = 1, 64 do
    local physId, primId, appId, value = sportTelemetryPop()
    if physId == nil then break end
    ST.sp = ST.sp + 1
    got = true
    if primId == 0x32 then
      if #spMsp < 16 then spMsp[#spMsp + 1] = { physId, primId, appId, value } end
    else
      if #spPass >= SP_MAX then table.remove(spPass, 1) ST.drop = ST.drop + 1 end
      spPass[#spPass + 1] = { physId, primId, appId, value }
    end
  end
  if got then stData() end
end
local function sportSensor(msp)
  return {
    popFrame = function(self)
      sportFill(msp)
      local f = table.remove(msp and spMsp or spPass, 1)
      if not f then return nil end
      return frameObj(f[1], f[2], f[3], f[4])
    end,
    pushFrame = function(self, t) return sportTelemetryPush(t.physId, t.primId, t.appId, t.value) end,
  }
end
local spPassSensor, spMspSensor = sportSensor(false), sportSensor(true)
E.sport = sportTelemetryPop and {
  getSensor = function(arg)
    if type(arg) == "table" and arg.primId == 0x32 then return spMspSensor end
    -- the shared code asks for two readers (both S.Port modules on Ethos); one queue here
    if type(arg) == "table" and arg.module then return nil end
    return spPassSensor
  end,
} or nil

-- ---------------------------------------------------------------- native sensors
-- Ethos source names and S.Port appIds -> EdgeTX sensor names
local NAMES = {
  ["Altitude"] = "Alt", ["GPS alt"] = "GAlt", ["VSpeed"] = "VSpd", ["GPS speed"] = "GSpd",
  ["Yaw"] = "Yaw", ["GPS heading"] = "Hdg", ["GPS satellites"] = "Sats", ["GPS Satellites"] = "Sats",
  ["Roll"] = "Roll", ["Pitch"] = "Ptch", ["Rx Batt"] = "RxBt", ["Batt"] = "RxBt",
  ["Rx Current"] = "Curr", ["Current"] = "Curr", ["Rx Cons"] = "Capa", ["Consumption"] = "Capa",
  ["Flight mode"] = "FM", ["Rx Quality"] = "RQly", ["RQly"] = "RQly",
  ["Rx RSSI1"] = "1RSS", ["1RSS"] = "1RSS", ["Rx RSSI2"] = "2RSS", ["2RSS"] = "2RSS",
  ["RSSI"] = "RSSI", ["RSSI 2.4G"] = "RSSI", ["RSSI 900M"] = "RSSI",
  ["Airspeed"] = "ASpd", ["Air speed"] = "ASpd", ["ASpd"] = "ASpd",
}
local APPIDS = {
  [0x0100] = "Alt", [0x0820] = "GAlt", [0x0110] = "VSpd", [0x0830] = "GSpd", [0x0840] = "Hdg",
  [0x0480] = "Sats", [0x0410] = "Tmp2", [0x0440] = "Roll", [0x0430] = "Ptch", [0x0210] = "VFAS",
  [0x0B50] = "RxBt", [0x0200] = "Curr", [0x0600] = "Fuel", [0x0470] = "Tmp1", [0x0400] = "Tmp1",
  [0x0A00] = "ASpd", [0xF101] = "RSSI", [0xF010] = "RSSI",
}

-- the unit each sensor is set to in the model's telemetry list
-- (one pass over the list, the first time a unit is asked for; rescanned after 10 s for
-- sensors discovered later)
local units, unitsAt = nil, -1000
local function sensorUnit(name)
  local now = getTime()
  if units == nil or (units[name] == nil and now - unitsAt > 1000) then
    units, unitsAt = {}, now
    if model and model.getSensor then
      for i = 0, 59 do
        local ok, sn = pcall(model.getSensor, i)
        if ok and type(sn) == "table" and sn.name and sn.name ~= "" then units[sn.name] = sn.unit end
      end
    end
  end
  return units[name]
end

-- telemetry stops reaching the radio: EdgeTX keeps the last values, Ethos-style nil is wanted.
-- Asked once per update (E.tick), not once per sensor.
local live = true
function E.tick()
  local rssi = getRSSI and getRSSI() or 1
  live = rssi ~= nil and rssi > 0
end

-- shown: the name the shared code asked for. telem.lua checks that a by-name hit carries that
-- name (Ethos once returned the wrong sensor); EdgeTX names differ ("Pitch" is "Ptch"), so the
-- Ethos name is reported here. Reporting the EdgeTX name hid pitch, mode, battery and current
-- on EdgeTX from test10 (TX16S MK3 tester with Betaflight, 2026-11-03).
local function source(name, field, shown)
  if not getFieldInfo(name) then return nil end
  return {
    value = function()
      if not live then return nil end
      local v = getValue(name)
      if field then
        if type(v) ~= "table" then return nil end
        return v[field]
      end
      if v == nil or (type(v) == "number" and v == 0 and name == "FM") then return nil end
      return v
    end,
    unit = function() return sensorUnit(name) end,
    name = function() return shown or name end,
  }
end

local function getSource(q)
  if type(q) == "string" then return source(NAMES[q] or q, nil, q) end
  if type(q) ~= "table" then return nil end
  if q.category == E.CATEGORY_SYSTEM then
    return { value = function() return getValue("tx-voltage") end, unit = function() return nil end,
             name = function() return "TX" end }
  end
  if q.name == "GPS" then return source("GPS", q.options == E.OPTION_LONGITUDE and "lon" or "lat") end
  if q.crsfId == 0x14 then return source("RQly") end          -- CRSF link statistics: CRSF links only
  if q.crsfId then return nil end
  if q.appId then
    local n = APPIDS[q.appId]
    -- the S.Port RSSI test tells the link apart, so it must not match on a CRSF link
    if q.appId == 0xF101 and getFieldInfo("RQly") then return nil end
    return n and source(n) or nil
  end
  return nil
end

-- dir() is tried as given, then without a trailing "/" (not every EdgeTX build takes "dir/")
local function listFiles(path)
  if dir == nil then return {} end
  for _, p in ipairs({ path, (string.gsub(path, "/+$", "")) }) do
    local out = {}
    local ok = pcall(function()
      for name in dir(p) do out[#out + 1] = name end
    end)
    if ok and #out > 0 then return out end
  end
  return {}
end

E.system = {
  getSource = getSource,
  playFile = function(path) playFile(path) end,
  listFiles = listFiles,
}

return E
