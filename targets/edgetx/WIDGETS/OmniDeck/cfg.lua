--[[
  OmniDeck settings on EdgeTX: the list SYS > Tools > OmniDeck Setup shows, and the per-model
  file it writes (/WIDGETS/OmniDeck/<model name>.cfg, one "key=value" per line). The widget
  reads the same file. Widget options were numbers only (and 5 at most before EdgeTX 2.11).

  Loaded with plain loadScript (no env argument: EdgeTX 2.9 breaks it), so it uses the radio's
  own io and model calls. No string methods (EdgeTX 2.9 strings have none).
]]

local C = {}
local DIR = "/WIDGETS/OmniDeck/"

-- key, label, then either a list of { value, name } choices or { min, max, step, unit, scale }
C.ITEMS = {
  -- list order only (grouped 0.4.0e); the file is key=value, so the order of the lines doesn't matter
  { "linkMode", "Telemetry link", { { 0, "Auto" }, { 1, "CRSF / ELRS / mLRS" }, { 2, "S.Port / F.Port / FBUS" } } },
  -- units
  { "spdUnit", "Speed units", { { 0, "km/h" }, { 1, "m/s" }, { 2, "knots" }, { 3, "mph" } } },
  { "altUnit", "Altitude units", { { 0, "metres" }, { 1, "feet" } } },
  { "effUnit", "Efficiency units", { { 0, "Wh/km" }, { 1, "mAh/km" }, { 2, "Wh/mi" }, { 3, "mAh/mi" } } },
  -- main page
  { "startPage", "Start page", { { 1, "Main" }, { 2, "Map" } } },
  -- the panel at the top right of the main page, above the data blocks (test42; etx3 had
  -- "panel": 0 minimap, 1 radar, 2 OmniDeck logo, 3 Stratos logo, carried over in C.read)
  { "topPanel", "Top-right panel", { { 0, "Minimap" }, { 1, "Home arrow" }, { 2, "Radar" }, { 3, "OmniDeck logo" },
    { 4, "Stratos logo" } } },
  -- map page
  { "orient", "Map orientation", { { 0, "North up" }, { 1, "Heading up" } } },
  { "zoomMode", "Map view", { { 0, "Aircraft-centred" }, { 1, "Home-centred" } } },
  -- a knob or slider sets the map zoom (all ranges across its travel); Off = wheel / auto zoom
  { "zoomSrc", "Map zoom control", "pots" },
  -- offline map tiles on the card (IMAGES/ethosmaps/maps/..., IMAGES/yaapu/maps/...)
  { "tileSet", "Map tiles", "tilesets" },
  { "trail", "Flight trail", { { 1, "On" }, { 0, "Off" } } },
  -- missions on the map
  -- Stratos firmware: the whole mission over MAVlite onto the map (S.Port, F.Port, ELRS, Crossfire)
  { "apMission", "ArduPilot mission download", { { 0, "Off" }, { 1, "On" } } },
  { "inavWp", "INAV mission download", { { 1, "On" }, { 0, "Off" } } },
  -- pages
  -- EdgeTX gives a widget touch and keys only in full screen; a switch changes pages anywhere
  { "pageSwitch", "Page switch", "switches" },
  { "pageSwMode", "Page switch action", { { 0, "Next page (flip up / press)" }, { 1, "Position picks page" }, { 2, "Up previous, down next" } } },
  -- the pages a tap cycles through (test42); the flight summary still opens on disarm
  { "msgPage", "Messages page", { { 0, "Auto (ArduPilot only)" }, { 1, "On" }, { 2, "Off" } } },
  { "statsPage", "Flight stats page", { { 0, "Off" }, { 1, "On" } } },
  { "sumAuto", "Flight summary on disarm", { { 1, "On" }, { 0, "Off" } } },
  { "checkPage", "Sensor check page", { { 0, "Off" }, { 1, "On" } } },
  -- parameters: ArduPlane (MAVlite) and INAV 9.1+ (MSP), params.lua
  { "paramsPage", "Params page (ArduPilot, INAV)", { { 0, "Off" }, { 1, "On" } } },
  -- in flight: PID / Q PID / TRIM rows only; everything else stays view only while armed
  { "flightEdit", "Params: edit in flight", { { 0, "Off" }, { 1, "Gains and trim" } } },
  -- voice and alarms
  { "voice", "Voice", "packs" },
  { "beep", "Message beep", { { 1, "Every message" }, { 2, "Warnings and errors" }, { 0, "Off" } } },
  { "batCap", "Battery mAh (INAV/BF only)", { 0, 30000, 100, "mAh", 1 } },
  { "cells", "Battery cells (0 = auto)", { 0, 14, 1, "", 1 } },
  -- the battery block's big figure; the other one is its small label (cells from the line above)
  { "battMain", "Battery block shows", { { 0, "Battery voltage" }, { 1, "Average cell" } } },
  { "lowVolt", "Low voltage alarm (per cell)", { 0, 450, 5, "V", 100 } },
  { "critVolt", "Critical voltage alarm (per cell)", { 0, 450, 5, "V", 100 } },
  { "lowAlt", "Low altitude alarm (0 = off)", { 0, 3000, 10, "", 1 } },
}

