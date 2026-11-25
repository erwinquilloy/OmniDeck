-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck vector map. The aircraft is always at the centre.

  Zoom "auto":   the range grows/shrinks in fixed steps so home stays on screen
                 (zooms out at once, zooms back in only when home is well inside).
  Zoom "manual": the pilot picks the range (touch +/-, rotary, or a pot/switch
                 source); the map scrolls under the aircraft and an edge marker
                 points to home when it is off screen.
  Orientation:   north up (arrow turns) or heading up (map turns, arrow points up).
]]

local M = {}

-- map radius (m) from the centre to the nearest edge
M.LEVELS = { 50, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 7500, 10000, 15000, 20000, 30000, 50000 }
local LEVELS = M.LEVELS

local C = {
  bg = lcd.RGB(16, 32, 24), ring = lcd.RGB(46, 84, 64), ringTxt = lcd.RGB(110, 160, 130),
  trail = lcd.RGB(255, 200, 40), own = lcd.RGB(255, 255, 255), ownEdge = lcd.RGB(0, 0, 0),
  home = lcd.RGB(80, 200, 255), wp = lcd.RGB(255, 80, 200), text = lcd.RGB(235, 235, 235),
  north = lcd.RGB(255, 90, 90), btn = lcd.RGB(40, 60, 50), btnTxt = lcd.RGB(255, 255, 255),
  wind = lcd.RGB(160, 200, 255), wpActive = lcd.RGB(60, 255, 90), wpTxt = lcd.RGB(0, 0, 0),
}
M.C = C

-- ---------------------------------------------------------------- trail
-- breadcrumbs in metres east/north of a fixed local origin (the first fix)
local trail = { e = {}, n = {}, count = 0, head = 0 }
local TRAIL_MAX = 300
local org = nil   -- { lat=, lon=, mlon= }

local function toEN(lat, lon)
  return (lon - org.lon) * org.mlon, (lat - org.lat) * 111320
end
function M.resetTrail() trail = { e = {}, n = {}, count = 0, head = 0 } end

function M.addTrail(lat, lon, rangeM)
  if not lat then return end
  if org == nil then org = { lat = lat, lon = lon, mlon = 111320 * math.cos(math.rad(lat)) } end
  local e, n = toEN(lat, lon)
  if trail.count > 0 then
    local le, ln = trail.e[trail.head], trail.n[trail.head]
    local minStep = math.max(5, (rangeM or 500) / 60)
    if (e - le) ^ 2 + (n - ln) ^ 2 < minStep * minStep then return end
  end
  trail.head = trail.head % TRAIL_MAX + 1
  trail.e[trail.head], trail.n[trail.head] = e, n
  if trail.count < TRAIL_MAX then trail.count = trail.count + 1 end
end

-- ---------------------------------------------------------------- zoom
-- home-centred view: the closest range step (or tile zoom) that still keeps an aircraft at
-- dist metres from home inside the map, with a margin. The caller zooms out to it at once,
-- and zooms in only one step at a time, once the aircraft is well inside (M.ZOOM_IN_AT).
M.EDGE = 0.85
M.ZOOM_IN_AT = 0.5
function M.levelFor(dist)
  for i = 1, #LEVELS do
    if dist <= M.EDGE * LEVELS[i] then return i end
  end
  return #LEVELS
end
function M.tileZFor(dist, lat, radiusPx, minZ, maxZ, TL)
  for z = maxZ, minZ, -1 do
    if dist <= M.EDGE * radiusPx * TL.mpp(lat, z) then return z end
  end
  return minZ
end

local function fmtDist(m)
  if m >= 1000 then
    local k = m / 1000
    return (k == math.floor(k)) and string.format("%dkm", k) or string.format("%.1fkm", k)
  end
  return string.format("%dm", math.floor(m + 0.5))
end
M.fmtDist = fmtDist

