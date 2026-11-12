--[[
  OmniDeck Mono, map page (128x64): a vector map, north up, no tiles.
    home         boxed H
    aircraft     arrow along its heading
    trail        dots, recorded by omnid.lua (ctx.trailE / ctx.trailN, metres east / north of home)
    waypoint     the current one (ArduPilot passthrough sends only the active waypoint: number,
                 distance and bearing from the aircraft), boxed with its number, dotted line to it
    scale        bar in a strip along the bottom; the view zooms itself to keep everything on screen
  Top bar: flight mode and the active waypoint; distance to home on the right.
]]

local floor, sin, cos, rad, max, abs = math.floor, math.sin, math.cos, math.rad, math.max, math.abs

local X0, Y0, X1, Y1 = 0, 10, 127, 52   -- map area; the strip below holds the scale and N
local M_PER_DEG = 111320
local STEPS = { 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000 }

local function dist(m)
  if m < 1000 then return string.format("%dM", floor(m + 0.5)) end
  if m < 100000 then return string.format("%.1fKM", m / 1000) end
  return string.format("%dKM", floor(m / 1000 + 0.5))
end

-- metres east / north of the reference point
local function en(s, lat, lon)
  return (lon - s.homeLon) * M_PER_DEG * cos(rad(s.homeLat)), (lat - s.homeLat) * M_PER_DEG
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

local function topBar(s, alive)
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  local mode = alive and string.upper(s.mode or "---") or "NO TELEM"
  if alive and s.wpNum and s.wpNum > 0 then mode = mode .. " WP" .. s.wpNum end
  lcd.drawText(1, 1, mode, INVERS)
  lcd.drawText(127, 1, s.homeDist and dist(s.homeDist) or "", INVERS + RIGHT)
end

local function draw(ctx)
  local T = ctx.T
  local s = T.s
  topBar(s, T.alive())
  if not (s.lat and s.homeLat) then
    lcd.drawText(16, 30, s.lat and "WAITING FOR HOME" or "WAITING FOR GPS", 0)
    return
  end

  -- everything to show, in metres from home
  local pe, pn = en(s, s.lat, s.lon)
  local we, wn
  if s.wpNum and s.wpNum > 0 and s.wpDist and s.wpBrg then
    local b = rad(s.wpBrg)
    we, wn = pe + sin(b) * s.wpDist, pn + cos(b) * s.wpDist
  end
  local tE, tN = ctx.trailE or {}, ctx.trailN or {}
  local minE, maxE, minN, maxN = math.min(0, pe), max(0, pe), math.min(0, pn), max(0, pn)
  if we then minE, maxE, minN, maxN = math.min(minE, we), max(maxE, we), math.min(minN, wn), max(maxN, wn) end
  for i = 1, #tE do
    local e, n = tE[i], tN[i]
    if e < minE then minE = e elseif e > maxE then maxE = e end
    if n < minN then minN = n elseif n > maxN then maxN = n end
  end

  -- zoom: the whole set inside the map with a margin, at least 2 m per pixel
  local mpp = max((maxE - minE) / 116, (maxN - minN) / 34, 2)
  local cE, cN = (minE + maxE) / 2, (minN + maxN) / 2
  local mx, my = (X0 + X1) / 2, (Y0 + Y1) / 2
  local function px(e, n) return floor(mx + (e - cE) / mpp + 0.5), floor(my - (n - cN) / mpp + 0.5) end

  for i = 1, #tE do
    local x, y = px(tE[i], tN[i])
    if x >= X0 and x <= X1 and y >= Y0 and y <= Y1 then lcd.drawPoint(x, y) end
  end

  local hx, hy = px(0, 0)
  if hy > Y1 - 3 then hy = Y1 - 3 end
  lcd.drawFilledRectangle(hx - 3, hy - 3, 7, 7, FORCE)
  lcd.drawText(hx - 1, hy - 2, "H", SMLSIZE + INVERS)

  local ax, ay = px(pe, pn)
  if we then
    local wx, wy = px(we, wn)
    lcd.drawLine(ax, ay, wx, wy, DOTTED, FORCE)
    local lab = tostring(s.wpNum)
    local w = #lab * 5 + 3
    lcd.drawFilledRectangle(wx - floor(w / 2), wy - 4, w, 9, ERASE)
    lcd.drawRectangle(wx - floor(w / 2), wy - 4, w, 9, FORCE)
    lcd.drawText(wx - floor(w / 2) + 2, wy - 2, lab, SMLSIZE)
  end
  lcd.drawFilledRectangle(ax - 5, ay - 5, 11, 11, ERASE)
  arrow(ax, ay, s.yaw)

  -- scale bar: the largest round length that fits in 40 px
  local len = STEPS[1]
  for i = 1, #STEPS do if STEPS[i] / mpp <= 40 then len = STEPS[i] end end
  local bw = floor(len / mpp + 0.5)
  lcd.drawLine(0, Y1 + 2, 127, Y1 + 2, DOTTED, FORCE)
  lcd.drawLine(1, 60, 1 + bw, 60, SOLID, FORCE)
  lcd.drawLine(1, 57, 1, 60, SOLID, FORCE)
  lcd.drawLine(1 + bw, 57, 1 + bw, 60, SOLID, FORCE)
  lcd.drawText(bw + 5, 57, dist(len), SMLSIZE)
  lcd.drawText(127, 57, "N", SMLSIZE + RIGHT)
  lcd.drawLine(119, 57, 119, 62, SOLID, FORCE)
  lcd.drawLine(118, 58, 120, 58, SOLID, FORCE)
end

return { draw = draw }