C.DEFAULTS = { linkMode = 0, voice = "", beep = 1, spdUnit = 0, altUnit = 0, effUnit = 0, orient = 0,
               zoomMode = 0, zoomSrc = "", tileSet = "*", trail = 1, startPage = 1, pageSwitch = "", pageSwMode = 0, sumAuto = 1, batCap = 0, lowVolt = 0, critVolt = 0,
               cells = 0, lowAlt = 0, inavWp = 0, panel = -1, topPanel = -1, msgPage = 0, statsPage = 0,
               checkPage = 0, paramsPage = 0, flightEdit = 0, apMission = 0, battMain = 0 }

-- EdgeTX: io.read(f, n) / io.write(f, s); standard Lua (simulator): f:read / f:write
local function fread(f)
  local parts = {}
  for _ = 1, 64 do
    local ok, d = pcall(io.read, f, 512)
    if not ok then
      local ok2, all = pcall(function() return f:read("*a") end)
      return ok2 and all or ""
    end
    if d == nil or d == "" then break end
    parts[#parts + 1] = d
  end
  return table.concat(parts)
end
local function fwrite(f, s)
  if not pcall(io.write, f, s) then pcall(function() f:write(s) end) end
end

function C.path()
  local name = "default"
  local ok, info = pcall(model.getInfo)
  if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then name = info.name end
  name = string.gsub(name, "[^%w%-_]", "_")
  return DIR .. name .. ".cfg"
end

-- the saved values over the defaults; numbers stay numbers, the voice pack name stays text
function C.read()
  local out = {}
  for k, v in pairs(C.DEFAULTS) do out[k] = v end
  local f = io.open(C.path(), "r")
  -- no file yet: voice on, with the first pack on the card (a first save must not turn it off)
  if not f then out.voice = C.packs()[1] or "" out.topPanel = 0 return out, false end
  local text = fread(f)
  io.close(f)
  for line in string.gmatch(text, "[^\r\n]+") do
    local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and C.DEFAULTS[k] ~= nil then
      if type(C.DEFAULTS[k]) == "number" then out[k] = tonumber(v) or C.DEFAULTS[k] else out[k] = v end
    end
  end
  -- test42: the top-right panel's choices changed; a file written before keeps what it showed
  if out.topPanel < 0 then
    local old = { [1] = 2, [2] = 3, [3] = 4 }
    out.topPanel = old[out.panel] or 0
  end
  return out, true
end

function C.write(values)
  local f = io.open(C.path(), "w")
  if not f then return false end
  for _, it in ipairs(C.ITEMS) do
    local k = it[1]
    fwrite(f, k .. "=" .. tostring(values[k] == nil and C.DEFAULTS[k] or values[k]) .. "\n")
  end
  io.close(f)
  return true
end

-- the radio's physical switches (sa, sb, ...), as getValue() names them; only those it has
function C.switches()
  local out = {}
  for _, n in ipairs({ "sa", "sb", "sc", "sd", "se", "sf", "sg", "sh", "si", "sj", "sk", "sl" }) do
    local ok, info = pcall(getFieldInfo, n)
    if ok and info then out[#out + 1] = n end
  end
  return out
end

-- the radio's knobs and sliders, by their getValue() names (they differ between EdgeTX versions
-- and radios: s1/s2/ls/rs on older builds, p1/p2/sl1/sl2 on newer); only those it has
function C.pots()
  local out = {}
  for _, n in ipairs({ "s1", "s2", "s3", "s4", "6pos", "ls", "rs", "p1", "p2", "p3", "p4", "sl1", "sl2", "sl3", "sl4",
                       "ext1", "ext2" }) do
    local ok, info = pcall(getFieldInfo, n)
    if ok and info then out[#out + 1] = n end
  end
  return out
end

-- the voice packs: folders in /WIDGETS/OmniDeck/audio/ (dir() as given, then without the "/")
function C.packs()
  local out = {}
  if dir == nil then return out end
  for _, p in ipairs({ DIR .. "audio/", DIR .. "audio" }) do
    local ok = pcall(function()
      for name in dir(p) do
        name = string.gsub(name, "/+$", "")
        if name ~= "" and not string.find(name, ".", 1, true) then out[#out + 1] = name end
      end
    end)
    if ok and #out > 0 then break end
  end
  table.sort(out)
  return out
end

return C
