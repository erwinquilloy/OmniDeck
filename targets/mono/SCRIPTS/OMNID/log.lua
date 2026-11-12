--[[
  OmniDeck Mono flight log: one text file per flight long enough for the summary, in
  /SCRIPTS/OMNID/logs/, named as the radio names its telemetry logs:
  <model>-<YYYY-MM-DD>-<HHMMSS>.txt (<model>-001.txt and up with no clock). Same contents as the
  colour build's log. Loaded only when a flight ends, then dropped, so it costs no memory in flight.
]]

local DIR = "/SCRIPTS/OMNID/"
local LOG_DIR = DIR .. "logs/"
local LOG_MSGS = 10

local function exists(path)
  local f = io.open(path, "r")
  if f then io.close(f) return true end
  return false
end

local function fileName(m, d)
  m = string.gsub(m, "[\\/:*?\"<>|]", "_")
  if m == "" then m = "model" end
  if d then
    local base = string.format("%s-%04d-%02d-%02d-%02d%02d%02d", m, d.year, d.mon, d.day, d.hour, d.min, d.sec)
    if not exists(LOG_DIR .. base .. ".txt") then return base .. ".txt" end
    for i = 2, 99 do
      if not exists(LOG_DIR .. base .. "-" .. i .. ".txt") then return base .. "-" .. i .. ".txt" end
    end
    return base .. "-99.txt"
  end
  for i = 1, 999 do
    local n = string.format("%s-%03d.txt", m, i)
    if not exists(LOG_DIR .. n) then return n end
  end
  return m .. "-999.txt"
end

-- s: telemetry, f: the finished flight (sum.lua), u: unit helpers (cfg.lua)
return function(s, f, u, version)
  local ok, d = pcall(getDateTime)
  if not (ok and type(d) == "table" and d.year and d.year > 2000) then d = nil end
  local okI, info = pcall(model.getInfo)
  local model = (okI and info and info.name) or "model"
  local function num(fmt, v) return v and string.format(fmt, v) or "--" end
  local function t(sec) sec = math.floor(sec or 0) return string.format("%02d:%02d", math.floor(sec / 60), sec % 60) end
  local function pos(la, lo) return (la and lo) and string.format("%.6f, %.6f", la, lo) or "--" end
  -- full units in the file (the screen uses short ones)
  local spdName = ({ K = "km/h", MS = "m/s", KT = "kt", MPH = "mph" })[u.spdLbl] or u.spdLbl
  local effName = ({ ["WH/KM"] = "Wh/km", ["MAH/KM"] = "mAh/km", ["WH/MI"] = "Wh/mi", ["MAH/MI"] = "mAh/mi" })[u.effLbl]
  local function dist(m)
    if m == nil then return "--" end
    if u.imperial then
      local ft = m * 3.28084
      return ft < 5279.5 and string.format("%dft", math.floor(ft + 0.5)) or string.format("%.2fmi", ft / 5280)
    end
    return m < 999.5 and string.format("%dm", math.floor(m + 0.5)) or string.format("%.2fkm", m / 1000)
  end
  local volts = f.voltN and f.voltSum / f.voltN
  local km = f.dist / 1000
  local eff = nil
  if f.used and f.dist > 100 then
    local perKm = nil
    if string.find(u.effLbl, "WH", 1, true) then
      if volts then perKm = f.used / 1000 * volts / km end
    else
      perKm = f.used / km
    end
    eff = perKm and perKm * (string.find(u.effLbl, "MI", 1, true) and 1.609344 or 1)
  end
  local L = {
    "OmniDeck Mono " .. version .. " flight log",
    "Model          " .. model,
    "Date           " .. (d and string.format("%04d-%02d-%02d %02d:%02d:%02d", d.year, d.mon, d.day, d.hour, d.min, d.sec) or "date unknown"),
    "FC             " .. tostring(s.fc or "?") .. ", link " .. tostring(s.link or "?"),
    "",
    "Flight time    " .. t(f.time),
    "Distance       " .. dist(f.dist),
    "Max home       " .. dist(f.maxHome),
    "Max alt        " .. (f.maxAlt and (u.alt(f.maxAlt) .. (u.imperial and "ft" or "m")) or "--"),
    "Max GSPD       " .. (f.maxGspd and (u.spd(f.maxGspd) .. " " .. spdName) or "--"),
    "Max AS         " .. (f.maxAspd and (u.spd(f.maxAspd) .. " " .. spdName) or "--"),
    "Used           " .. num("%dmAh", f.used and math.floor(f.used + 0.5)),
    "Efficiency     " .. num("%.2f", eff) .. " " .. effName,
    "Min volt       " .. num("%.2fV", f.minVolt),
    "Avg volt       " .. num("%.2fV", volts),
    "Max curr       " .. num("%.1fA", f.maxCurr),
    (f.minLq and "Min LQ         " or "Min RSSI       ") .. num("%d", f.minLq or f.minRssi),
    "Link lost      " .. ((f.lost or 0) > 0 and t(f.lost) or "none"),
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
  local name = fileName(model, d)
  local fh = io.open(LOG_DIR .. name, "w") or io.open(DIR .. name, "w")   -- no logs/ folder: next to the scripts
  if not fh then return nil end
  io.write(fh, table.concat(L, "\n") .. "\n")
  io.close(fh)
  return name
end
