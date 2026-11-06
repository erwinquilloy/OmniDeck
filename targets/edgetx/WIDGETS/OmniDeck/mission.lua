-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck mission overlay.

  ArduPilot's passthrough telemetry carries no mission download, only the
  active waypoint (0x500D: number, distance, bearing). Two ways to show it:

    file    - a Mission Planner / QGC ".waypoints" file (QGC WPL 110) copied to
              /scripts/omnideck/missions/ on the SD card and picked in the settings
    learned - each waypoint is placed from 0x500D as it becomes active, from the
              closest approach seen (distance is exact to 1 m below 1 km, the
              bearing is in 3 deg steps, so the fix improves as the plane nears it)

  The active waypoint number comes from 0x500D in both cases.

  INAV: the whole mission is downloaded over MSP (mspclient.lua) and the
  active waypoint comes from MSP_NAV_STATUS.
]]

local MI = {}
MI.DIR = (OD_ROOT or "/scripts/omnideck/") .. "missions/"

local T = nil
function MI.init(telem) T = telem end

-- ---------------------------------------------------------------- learned
local learned = {}   -- [num] = { lat=, lon=, best= }
local lastStamp = nil

function MI.clearLearned() learned = {} end

function MI.update(s)
  if not (s.wpNum and s.wpDist and s.wpBrg and s.lat and s.posAt) then return end
  if s.wpDist <= 0 or s.wpNum <= 0 then return end
  if os.clock() - s.posAt > 0.3 then return end
  local stamp = s.wpNum .. ":" .. s.wpDist .. ":" .. s.wpBrg .. ":" .. s.lat
  if stamp == lastStamp then return end
  lastStamp = stamp
  local e = learned[s.wpNum]
  if e == nil or s.wpDist < e.best then
    local la, lo = T.project(s.lat, s.lon, s.wpDist, s.wpBrg)
    learned[s.wpNum] = { lat = la, lon = lo, best = s.wpDist }
  end
end

local function learnedList()
  local nums = {}
  for n in pairs(learned) do nums[#nums + 1] = n end
  table.sort(nums)
  local out = {}
  for _, n in ipairs(nums) do
    out[#out + 1] = { lat = learned[n].lat, lon = learned[n].lon, num = n }
  end
  return out
end

-- ---------------------------------------------------------------- mission file
-- MAV_CMD values with a position the vehicle flies to
local NAV = { [16] = "", [17] = "", [18] = "", [19] = "", [21] = "L", [22] = "T", [31] = "", [82] = "",
              [84] = "T", [85] = "L" }

function MI.parseFile(text)
  local out = {}
  local first = true
  for line in string.gmatch(text, "[^\r\n]+") do
    if first then
      first = false
      if not string.find(line, "QGC WPL") then return nil, "not a QGC WPL file" end
    else
      local f = {}
      for v in string.gmatch(line, "[^\t]+") do f[#f + 1] = v end
      -- idx current frame cmd p1 p2 p3 p4 lat lon alt autocontinue
      local idx, cmd = tonumber(f[1]), tonumber(f[4])
      local lat, lon, alt = tonumber(f[9]), tonumber(f[10]), tonumber(f[11])
      if idx and idx > 0 and cmd and NAV[cmd] and lat and lon and (lat ~= 0 or lon ~= 0) then
        local lbl = NAV[cmd] ~= "" and (NAV[cmd] .. idx) or tostring(idx)
        out[#out + 1] = { lat = lat, lon = lon, alt = alt, num = idx, label = lbl }
      end
    end
  end
  return out
end

function MI.listFiles()
  if not (system and system.listFiles) then return {} end
  local ok, entries = pcall(system.listFiles, MI.DIR)
  if not ok or type(entries) ~= "table" then return {} end
  local out = {}
  for _, n in ipairs(entries) do
    if type(n) == "string" and (string.match(string.lower(n), "%.waypoints$") or string.match(string.lower(n), "%.txt$")) then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end

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

local fileName, fileList, fileErr = nil, nil, nil
function MI.loadFile(name)
  fileName, fileList, fileErr = name, nil, nil
  if not name or name == "" then return end
  local f = io.open(MI.DIR .. name, "r")
  if not f then fileErr = "cannot open " .. name return end
  local text = readAll(f)
  f:close()
  local list, err = MI.parseFile(text or "")
  fileList, fileErr = list, err
end
function MI.fileError() return fileErr end

-- ---------------------------------------------------------------- INAV (MSP download)
-- INAV waypoint actions with a position the aircraft flies to
local INAV_NAV = { [1] = "", [2] = "H", [3] = "H", [8] = "L" }
local inavList = nil
function MI.setInav(wps)
  if not wps or #wps == 0 then inavList = nil return end
  local out = {}
  for _, wp in ipairs(wps) do
    if INAV_NAV[wp.action] and (wp.lat ~= 0 or wp.lon ~= 0) then
      local l = INAV_NAV[wp.action]
      out[#out + 1] = { lat = wp.lat, lon = wp.lon, alt = wp.alt, num = wp.idx, label = l ~= "" and (l .. wp.idx) or tostring(wp.idx) }
    end
    if wp.flags == 0xA5 then break end   -- end of the first mission
  end
  inavList = #out > 0 and out or nil
end

-- ---------------------------------------------------------------- what the map draws
function MI.current()
  if inavList then return inavList, "inav" end
  if fileList and #fileList > 0 then return fileList, "file" end
  local l = learnedList()
  if #l > 0 then return l, "learned" end
  return nil, nil
end

return MI
