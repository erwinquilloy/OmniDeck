--[[
  OmniDeck Mono: telemetry display for EdgeTX black-and-white radios (TX12 MK2, Pocket, Boxer;
  128x64). ArduPilot over FrSky passthrough (CRSF / ELRS / mLRS, S.Port, F.Port), INAV and
  Betaflight from the radio's own sensors - the same decoding as the colour OmniDeck.

  Set it up as a telemetry screen: MODEL > DISPLAY > a screen > Script > omnid.
  ENTER: next page - main, map, messages (ArduPilot only), flight stats (Setup: STATS PAGE),
  link check, sensor check (Setup: SENSOR PAGE). The wheel or +/- scrolls messages and sensors.
  The flight summary opens by itself at disarm (Setup: SUMMARY); ENTER leaves it. A text log of
  each flight is written at landing only with Setup: FLIGHT LOG ON (default OFF).
  Every start is a fresh one, and so is a model switch: nothing of the old model stays.
  Settings: SYS > Tools > OmniDeck Setup (per model; applied when the tool is left).

  Memory: EdgeTX gives a telemetry script about 127 KB of Lua memory on a TX12 MK2 (measured).
  The telemetry code, the flight summary and the voice stay loaded; a page is loaded when it is
  shown and dropped when another one is, and the log writer only for the moment it writes.

  background() runs while another screen is up, run() while this one is shown; both read
  telemetry, so nothing is missed either way.
]]

