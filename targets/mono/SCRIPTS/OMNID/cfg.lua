--[[
  OmniDeck Mono settings: the list SYS > Tools > OmniDeck Setup shows, the per-model file it
  writes (/SCRIPTS/OMNID/<model>.cfg, one "key=value" per line), and the unit helpers the
  pages use. The telemetry script reads the file when it starts; EdgeTX stops telemetry
  scripts while a tool runs and starts them again after, so a change applies on leaving.
]]

local C = {}
local DIR = "/SCRIPTS/OMNID/"

-- key, label (fits 128 px with the value), then { value, name } choices or { min, max, step, unit, scale }
C.ITEMS = {
  { "voice", "VOICE", "packs" },
  { "beep", "MSG BEEP", { { 1, "ALL" }, { 2, "WARNINGS" }, { 0, "OFF" } } },
  { "spdUnit", "SPEED", { { 0, "KM/H" }, { 1, "M/S" }, { 2, "KNOTS" }, { 3, "MPH" } } },
  { "altUnit", "ALT/DIST", { { 0, "METRIC" }, { 1, "FEET/MILES" } } },
  { "effUnit", "EFFICIENCY", { { 0, "WH/KM" }, { 1, "MAH/KM" }, { 2, "WH/MI" }, { 3, "MAH/MI" } } },
  { "sumAuto", "SUMMARY", { { 1, "ON DISARM" }, { 0, "OFF" } } },
  { "logFlight", "FLIGHT LOG", { { 0, "OFF" }, { 1, "ON" } } },
  { "cells", "CELLS", { 0, 14, 1, "", 1 } },
  { "lowVolt", "LOW V/CELL", { 0, 450, 5, "V", 100 } },
  { "critVolt", "CRIT V/CELL", { 0, 450, 5, "V", 100 } },
  { "batCap", "BATT MAH", { 0, 30000, 100, "", 1 } },
  { "startPage", "START PAGE", { { 1, "MAIN" }, { 2, "MAP" } } },
  { "mapView", "MAP VIEW", { { 0, "AIRCRAFT" }, { 1, "HOME" } } },
  { "statsPage", "STATS PAGE", { { 0, "HIDE" }, { 1, "SHOW" } } },
  { "checkPage", "SENSOR PAGE", { { 0, "HIDE" }, { 1, "SHOW" } } },
  { "linkMode", "LINK", { { 0, "AUTO" }, { 1, "CRSF" }, { 2, "S.PORT" } } },
}
C.NOTE = { statsPage = "IN THE PAGE CYCLE", checkPage = "PAGE 5", cells = "0 = AUTO", lowVolt = "0 = OFF", critVolt = "0 = OFF", batCap = "INAV/BF ONLY, 0 = OFF",
           logFlight = "TEXT FILE IN OMNID/LOGS", mapView = "CENTRE OF THE MAP" }

C.DEFAULTS = { voice = "", beep = 1, spdUnit = 0, altUnit = 0, effUnit = 0, sumAuto = 1, logFlight = 0, cells = 0,
               lowVolt = 0, critVolt = 0, batCap = 0, startPage = 1, mapView = 0, statsPage = 0, checkPage = 0, linkMode = 0 }

function C.path()
  local name = "default"
  local ok, info = pcall(model.getInfo)
  if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then name = info.name end
  return DIR .. string.gsub(name, "[^%w%-_]", "_") .. ".cfg"
end

-- the voice packs: folders in /SCRIPTS/OMNID/audio/
function C.packs()
  local out = {}
  if dir == nil then return out end
  pcall(function()
    for name in dir(DIR .. "audio") do
      name = string.gsub(name, "/+$", "")
      if name ~= "" and not string.find(name, ".", 1, true) then out[#out + 1] = name end
    end
  end)
  table.sort(out)
  return out
end

function C.read()
  local out = {}
  for k, v in pairs(C.DEFAULTS) do out[k] = v end
  local f = io.open(C.path(), "r")
  if not f then out.voice = C.packs()[1] or "" return out end   -- first run: voice on
  local text = io.read(f, 1024) or ""
  io.close(f)
  for line in string.gmatch(text, "[^\r\n]+") do
    local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and C.DEFAULTS[k] ~= nil then
      if type(C.DEFAULTS[k]) == "number" then out[k] = tonumber(v) or C.DEFAULTS[k] else out[k] = v end
    end
  end
  return out
end

function C.write(vals)
  local f = io.open(C.path(), "w")
  if not f then return false end
  for _, it in ipairs(C.ITEMS) do
    local k = it[1]
    io.write(f, k .. "=" .. tostring(vals[k] == nil and C.DEFAULTS[k] or vals[k]) .. "\n")
  end
  io.close(f)
  return true
end

-- unit helpers for the pages: numbers in the chosen unit and short labels for 128x64
local SPD = { [0] = { 3.6, "k" }, [1] = { 1, "MS" }, [2] = { 1.943844, "KT" }, [3] = { 2.236936, "MPH" } }
local EFF = { [0] = { true, 1, "WH/km" }, [1] = { false, 1, "MAH/km" }, [2] = { true, 1.609344, "WH/mi" },
              [3] = { false, 1.609344, "MAH/mi" } }
function C.units(v)
  local sp, e, ft = SPD[v.spdUnit] or SPD[0], EFF[v.effUnit] or EFF[0], v.altUnit == 1
  local floor = math.floor
  local u = { imperial = ft, spdLbl = sp[2], altLbl = ft and "ft" or "m", effLbl = e[3] }
  function u.spd(mps) return floor(mps * sp[1] + 0.5) end
  function u.alt(m) return floor((ft and m * 3.28084 or m) + 0.5) end
  -- altitude with its unit: 999m, then 1.00km .. 9.99km, then 10.0km (user 2026-11-20); feet stay feet
  function u.altStr(m)
    if ft then return floor(m * 3.28084 + 0.5) .. "ft" end
    if m < 999.5 then return floor(m + 0.5) .. "m" end
    return string.format(m < 9995 and "%.2fkm" or "%.1fkm", m / 1000)
  end
  -- distance in at most 5 characters: 999m 9.9k 99.9k 123k / 528ft 0.2mi 9.9mi 99mi 100mi
  function u.dist(m)
    if not m then return "---" end
    if ft then
      local mi = m / 1609.344
      if mi < 0.1 then return floor(m * 3.28084 + 0.5) .. "ft" end
      if mi < 9.95 then return string.format("%.1fmi", mi) end
      return floor(mi + 0.5) .. "mi"
    end
    if m < 999.5 then return floor(m + 0.5) .. "m" end
    if m < 99950 then return string.format("%.1fk", m / 1000) end
    return floor(m / 1000 + 0.5) .. "k"
  end
  -- efficiency from power or current over ground speed (m/s), in the chosen unit
  function u.eff(volt, amps, mps)
    if not (amps and mps) or mps < 2 or (e[1] and not volt) then return nil end
    local perKm = (e[1] and volt * amps or amps * 1000) / (mps * 3.6)
    return perKm * e[2]
  end
  return u
end

return C
