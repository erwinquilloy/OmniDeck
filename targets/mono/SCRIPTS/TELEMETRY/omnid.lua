--[[
  OmniDeck Mono: telemetry display for EdgeTX black-and-white radios (TX12 MK2, Pocket, Boxer;
  128x64). ArduPilot over FrSky passthrough (CRSF / ELRS / mLRS, S.Port, F.Port), INAV and
  Betaflight from the radio's own sensors - the same decoding as the colour OmniDeck.

  Set it up as a telemetry screen: MODEL > DISPLAY > a screen > Script > omnid.
  ENTER: next page. Settings come from SYS > Tools > OmniDeck Setup (a later step).

  Memory: EdgeTX gives a telemetry script about 127 KB of Lua memory on a TX12 MK2 (measured).
  The telemetry code stays loaded; a page is loaded when it is shown and dropped when another
  one is, so only one page's code is in memory at a time.

  background() runs while another screen is up, run() while this one is shown; both read
  telemetry, so nothing is missed either way.
]]

local ROOT = "/SCRIPTS/OMNID/"
local VERSION = "0.1.0"
local PAGES = { "pmain.lua", "plink.lua" }

local E, T
local ctx = { version = VERSION, armedFor = 0 }
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
