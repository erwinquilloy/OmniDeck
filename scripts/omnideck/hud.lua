-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck avionics: artificial horizon with pitch ladder and roll scale, speed tape
  (left), altitude tape (right), heading tape (top) and a vertical-speed bar.
]]

local H = {}

local C = {
  sky = lcd.RGB(40, 110, 190), ground = lcd.RGB(130, 80, 40), line = lcd.RGB(255, 255, 255),
  tape = lcd.RGB(0, 0, 0), tapeTxt = lcd.RGB(255, 255, 255), box = lcd.RGB(0, 0, 0),
  sym = lcd.RGB(255, 210, 0), home = lcd.RGB(80, 200, 255), climb = lcd.RGB(80, 230, 80),
  sink = lcd.RGB(255, 120, 60), dim = lcd.RGB(190, 190, 190), gs = lcd.RGB(90, 235, 140),
  warn = lcd.RGB(255, 190, 40), bad = lcd.RGB(255, 70, 70),
}
H.C = C

-- round to a pixel; where Lua time is short (EdgeTX) the radio's own floor() is used directly
-- a NaN or infinite value (bad sensor data) would stop paint() on Ethos: drawn at 0 instead
local I = OD_LITE and math.floor or function(v) v = math.floor(v + 0.5) if v ~= v or v == math.huge or v == -math.huge then return 0 end return v end

-- dark translucent backing for tapes; Ethos has no alpha fill, so a dotted look is avoided and a solid strip is used
local function strip(x, y, w, h)
  lcd.color(lcd.RGB(20, 20, 20))
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
end

-- value box with a pointer on one side
local function readout(x, y, w, h, text, pointRight, font)
  lcd.color(C.box)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  local tip = h / 2
  if pointRight then
    lcd.drawFilledTriangle(I(x + w), I(y), I(x + w + tip), I(y + h / 2), I(x + w), I(y + h))
  else
    lcd.drawFilledTriangle(I(x), I(y), I(x - tip), I(y + h / 2), I(x), I(y + h))
  end
  lcd.color(C.line)
  lcd.drawRectangle(I(x), I(y), I(w), I(h))
  lcd.font(font)
  local _, th = lcd.getTextSize(text)
  lcd.drawText(I(x + w / 2), I(y + (h - th) / 2), text, CENTERED)
end

-- ground speed box under the airspeed box: a size smaller, in its own colour
local function subReadout(x, y, w, text, font)
  lcd.font(FONT_XS)
  local tagW, tagH = lcd.getTextSize("GS")
  lcd.font(font)
  local tw, th = lcd.getTextSize(text)
  local bw, bh = math.max(w, tw + tagW + 12), th + 4
  lcd.color(C.box)
  lcd.drawFilledRectangle(I(x), I(y), I(bw), I(bh))
  lcd.color(C.gs)
  lcd.drawRectangle(I(x), I(y), I(bw), I(bh))
  lcd.drawText(I(x + bw - 4), I(y + 2), text, RIGHT)
  lcd.font(FONT_XS)
  lcd.drawText(I(x + 4), I(y + (bh - tagH) / 2), "GS")
end

-- white text with a black outline, readable over both sky and ground
local function outlined(x, y, text, flags, color)
  x, y = I(x), I(y)
  lcd.color(C.tape)
  if OD_LITE then
    lcd.drawText(x + 1, y + 1, text, flags)
  else
    lcd.drawText(x - 1, y - 1, text, flags)
    lcd.drawText(x + 1, y - 1, text, flags)
    lcd.drawText(x - 1, y + 1, text, flags)
    lcd.drawText(x + 1, y + 1, text, flags)
  end
  lcd.color(color)
  lcd.drawText(x, y, text, flags)
end

H.outlined = outlined

