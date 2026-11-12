--[[
  OmniDeck Mono: telemetry display for EdgeTX black-and-white radios (TX12 MK2, Pocket, Boxer;
  128x64). ArduPilot over FrSky passthrough (CRSF / ELRS / mLRS, S.Port, F.Port), INAV and
  Betaflight from the radio's own sensors - the same decoding as the colour OmniDeck.

  Set it up as a telemetry screen: MODEL > DISPLAY > a screen > Script > omnid.
  ENTER: next page - main, map, messages (ArduPilot only), flight stats (Setup: STATS PAGE),
  link check, sensor check (Setup: SENSOR PAGE). The wheel or +/- scrolls messages and sensors.
  The flight summary opens by itself at disarm (Setup: SUMMARY); ENTER leaves it.
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

local function load(name)
  local chunk = loadScript(ROOT .. name, OD_DEBUGLOAD and "T" or "bt")
  return chunk and chunk() or nil
end

local function loadPage(n, auto)
  page = nil
  collectgarbage()
  page = load(PAGES[n])
  pageN, onSummary = n, auto == true
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
local function trail(s)
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
local function pump()
  E.tick()
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
      local w = load("log.lua")
      local ok, name = false, nil
      if w then ok, name = pcall(w, s, F.last(), ctx.u, VERSION) end
      ctx.logName = ok and name or nil
      w = nil
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

local function init()
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

local function background()
  pump()
end

local function run(event)
  pump()
  if ctx.wantSummary then
    ctx.wantSummary = false
    loadPage(4, true)
  elseif ctx.wantStart then
    ctx.wantStart = false
    loadPage(startPage())
  elseif event == EVT_VIRTUAL_ENTER then
    if onSummary then loadPage(startPage()) else loadPage(nextPage()) end
  end
  lcd.clear()
  if page then
    page.draw(ctx, event)
  else
    lcd.drawText(1, 1, "OmniDeck: page missing", 0)
  end
  return 0
end

return { init = init, background = background, run = run }
