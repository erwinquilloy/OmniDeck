--[[
  OmniDeck - avionics + moving map telemetry widget for FrSky Ethos.
  ArduPilot (passthrough over CRSF/ELRS, S.Port/F.Port/FBUS, mLRS), INAV and
  Betaflight (the radio's native telemetry sensors).

  This file is the Ethos front end: widget registration, the settings form and
  storage. The pages and telemetry live in ui.lua and the modules it loads, which
  the EdgeTX version shares. Use it as a full-screen widget.
]]

local UI = assert(loadfile((OD_DIR or "") .. "ui.lua"))()
local VERSION = UI.VERSION
local T, MAP, TL, MI, MSPC, AU = UI.T, UI.MAP, UI.TL, UI.MI, UI.MSPC, UI.AU

-- ---------------------------------------------------------------- settings
local function configure(w)
  -- form order only (grouped 0.4.0e); what is saved and in which order is SETTINGS below
  local line = form.addLine("Telemetry link")
  form.addChoiceField(line, nil, { { "Auto", T.LINK_AUTO }, { "CRSF / ELRS / mLRS", T.LINK_CRSF }, { "S.Port / F.Port / FBUS", T.LINK_SPORT } },
    function() return w.linkMode end, function(v) w.linkMode = v end)
  -- units
  line = form.addLine("Speed units")
  form.addChoiceField(line, nil, { { "km/h", 0 }, { "m/s", 1 }, { "knots", 2 }, { "mph", 3 } },
    function() return w.spdUnit end, function(v) w.spdUnit = v end)
  line = form.addLine("Altitude units")
  form.addChoiceField(line, nil, { { "metres", 0 }, { "feet", 1 } },
    function() return w.altUnit end, function(v) w.altUnit = v end)
  line = form.addLine("Efficiency units")
  form.addChoiceField(line, nil, { { "Wh/km", 0 }, { "mAh/km", 1 }, { "Wh/mi", 2 }, { "mAh/mi", 3 } },
    function() return w.effUnit end, function(v) w.effUnit = v end)
  -- main page
  line = form.addLine("Start page")
  form.addChoiceField(line, nil, { { "Main", 1 }, { "Map", 2 } },
    function() return w.startPage end, function(v) w.startPage = v end)
  -- the panel at the top right of the main page, above the data blocks (test42)
  line = form.addLine("Main page top-right panel")
  form.addChoiceField(line, nil, { { "Minimap", 0 }, { "Home arrow", 1 }, { "Radar", 2 }, { "OmniDeck logo", 3 },
    { "Logo file (below)", 4 } },
    function() return w.topPanel end, function(v) w.topPanel = v end)
  -- the logo for panel choice "Logo file": any PNG in /scripts/omnideck/logos/ (bigger ones
  -- are scaled down to the panel, smaller ones are not enlarged)
  local logos = UI.logoFiles()
  local lchoices = { { "None", 0 } }
  for i, n in ipairs(logos) do lchoices[#lchoices + 1] = { n, i } end
  line = form.addLine("Logo file")
  form.addChoiceField(line, nil, lchoices,
    function()
      for i, n in ipairs(logos) do if n == w.logoFile then return i end end
      return 0
    end,
    function(v) w.logoFile = (v > 0 and logos[v]) or "" end)
  -- map page
  line = form.addLine("Map orientation")
  form.addChoiceField(line, nil, { { "North up", 0 }, { "Heading up", 1 } },
    function() return w.orient end, function(v) w.orient = v end)
  line = form.addLine("Map view")
  form.addChoiceField(line, nil, { { "Aircraft centred (zoom by hand)", 0 }, { "Home centred (zooms out to keep the aircraft on the map)", 1 } },
    function() return w.zoomMode end, function(v) w.zoomMode = v end)
  line = form.addLine("Zoom source")
  form.addSourceField(line, nil, function() return w.zoomSource end, function(v) w.zoomSource = v end)
  -- tile sets found on the SD card (High Resolution Map Generator / Yaapu folders)
  local tileSets = UI.scanTiles()
  local tchoices = { { "Off (vector map)", 0 } }
  for i, ts in ipairs(tileSets) do tchoices[#tchoices + 1] = { string.format("%s (z%d-%d)", ts.label, ts.minZ, ts.maxZ), i } end
  line = form.addLine("Map tiles")
  form.addChoiceField(line, nil, tchoices,
    function()
      for i, ts in ipairs(tileSets) do if ts.label == w.tileSet then return i end end
      return 0
    end,
    function(v)
      w.tileSet = (v > 0 and tileSets[v]) and tileSets[v].label or ""
      w.tz = nil
      TL.clear()
    end)
  line = form.addLine("Flight trail")
  form.addChoiceField(line, nil, { { "On", 1 }, { "Off", 0 } },
    function() return w.trail end, function(v) w.trail = v end)
  if form.addTextButton then
    line = form.addLine("Clear trail + learned WPs")
    form.addTextButton(line, nil, "Clear", function() MAP.resetTrail() MI.clearLearned() return true end)
  end
  -- missions on the map
  -- ArduPilot mission file (Mission Planner .waypoints in /scripts/omnideck/missions/)
  local files = MI.listFiles()
  local fchoices = { { "None (learn from telemetry)", 0 } }
  for i, n in ipairs(files) do fchoices[#fchoices + 1] = { n, i } end
  line = form.addLine("Mission file")
  form.addChoiceField(line, nil, fchoices,
    function()
      for i, n in ipairs(files) do if n == w.missionFile then return i end end
      return 0
    end,
    function(v)
      w.missionFile = (v > 0 and files[v]) or ""
      MI.loadFile(w.missionFile)
    end)
  -- Stratos firmware: the whole mission over MAVlite onto the map (S.Port, F.Port, ELRS, Crossfire)
  line = form.addLine("ArduPilot mission download")
  form.addChoiceField(line, nil, { { "Off", 0 }, { "On", 1 } },
    function() return w.apMission end, function(v) w.apMission = v end)
  line = form.addLine("INAV mission download")
  form.addChoiceField(line, nil, { { "On", 1 }, { "Off", 0 } },
    function() return w.inavWp end, function(v) w.inavWp = v if v == 0 then MI.setInav(nil) end end)
  if form.addTextButton then
    line = form.addLine("Re-download INAV mission")
    form.addTextButton(line, nil, "Reload", function() MSPC.restart() MI.setInav(nil) w.inavWpN = nil return true end)
  end
  -- the pages a tap cycles through (test42); the flight summary still opens on disarm
  line = form.addLine("Messages page")
  form.addChoiceField(line, nil, { { "Auto (ArduPilot only)", 0 }, { "On", 1 }, { "Off", 2 } },
    function() return w.msgPage end, function(v) w.msgPage = v end)
  line = form.addLine("Flight stats page")
  form.addChoiceField(line, nil, { { "Off", 0 }, { "On", 1 } },
    function() return w.statsPage end, function(v) w.statsPage = v end)
  line = form.addLine("Flight summary on disarm")
  form.addChoiceField(line, nil, { { "On", 1 }, { "Off", 0 } },
    function() return w.sumAuto end, function(v) w.sumAuto = v end)
  line = form.addLine("Sensor check page")
  form.addChoiceField(line, nil, { { "Off", 0 }, { "On", 1 } },
    function() return w.checkPage end, function(v) w.checkPage = v end)
  -- parameters: ArduPlane (MAVlite) and INAV 9+ (MSP)
  line = form.addLine("Params page (ArduPilot, INAV)")
  form.addChoiceField(line, nil, { { "Off", 0 }, { "On", 1 } },
    function() return w.paramsPage end, function(v) w.paramsPage = v end)
  -- in flight: PID / Q PID / TRIM rows only; everything else stays view only while armed
  line = form.addLine("Params: edit in flight")
  form.addChoiceField(line, nil, { { "Off", 0 }, { "Gains and trim", 1 } },
    function() return w.flightEdit end, function(v) w.flightEdit = v end)
  -- voice and alarms
  -- voice packs found in /scripts/omnideck/audio/
  local packs = AU.packs()
  local vchoices = { { "Off", 0 } }
  for i, n in ipairs(packs) do vchoices[#vchoices + 1] = { n, i } end
  line = form.addLine("Voice")
  form.addChoiceField(line, nil, vchoices,
    function()
      for i, n in ipairs(packs) do if n == w.voice then return i end end
      return 0
    end,
    function(v)
      w.voice = (v > 0 and packs[v]) or "off"
      AU.setVoice(w.voice)
      AU.test()
    end)
  line = form.addLine("Message beep")
  form.addChoiceField(line, nil, { { "Every message", 1 }, { "Warnings and errors", 2 }, { "Off", 0 } },
    function() return w.beep end, function(v) w.beep = v AU.setBeep(v) end)
  line = form.addLine("Battery mAh (INAV/BF only)")
  form.addNumberField(line, nil, 0, 50000, function() return w.batCap end, function(v) w.batCap = v end)
  line = form.addLine("Battery cells (0 = auto)")
  form.addNumberField(line, nil, 0, 14, function() return w.cells end, function(v) w.cells = v end)
  line = form.addLine("Low voltage alarm (V per cell, 0 = off)")
  local fv = form.addNumberField(line, nil, 0, 450, function() return w.lowVolt end, function(v) w.lowVolt = v end)
  pcall(function() fv:decimals(2) end)
  pcall(function() fv:suffix("V") end)
  line = form.addLine("Critical voltage alarm (V per cell, 0 = off)")
  local fc = form.addNumberField(line, nil, 0, 450, function() return w.critVolt end, function(v) w.critVolt = v end)
  pcall(function() fc:decimals(2) end)
  pcall(function() fc:suffix("V") end)
  line = form.addLine("Low altitude alarm: Terrain, pull up (0 = off)")
  local fa = form.addNumberField(line, nil, 0, 3000, function() return w.lowAlt end, function(v) w.lowAlt = v end)
  pcall(function() fa:suffix(w.altUnit == 1 and "ft" or "m") end)
  form.addLine("OmniDeck " .. VERSION)
end

-- Ethos widget storage is positional: the key names are ignored and values come back in
-- the order they were written (see b14ckyy's ETHOS Mapping Widget, and Ethos issue 5462).
-- So read() and write() walk this one list in the same order, nothing is ever written as
-- nil (a missing value would shift every later one), and a schema number goes first so
-- settings saved by an older layout fall back to defaults instead of being read shifted.
local SCHEMA = 2
local SETTINGS = {
  -- { field in w, kind (n number, s string, src source), default }
  { "linkMode", "n", T.LINK_AUTO }, { "orient", "n", 0 }, { "zoomMode", "n", 0 },
  { "zoomSource", "src" }, { "spdUnit", "n", 0 }, { "altUnit", "n", 0 }, { "trail", "n", 1 },
  { "startPage", "n", 1 }, { "level", "n", 4 }, { "tileSet", "s", "" }, { "missionFile", "s", "" },
  { "tz", "n", 0 }, { "inavWp", "n", 0 }, { "sumAuto", "n", 1 }, { "voice", "s", "" },
  { "batCap", "n", 0 }, { "effUnit", "n", 0 }, { "beep", "n", 1 },
  -- added in 0.2.0-test6: at the end, so settings saved before still read back in place
  { "lowVolt", "n", 0 }, { "cells", "n", 0 }, { "lowAlt", "n", 0 }, { "critVolt", "n", 0 },
  -- added in 0.2.0-test41, at the end for the same reason
  { "logoFile", "s", "omnideck.png" },
  -- added in 0.2.0-test42, at the end: -1 = not saved yet (taken from the older settings)
  { "topPanel", "n", -1 }, { "msgPage", "n", 0 }, { "statsPage", "n", 0 }, { "checkPage", "n", 0 },
  -- added for the PARAMS page, at the end for the same reason
  { "paramsPage", "n", 0 }, { "flightEdit", "n", 0 },
  -- added for the ArduPilot mission download, at the end for the same reason
  { "apMission", "n", 0 },
}

local function isSource(v) return type(v) == "userdata" end

local function read(w)
  local ok = tonumber(storage.read("schema")) == SCHEMA
  for _, f in ipairs(SETTINGS) do
    local v = ok and storage.read(f[1]) or nil
    if f[2] == "n" then v = tonumber(v) if v == nil then v = f[3] end
    elseif f[2] == "s" then if type(v) ~= "string" then v = f[3] end
    elseif not isSource(v) then v = nil end
    w[f[1]] = v
  end
  if w.tz == 0 then w.tz = nil end
  -- test42: the X18 can show the minimap again; a model saved before keeps its logo (test41
  -- showed the logo file, OmniDeck by default)
  if w.topPanel < 0 then
    w.topPanel = (w.logoFile == "omnideck.png" or w.logoFile == "") and 3 or 4
  end
  MI.loadFile(w.missionFile)
  AU.setBeep(w.beep)
  -- voice: on until the pilot picks something else, if a pack is on the card
  if w.voice == "" then w.voice = AU.packs()[1] or "off" end
  AU.setVoice(w.voice)
  w.page = w.startPage
end

local function write(w)
  storage.write("schema", SCHEMA)
  for _, f in ipairs(SETTINGS) do
    local v = w[f[1]]
    if f[2] == "n" then v = tonumber(v) or f[3]
    elseif f[2] == "s" then v = type(v) == "string" and v or f[3]
    elseif not isSource(v) then v = 0 end          -- no source chosen: a placeholder, never nil
    storage.write(f[1], v)
  end
end

local function init()
  system.registerWidget({
    key = "omndeck", name = "OmniDeck", create = UI.create, paint = UI.paint, wakeup = UI.wakeup,
    event = UI.event, configure = configure, read = read, write = write,
  })
end

return { init = init }
