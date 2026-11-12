--[[
  OmniDeck Mono, main page (128x64):
    top bar      flight mode (inverted), arm state, GPS fix and satellites
    left 70 px   horizon: ground filled, pitch ladder every 10 deg, fixed aircraft symbol
    right        altitude, speed, home distance with an arrow to home, battery, flight time, current
  Values are in metres and km/h for now (units come with the settings in a later step).
]]

local floor, sin, cos, rad, abs = math.floor, math.sin, math.cos, math.rad, math.abs

local BX0, BY0, BX1, BY1 = 0, 10, 69, 63   -- horizon box, inclusive
local CX, CY = 34, 37                       -- aircraft symbol
local PPD = 1.6                             -- pixels per degree of pitch

-- a line clipped to the horizon box (Liang-Barsky)
local function boxLine(x1, y1, x2, y2, flags)
  local dx, dy = x2 - x1, y2 - y1
  local t0, t1 = 0, 1
  local p = { -dx, dx, -dy, dy }
  local q = { x1 - BX0, BX1 - x1, y1 - BY0, BY1 - y1 }
  for i = 1, 4 do
    if p[i] == 0 then
      if q[i] < 0 then return end
    else
      local r = q[i] / p[i]
      if p[i] < 0 then
        if r > t1 then return end
        if r > t0 then t0 = r end
      else
        if r < t0 then return end
        if r < t1 then t1 = r end
      end
    end
  end
  lcd.drawLine(floor(x1 + t0 * dx + 0.5), floor(y1 + t0 * dy + 0.5),
               floor(x1 + t1 * dx + 0.5), floor(y1 + t1 * dy + 0.5), SOLID, flags)
end

local function horizon(s)
  local r = rad(s.roll or 0)
  local cr, sr = cos(r), sin(r)
  local hy = CY + (s.pitch or 0) * PPD     -- nose up: the horizon moves down
  -- ground: one vertical line per column below the horizon (above it when upside down)
  local up = cr < 0
  local slope = (abs(cr) > 0.05) and (sr / cr) or (sr >= 0 and 20 or -20)
  for x = BX0, BX1 do
    local y = floor(hy - (x - CX) * slope + 0.5)
    if up then
      if y > BY0 then lcd.drawLine(x, BY0, x, (y > BY1) and BY1 or y, SOLID, FORCE) end
    else
      if y < BY1 then lcd.drawLine(x, (y < BY0) and BY0 or y, x, BY1, SOLID, FORCE) end
    end
  end
  -- pitch ladder: black on the sky, white on the ground
  local dx, dy = cr, -sr       -- along the horizon
  local nx, ny = -sr, -cr      -- up from the horizon
  for p = -20, 20, 10 do
    if p ~= 0 then
      local len = (p % 20 == 0) and 10 or 6
      local mx, my = CX + nx * p * PPD, hy + ny * p * PPD
      boxLine(mx - dx * len, my - dy * len, mx + dx * len, my + dy * len, p < 0 and ERASE or FORCE)
    end
  end
  -- aircraft symbol on a white band, so it shows on sky and ground
  lcd.drawFilledRectangle(22, CY - 1, 9, 3, ERASE)
  lcd.drawFilledRectangle(38, CY - 1, 9, 3, ERASE)
  lcd.drawFilledRectangle(CX - 1, CY - 1, 3, 3, ERASE)
  lcd.drawLine(22, CY, 30, CY, SOLID, FORCE)
  lcd.drawLine(38, CY, 46, CY, SOLID, FORCE)
  lcd.drawPoint(CX, CY)
  lcd.drawLine(BX1 + 1, BY0 - 1, BX1 + 1, BY1, SOLID, FORCE)
end

-- arrow pointing to home, relative to the aircraft's heading
local function homeArrow(x, y, s)
  if not (s.homeBrg and s.yaw) then return end
  local a = rad(s.homeBrg - s.yaw)
  local function pt(da, len) return floor(x + sin(a + da) * len + 0.5), floor(y - cos(a + da) * len + 0.5) end
  local tx, ty = pt(0, 4)
  local lx, ly = pt(2.5, 3)
  local rx, ry = pt(-2.5, 3)
  lcd.drawLine(tx, ty, lx, ly, SOLID, FORCE)
  lcd.drawLine(tx, ty, rx, ry, SOLID, FORCE)
  lcd.drawLine(lx, ly, rx, ry, SOLID, FORCE)
end

local function dist(m)
  if not m then return "---" end
  if m < 1000 then return string.format("%dM", floor(m + 0.5)) end
  return string.format("%.1fK", m / 1000)
end

local function topBar(ctx, s, alive)
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  local mode = alive and (s.mode or "---") or "NO TELEM"
  lcd.drawText(1, 1, string.upper(mode), INVERS)
  local arm = s.armed and "ARM" or "DIS"
  local gps = (s.fix or 0) >= 3 and "3D" or ((s.fix or 0) == 2 and "2D" or "NO")
  lcd.drawText(127, 1, string.format("%s %s%d", arm, gps, s.sats or 0), INVERS + RIGHT)
end

local function draw(ctx)
  local T = ctx.T
  local s = T.s
  local alive = T.alive()
  topBar(ctx, s, alive)
  horizon(s)
  local x = 73
  lcd.drawText(x, 11, "ALT " .. (s.alt and string.format("%dM", floor(s.alt + 0.5)) or "---"), 0)
  local spd = s.aspd or s.gspd
  lcd.drawText(x, 20, "SPD " .. (spd and string.format("%3d", floor(spd * 3.6 + 0.5)) or "---"), 0)
  lcd.drawText(x, 29, "HOM " .. dist(s.homeDist), 0)
  homeArrow(123, 33, s)
  local pct = (s.cap and s.cap > 0 and s.mah) and floor((1 - s.mah / s.cap) * 100 + 0.5) or nil
  lcd.drawText(x, 38, (s.volt and string.format("%.1fV", s.volt) or "--.-V") .. (pct and string.format(" %d%%", pct) or ""), 0)
  lcd.drawLine(x, 47, 127, 47, SOLID, FORCE)
  local t = floor(ctx.armedFor or 0)
  lcd.drawText(x, 49, string.format("T %02d:%02d", floor(t / 60), t % 60), 0)
  lcd.drawText(x, 57, s.curr and string.format("%.1fA", s.curr) or "--.-A", 0)
end

return { draw = draw }
