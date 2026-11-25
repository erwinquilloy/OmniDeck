--[[
  OmniDeck Mono on EdgeTX black-and-white radios (TX12 MK2, Pocket, Boxer; 128x64):
  the telemetry half of the colour build's etx.lua, so telem.lua runs unchanged.

  Gives the shared telemetry code its Ethos-style calls: system.getSource over the
  radio's sensors, the CRSF and S.Port frame queues, os.clock from getTime(), io.
  No drawing here: the Mono pages draw with EdgeTX's own black-and-white lcd calls.
  Lua 5.2: no integer division or bitwise operators.
]]

local ROOT = "/SCRIPTS/OMNID/"

local E = setmetatable({}, { __index = _G })
E.OD_ROOT = ROOT
E.OD_LITE = true          -- EdgeTX budgets in telem.lua (lookups, native reads 5 per second)
E.OD_MAX_CRSF = 3         -- CRSF frames decoded per update
E.OD_MAX_SPORT = 10       -- S.Port frames per update: one value each, so cheap but frequent

-- Mono runs on EdgeTX only. The colour build tells OpenTX apart by a missing lcd.sizeText, which
-- black-and-white EdgeTX may lack too, so it is not asked here.
local OTX = false
E.OD_OTX = false

-- OD_DEBUGLOAD: load from the .lua text ("T"), so an
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
-- read once per screen update (E.tick): the shared code asks for the time dozens of times per
-- update, and a getTime() call plus the arithmetic each time added up on OpenTX's budget
local clockBase = getTime()
local clockNow = 0
local tickN = 0   -- screen updates (E.tick), so per-update work is done once
E.os = setmetatable({ clock = function() return clockNow end }, { __index = os })

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
E.OPTION_LATITUDE, E.OPTION_LONGITUDE = 1, 2
E.CATEGORY_SYSTEM, E.MAIN_VOLTAGE = 1001, 1002
E.EVT_TOUCH, E.EVT_KEY = 1, 2
E.TOUCH_START, E.TOUCH_MOVE, E.TOUCH_END = 1, 2, 3
E.KEY_ENTER_BREAK, E.KEY_ROTARY_LEFT, E.KEY_ROTARY_RIGHT = 1, 2, 3
-- telemetry units: the numbers of EdgeTX's TelemetryUnit list; ones EdgeTX lacks are never matched
E.UNIT_KNOT, E.UNIT_FOOT_PER_SECOND, E.UNIT_KILOMETER_PER_HOUR, E.UNIT_MILE_PER_HOUR = 4, 6, 7, 8
E.UNIT_FOOT, E.UNIT_RADIAN, E.UNIT_KILOMETER = 10, 21, 28
E.UNIT_CENTIMETER_PER_SECOND, E.UNIT_METER_PER_MINUTE, E.UNIT_FOOT_PER_MINUTE, E.UNIT_CENTIMETER = -1, -2, -3, -4

-- ---------------------------------------------------------------- files
local rawio0 = io
local function fileExists(path)
  local f = rawio0.open(path, "r")
  if f == nil then return false end
  rawio0.close(f)
  return true
end

-- ---------------------------------------------------------------- link statistics
-- For the sensor check page (page 5): what actually reaches the widget, so a tester's photo shows
-- whether frames are missing or the screen updates too slowly. Counted over 5 s windows.
local ST = { t0 = getTime(), upd = 0, raw = 0, pass = 0, sp = 0, drop = 0, lastData = nil, gap = 0, maxGap = 0,
             rate = nil }
