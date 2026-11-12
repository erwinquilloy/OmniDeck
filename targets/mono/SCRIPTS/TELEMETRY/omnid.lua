--[[
  OmniDeck Mono: telemetry display for EdgeTX black-and-white radios (TX12 MK2, Pocket, Boxer;
  128x64). ArduPilot over FrSky passthrough (CRSF / ELRS / mLRS, S.Port, F.Port), INAV and
  Betaflight from the radio's own sensors - the same decoding as the colour OmniDeck.

  Set it up as a telemetry screen: MODEL > DISPLAY > a screen > Script > omnid.
  ENTER: next page (main, map, messages, link check); the wheel scrolls the messages. Settings come from SYS > Tools > OmniDeck Setup (a later step).

  Memory: EdgeTX gives a telemetry script about 127 KB of Lua memory on a TX12 MK2 (measured).
  The telemetry code stays loaded; a page is loaded when it is shown and dropped when another
  one is, so only one page's code is in memory at a time.

  background() runs while another screen is up, run() while this one is shown; both read
  telemetry, so nothing is missed either way.
]]

local ROOT = "/SCRIPTS/OMNID/"
local VERSION = "0.1.0"
local PAGES = { "pmain.lua", "pmap.lua", "pmsg.lua", "plink.lua" }

local E, T
local ctx = { version = VERSION, armedFor = 0, trailE = {}, trailN = {} }

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
local pageN, page = 1, nil

local function loadPage(n)
  page = nil
  collectgarbage()
  local chunk = loadScript(ROOT .. PAGES[n], OD_DEBUGLOAD and "T" or "bt")
  page = chunk and chunk() or nil
  pageN = n
  collectgarbage()
end

-- read telemetry; the flight timer counts while armed (the flight summary comes in a later step)
local function pump()
  E.tick()
  T.wakeup(0)
  local s, now = T.s, E.os.clock()
  if s.armed then
    if not ctx.armAt then ctx.armAt = now - ctx.armedFor end
    ctx.armedFor = now - ctx.armAt
  else
    ctx.armAt = nil
  end
  trail(s)
end

local function init()
  E = loadScript(ROOT .. "etx.lua", OD_DEBUGLOAD and "T" or "bt")()
  T = E.loadfile("telem.lua")()
  ctx.T, ctx.clock = T, E.os.clock
  loadPage(1)
end

local function background()
  pump()
end

local function run(event)
  pump()
  if event == EVT_VIRTUAL_ENTER then loadPage(pageN % #PAGES + 1) end
  lcd.clear()
  if page then
    page.draw(ctx, event)
  else
    lcd.drawText(1, 1, "OmniDeck: page missing", 0)
  end
  return 0
end

return { init = init, background = background, run = run }
