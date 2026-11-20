--[[
  OmniDeck Mono, main page (128x64), layout agreed on the scope page 2026-11-12:
    top bar      flight mode (inverted, small font when long); TX voltage (small); arm state in a
                 white block; GPS fix + satellites, or NOFIX
    left 70 px   horizon: ground filled, pitch rungs every 10 deg with numbers at their left end,
                 heading box at the top centre, home icon under it at the bearing to home,
                 speed box at the left edge (airspeed when a sensor reports it, with a GS box
                 under it; ground speed alone otherwise), altitude box at the right edge
    right        ALT, SPD, H (home distance + arrow), BAT, CUR (normal font); EF and TIM (small
                 font); labels at the left of the column, values right-aligned (user 2026-11-20)
  Units follow OmniDeck Setup (ctx.u, from cfg.lua).
]]

local floor, sin, cos, rad, abs = math.floor, math.sin, math.cos, math.rad, math.abs

local BX0, BY0, BX1, BY1 = 0, 10, 69, 63   -- horizon box, inclusive
local RY0 = BY0 + 9                         -- rungs and their numbers stay below the heading row
local CX, CY = 34, 37                       -- aircraft symbol
local PPD = 1.6                             -- pixels per degree of pitch
local SW = 5                                -- SMLSIZE character pitch

-- a line clipped to the horizon box below the heading row (Liang-Barsky)
local function boxLine(x1, y1, x2, y2, flags)
  local dx, dy = x2 - x1, y2 - y1
  local t0, t1 = 0, 1
  local p = { -dx, dx, -dy, dy }
  local q = { x1 - BX0, BX1 - x1, y1 - RY0, BY1 - y1 }
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

-- small inverted number box with a white edge, readable on sky and ground
local function valBox(x, y, str, right)
  local w = #str * SW + 1
  if right then x = x - w + 1 end
  lcd.drawFilledRectangle(x - 1, y - 1, w + 2, 9, ERASE)
  lcd.drawFilledRectangle(x, y, w, 7, FORCE)
  lcd.drawText(x + 1, y + 1, str, SMLSIZE + INVERS)
  return x, w
end