-- ---------------------------------------------------------------- drawing helpers
-- round to a pixel; where Lua time is short (EdgeTX) the radio's own floor() is used directly
-- a NaN or infinite value (bad sensor data) would stop paint() on Ethos: drawn at 0 instead
-- test41: Ethos too. The rounding helper this was (floor, then NaN and infinity tests) was half of
-- the main page's Lua time on an X18; bad telemetry is now checked once per update where it comes
-- in (H.draw), and coordinates floor straight away as EdgeTX's always did (at most 1 px apart)
local I = math.floor
-- Lighter drawing on every radio (EdgeTX / OpenTX since test17, Ethos since test36): numbers on
-- every other tape tick, 15 deg heading ticks, 10 deg pitch rungs numbered on one side, no 45 deg
-- roll ticks, one-pixel text shadows. The full set put a tester's X18 over Ethos's per-call Lua
-- limit ("Max instructions count reached", INAV + TBS, 2026-11-05) where an X20S ran it clean.
-- OD_LEAN = false brings the full drawing back (simulator comparisons).
local LEAN = OD_LITE or OD_LEAN ~= false
-- trail segments on the map page (twice this) and waypoints drawn; EdgeTX / OpenTX set their own
local TRAIL_SEGS = OD_TRAIL_SEGS or (LEAN and 50 or nil)
local MAX_WPS = OD_MAX_WPS or (LEAN and 30 or nil)

-- OpenTX 2.3 (set by etx.lua): no filled triangles, each is filled in Lua there, and a widget
-- gets 10,000 Lua instructions per screen update. Shapes are drawn as outlines there.
local OTX = OD_OTX
local misX, misY = {}, {}   -- the mission's screen points, reused every update
-- OpenTX: OpenTX's own line call (etx.lua OD_RAW) for lines wholly inside the map box, which
-- M.draw records here; anything that crosses its edge still goes through the adapter's clipping
local RAWL = OTX and OD_RAW or nil
local boxX1, boxY1, boxX2, boxY2 = 0, 0, 0, 0

local function arrow(cx, cy, ang, size, fill, edge)
  local r = math.rad(ang)
  local sn, cs = math.sin(r), math.cos(r)
  local function pt(x, y) return cx + x * cs - y * sn, cy + x * sn + y * cs end
  local ax, ay = pt(0, -size)
  local bx, by = pt(size * 0.62, size * 0.78)
  local mx, my = pt(0, size * 0.38)
  local dx, dy = pt(-size * 0.62, size * 0.78)
  if OTX then   -- the outline in the fill colour, with a spine so it still reads as solid
    lcd.color(fill)
    if RAWL and ax >= boxX1 and ax < boxX2 and bx >= boxX1 and bx < boxX2 and mx >= boxX1 and mx < boxX2
       and dx >= boxX1 and dx < boxX2 and ay >= boxY1 and ay < boxY2 and by >= boxY1 and by < boxY2
       and my >= boxY1 and my < boxY2 and dy >= boxY1 and dy < boxY2 then
      RAWL.color(fill)
      local l, LN, CU = RAWL.line, RAWL.LINE, RAWL.CUSTOM
      l(ax, ay, bx, by, LN, CU) l(bx, by, mx, my, LN, CU) l(mx, my, dx, dy, LN, CU)
      l(dx, dy, ax, ay, LN, CU) l(ax, ay, mx, my, LN, CU)
      return
    end
    lcd.drawLine(I(ax), I(ay), I(bx), I(by)); lcd.drawLine(I(bx), I(by), I(mx), I(my))
    lcd.drawLine(I(mx), I(my), I(dx), I(dy)); lcd.drawLine(I(dx), I(dy), I(ax), I(ay))
    lcd.drawLine(I(ax), I(ay), I(mx), I(my))
    return
  end
  lcd.color(fill)
  lcd.drawFilledTriangle(I(ax), I(ay), I(bx), I(by), I(mx), I(my))
  lcd.drawFilledTriangle(I(ax), I(ay), I(mx), I(my), I(dx), I(dy))
  if edge then
    lcd.color(edge)
    lcd.drawLine(I(ax), I(ay), I(bx), I(by)); lcd.drawLine(I(bx), I(by), I(mx), I(my))
    lcd.drawLine(I(mx), I(my), I(dx), I(dy)); lcd.drawLine(I(dx), I(dy), I(ax), I(ay))
  end
