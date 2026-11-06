-- OmniDeck Check: run it from SYS > Tools when the OmniDeck widget does not show up in the
-- widget list. EdgeTX leaves a widget out of that list when its main.lua is missing or stops
-- with an error while loading, and says nothing; this tool loads it the same way and shows
-- what happened. Take a photo of the screen and send it back.

local ROOT = "/WIDGETS/OmniDeck/"
local FILES = { "main.lua", "etx.lua", "cfg.lua", "ui.lua", "telem.lua", "hud.lua", "map.lua", "tiles.lua",
                "audio.lua", "summary.lua", "mission.lua", "mspclient.lua" }
local lines = {}

local function add(text)
  -- wrap long error messages to the screen
  text = tostring(text)
  while #text > 58 do
    lines[#lines + 1] = string.sub(text, 1, 58)
    text = "  " .. string.sub(text, 59)
  end
  lines[#lines + 1] = text
end

local function exists(path)
  local f = io.open(path, "r")
  if f == nil then return false end
  io.close(f)
  return true
end

local function init()
  local ver, radio, maj, minor, rev, osname = getVersion()
  add(string.format("%s %s  radio %s  screen %dx%d", tostring(osname or "EdgeTX"), tostring(ver),
    tostring(radio), LCD_W or 0, LCD_H or 0))
  local missing = {}
  for _, f in ipairs(FILES) do
    if not exists(ROOT .. f) then missing[#missing + 1] = f end
  end
  if #missing > 0 then
    add("MISSING in " .. ROOT .. ": " .. table.concat(missing, ", "))
    add("Copy the zip's WIDGETS folder to the root of the SD card.")
    return
  end
  add("Files: all in " .. ROOT)
  -- load from the .lua text so an error names its file and line (the compiled .luac do not)
  OD_DEBUGLOAD = true
  -- does loadScript's third argument (the environment the widget's modules run in) work here?
  local probe = ROOT .. "_probe.lua"
  local pf = io.open(probe, "w")
  if pf then
    -- EdgeTX: io.write(file, text); standard Lua (simulator): file:write(text)
    if not pcall(io.write, pf, "return ODPROBE") then pcall(function() pf:write("return ODPROBE") end) end
    io.close(pf)
    local pc, perr = loadScript(probe, "T", { ODPROBE = 42 })
    local okP, pv = false, perr
    if pc then okP, pv = pcall(pc) end
    -- informational: OmniDeck no longer relies on it (EdgeTX 2.9 gives the chunk _ENV = nil)
    add("env test: " .. (okP and pv == 42 and "works" or "broken (EdgeTX 2.9; handled)"))
  else
    add("env test: could not write " .. probe)
  end
  -- step by step: the adapter, then each module on its own, so a failure names the module
  local echunk, eerr = loadScript(ROOT .. "etx.lua", "T")
  if not echunk then add("LOAD ERROR etx.lua: " .. tostring(eerr)) return end
  local okE, E = pcall(echunk)
  if not okE then add("ERROR in etx.lua: " .. tostring(E)) return end
  for _, m in ipairs({ "telem.lua", "map.lua", "hud.lua", "tiles.lua", "mission.lua", "mspclient.lua",
                       "summary.lua", "audio.lua", "ui.lua" }) do
    local okL, chunk = pcall(E.loadfile, m)
    if not okL then add("LOAD ERROR " .. tostring(chunk)) return end
    local okR, res = pcall(chunk)
    if not okR then add("ERROR in " .. m .. ": " .. tostring(res)) return end
    if res == nil then add("ERROR: " .. m .. " returned nothing") return end
  end
  add("OK: adapter + all modules load")
  local chunk, err = loadScript(ROOT .. "main.lua", "T")
  if not chunk then add("LOAD ERROR: " .. tostring(err)) return end
  local ok, w = pcall(chunk)
  if not ok then add("ERROR while loading: " .. tostring(w)) return end
  if type(w) ~= "table" or type(w.refresh) ~= "function" then add("main.lua did not return a widget") return end
  add("OK: widget '" .. tostring(w.name) .. "' loads, " .. #(w.options or {}) .. " options")
  -- also build one, as the radio does when it is put on a screen (errors here show in the zone)
  local opt = {}
  for _, o in ipairs(w.options or {}) do opt[o[1]] = o[3] end
  local okC, inst = pcall(w.create, { x = 0, y = 0, w = LCD_W, h = LCD_H }, opt)
  if not okC then add("ERROR in create: " .. tostring(inst)) return end
  local okR, errR = pcall(w.refresh, inst)
  if not okR then add("ERROR in first refresh: " .. tostring(errR)) return end
  add("OK: create + first screen update")
  -- voice: the packs the widget can see (folders in WIDGETS/OmniDeck/audio/)
  local packs = E.system.listFiles(ROOT .. "audio/")
  local names = {}
  for _, n in ipairs(packs) do
    n = string.gsub(n, "/+$", "")
    if n ~= "" and not string.find(n, ".", 1, true) then names[#names + 1] = n end
  end
  table.sort(names)
  if dir == nil then add("Voice: this EdgeTX has no dir(), packs cannot be listed")
  elseif #names == 0 then add("Voice: NO packs in " .. ROOT .. "audio/ - copy the audio folder from the full zip")
  else
    add("Voice packs: " .. table.concat(names, ", ") .. " (pick one in SYS > Tools > OmniDeck Setup)")
    -- every pack should hold the same sounds: list what each lacks against all of them together
    local files, all = {}, {}
    for _, pk in ipairs(names) do
      files[pk] = {}
      for _, f in ipairs(E.system.listFiles(ROOT .. "audio/" .. pk .. "/")) do
        if string.find(f, "%.wav$") then files[pk][f] = true all[f] = true end
      end
    end
    for _, pk in ipairs(names) do
      local miss = {}
      for f in pairs(all) do if not files[pk][f] then miss[#miss + 1] = string.gsub(f, "%.wav$", "") end end
      table.sort(miss)
      if #miss > 0 then
        add(pk .. ": " .. #miss .. " sounds MISSING: " .. table.concat(miss, " ", 1, math.min(#miss, 12)) ..
          (#miss > 12 and " ..." or "") .. " - copy the folder again from the zip")
      end
    end
  end
  if getAvailableMemory then add("Free Lua memory: " .. math.floor(getAvailableMemory() / 1024) .. " KB") end
  add("Restart the radio, then add it in Screens setup.")
end

local function run(event)
  lcd.clear()
  lcd.drawText(6, 4, "OmniDeck Check", MIDSIZE)
  for i, t in ipairs(lines) do lcd.drawText(6, 24 + i * 18, t, SMLSIZE) end
  if event == EVT_VIRTUAL_EXIT then return 1 end
  return 0
end

return { init = init, run = run }