-- EdgeTX on this radio may run without Lua's table library ("attempt to index a nil value (field
-- 'table')", TX12 MK2, EdgeTX 2.12, 2026-11-13). The few calls OmniDeck makes, in plain Lua, only
-- where the library is missing.
if rawget(_G, "table") == nil then
  local T = {}
  function T.insert(t, a, b)
    if b == nil then t[#t + 1] = a return end
    for i = #t, a, -1 do t[i + 1] = t[i] end
    t[a] = b
  end
  function T.remove(t, pos)
    local n = #t
    if n == 0 then return nil end
    pos = pos or n
    local v = t[pos]
    for i = pos, n - 1 do t[i] = t[i + 1] end
    t[n] = nil
    return v
  end
  function T.concat(t, sep, i, j)
    sep, i, j = sep or "", i or 1, j or #t
    local out = ""
    for k = i, j do out = out .. t[k] .. (k < j and sep or "") end
    return out
  end
  function T.sort(t, lt)
    lt = lt or function(a, b) return a < b end
    for i = 2, #t do
      local v, k = t[i], i - 1
      while k >= 1 and lt(v, t[k]) do t[k + 1] = t[k] k = k - 1 end
      t[k + 1] = v
    end
  end
  local function unpack(t, i, j)
    i, j = i or 1, j or #t
    if i > j then return end
    return t[i], unpack(t, i + 1, j)
  end
  T.unpack = unpack
  table = T
end

local ROOT = "/SCRIPTS/OMNID/"
local VERSION = "0.1.0"
-- the page cycle; a page whose test fails is skipped
local PAGES = { "pmain.lua", "pmap.lua", "pmsg.lua", "psum.lua", "plink.lua", "psens.lua" }
local SHOW = {
  ["pmsg.lua"] = function(s, c) return s.fc == "ArduPilot" end,
  ["psum.lua"] = function(s, c) return c.statsPage == 1 end,
  ["psens.lua"] = function(s, c) return c.checkPage == 1 end,
}

local E, T, F, A
local ctx = { version = VERSION, flightT = 0, trailE = {}, trailN = {} }
local cfg
local pageN, page, onSummary = 1, nil, false   -- onSummary: opened by the disarm, not the cycle

-- why the last load failed (shown in place of a page that didn't load): loadScript's own message,
-- e.g. "not enough memory", or the error the file raised when run
local loadErr = nil
local function load(name)
  loadErr = nil
  local chunk, err = loadScript(ROOT .. name, OD_DEBUGLOAD and "T" or "bt")
  if not chunk then loadErr = name .. ": " .. tostring(err) return nil end
  local ok, r = pcall(chunk)
  if not ok then loadErr = name .. ": " .. tostring(r) return nil end
  if r == nil then loadErr = name .. ": returned nothing" end
  return r
end

-- A page that didn't load is tried again only every 3 s (retryAt): a load that failed for lack of
-- memory, tried again on every update, froze the TX12 MK2 (power switch dead, RC link still up;
-- a page load test 2026-11-17). Its reason is shown in its place.
local retryAt = -100
local function loadPage(n, auto)
  page = nil
  collectgarbage()
  page = load(PAGES[n])
  pageN, onSummary = n, auto == true
  if not page and E then retryAt = E.os.clock() + 3 end
  collectgarbage()
end

local function nextPage()
  local s = T.s
  for k = 1, #PAGES do
    local n = (pageN + k - 1) % #PAGES + 1
    local test = SHOW[PAGES[n]]
    if not test or test(s, cfg) then return n end
  end
  return 1
end

-- flight trail for the map, in metres east / north of home. A point every TRAIL_STEP metres;
-- when full, every other point goes and the spacing doubles, so the whole flight stays in
-- TRAIL_MAX points (about 3 KB) however long it is. Cleared when home moves (a new flight).
local TRAIL_MAX, TRAIL_STEP0 = 80, 15
local trailStep, trailLat, trailLon = TRAIL_STEP0, nil, nil
local trailGen = 0
local function trail(s)
  if T.gen ~= trailGen then   -- another flight controller (telem.lua resetFc): its own flight
    trailGen = T.gen
    ctx.trailE, ctx.trailN, trailStep, trailLat, trailLon = {}, {}, TRAIL_STEP0, nil, nil
  end
  if not (s.lat and s.homeLat) then return end
  local tE, tN = ctx.trailE, ctx.trailN
  if s.homeLat ~= trailLat or s.homeLon ~= trailLon then
    if trailLat then
      local dE = (s.homeLon - trailLon) * 111320 * math.cos(math.rad(s.homeLat))
      local dN = (s.homeLat - trailLat) * 111320
      if dE * dE + dN * dN > 250000 then   -- home moved over 500 m: a new flight
        tE, tN = {}, {}
        ctx.trailE, ctx.trailN, trailStep = tE, tN, TRAIL_STEP0
      end
    end
    trailLat, trailLon = s.homeLat, s.homeLon
  end
  local e = (s.lon - s.homeLon) * 111320 * math.cos(math.rad(s.homeLat))
  local n = (s.lat - s.homeLat) * 111320
  local k = #tE
  if k > 0 then
    local de, dn = e - tE[k], n - tN[k]
    if de * de + dn * dn < trailStep * trailStep then return end
  end
  tE[k + 1], tN[k + 1] = e, n
  if k + 1 >= TRAIL_MAX then
    local j = 0
    for i = 1, k + 1, 2 do j = j + 1; tE[j], tN[j] = tE[i], tN[i] end
    for i = k + 1, j + 1, -1 do tE[i], tN[i] = nil, nil end
    trailStep = trailStep * 2
  end
end

-- read telemetry; voice and flight summary take turns, one per call (each still runs several
-- times a second), so no call carries both inside EdgeTX's per-call Lua limit
local turn = 0
local init

-- A model switch is a fresh start, as in the colour OmniDeck: telemetry, messages, trail, flight
-- in progress and last flight, alarms, settings (they are per model) and the page all start
-- again, by loading everything anew. Checked once a second; harmless where EdgeTX itself
-- restarts the script on a model switch.
local curModel, modelAt = nil, -100
local function modelName()
  local ok, info = pcall(model.getInfo)
  return ok and type(info) == "table" and info.name or nil
end
local function freshStart()
  page, T, F, A, E, cfg = nil, nil, nil, nil, nil, nil
  ctx.T, ctx.F, ctx.A = nil, nil, nil
  ctx.flightT, ctx.trailE, ctx.trailN = 0, {}, {}
  ctx.logName, ctx.wantSummary, ctx.wantStart, ctx.wantLog = nil, nil, nil, nil
  trailStep, trailLat, trailLon, trailGen = TRAIL_STEP0, nil, nil, 0
  collectgarbage()
  init()
end

local function pump()
  E.tick()
  if E.os.clock() - modelAt >= 1 then
    modelAt = E.os.clock()
    local n = modelName()
    if n ~= curModel then freshStart() return end
  end
  T.wakeup(cfg.linkMode)
  local s, now = T.s, E.os.clock()
  -- ArduPilot sends BATT_CAPACITY; INAV and Betaflight don't, so the pilot sets it
  if s.fc and s.fc ~= "ArduPilot" then s.cap = cfg.batCap > 0 and cfg.batCap or nil end
  turn = 1 - turn
  local alive = T.alive()
  if turn == 0 then
    A.update(s, alive, now)
  else
    local ev = F.update(s, alive, now, T.distBrg)
    if ev == "done" then
      ctx.logName = nil
      ctx.wantLog = cfg.logFlight == 1
      if cfg.sumAuto == 1 then ctx.wantSummary = true end
    elseif ev == "armed" then
      ctx.logName = nil
      if onSummary then ctx.wantStart = true end
    end
  end
  ctx.flightT = F.timer(now) or 0
  trail(s)
end

local function startPage() return cfg.startPage == 2 and 2 or 1 end

-- the flight log, at landing: the page is unloaded first and the writer dropped before the
-- summary page loads, so the three are never in memory together. Writing the log with the main
-- page and the summary loaded took the TX12 MK2 past EdgeTX's Lua limit ("Lua disabled!", 2026-11-13).
local function writeLog()
  if not ctx.wantLog then return end
  ctx.wantLog = false
  page = nil
  collectgarbage()
  local w = load("log.lua")
  local ok, name = false, nil
  if w then ok, name = pcall(w, T.s, F.last(), ctx.u, VERSION) end
  ctx.logName = ok and name or nil
  w = nil
  collectgarbage()
end

init = function()
  curModel, modelAt = modelName(), -100
  E = load("etx.lua")
  T = E.loadfile("telem.lua")()
  F = load("sum.lua")
  A = load("aud.lua")
  local C = load("cfg.lua")
  cfg = C.read()
  ctx.u = C.units(cfg)
  C = nil
  A.setVoice(cfg.voice)
  A.setBeep(cfg.beep)
  E.tick()
  A.greetNow(E.os.clock())
  A.cells, A.vLow, A.vCrit = cfg.cells, cfg.lowVolt / 100, cfg.critVolt / 100
  ctx.T, ctx.F, ctx.A, ctx.clock = T, F, A, E.os.clock
  loadPage(startPage())
end

-- EdgeTX stops all Lua ("Lua disabled!") once the script heap passes ~127 KB on a TX12 MK2, and
-- it counts garbage not yet collected: Lua's own collector lets that pile up well past the live
-- data before it runs (TX12 MK2, INAV, killed at disarm 2026-11-13). A full collection whenever
-- the heap passes GC_KB keeps the garbage from ever reaching the limit.
-- The trigger sits GC_MARGIN KB above the live data (at least GC_KB, at most GC_MAX_KB), so a
-- collection runs every second or two rather than on every call when the live data is large.
-- 8 / 112 since 2026-11-20: over mLRS (bigger CRSF passthrough frames, a new table per frame)
-- the TX12 MK2 showed 107/127K and froze with the old 12 / 118 (screen, keys and power switch
-- dead, RF up); the margin to the ~127 KB ceiling was too thin for that much garbage.
local GC_KB, GC_MAX_KB, GC_MARGIN = OD_GC_KB or 96, OD_GC_MAX_KB or 112, OD_GC_MARGIN or 8
local gcAt = GC_KB
local function gcGuard()
  if collectgarbage("count") > gcAt then
    collectgarbage()
    gcAt = math.max(GC_KB, math.min(GC_MAX_KB, collectgarbage("count") + GC_MARGIN))
  end
end

local function background()
  pump()
  writeLog()
  gcGuard()
end

local function run(event)
  pump()
  writeLog()
  if ctx.wantSummary then
    ctx.wantSummary = false
    loadPage(4, true)
  elseif ctx.wantStart then
    ctx.wantStart = false
    loadPage(startPage())
  elseif event == EVT_VIRTUAL_ENTER then
    if onSummary then loadPage(startPage()) else loadPage(nextPage()) end
    event = 0   -- the key that turned the page is not the new page's
  end
  -- unloaded for the log: back at once; a page that failed to load: every 3 s at most
  if page == nil and T and E.os.clock() >= retryAt then loadPage(pageN, onSummary) end
  lcd.clear()
  if page then
    page.draw(ctx, event)
  else
    lcd.drawText(1, 1, "OmniDeck: page missing", 0)
    -- the reason, 25 characters a line, and the memory in use (EdgeTX stops Lua at ~127 KB)
    local t = loadErr or "?"
    for i = 0, 4 do lcd.drawText(1, 11 + i * 8, string.sub(t, i * 25 + 1, i * 25 + 25), SMLSIZE) end
    lcd.drawText(1, 56, "LUA MEM " .. math.floor(collectgarbage("count")) .. "K", SMLSIZE)
  end
  gcGuard()
  return 0
end

return { init = init, background = background, run = run }