end
M.arrow = arrow

local function homeIcon(x, y, sz)
  lcd.color(C.home)
  if OTX then   -- OpenTX: the roof as two lines
    lcd.drawLine(I(x - sz), I(y - sz * 0.1), I(x), I(y - sz))
    lcd.drawLine(I(x), I(y - sz), I(x + sz), I(y - sz * 0.1))
  else
    lcd.drawFilledTriangle(I(x - sz), I(y - sz * 0.1), I(x), I(y - sz), I(x + sz), I(y - sz * 0.1))
  end
  lcd.drawFilledRectangle(I(x - sz * 0.65), I(y - sz * 0.1), I(sz * 1.3), I(sz * 0.9))
end

-- ---------------------------------------------------------------- radar
-- The radar of iNav LuaTelemetry's colour-screen view (iNavFlight/LuaTelemetry, src/iNav/horus.lua,
-- "Radar"), written again here: no map, trail or tiles, only home and the aircraft.
--  - scale: maxDist = max(min(furthest from home this flight, distance x 6), distRef x 10), distRef
--    6 m; the aircraft sits distance / maxDist x reach from home, kept between 7 px and reach
--  - home and the aircraft are centred as a pair (home moved back by half the offset)
--  - home: an icon from 12 px out, a 3 px dot closer; at home (under 6 m) only the aircraft, centred
--  - the aircraft: three lines, 8 px, at its heading and +-145 deg, the back one grey
--  - the distance bottom left; W and E on the sides when north is up (its dir[6] and dir[2])
-- o: { orient = "north" | "heading", maxDist = furthest from home (m), distF = fn(m) -> text }
local RADAR_DIST_REF = 6
local GREY = lcd.RGB(160, 160, 160)
-- OpenTX: the same radar with OpenTX's own calls (etx.lua OD_RAW), no adapter in between. Nothing
-- needs clipping: home and the aircraft stay within reach / 2 + 8 px of the centre, inside the panel.
local RAW = OD_RAW
local radTh = nil
local function radarRaw(x, y, w, h, s, o)
  local sin, cos, rad, floor, min, max = math.sin, math.cos, math.rad, math.floor, math.min, math.max
  local fill, line, text, color, CU, LN = RAW.fill, RAW.line, RAW.text, RAW.color, RAW.CUSTOM, RAW.LINE
  local FS = CU + RAW.FONTS[FONT_S]
  if radTh == nil then lcd.font(FONT_S) local _, t = lcd.getTextSize("0") radTh = t end
  local th = radTh
  color(C.bg)
  fill(x, y, w, h, CU)
  local cxp, cyp = floor(x + w / 2), floor(y + h / 2)
  local reach = min(100, (min(w, h) / 2 - 10) * 2)
  local north = o.orient ~= "heading"
  local hdg = s.yaw or 0
  local rot = north and 0 or hdg
  local cx, cy = cxp, cyp
  local dist, brg = s.homeDist, s.homeBrg
  if dist and brg then
    local maxDist = max(min(o.maxDist or dist, dist * 6), RADAR_DIST_REF * 10)
    local d = dist >= RADAR_DIST_REF and min(max(dist / maxDist * reach, 7), reach) or 1
    local r = rad(brg + 180 - rot)
    local ox, oy = floor(sin(r) * d + 0.5), floor(cos(r) * d + 0.5)
    local hx, hy = cxp, cyp
    if d > 9 then hx, hy = floor(hx - ox * 0.5), floor(hy + oy * 0.5) end
    color(C.home)
    if d >= 12 then   -- the home icon as on OpenTX's map: roof as two lines, a 9 x 6 box
      line(hx - 7, hy - 1, hx, hy - 7, LN, CU)
      line(hx, hy - 7, hx + 7, hy - 1, LN, CU)
      fill(hx - 4, hy - 1, 9, 6, CU)
    elseif d > 1 then
      fill(hx - 1, hy - 1, 3, 3, CU)
    end
    if d ~= 1 then cx, cy = hx + ox, hy - oy end
    if o.distF then
      color(C.text)
      text(x + 2, y + h - th - 1, o.distF(dist), FS)
    end
  end
  if north then
    color(C.text)
    text(x + 2, floor(cyp - th / 2), "W", FS)
    text(x + w - 2, floor(cyp - th / 2), "E", FS + (RAW.ALIGN[2] or 0))
  end
  local r1 = rad(hdg - rot)
  local r2, r3 = r1 + 2.5307, r1 - 2.5307
  local x1, y1 = floor(cx + sin(r1) * 8), floor(cy - cos(r1) * 8)
  local x2, y2 = floor(cx + sin(r2) * 8), floor(cy - cos(r2) * 8)
  local x3, y3 = floor(cx + sin(r3) * 8), floor(cy - cos(r3) * 8)
  color(GREY)
  line(x2, y2, x3, y3, LN, CU)
  color(C.own)
  line(x1, y1, x2, y2, LN, CU)
  line(x1, y1, x3, y3, LN, CU)
