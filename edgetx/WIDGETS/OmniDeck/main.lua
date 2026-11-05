--[[
  OmniDeck for EdgeTX colour radios (RadioMaster TX16S MK2 480x272, MK3 800x480, ...).
  Avionics + moving map for ArduPilot (FrSky passthrough over CRSF/ELRS, S.Port,
  F.Port, mLRS), INAV and Betaflight (the radio's telemetry sensors).

  Same pages and telemetry as the Ethos widget: the shared files (ui.lua and the
  modules it loads) run on etx.lua, which gives them the Ethos-style calls.

  Use it full screen: add it to a one-zone layout, then long-press it and pick
  "Full screen". Tap or press ENTER to change page; the wheel zooms the map and
  scrolls the messages. Long-press RTN to leave full screen.

  EdgeTX stops a widget that runs more than about 20,000 Lua instructions in one
  call, so telemetry reading is capped per call and the work is spread out.
]]

local ROOT = "/WIDGETS/OmniDeck/"
local E = loadScript(ROOT .. "etx.lua", OD_DEBUGLOAD and "T" or "bt")()
local UI = E.loadfile("ui.lua")()

-- Settings come from SYS > Tools > OmniDeck Setup (cfg.lua, one file per model), by name;
-- widget options were bare numbers and only 5 before EdgeTX 2.11. No options here any more.
local CFG = loadScript(ROOT .. "cfg.lua")()
-- One option per widget instance (as Yaapu's screen option): the page this OmniDeck shows, so
-- several telemetry screens can each show a different one. Everything else is in OmniDeck Setup.
-- 0 = the Start page from OmniDeck Setup, 1 Main, 2 Map, 3 Messages, 4 Flight summary, 5 Sensor check
local options = { { "Page", VALUE, 0, 0, 5 } }
-- queued CRSF frames are read after drawing until this much of the Lua limit is used: one
-- frame costs a few percent, the simulator's 88 % margin must hold
local DRAIN_PCT = 75
local function fixedPage(opt)
  local p = opt and opt.Page
  return (type(p) == "number" and p >= 1 and p <= 5) and p or nil
end

local function apply(w)
  local v, found = CFG.read()
  for k, val in pairs(v) do
    if k ~= "voice" then w[k] = val end
  end
  -- voice: the pack named in the file ("" = off; no file = the first pack, see cfg.lua)
  w.voice = (v.voice ~= "" and v.voice) or "off"
  UI.AU.setVoice(w.voice)
  -- zoom control: an Ethos-style source (value()) over the radio's getValue()
  local zs = v.zoomSrc
  if zs ~= nil and zs ~= "" then
    w.zoomSource = { name = function() return zs end, value = function() return getValue(zs) end }
  else
    w.zoomSource = nil
  end
  UI.AU.setBeep(w.beep)
  -- map tiles (OmniDeck Setup): "*" = the first set found on the card, "" = off, else that set
  if v.tileSet == "*" then
    local sets = UI.scanTiles()
    w.tileSet = sets[1] and sets[1].label or ""
  else
    w.tileSet = v.tileSet or ""
  end
end

local function create(zone, opt)
  local w = UI.create()
  w.zone = zone
  apply(w)
  w.homePage = fixedPage(opt)   -- arming / the summary timeout return here (nil = main)
  w.page = w.homePage or w.startPage or 1
  w.lastRefresh = getTime()
  return w
end

local function update(w, opt)
  apply(w)
  local p = fixedPage(opt)
  w.homePage = p
  if p then w.page = p end
end

local function background(w)
  E.tick()
  UI.wakeup(w)
end

-- EdgeTX events -> the Ethos-style events ui.lua expects
local function event(w, evt, touch)
  if evt == nil or evt == 0 then return end
  if touch and EVT_TOUCH_FIRST and evt == EVT_TOUCH_FIRST then
    UI.event(w, E.EVT_TOUCH, E.TOUCH_START, touch.x, touch.y)
  elseif touch and EVT_TOUCH_SLIDE and evt == EVT_TOUCH_SLIDE then
    UI.event(w, E.EVT_TOUCH, E.TOUCH_MOVE, touch.x, touch.y)
  elseif touch and EVT_TOUCH_BREAK and evt == EVT_TOUCH_BREAK then
    UI.event(w, E.EVT_TOUCH, E.TOUCH_END, touch.x, touch.y)
  elseif touch and EVT_TOUCH_TAP and evt == EVT_TOUCH_TAP then
    -- a quick tap ends with TAP, not BREAK, on the radio (TX16S MK2 tester: pages did not change)
    UI.event(w, E.EVT_TOUCH, E.TOUCH_START, touch.x, touch.y)
    UI.event(w, E.EVT_TOUCH, E.TOUCH_END, touch.x, touch.y)
  elseif evt == EVT_VIRTUAL_ENTER then
    UI.event(w, E.EVT_KEY, E.KEY_ENTER_BREAK)
  elseif evt == EVT_VIRTUAL_NEXT then
    UI.event(w, E.EVT_KEY, E.KEY_ROTARY_RIGHT)
  elseif evt == EVT_VIRTUAL_PREV then
    UI.event(w, E.EVT_KEY, E.KEY_ROTARY_LEFT)
  end
end

-- Page switch (OmniDeck Setup): works outside full screen too, where EdgeTX sends no touch or
-- keys. "Next page": each move to the up position (or press of a momentary switch).
-- "Position picks page": up Main, middle Map, down Messages.
local function pageSwitch(w)
  local sw = w.pageSwitch
  if sw == nil or sw == "" then return end
  local v = getValue(sw)
  if type(v) ~= "number" then return end
  if w.pageSwMode == 1 then
    local pos = (v < -300 and 1) or (v > 300 and 3) or 2
    if pos ~= w.swLastPos then w.swLastPos = pos w.page = pos end
  else
    local up = v > 300
    if w.swLastUp ~= nil and up and not w.swLastUp then UI.nextPage(w) end
    w.swLastUp = up
  end
end

local SUM_PAGE, SUM_ZONE_TICKS = 4, 1500   -- page 4 = flight summary; 1500 x 10 ms = 15 s

local function refresh(w, evt, touch)
  -- back on screen after a pause (e.g. from OmniDeck Setup): read the settings again
  local now = getTime()
  if now - (w.lastRefresh or now) > 100 then apply(w) end
  w.lastRefresh = now
  -- full screen gets events; in a layout zone it shows the minimap only
  local zw, zh = w.zone.w, w.zone.h
  if evt ~= nil then zw, zh = LCD_W, LCD_H end
  E.lcd.setWindow(zw, zh)
  E.tick()
  E.countUpdate()
  -- CRSF frames per update: their values are collected (newest per kind) and decoded once, so a
  -- frame costs little. A TX16S MK2 updates about 8 times a second and ArduPilot over ELRS sends
  -- about 22 frames a second (page-5 link stats, 2026-11-03): 3 per update to keep up, more to
  -- catch up. The main page is the heaviest to draw, so it takes fewer.
  E.OD_MAX_CRSF = (w.page == 1) and 2 or 10
  E.OD_MAX_SPORT = (w.page == 1) and 6 or 10   -- S.Port: one value per frame, about 60 a second
  UI.wakeup(w)
  -- outside full screen EdgeTX sends no touch or keys, so the flight summary (opened on disarm)
  -- could never be closed there: it goes back to the main page after SUM_ZONE_TICKS
  if evt == nil and w.page == SUM_PAGE then
    w.sumSince = w.sumSince or now
    if now - w.sumSince > SUM_ZONE_TICKS then w.page = w.homePage or 1 w.sumSince = nil end
  else
    w.sumSince = nil
  end
  pageSwitch(w)
  event(w, evt, touch)
  UI.paint(w)
  -- then catch up on queued telemetry with what is left of this update's Lua budget
  if w.linkMode ~= UI.T.LINK_SPORT then UI.T.drainCrsf(DRAIN_PCT, 12) end
end

return { name = "OmniDeck", options = options, create = create, update = update,
         background = background, refresh = refresh }
