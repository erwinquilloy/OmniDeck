--[[
  OmniDeck Mono, map page (128x64): a vector map, north up, no tiles. Behaves like the colour
  builds' map (ui.lua / map.lua):
    MAP VIEW (Setup) AIRCRAFT  the aircraft in the centre; the wheel (or +/-) zooms: right in,
                               left out, through the colour builds' range steps (50 m .. 50 km
                               from the centre to the nearest edge), starting at 300 m
                     HOME      home in the centre; zooms itself: out at once when the aircraft
                               nears the edge, back in one step at a time (at most every 2 s)
                               once it is well inside; the closest step again at each arming.
                               The wheel still zooms, and the next update corrects it if needed.
    home         boxed H; held at the edge of the map when it is off it, so it shows the way
    aircraft     arrow along its heading
    trail        dots, recorded by omnid.lua (ctx.trailE / ctx.trailN, metres east / north of home)
    waypoint     the current one (ArduPilot passthrough sends only the active waypoint: number,
                 distance and bearing from the aircraft), boxed with its number, dotted line to it
    scale        bar with its length at the bottom left of the map, N at the top right
  Top bar: flight mode and the active waypoint; distance to home on the right.
  Bottom strip: the aircraft's latitude and longitude (5 decimals, about 1 m: the radio's Lua
  numbers are 32-bit), or the last known position marked LAST when there is no fix.
]]

local floor, sin, cos, rad, max, min, sqrt = math.floor, math.sin, math.cos, math.rad, math.max, math.min, math.sqrt

-- 128x64, or 212x64 (Taranis X9D / X9D+ / X9E): the map runs the full width; the scale (R) is
-- set by the height, so it is the same on both
local W = (LCD_W or 128) >= 200 and 212 or 128
local X0, Y0, X1, Y1 = 0, 10, W - 1, 55   -- map area; the strip below holds the coordinates
local MX, MY = (X0 + X1) / 2, (Y0 + Y1) / 2
local R = 22                             -- pixels from the centre to the nearest edge
local M_PER_DEG = 111320
-- range steps (m from the centre to the nearest edge), as the colour builds' map.lua LEVELS
local LEVELS = { 50, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 7500, 10000, 15000, 20000, 30000, 50000 }
local START_LEVEL, EDGE, ZOOM_IN_AT, ZOOM_IN_S = 4, 0.85, 0.5, 2
-- scale bar lengths in metres: metric, or round feet then miles
local STEPS = { 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000 }
local STEPS_FT = { 15.24, 30.48, 60.96, 152.4, 304.8, 804.672, 1609.344, 3218.688, 8046.72, 16093.44, 32186.88,
                   80467.2 }
local LABELS_FT = { "50ft", "100ft", "200ft", "500ft", "1000ft", "0.5mi", "1mi", "2mi", "5mi", "10mi", "20mi", "50mi" }

local fresh = true   -- first draw since the page loaded: the home view fits its zoom at once

local function levelFor(d)
  for i = 1, #LEVELS do if d <= EDGE * LEVELS[i] then return i end end
  return #LEVELS
end

local function arrow(x, y, hdg)
  local a = rad(hdg or 0)
  local function pt(da, len) return floor(x + sin(a + da) * len + 0.5), floor(y - cos(a + da) * len + 0.5) end
  local tx, ty = pt(0, 5)
  local lx, ly = pt(2.6, 4)
  local rx, ry = pt(-2.6, 4)
  lcd.drawLine(tx, ty, lx, ly, SOLID, FORCE)
  lcd.drawLine(tx, ty, rx, ry, SOLID, FORCE)
  lcd.drawLine(lx, ly, rx, ry, SOLID, FORCE)
end

-- a marker point held inside the map area, pad pixels from its edges
local function inside(x, y, pad)
  return max(X0 + pad, min(X1 - pad, x)), max(Y0 + pad, min(Y1 - pad, y))
end

local function topBar(s, alive, u)
  lcd.drawFilledRectangle(0, 0, W, 9, FORCE)
  local mode = alive and string.upper(s.mode or "---") or "NO TELEM"
  if alive and s.wpNum and s.wpNum > 0 then mode = mode .. " WP" .. s.wpNum end
  lcd.drawText(1, 1, mode, INVERS)
  lcd.drawText(X1, 1, s.homeDist and u.dist(s.homeDist) or "", INVERS + RIGHT)
end

local function coords(ctx, s)
  lcd.drawLine(0, Y1 + 1, X1, Y1 + 1, DOTTED, FORCE)
  local la, lo, tag = s.lat, s.lon, ""
  if not la and ctx.lastLat then la, lo, tag = ctx.lastLat, ctx.lastLon, "LAST " end
  lcd.drawText(1, 58, la and (tag .. string.format("%.5f %.5f", la, lo)) or "NO POSITION", SMLSIZE)
end

local function zoomKey(e)
  if e == EVT_VIRTUAL_NEXT or e == EVT_VIRTUAL_INC or e == EVT_ROT_RIGHT or e == EVT_PLUS_FIRST
     or e == EVT_PLUS_REPT then return -1 end   -- wheel right: closer
  if e == EVT_VIRTUAL_PREV or e == EVT_VIRTUAL_DEC or e == EVT_ROT_LEFT or e == EVT_MINUS_FIRST
     or e == EVT_MINUS_REPT then return 1 end
  return 0