-- vertical tape: value in display units, step between labels, pixels per unit.
-- It has no background, so the horizon shows through.
local function vtape(x, y, w, h, value, step, ppu, leftSide, font, boxFont, label)
  lcd.font(FONT_XS)
  local _, lh = lcd.getTextSize("A")
  -- the ladder stops below the label, so a number scrolling past never runs into it
  lcd.setClipping(I(x), I(y + lh + 3), I(w), I(h - lh - 3))
  local cy = y + h / 2
  lcd.font(font)
  local _, th = lcd.getTextSize("0")
  local first = math.floor((value - (h / 2) / ppu) / step) * step
  local v = first
  while v <= value + (h / 2) / ppu + step do
    local ty = cy - (v - value) * ppu
    local tick = w * 0.22
    local x1 = leftSide and x + w - tick or x
    if not OD_LITE then
      lcd.color(C.tape)
      lcd.drawLine(I(x1), I(ty) + 1, I(x1 + tick), I(ty) + 1)
    end
    lcd.color(C.tapeTxt)
    lcd.drawLine(I(x1), I(ty), I(x1 + tick), I(ty))
    -- OD_LITE (EdgeTX): a number on every other tick, to save Lua time
    if OD_LITE and (v / step) % 2 ~= 0 then
      -- tick only
    elseif leftSide then
      outlined(x + w - tick - 4, ty - th / 2, string.format("%d", v), RIGHT, C.tapeTxt)
    else
      outlined(x + tick + 4, ty - th / 2, string.format("%d", v), LEFT, C.tapeTxt)
    end
    v = v + step
  end
  local W, Hh = lcd.getWindowSize()
  lcd.setClipping(0, 0, W, Hh)
  -- current value box: a size up from the ladder, and wide enough for the digits
  local text = string.format("%d", math.floor(value + 0.5))
  lcd.font(boxFont)
  local tw, bth = lcd.getTextSize(text)
  local bh = bth + 6
  local bw = math.max(w - bh / 2 - 2, tw + 10)
  local bx = leftSide and x + 1 or x + w - bw - 1
  readout(bx, cy - bh / 2, bw, bh, text, leftSide, boxFont)
  if label then
    lcd.font(FONT_XS)
    if lcd.getTextSize(label) > w - 2 then lcd.font(FONT_XXS) end   -- narrow tape (480x272)
    outlined(x + w / 2, y + 2, label, CENTERED, C.tapeTxt)
  end
  return bx, cy + bh / 2, bw, bh
end

local CARD = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" }

-- no background: the horizon shows through, as on the speed and altitude tapes
local function headingTape(x, y, w, h, hdg, homeBrg, font, boxFont)
  lcd.setClipping(I(x), I(y), I(w), I(h))
  local cx = x + w / 2
  local span = 90                       -- degrees across the tape
  local ppd = w / span
  lcd.font(font)
  local _, th = lcd.getTextSize("N")
  lcd.color(C.tapeTxt)
  -- OD_LITE (EdgeTX): 15 deg ticks only, to save Lua time
  local stepD = OD_LITE and 15 or 5
  local start = math.floor((hdg - span / 2) / stepD) * stepD
  for d = start, start + span + stepD, stepD do
    local tx = cx + (d - hdg) * ppd
    local dd = d % 360
    local y0 = (dd % 15 == 0) and y + h - h * 0.3 or y + h - h * 0.15
    if not OD_LITE then
      lcd.color(C.tape)
      lcd.drawLine(I(tx) + 1, I(y0), I(tx) + 1, I(y + h - 1))
    end
    lcd.color(C.tapeTxt)
    lcd.drawLine(I(tx), I(y0), I(tx), I(y + h - 1))
    if dd % 15 == 0 then
      -- OD_LITE (EdgeTX): the compass points only; the box below has the exact heading
      local lbl = CARD[dd] or ((dd % 30 == 0 and not OD_LITE) and tostring(math.floor(dd / 10)) or nil)
      if lbl then outlined(tx, y + 1, lbl, CENTERED, C.tapeTxt) end
    end
  end
  if homeBrg then
    local rel = (homeBrg - hdg + 540) % 360 - 180
    local hx = cx + math.max(-span / 2, math.min(span / 2, rel)) * ppd
    lcd.color(C.home)
    lcd.drawFilledTriangle(I(hx - 5), I(y + h - 1), I(hx), I(y + h - 8), I(hx + 5), I(y + h - 1))
  end
  local W, Hh = lcd.getWindowSize()
  lcd.setClipping(0, 0, W, Hh)
  -- heading box
  local txt = string.format("%03d", math.floor(hdg + 0.5) % 360)
  lcd.font(boxFont)
  local tw, bth = lcd.getTextSize("000")
  lcd.color(C.box)
  lcd.drawFilledRectangle(I(cx - tw / 2 - 4), I(y + h), I(tw + 8), I(bth + 2))
  lcd.color(C.line)
  lcd.drawRectangle(I(cx - tw / 2 - 4), I(y + h), I(tw + 8), I(bth + 2))
  lcd.drawText(I(cx), I(y + h + 1), txt, CENTERED)
end