local function stNow() return clockNow end   -- the update's time (E.tick)
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
-- OpenTX keeps only the newest few passthrough frames (it has no catch-up after drawing, so a
-- long queue would show values a second old), in a ring of 4 that is overwritten in place, so
-- emptying a backlog after a pause costs a few steps per frame, not a table each. Status text
-- frames (0xF1) go to their own short queue and are never pushed out by status values.
local RING = 4
local ringC, ringD, ringHead, ringN = {}, {}, 1, 0
local otxText = {}
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
      if OTX then
        if data and data[1] == 0xF1 then
          if #otxText < 8 then otxText[#otxText + 1] = data else ST.drop = ST.drop + 1 end
        else
          if ringN >= RING then ringHead = ringHead % RING + 1 ringN = ringN - 1 ST.drop = ST.drop + 1 end
          local i = (ringHead + ringN - 1) % RING + 1
          ringC[i], ringD[i] = cmd, data
          ringN = ringN + 1
        end
      else
        if #crsfPass >= PASS_MAX then table.remove(crsfPass, 1) ST.drop = ST.drop + 1 end
        crsfPass[#crsfPass + 1] = { cmd, data }
      end
    end
  end
  if got then stData() end
end
local crsfSensor = {
  popFrame = function(self, lo, hi)
    crsfFill(lo)
    if OTX and lo ~= 0x7B then
      if #otxText > 0 then return 0x80, table.remove(otxText, 1) end   -- texts first, in order
      if ringN == 0 then return nil end
      local c, d = ringC[ringHead], ringD[ringHead]
      ringC[ringHead], ringD[ringHead] = nil, nil
      ringHead, ringN = ringHead % RING + 1, ringN - 1
      return c, d
    end
    local q = lo == 0x7B and crsfMsp or crsfPass
    local f = table.remove(q, 1)
    if not f then return nil end
    return f[1], f[2]
  end,
  pushFrame = function(self, cmd, data) return crossfireTelemetryPush(cmd, data) end,
}
E.crsf = crossfireTelemetryPop and { getSensor = function() return crsfSensor end } or nil

-- S.Port: MSP replies (primId 0x32) wait for mspclient; passthrough and the rest go to telem
local spMsp = {}
-- passthrough values in a ring (four parallel arrays, no table per frame): taking the oldest is a
-- step of the head index, where table.remove(t, 1) moved every entry up, 60 of them
-- OpenTX decodes fewer values per update than arrive at times, so there only the newest 16 are
-- kept (the oldest dropped): what is shown stays within about a quarter of a second
local SP_MAX = OTX and 16 or 60
local fillTick = -1
local spA, spB, spC, spD, spHead, spN = {}, {}, {}, {}, 1, 0
-- same for S.Port: drained completely, one value per frame, so more of them are kept
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
      if spN >= SP_MAX then spHead = spHead % SP_MAX + 1 spN = spN - 1 ST.drop = ST.drop + 1 end
      local i = (spHead + spN - 1) % SP_MAX + 1
      spA[i], spB[i], spC[i], spD[i] = physId, primId, appId, value
      spN = spN + 1
    end
  end
  if got then stData() end
end
-- one frame object per reader, filled for each pop: the reader takes its values before the next
-- pop, so the four closures per frame are no longer made
local function frameObject()
  local o = {}
  function o.physId(self) return self[1] end
  function o.primId(self) return self[2] end
  function o.appId(self) return self[3] end
  function o.value(self) return self[4] end
  return o
end
local function sportSensor(msp)
  local fo = frameObject()
  return {
    -- passthrough values straight, for telem.lua (no frame object); the radio's queue is
    -- emptied into the ring once per screen update, not on every value
    popRaw = (not msp) and function(self)
      if fillTick ~= tickN then fillTick = tickN sportFill(false) end
      if spN == 0 then return nil end
      local h = spHead
      spHead, spN = h % SP_MAX + 1, spN - 1
      return spA[h], spB[h], spC[h], spD[h]
    end or nil,
    popFrame = function(self)
      sportFill(msp)
      if msp then
        local f = table.remove(spMsp, 1)
        if not f then return nil end
        fo[1], fo[2], fo[3], fo[4] = f[1], f[2], f[3], f[4]
        return fo
      end
      if spN == 0 then return nil end
      fo[1], fo[2], fo[3], fo[4] = spA[spHead], spB[spHead], spC[spHead], spD[spHead]
      spHead, spN = spHead % SP_MAX + 1, spN - 1
      return fo
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
  tickN = tickN + 1
  clockNow = (getTime() - clockBase) / 100
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
  -- OpenTX has no dir(): no listing, tiles.lua looks for tile files instead
  listFiles = dir and listFiles or nil,
  fileExists = fileExists,
}

return E
