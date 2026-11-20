--[[
  OmniDeck Mono on EdgeTX black-and-white radios (TX12 MK2, Pocket, Boxer; 128x64):
  the telemetry half of the colour build's etx.lua, so telem.lua runs unchanged.

  Gives the shared telemetry code its Ethos-style calls: system.getSource over the
  radio's sensors, the CRSF and S.Port frame queues, os.clock from getTime(), io.
  No drawing here: the Mono pages draw with EdgeTX's own black-and-white lcd calls.
  Lua 5.2: no integer division or bitwise operators.

  Trimmed for memory (2026-11-20, TX12 MK2 at 104 KB live of ~127 KB): no Ethos-style io
  wrapper, file listing, link statistics, OpenTX ring buffers or MSP queues - the colour build
  uses them for its check page, map tiles and INAV mission download, which Mono does not have.
]]

local ROOT = "/SCRIPTS/OMNID/"

local E = setmetatable({}, { __index = _G })
E.OD_ROOT = ROOT
E.OD_LITE = true          -- EdgeTX budgets in telem.lua (lookups, native reads 5 per second)
E.OD_MAX_CRSF = 3         -- CRSF frames decoded per update
E.OD_MAX_SPORT = 10       -- S.Port frames per update: one value each, so cheap but frequent

-- Mono runs on EdgeTX only (the colour build's OpenTX paths are left out)
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


-- ---------------------------------------------------------------- constants the shared code uses
E.OPTION_LATITUDE, E.OPTION_LONGITUDE = 1, 2
-- telemetry units: the numbers of EdgeTX's TelemetryUnit list; ones EdgeTX lacks are never matched
E.UNIT_KNOT, E.UNIT_FOOT_PER_SECOND, E.UNIT_KILOMETER_PER_HOUR, E.UNIT_MILE_PER_HOUR = 4, 6, 7, 8
E.UNIT_FOOT, E.UNIT_RADIAN, E.UNIT_KILOMETER = 10, 21, 28
E.UNIT_CENTIMETER_PER_SECOND, E.UNIT_METER_PER_MINUTE, E.UNIT_FOOT_PER_MINUTE, E.UNIT_CENTIMETER = -1, -2, -3, -4

-- ---------------------------------------------------------------- telemetry queues
-- CRSF: the radio's own queue is drained on every call (EdgeTX drops new frames once it is full),
-- and the passthrough frames kept for telem.lua, the newest PASS_MAX. Other frame types (MSP
-- replies, mLRS bridge, ...) are dropped at once.
local PASS_MAX = 24
local crsfPass = {}
local function crsfFill()
  for _ = 1, 32 do
    local cmd, data = crossfireTelemetryPop()
    if cmd == nil then break end
    if cmd == 0x80 or cmd == 0x7F then
      if #crsfPass >= PASS_MAX then table.remove(crsfPass, 1) end
      crsfPass[#crsfPass + 1] = { cmd, data }
    end
  end
end
local crsfSensor = {
  popFrame = function(self)
    crsfFill()
    local f = table.remove(crsfPass, 1)
    if not f then return nil end
    return f[1], f[2]
  end,
}
E.crsf = crossfireTelemetryPop and { getSensor = function() return crsfSensor end } or nil

-- S.Port: the values in a ring (four parallel arrays, no table per frame), drained from the radio's
-- queue once per screen update; MSP replies (primId 0x32) are dropped
local SP_MAX = 60
local fillTick = -1
local spA, spB, spC, spD, spHead, spN = {}, {}, {}, {}, 1, 0
local function sportFill()
  for _ = 1, 64 do
    local physId, primId, appId, value = sportTelemetryPop()
    if physId == nil then break end
    if primId ~= 0x32 then
      if spN >= SP_MAX then spHead = spHead % SP_MAX + 1 spN = spN - 1 end
      local i = (spHead + spN - 1) % SP_MAX + 1
      spA[i], spB[i], spC[i], spD[i] = physId, primId, appId, value
      spN = spN + 1
    end
  end
end
-- one frame object, filled for each pop: the reader takes its values before the next pop
local fo = {}
function fo.physId(self) return self[1] end
function fo.primId(self) return self[2] end
function fo.appId(self) return self[3] end
function fo.value(self) return self[4] end
local spSensor = {
  -- passthrough values straight, for telem.lua (no frame object)
  popRaw = function(self)
    if fillTick ~= tickN then fillTick = tickN sportFill() end
    if spN == 0 then return nil end
    local h = spHead
    spHead, spN = h % SP_MAX + 1, spN - 1
    return spA[h], spB[h], spC[h], spD[h]
  end,
  popFrame = function(self)
    sportFill()
    if spN == 0 then return nil end
    fo[1], fo[2], fo[3], fo[4] = spA[spHead], spB[spHead], spC[spHead], spD[spHead]
    spHead, spN = spHead % SP_MAX + 1, spN - 1
    return fo
  end,
}
E.sport = sportTelemetryPop and {
  getSensor = function(arg)
    -- the shared code asks for two readers (both S.Port modules on Ethos); one queue here
    if type(arg) == "table" and arg.module then return nil end
    return spSensor
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

E.system = {
  getSource = getSource,
  playFile = function(path) playFile(path) end,
}

return E