-- roll scale ticks: sin, cos, length; worked out once
local ROLL_TICKS = {}
for _, a in ipairs(OD_LITE and { -60, -30, -20, -10, 0, 10, 20, 30, 60 } or { -60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60 }) do
  local t = math.rad(a)
  ROLL_TICKS[#ROLL_TICKS + 1] = { math.sin(t), math.cos(t), (a % 30 == 0) and 9 or 5 }
end

-- horizon + ladder + roll scale inside (x,y,w,h)
local function horizon(x, y, w, h, roll, pitch, font)
  local cx, cy = x + w / 2, y + h / 2
  local ppd = h / 50                    -- 50 deg of pitch over the full height
  local r = math.rad(roll)
  local sr, cr = math.sin(r), math.cos(r)
  -- along-horizon direction and the "down" normal (screen y grows downwards)
  local dx, dy = cr, -sr
  local nx, ny = sr, cr
  -- EdgeTX's own ground fill (lcd.drawHudGround, adapter) shifts the horizon by pitch along the
  -- screen axes, the vertical part stretched 1.85x: horizon line and ladder follow the same rule,
  -- so their sideways shift is ppd / 1.85 there (Yaapu's look) instead of ppd.
  local hudGround = lcd.drawHudGround
  local ppx = hudGround and ppd / 1.85 or ppd
  local px, py = cx + nx * pitch * ppx, cy + ny * pitch * ppd
  local L = (w + h) * 2

  lcd.setClipping(I(x), I(y), I(w), I(h))
  lcd.color(C.sky)
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  local ax, ay = px - dx * L, py - dy * L
  local bx, by = px + dx * L, py + dy * L
  lcd.color(C.ground)
  if hudGround then
    hudGround(pitch * ppd / 1.85, roll, I(x), I(y), I(w), I(h))
  else
    local cx2, cy2 = bx + nx * L, by + ny * L
    local dx2, dy2 = ax + nx * L, ay + ny * L
    if lcd.drawFilledQuad then
      lcd.drawFilledQuad(ax, ay, bx, by, cx2, cy2, dx2, dy2)   -- EdgeTX adapter: clipped once as one polygon
    else
      lcd.drawFilledTriangle(I(ax), I(ay), I(bx), I(by), I(cx2), I(cy2))
      lcd.drawFilledTriangle(I(ax), I(ay), I(cx2), I(cy2), I(dx2), I(dy2))
    end
  end
  lcd.color(C.line)
  lcd.drawLine(I(ax), I(ay), I(bx), I(by))

  -- pitch ladder every 10 deg (5 deg short marks)
  lcd.font(font)
  local _, th = lcd.getTextSize("0")
  for a = -40, 40, OD_LITE and 10 or 5 do
    if a ~= 0 and math.abs(a - pitch) <= 22 then
      local half = (a % 10 == 0) and w * 0.14 or w * 0.06
      local lx, ly = px - nx * a * ppx, py - ny * a * ppd
      lcd.drawLine(I(lx - dx * half), I(ly - dy * half), I(lx + dx * half), I(ly + dy * half))
      if a % 10 == 0 then
        lcd.drawText(I(lx + dx * (half + 16)), I(ly + dy * (half + 16) - th / 2), tostring(math.abs(a)), CENTERED)
        if not OD_LITE then   -- EdgeTX: one side only, to save Lua time
          lcd.drawText(I(lx - dx * (half + 16)), I(ly - dy * (half + 16) - th / 2), tostring(math.abs(a)), CENTERED)
        end
      end
    end
  end

  -- roll scale (fixed) and pointer (turns with the horizon)
  local R = math.min(w, h) * 0.42
  for _, t in ipairs(ROLL_TICKS) do
    local sn, cs, len = t[1], t[2], t[3]
    local sx, sy = cx + sn * R, cy - cs * R
    local ex, ey = cx + sn * (R + len), cy - cs * (R + len)
    lcd.drawLine(I(sx), I(sy), I(ex), I(ey))
  end
  local pr = math.rad(-roll)
  local tipx, tipy = cx + math.sin(pr) * (R - 1), cy - math.cos(pr) * (R - 1)
  local bxl, byl = cx + math.sin(pr - 0.06) * (R - 11), cy - math.cos(pr - 0.06) * (R - 11)
  local bxr, byr = cx + math.sin(pr + 0.06) * (R - 11), cy - math.cos(pr + 0.06) * (R - 11)
  lcd.color(C.sym)
  lcd.drawFilledTriangle(I(tipx), I(tipy), I(bxl), I(byl), I(bxr), I(byr))

  -- fixed aircraft symbol
  local ww = w * 0.16
  lcd.drawFilledRectangle(I(cx - ww - 2), I(cy - 2), I(ww * 0.7), 4)
  lcd.drawFilledRectangle(I(cx + ww * 0.3 + 2), I(cy - 2), I(ww * 0.7), 4)
  lcd.drawFilledRectangle(I(cx - 3), I(cy - 3), 6, 6)

  local W, Hh = lcd.getWindowSize()
  lcd.setClipping(0, 0, W, Hh)
end

-- vertical speed bar on the right edge of the horizon
local function vario(x, y, w, h, vs)
  if vs == nil then return end
  local cy = y + h / 2
  local full = 5                         -- m/s at the end of the bar
  local len = math.max(-1, math.min(1, vs / full)) * (h / 2 - 2)
  lcd.color(lcd.RGB(20, 20, 20))
  lcd.drawFilledRectangle(I(x), I(y), I(w), I(h))
  lcd.color(vs >= 0 and C.climb or C.sink)
  if len >= 0 then lcd.drawFilledRectangle(I(x + 1), I(cy - len), I(w - 2), I(len) + 1)
  else lcd.drawFilledRectangle(I(x + 1), I(cy), I(w - 2), I(-len) + 1) end
  lcd.color(C.line)
  lcd.drawLine(I(x), I(cy), I(x + w), I(cy))
end

-- ready-to-arm status, centred on the horizon just below the aircraft symbol; (x,y,w,h) as for H.draw
function H.armStatus(x, y, w, h, s)
  local text, col
  if s.armReady == true then
    text, col = s.armNote and ("READY, " .. s.armNote) or "READY TO ARM", s.armNote and C.warn or C.climb
  elseif s.armReady == false then
    text, col = s.armNote or "NOT READY TO ARM", C.bad
  elseif s.fc == "ArduPilot" then
    text, col = "CHECKING ARMING", C.dim
  else
    return
  end
  lcd.font(h >= 350 and FONT_L or (h >= 240 and FONT_STD or FONT_S))
  local tw, th = lcd.getTextSize(text)
  local bw, bh = tw + 16, th + 8
  local bx, by = x + (w - bw) / 2, y + h / 2 + h * 0.08
  lcd.color(C.box)
  lcd.drawFilledRectangle(I(bx), I(by), I(bw), I(bh))
  lcd.color(col)
  lcd.drawRectangle(I(bx), I(by), I(bw), I(bh))
  lcd.drawRectangle(I(bx + 1), I(by + 1), I(bw - 2), I(bh - 2))
  lcd.drawText(I(bx + 8), I(by + 4), text)
end

-- u: { spd=fn(m/s)->display, spdLbl=, alt=fn(m)->display, altLbl= }
function H.draw(x, y, w, h, s, u)
  -- bodies are ~400 px tall on 800x480 and ~270 px on 480x320
  local big, med = h >= 350, h >= 240
  local font = big and FONT_STD or (med and FONT_S or FONT_XS)        -- ladders
  local boxFont = big and FONT_XL or (med and FONT_L or FONT_STD)     -- current speed/altitude
  local hdgFont = big and FONT_L or (med and FONT_STD or FONT_S)      -- current heading
  local tapeW = math.max(46, math.floor(w * 0.17))
  local headH = math.max(18, math.floor(h * 0.08))
  local varW = med and 8 or 6

  local hx, hy, hw, hh = x, y, w, h
  horizon(hx, hy, hw, hh, s.roll or 0, s.pitch or 0, big and FONT_S or (med and FONT_XS or FONT_XXS))

  local spd = s.aspd or s.gspd
  if spd then
    local bx, by, bw = vtape(x, y + headH + 16, tapeW, h - headH - 22, u.spd(spd), u.spdStep, u.spdPpu(h), true, font, boxFont,
      (s.aspd and "AS " or "GS ") .. u.spdLbl)
    if s.aspd and s.gspd then
      subReadout(bx, by + 3, bw, string.format("%d", I(u.spd(s.gspd))), hdgFont)
    end
  end
  if s.alt then
    local ax, ay, aw, ah = vtape(x + w - tapeW - varW, y + headH + 16, tapeW, h - headH - 22, u.alt(s.alt), u.altStep, u.altPpu(h), false, font, boxFont,
      "ALT " .. u.altLbl)
    if u.alarmA then   -- below the low altitude alarm: red frame round the altitude box
      lcd.color(C.bad)
      lcd.drawRectangle(I(ax - 2), I(ay - ah - 2), I(aw + 4), I(ah + 4))
      lcd.drawRectangle(I(ax - 3), I(ay - ah - 3), I(aw + 6), I(ah + 6))
    end
  end
  vario(x + w - varW, y + headH + 16, varW, h - headH - 22, s.vspd)
  if s.yaw then
    headingTape(x + tapeW + 4, y, w - 2 * tapeW - varW - 8, headH, s.yaw, s.homeBrg, font, hdgFont)
  end
end

return H