end
function M.radar(x, y, w, h, s, o)
  if RAW then return radarRaw(x, y, w, h, s, o) end
  local sin, cos, rad, floor, min, max = math.sin, math.cos, math.rad, math.floor, math.min, math.max
  lcd.color(C.bg)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  local cxp, cyp = x + w / 2, y + h / 2
  -- LuaTelemetry reaches 100 px in its 126 px tall panel; here the same share of this panel
  local reach = min(100, (min(w, h) / 2 - 10) * 2)
  local north = o.orient ~= "heading"
  local hdg = s.yaw or 0
  local rot = north and 0 or hdg
  local cx, cy = cxp, cyp
  local dist, brg = s.homeDist, s.homeBrg
  lcd.font(FONT_S)
  local _, th = lcd.getTextSize("0")
  if dist and brg and s.homeLat ~= false then
    local maxDist = max(min(o.maxDist or dist, dist * 6), RADAR_DIST_REF * 10)
    local d = dist >= RADAR_DIST_REF and min(max(dist / maxDist * reach, 7), reach) or 1
    local r = rad(brg + 180 - rot)                  -- homeBrg points to home; this is home -> aircraft
    local ox, oy = floor(sin(r) * d + 0.5), floor(cos(r) * d + 0.5)
    local hx, hy = cxp, cyp
    if d > 9 then hx, hy = hx - ox * 0.5, hy + oy * 0.5 end
    if d >= 12 then homeIcon(hx, hy, 7)
    elseif d > 1 then
      lcd.color(C.home)
      lcd.drawFilledRectangle(I(hx - 1), I(hy - 1), 3, 3)
    end
    if d ~= 1 then cx, cy = hx + ox, hy - oy end
    if o.distF then
      lcd.color(C.text)
      lcd.drawText(I(x + 2), I(y + h - th - 1), o.distF(dist))
    end
  end
  if north then
    lcd.color(C.text)
    lcd.drawText(I(x + 2), I(cyp - th / 2), "W")
    lcd.drawText(I(x + w - 2), I(cyp - th / 2), "E", RIGHT)
  end
  local r1 = rad(hdg - rot)
  local r2, r3 = r1 + 2.5307, r1 - 2.5307             -- 145 deg
  local x1, y1 = cx + sin(r1) * 8, cy - cos(r1) * 8
  local x2, y2 = cx + sin(r2) * 8, cy - cos(r2) * 8
  local x3, y3 = cx + sin(r3) * 8, cy - cos(r3) * 8
  lcd.color(GREY)
  lcd.drawLine(I(x2), I(y2), I(x3), I(y3))
  lcd.color(C.own)
  lcd.drawLine(I(x1), I(y1), I(x2), I(y2))
  lcd.drawLine(I(x1), I(y1), I(x3), I(y3))