local function horizon(s, boxBottom)
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
  -- pitch rungs: black on the sky, white on the ground; the number at the left end
  local dx, dy = cr, -sr       -- along the horizon
  local nx, ny = -sr, -cr      -- up from the horizon
  for p = -20, 20, 10 do
    if p ~= 0 then
      local len = (p % 20 == 0) and 10 or 6
      local mx, my = CX + nx * p * PPD, hy + ny * p * PPD
      local x0, y0 = mx - dx * len, my - dy * len
      boxLine(x0, y0, mx + dx * len, my + dy * len, p < 0 and ERASE or FORCE)
      local lab = tostring(abs(p))
      local lx, ly = floor(x0 - 2 - #lab * SW + 0.5), floor(y0 - 3 + 0.5)
      -- skipped where the speed (and GS) boxes on the left would cover it
      local hidden = lx < 26 and ly + 6 >= CY - 4 and ly <= boxBottom
      if not hidden and lx >= BX0 and lx + #lab * SW <= BX1 and ly >= RY0 and ly + 6 <= BY1 then
        lcd.drawText(lx, ly, lab, SMLSIZE + (p < 0 and INVERS or 0))
      end
    end
  end
  -- aircraft symbol on a white band, so it shows on sky and ground
  lcd.drawFilledRectangle(22, CY - 1, 9, 3, ERASE)
  lcd.drawFilledRectangle(38, CY - 1, 9, 3, ERASE)
  lcd.drawFilledRectangle(CX - 1, CY - 1, 3, 3, ERASE)
  lcd.drawLine(22, CY, 30, CY, SOLID, FORCE)
  lcd.drawLine(38, CY, 46, CY, SOLID, FORCE)
  lcd.drawPoint(CX, CY)
end

-- heading box with a degree mark (drawn: the B&W fonts have no degree sign), home icon under it
local function heading(s)
  if not s.yaw then return end
  local str = string.format("%03d", floor(s.yaw % 360 + 0.5) % 360)
  local w = #str * SW + 5
  local x = CX - floor(w / 2)
  lcd.drawFilledRectangle(x - 1, BY0, w + 2, 9, ERASE)
  lcd.drawFilledRectangle(x, BY0 + 1, w, 7, FORCE)
  lcd.drawText(x + 1, BY0 + 2, str, SMLSIZE + INVERS)
  lcd.drawRectangle(x + w - 4, BY0 + 2, 3, 3, ERASE)
  if not s.homeBrg or (s.homeDist or 0) < 1 then return end
  local rel = (s.homeBrg - s.yaw + 540) % 360 - 180
  local ix, arrow = floor(CX + rel * 0.45 + 0.5), nil
  if ix < BX0 + 4 then ix, arrow = BX0 + 4, "<" elseif ix > BX1 - 4 then ix, arrow = BX1 - 4, ">" end
  local iy = BY0 + 10
  lcd.drawFilledRectangle(ix - 3, iy, 7, 7, FORCE)
  lcd.drawText(ix - 1, iy + 1, "H", SMLSIZE + INVERS)
  if arrow then lcd.drawText(arrow == "<" and ix + 5 or ix - 8, iy + 1, arrow, SMLSIZE) end
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

-- top bar, right to left: GPS fix + satellites, arm state in a white block, transmitter voltage;
-- the flight mode takes what is left, in the small font when the normal one does not fit
local function topBar(s, alive)
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  local fix = s.fix or 0
  local gps = fix >= 3 and ("3D" .. (s.sats or 0)) or (fix == 2 and ("2D" .. (s.sats or 0)) or "NOFIX")
  lcd.drawText(127, 1, gps, INVERS + RIGHT)
  local x = 127 - #gps * 6 - 3
  local arm = s.armed and "ARM" or "DIS"
  local bw = #arm * 6 + 3
  x = x - bw
  lcd.drawFilledRectangle(x, 0, bw, 9, ERASE)
  lcd.drawText(x + 2, 1, arm, 0)
  local tx = getValue("tx-voltage")
  if type(tx) == "number" and tx > 0 then
    local str = string.format("%.1fV", tx)
    x = x - 2
    lcd.drawText(x, 2, str, SMLSIZE + INVERS + RIGHT)
    x = x - #str * SW
  end
  local mode = string.upper(alive and (s.mode or "---") or "NO TELEM")
  local room = x - 3
  if #mode * 6 <= room then
    lcd.drawText(1, 1, mode, INVERS)
  else
    local n = floor(room / SW)
    lcd.drawText(1, 2, #mode > n and string.sub(mode, 1, n) or mode, SMLSIZE + INVERS)
  end
end

-- live efficiency: volts, amps and ground speed each smoothed over about 10 s, then the ratio
local sV, sA, sG, lastT
local function efficiency(u, s, now)
  local dt = lastT and (now - lastT) or 0
  lastT = now
  if not (s.curr and s.gspd) then sV, sA, sG = nil, nil, nil return nil end
  local k = (dt > 0 and dt < 2) and dt / (10 + dt) or 1
  sA = sA and (sA + (s.curr - sA) * k) or s.curr
  sG = sG and (sG + (s.gspd - sG) * k) or s.gspd
  if s.volt then sV = sV and (sV + (s.volt - sV) * k) or s.volt end
  return u.eff(sV, sA, sG)
end

local function draw(ctx)
  local T, u = ctx.T, ctx.u
  local s = T.s
  local alive = T.alive()
  topBar(s, alive)
  local spd = s.aspd or s.gspd
  horizon(s, (s.aspd and s.gspd) and CY + 14 or CY + 4)
  heading(s)
  if spd then valBox(BX0 + 1, CY - 3, tostring(u.spd(spd))) end
  if s.aspd and s.gspd then
    local str = "GS " .. u.spd(s.gspd)
    local w = #str * SW + 3
    lcd.drawFilledRectangle(BX0, CY + 5, w + 2, 9, ERASE)
    lcd.drawRectangle(BX0 + 1, CY + 6, w, 7, FORCE)
    lcd.drawText(BX0 + 3, CY + 7, str, SMLSIZE)
  end
  if s.alt then valBox(BX1 - 1, CY - 3, tostring(u.alt(s.alt)), true) end
  lcd.drawLine(BX1 + 1, BY0 - 1, BX1 + 1, BY1, SOLID, FORCE)

  -- right column: label at the left edge, value right-aligned. The column is x 74-127 (54 px =
  -- 9 normal or 11 small characters); a label is left out when it would not fit beside its
  -- value with a space, so the number always shows.
  local x = 74
  local function row(y, label, val, flags, small)
    local f = small and SMLSIZE or 0
    if (#label + 1 + #val) * (small and SW or 6) <= 55 then lcd.drawText(x, y, label, f) end
    lcd.drawText(127, y, val, f + RIGHT + (flags or 0))
  end
  -- low-altitude alarm (Setup LOW ALT): the value inverted and blinking while low
  row(10, "ALT", s.alt and u.altStr(s.alt) or "---", ctx.A.altLow and (BLINK + INVERS) or 0)
  row(18, "SPD", spd and (u.spd(spd) .. u.spdLbl) or "---")
  -- home row: "H", the arrow to home right after it (radius 4: x 82-90), the distance right-aligned
  -- at the column edge like the other rows (5 characters at most: x 98-127)
  lcd.drawText(x, 26, "H", 0)
  homeArrow(x + 12, 29, s)
  lcd.drawText(127, 26, u.dist(s.homeDist), RIGHT)
  -- voltage alarm (OmniDeck Setup): the value inverted while low, blinking while critical
  local st = ctx.A.stage or 0
  local vf = (st == 2 and BLINK + INVERS) or (st == 1 and INVERS) or 0
  row(34, "BAT", s.volt and string.format("%.1fV", s.volt) or "--.-V", vf)
  -- whole amps from 100 A so "CUR" still fits; floor() because Lua 5.3 (EdgeTX B&W) refuses
  -- "%d" for a number with a fraction ("number has no integer representation")
  row(42, "CUR", s.curr and (s.curr < 99.95 and string.format("%.1fA", s.curr) or (floor(s.curr + 0.5) .. "A")) or "--.-A")
  local e = efficiency(u, s, ctx.clock())
  row(51, "EF", (e and (e < 99.95 and string.format("%.1f", e) or tostring(floor(e + 0.5))) or "--") .. u.effLbl, 0, true)
  local t = floor(ctx.flightT or 0)
  row(58, "TIM", string.format("%02d:%02d", floor(t / 60), t % 60), 0, true)
end

return { draw = draw }