end

local function scaleBar(u, mpp)
  local steps = u.imperial and STEPS_FT or STEPS
  local idx = 1
  for i = 1, #steps do if steps[i] / mpp <= 40 then idx = i end end
  local bw = max(2, floor(steps[idx] / mpp + 0.5))
  local lab = u.imperial and LABELS_FT[idx] or u.dist(steps[idx])
  lcd.drawFilledRectangle(X0, Y1 - 8, bw + 6 + #lab * 5, 9, ERASE)
  lcd.drawLine(1, Y1 - 1, 1 + bw, Y1 - 1, SOLID, FORCE)
  lcd.drawLine(1, Y1 - 4, 1, Y1 - 1, SOLID, FORCE)
  lcd.drawLine(1 + bw, Y1 - 4, 1 + bw, Y1 - 1, SOLID, FORCE)
  lcd.drawText(bw + 5, Y1 - 6, lab, SMLSIZE)
end

local function north()
  lcd.drawFilledRectangle(X1 - 10, Y0, 11, 8, ERASE)
  lcd.drawText(X1, Y0 + 1, "N", SMLSIZE + RIGHT)
  lcd.drawLine(X1 - 8, Y0 + 1, X1 - 8, Y0 + 6, SOLID, FORCE)
  lcd.drawLine(X1 - 9, Y0 + 2, X1 - 7, Y0 + 2, SOLID, FORCE)
end

local function draw(ctx, event)
  local T = ctx.T
  local s = T.s
  local u = ctx.u
  local mp = ctx.map
  if not mp then mp = { level = START_LEVEL, zoomInAt = -100, armed = false } ctx.map = mp end
  local homeView = ctx.mapView == 1
  local d = zoomKey(event)
  if d ~= 0 then mp.level = max(1, min(#LEVELS, mp.level + d)) end

  topBar(s, T.alive(), u)
  coords(ctx, s)
  if not s.lat then
    lcd.drawText(16, 28, "WAITING FOR GPS", 0)
    return
  end
  if not s.homeLat then
    -- no home yet: the aircraft alone, in the centre
    arrow(floor(MX + 0.5), floor(MY + 0.5), s.yaw)
    lcd.drawText(1, Y0 + 1, "NO HOME", SMLSIZE)
    scaleBar(u, LEVELS[mp.level] / R)
    north()
    return
  end

  -- metres east / north of home
  local cosLat = cos(rad(s.homeLat))
  local pe, pn = (s.lon - s.homeLon) * M_PER_DEG * cosLat, (s.lat - s.homeLat) * M_PER_DEG

  -- home view: zoom out at once to keep the aircraft on the map, in one step at a time
  if homeView then
    local dist = s.homeDist or sqrt(pe * pe + pn * pn)
    local now = ctx.clock()
    if s.armed == true and not mp.armed then mp.level = 1 end
    mp.armed = s.armed == true
    local l = levelFor(dist)
    if fresh or l > mp.level then
      mp.level = l
    elseif mp.level > 1 and now - mp.zoomInAt >= ZOOM_IN_S and dist <= ZOOM_IN_AT * EDGE * LEVELS[mp.level - 1] then
      mp.level, mp.zoomInAt = mp.level - 1, now
    end
  end
  fresh = false

  local mpp = LEVELS[mp.level] / R
  local cE, cN = 0, 0
  if not homeView then cE, cN = pe, pn end
  local function px(e, n) return floor(MX + (e - cE) / mpp + 0.5), floor(MY - (n - cN) / mpp + 0.5) end

  local tE, tN = ctx.trailE or {}, ctx.trailN or {}
  for i = 1, #tE do
    local x, y = px(tE[i], tN[i])
    if x >= X0 and x <= X1 and y >= Y0 and y <= Y1 then lcd.drawPoint(x, y) end
  end

  -- scale and N first: home, the waypoint and the aircraft are drawn over them, so a marker held
  -- at the edge of the map is never covered
  scaleBar(u, mpp)
  north()

  local hx, hy = px(0, 0)
  hx, hy = inside(hx, hy, 4)
  lcd.drawFilledRectangle(hx - 3, hy - 3, 7, 7, FORCE)
  lcd.drawText(hx - 1, hy - 2, "H", SMLSIZE + INVERS)

  local ax, ay = px(pe, pn)
  ax, ay = inside(ax, ay, 5)
  if s.wpNum and s.wpNum > 0 and s.wpDist and s.wpBrg then
    local b = rad(s.wpBrg)
    local wx, wy = px(pe + sin(b) * s.wpDist, pn + cos(b) * s.wpDist)
    wx, wy = inside(wx, wy, 5)
    lcd.drawLine(ax, ay, wx, wy, DOTTED, FORCE)
    local lab = tostring(s.wpNum)
    local w = #lab * 5 + 3
    lcd.drawFilledRectangle(wx - floor(w / 2), wy - 4, w, 9, ERASE)
    lcd.drawRectangle(wx - floor(w / 2), wy - 4, w, 9, FORCE)
    lcd.drawText(wx - floor(w / 2) + 2, wy - 2, lab, SMLSIZE)
  end
  lcd.drawFilledRectangle(ax - 5, ay - 5, 11, 11, ERASE)
  arrow(ax, ay, s.yaw)
end

return { draw = draw }