end

-- ---------------------------------------------------------------- main draw
-- s: telemetry state; o: { level=, orient="north"|"heading", mini=bool, trail=bool, homeView=bool,
--   home={lat,lon} (centre on home), center={lat,lon} (stand-in centre with no fix),
--                          tiles=TL module, tz=tile zoom (nil = vector map), mission={wp...}, activeWp= }
-- returns button hit boxes for the full map
function M.draw(x, y, w, h, s, o)
  -- no position yet (no GPS fix): centre on o.center (last known position, or home) so the
  -- tiles and range rings still show; the aircraft itself is not drawn then
  local lat, lon = s.lat, s.lon
  local fallback = false
  if o.home then lat, lon = o.home[1], o.home[2]             -- home-centred view
  elseif lat == nil and o.center then lat, lon, fallback = o.center[1], o.center[2], true end
  local cx, cy = x + w / 2, y + h / 2
  local radiusPx = math.min(w, h) / 2 - (o.mini and 4 or 8)
  M.lastRadiusPx = radiusPx
  -- with tiles the scale is the tile zoom's; otherwise the vector range step
  local TL = o.tiles
  local useTiles = TL ~= nil and o.tz ~= nil and lat ~= nil
  local level, ppm
  if useTiles then
    ppm = 1 / TL.mpp(lat, o.tz)
    level = radiusPx / ppm
  else
    level = LEVELS[o.level] or 500
    ppm = radiusPx / level
  end
  -- screen angle of a bearing is bearing + rot (heading up: rot = -yaw).
  -- Tiles cannot be rotated cheaply on the radio, so a tiled map is always north up.
  local rot = (not useTiles and o.orient == "heading" and s.yaw) and -s.yaw or 0
  local rr = math.rad(-rot)
  local sr, cr = math.sin(rr), math.cos(rr)

  -- east/north offset (m) from the aircraft -> screen
  local function scr(de, dn)
    local ex, ny = de * cr - dn * sr, de * sr + dn * cr
    return cx + ex * ppm, cy - ny * ppm
  end

  -- the aircraft: in the centre, or (home-centred view) where it is relative to home
  local acShown = s.lat ~= nil
  local ade, adn, acx, acy = 0, 0, cx, cy
  if acShown and (s.lat ~= lat or s.lon ~= lon) then
    ade = (s.lon - lon) * 111320 * math.cos(math.rad(lat))
    adn = (s.lat - lat) * 111320
    acx, acy = scr(ade, adn)
  end

  lcd.setClipping(I(x), I(y), I(w), I(h))
  boxX1, boxY1 = I(x), I(y)
  boxX2, boxY2 = boxX1 + I(w), boxY1 + I(h)
  lcd.color(C.bg)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))

  if useTiles then
    -- tile grid around the aircraft's Mercator pixel; tiles not loaded yet stay background
    local z, T = o.tz, TL.TILE
    local gx, gy = TL.toPixel(lat, lon, z)
    local x0, x1 = math.floor((gx - w / 2) / T), math.floor((gx + w / 2) / T)
    local y0, y1 = math.floor((gy - h / 2) / T), math.floor((gy + h / 2) / T)
    TL.view(z, x0, y0, x1, y1, math.floor(gx / T), math.floor(gy / T))
    for ty = y0, y1 do
      for tx = x0, x1 do
        local bmp = TL.get(z, tx, ty)
        if bmp then lcd.drawBitmap(I(cx + tx * T - gx), I(cy + ty * T - gy), bmp) end
      end
    end
  else
    -- range rings at 1/2 and full range
    lcd.font(o.mini and FONT_XXS or FONT_S)
    lcd.color(C.ring)
    lcd.drawCircle(I(cx), I(cy), I(radiusPx / 2))
    lcd.drawCircle(I(cx), I(cy), I(radiusPx))
    lcd.color(C.ringTxt)
    local la = math.rad(-45)
    if not o.mini then
      lcd.drawText(I(cx + math.cos(la) * radiusPx / 2 + 2), I(cy + math.sin(la) * radiusPx / 2 - 2), fmtDist(level / 2))
    end
    lcd.drawText(I(cx + math.cos(la) * radiusPx * 0.72), I(cy + math.sin(la) * radiusPx * 0.72), fmtDist(level))
  end

  local hasPos = lat ~= nil
  local se, sn = 0, 0
  if hasPos and org then se, sn = toEN(lat, lon) end

  -- EdgeTX (OD_LITE): the main page's minimap leaves out the trail and the mission, which
  -- cost the most Lua time; the map page shows both
  local bare = LEAN and o.mini

  -- trail
  if o.trail and hasPos and org and trail.count > 1 and not bare then
    lcd.color(C.trail)
    -- EdgeTX caps the Lua work per screen update, so there every Nth point is drawn:
    -- the whole trail keeps its shape at a fixed cost
    local segs = TRAIL_SEGS and (o.mini and TRAIL_SEGS or 2 * TRAIL_SEGS) or TRAIL_MAX
    local stride = math.max(1, math.ceil((trail.count - 1) / segs))
    local idx = (trail.head - trail.count) % TRAIL_MAX + 1
    local px, py = scr(trail.e[idx] - se, trail.n[idx] - sn)
    local k = 1
    if OD_LITE then
      -- EdgeTX / OpenTX: scr() worked out inline and no rounding (the radio truncates
      -- coordinates itself), so a segment costs a third of the loop below. OpenTX has no budget
      -- check to ask (its adapter never runs out early).
      local starved = (not OTX) and lcd.starved
      local a, b = cr * ppm, sr * ppm
      local te, tn, cnt, line = trail.e, trail.n, trail.count, lcd.drawLine
      local ox, oy = cx - se * a + sn * b, cy + se * b + sn * a   -- the screen point of (0, 0)
      -- OpenTX: segments wholly inside the map with OpenTX's own call (colour sent once here)
      local rl, LN, CU = RAWL and RAWL.line, RAWL and RAWL.LINE, RAWL and RAWL.CUSTOM
      local x1, y1, x2, y2 = boxX1, boxY1, boxX2, boxY2
      if rl then RAWL.color(C.trail) end
      while k < cnt do
        if starved and starved() then break end
        local nk = k + stride
        if nk > cnt then nk = cnt end
        idx = (idx + nk - k - 1) % TRAIL_MAX + 1
        k = nk
        local de, dn = te[idx], tn[idx]
        local qx, qy = ox + de * a - dn * b, oy - de * b - dn * a
        if rl and px >= x1 and px < x2 and qx >= x1 and qx < x2 and py >= y1 and py < y2 and qy >= y1 and qy < y2 then
          rl(px, py, qx, qy, LN, CU)
        else
          line(px, py, qx, qy)
        end
        px, py = qx, qy
      end
    else
      local starved = lcd.starved
      while k < trail.count do
        if starved and starved() then break end
        local nk = math.min(trail.count, k + stride)
        idx = (idx + nk - k - 1) % TRAIL_MAX + 1
        k = nk
        local qx, qy = scr(trail.e[idx] - se, trail.n[idx] - sn)
        lcd.drawLine(I(px), I(py), I(qx), I(qy))
        px, py = qx, qy
      end
    end
    if acShown then lcd.drawLine(I(px), I(py), I(acx), I(acy)) end
  end

  -- mission (INAV download, ArduPilot mission file or learned waypoints)
  local mis = o.mission
  if hasPos and mis and #mis > 0 and not bare then
    -- EdgeTX caps the Lua work per screen update: there a long mission is drawn from just
    -- before the active waypoint, OD_MAX_WPS of them
    local first, last = 1, #mis
    local cap = MAX_WPS
    if cap and #mis > cap then
      local ai = 1
      if o.activeWp then
        for i, wp in ipairs(mis) do if wp.num == o.activeWp then ai = i break end end
      end
      first = math.max(1, ai - 3)
      last = math.min(#mis, first + cap - 1)
      first = math.max(1, last - cap + 1)
    end
    local mlon = 111320 * math.cos(math.rad(lat))
    -- screen points in two arrays kept between updates (no table per waypoint per update)
    local PX, PY = misX, misY
    if OD_LITE then
      -- EdgeTX / OpenTX: scr() inline, and no rounding (the radio truncates coordinates itself)
      local a, b = cr * ppm, sr * ppm
      for i = first, last do
        local wp = mis[i]
        local de, dn = (wp.lon - lon) * mlon, (wp.lat - lat) * 111320
        PX[i], PY[i] = cx + de * a - dn * b, cy - de * b - dn * a
      end
    else
      for i = first, last do
        local wp = mis[i]
        PX[i], PY[i] = scr((wp.lon - lon) * mlon, (wp.lat - lat) * 111320)
      end
    end
    lcd.color(C.wp)
    if OD_LITE then
      for i = first + 1, last do
        if not mis[i].noLine then lcd.drawLine(PX[i - 1], PY[i - 1], PX[i], PY[i]) end
      end
    else
      for i = first + 1, last do
        if not mis[i].noLine then lcd.drawLine(I(PX[i - 1]), I(PY[i - 1]), I(PX[i]), I(PY[i])) end
      end
    end
    local r = o.mini and 3 or 8
    local th = 0
    if not o.mini then
      lcd.font(FONT_S)
      local _, h0 = lcd.getTextSize("0")
      th = h0
    end
    for i = first, last do
      local wp = mis[i]
      local px, py = PX[i], PY[i]
      if px > x - r and px < x + w + r and py > y - r and py < y + h + r then
        local active = o.activeWp ~= nil and wp.num == o.activeWp
        lcd.color(active and C.wpActive or C.wp)
        lcd.drawFilledCircle(I(px), I(py), active and r + 2 or r)
        if not o.mini then
          lcd.color(C.wpTxt)
          lcd.drawText(I(px), I(py - th / 2), wp.label or tostring(wp.num), CENTERED)
        end
      end
    end
  end

  -- next waypoint (ArduPilot 0x500D: distance + bearing from the aircraft)
  if not (mis and #mis > 0) and s.wpDist and s.wpBrg and s.wpDist > 0 then
    local b = math.rad(s.wpBrg)
    local wx, wy = scr(ade + math.sin(b) * s.wpDist, adn + math.cos(b) * s.wpDist)
    lcd.color(C.wp)
    if wx > x and wx < x + w and wy > y and wy < y + h then
      lcd.drawLine(I(acx), I(acy), I(wx), I(wy))
      lcd.drawFilledCircle(I(wx), I(wy), o.mini and 3 or 5)
      if not o.mini and s.wpNum then lcd.drawText(I(wx + 7), I(wy - 7), "WP" .. s.wpNum) end
    end
  end

  -- home: on the map, or a marker on the edge pointing at it (distance and bearing are from
  -- the aircraft, so not while the map is centred on a stand-in position)
  if o.home then
    homeIcon(cx, cy, o.mini and 5 or 8)
  elseif s.homeDist and s.homeBrg and not fallback then
    local b = math.rad(s.homeBrg)
    local hx, hy = scr(math.sin(b) * s.homeDist, math.cos(b) * s.homeDist)
    local m = o.mini and 6 or 10
    if hx >= x + m and hx <= x + w - m and hy >= y + m and hy <= y + h - m then
      homeIcon(hx, hy, o.mini and 5 or 8)
    else
      local dx, dy = hx - cx, hy - cy
      local k = math.min((w / 2 - m) / math.max(math.abs(dx), 1e-6), (h / 2 - m) / math.max(math.abs(dy), 1e-6))
      local ex, ey = cx + dx * k, cy + dy * k
      -- home off the map: a small home icon on the edge, in home's direction
      homeIcon(ex, ey + (o.mini and 2 or 4), o.mini and 4 or 7)
      if not o.mini then
        lcd.color(C.home)
        local tx = ex < cx and ex + 12 or ex - 12
        lcd.drawText(I(tx), I(ey - 6), fmtDist(s.homeDist), ex < cx and LEFT or RIGHT)
      end
    end
  end

  -- north marker on the outer ring
  do
    local nx, ny = scr(0, level)
    lcd.color(C.north)
    lcd.font(o.mini and FONT_XS or FONT_STD)
    lcd.drawText(I(nx), I(ny - (o.mini and 7 or 11)), "N", CENTERED)
  end

  -- wind (direction it blows FROM), full map only
  if not o.mini and s.windDir and s.windSpd and s.windSpd > 0.5 then
    local wx, wy = x + w - 26, y + 26
    lcd.color(C.wind)
    arrow(wx, wy, s.windDir + 180 + rot, 10, C.wind, nil)
    lcd.font(FONT_S)
    lcd.drawText(I(wx), I(wy + 12), string.format("%.0f", s.windSpd * (o.windScale or 1)), CENTERED)
  end

  if useTiles then
    -- scale bar: the largest 1-2-5 distance that fits in a quarter of the width
    local maxM = (w / 4) / ppm
    local nice = 1
    while nice * 10 <= maxM do nice = nice * 10 end
    if nice * 5 <= maxM then nice = nice * 5 elseif nice * 2 <= maxM then nice = nice * 2 end
    local bx, by, bl = x + 8, y + h - (o.mini and 6 or 34), nice * ppm   -- full map: above the message line
    lcd.color(C.ownEdge)
    lcd.drawFilledRectangle(I(bx - 1), I(by - 3), I(bl + 2), 6)
    lcd.color(C.own)
    lcd.drawFilledRectangle(I(bx), I(by - 2), I(bl), 4)
    lcd.font(o.mini and FONT_XS or FONT_S)
    local _, th = lcd.getTextSize("0")
    lcd.drawText(I(bx), I(by - th - 4), fmtDist(nice))
  end

  -- aircraft
  local hdg = s.yaw or 0
  if acShown or (not fallback and not o.home and s.yaw) then
    arrow(acx, acy, hdg + rot, o.mini and 8 or 13, C.own, C.ownEdge)
  end
  if s.lat == nil then
    lcd.color(C.text)
    lcd.font(o.mini and FONT_XS or FONT_S)
    lcd.drawText(I(cx), I(cy + (o.mini and 10 or 18)), "NO GPS", CENTERED)
  end

  -- zoom controls (full map)
  local btns = nil
  if not o.mini then
    lcd.font(FONT_STD)
    -- wide enough for "PLANE" on any screen, and still a decent touch target
    local bw, bh = math.max(40, I(w * 0.08), lcd.getTextSize("PLANE") + 10), math.max(32, I(h * 0.1))
    local bx, by = x + w - bw - 6, y + h - 3 * (bh + 6)
    btns = {
      plus  = { x = bx, y = by, w = bw, h = bh, label = "+" },
      minus = { x = bx, y = by + bh + 6, w = bw, h = bh, label = "-" },
      -- the view: HOME (centred on home) or PLANE (centred on the aircraft); a tap switches
      auto  = { x = bx, y = by + 2 * (bh + 6), w = bw, h = bh, label = o.homeView and "HOME" or "PLANE" },
    }
    lcd.font(FONT_STD)
    for _, b in pairs(btns) do
      lcd.color(C.btn); lcd.drawFilledRectangle(b.x, b.y, b.w, b.h)
      lcd.color(C.btnTxt); lcd.drawRectangle(b.x, b.y, b.w, b.h)
      local _, th = lcd.getTextSize(b.label)
      lcd.drawText(I(b.x + b.w / 2), I(b.y + (b.h - th) / 2), b.label, CENTERED)
    end
  end

  local W, H = lcd.getWindowSize()
  lcd.setClipping(0, 0, W, H)
  return btns
end

return M
