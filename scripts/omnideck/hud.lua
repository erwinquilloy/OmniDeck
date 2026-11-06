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
-- test41: Ethos too. The rounding helper this was (floor, then NaN and infinity tests) was half of
-- the main page's Lua time on an X18; bad telemetry is now checked once per update where it comes
-- in (H.draw), and coordinates floor straight away as EdgeTX's always did (at most 1 px apart)
local I = math.floor
-- displayed numbers: rounded to the nearest whole number on Ethos (NaN/inf shown as 0), as I() did
-- before test41; EdgeTX/OpenTX floor them as they always did. A few calls per update, so not I().
local R = OD_LITE and math.floor or function(v) v = math.floor(v + 0.5) if v ~= v or v == math.huge or v == -math.huge then return 0 end return v end
-- a finite number, or nil: NaN and infinity from bad sensor data would stop a drawing call
local function fin(v) if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end return v end
-- Lighter drawing on every radio (EdgeTX / OpenTX since test17, Ethos since test36): numbers on
-- every other tape tick, 15 deg heading ticks, 10 deg pitch rungs numbered on one side, no 45 deg
-- roll ticks, one-pixel text shadows. The full set put a tester's X18 over Ethos's per-call Lua
-- limit ("Max instructions count reached", INAV + TBS, 2026-11-05) where an X20S ran it clean.
-- OD_LEAN = false brings the full drawing back (simulator comparisons).
local LEAN = OD_LITE or OD_LEAN ~= false

-- OpenTX 2.3 (set by etx.lua): no filled triangles, so each one is filled in Lua strip by strip,
-- and a widget gets 10,000 Lua instructions per screen update. Shapes are kept simple there.
local OTX = OD_OTX

-- OpenTX: the ground below a tilted horizon in rectangles, as Yaapu fills it on OpenTX. Ground is
-- where (X - px) * nx + (Y - py) * ny > 0. Only the band the horizon line crosses is filled in
-- 6 px rows (columns when banked past 45 deg); the ground beyond it is one rectangle. Level
-- flight takes two rectangles, 20 deg of bank about 16.
local STRIP = 6
-- OpenTX: the strips skip the adapter (etx.lua OD_RAW): one OpenTX call each, colour set once
local RAW = OD_RAW
local rfill, CUST = RAW and RAW.fill, RAW and RAW.CUSTOM
local lcdFill = lcd.drawFilledRectangle
local function groundRects(x, y, w, h, px, py, nx, ny)
  local x2, y2 = x + w, y + h
  -- OpenTX: OpenTX's own fill with the colour flag (the 5th argument; the adapter ignores it).
  -- It doesn't clip, so every size is cut to the box here: the same pixels the adapter drew.
  local fill = rfill or lcdFill
  if RAW then RAW.color(C.ground) end
  local min, max, floor = math.min, math.max, math.floor
  local ix, iy = I(x), I(y)
  if math.abs(ny) >= math.abs(nx) then
    -- rows: the line's height at the left and right edges gives the band
    local yl = py - (x - px) * nx / ny
    local yr = py - (x2 - px) * nx / ny
    local b1, b2 = max(y, min(yl, yr)), min(y2, max(yl, yr))
    if ny > 0 then   -- ground below the band
      if b2 < y2 then local ys = I(max(y, b2)) fill(ix, ys, I(w), y2 - ys, CUST) end
    else             -- inverted: ground above the band
      if b1 > y then fill(ix, iy, I(w), min(I(min(y2, b1) - y) + 1, y2 - iy), CUST) end
    end
    if nx ~= 0 then
      local st = STRIP   -- 6 px: taller strips (fewer calls) showed as steps under the horizon line
      local yy = floor(b1)
      while yy < b2 do
        local sh = min(st, y2 - yy)
        local xb = px - (yy + st / 2 - py) * ny / nx
        if nx > 0 then
          if xb < x2 then local xs = I(max(x, xb)) fill(xs, yy, x2 - xs, sh, CUST) end
        elseif xb > x then
          fill(ix, yy, min(I(min(x2, xb) - x) + 1, x2 - ix), sh, CUST)
        end
        yy = yy + st
      end
    end
  else
    -- columns: steep horizon (banked past 45 deg)
    local xt = px - (y - py) * ny / nx
    local xb = px - (y2 - py) * ny / nx
    local b1, b2 = max(x, min(xt, xb)), min(x2, max(xt, xb))
    if nx > 0 then
      if b2 < x2 then local xs = I(max(x, b2)) fill(xs, iy, x2 - xs, I(h), CUST) end
    else
      if b1 > x then fill(ix, iy, min(I(min(x2, b1) - x) + 1, x2 - ix), I(h), CUST) end
    end
    if ny ~= 0 then
      local st = STRIP
      local xx = floor(b1)
      while xx < b2 do
        local sw = min(st, x2 - xx)
        local yb = py - (xx + st / 2 - px) * nx / ny
        if ny > 0 then
          if yb < y2 then local ys = I(max(y, yb)) fill(xx, ys, sw, y2 - ys, CUST) end
        elseif yb > y then
          fill(xx, iy, sw, min(I(min(y2, yb) - y) + 1, y2 - iy), CUST)
        end
        xx = xx + st
      end
    end
  end
end

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
  if OTX then
    -- OpenTX: the box alone (a pointer is a filled triangle, filled in Lua there)
  elseif pointRight then
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
  if LEAN then
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

-- OpenTX: one draw, no outline (chosen here once, so EdgeTX and Ethos don't test for it per call)
if OTX then
  outlined = function(x, y, text, flags, color)
    lcd.color(color)
    lcd.drawText(I(x), I(y), text, flags)
  end
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
  -- OpenTX: no moving ladder, only the current value box below (and the label)
  if OTX then v = math.huge end
  while v <= value + (h / 2) / ppu + step do
    local ty = cy - (v - value) * ppu
    local tick = w * 0.22
    local x1 = leftSide and x + w - tick or x
    if not LEAN then
      lcd.color(C.tape)
      lcd.drawLine(I(x1), I(ty) + 1, I(x1 + tick), I(ty) + 1)
    end
    lcd.color(C.tapeTxt)
    lcd.drawLine(I(x1), I(ty), I(x1 + tick), I(ty))
    -- LEAN (EdgeTX): a number on every other tick, to save Lua time (OpenTX skips the loop)
    if LEAN and (v / step) % 2 ~= 0 then
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

-- the heading box under the heading tape; returns its text position
local function headingBox(x, y, w, h, boxFont, frame)
  local cx = x + w / 2
  lcd.font(boxFont)
  local tw, bth = lcd.getTextSize("000")
  if frame then
    lcd.color(C.box)
    lcd.drawFilledRectangle(I(cx - tw / 2 - 4), I(y + h), I(tw + 8), I(bth + 2))
    lcd.color(C.line)
    lcd.drawRectangle(I(cx - tw / 2 - 4), I(y + h), I(tw + 8), I(bth + 2))
  end
  return cx, y + h + 1
end

local CARD = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" }

-- no background: the horizon shows through, as on the speed and altitude tapes
local function headingTape(x, y, w, h, hdg, homeBrg, font, boxFont, fixedDone)
  -- OpenTX: no moving tape and no home marker on it, only the heading box (the HOME block has
  -- the home arrow)
  if OTX then homeBrg = nil end
  lcd.setClipping(I(x), I(y), I(w), I(h))
  local cx = x + w / 2
  local span = 90                       -- degrees across the tape
  local ppd = w / span
  lcd.font(font)
  local _, th = lcd.getTextSize("N")
  lcd.color(C.tapeTxt)
  -- LEAN (EdgeTX): 15 deg ticks only, to save Lua time
  local stepD = LEAN and 15 or 5
  local start = math.floor((hdg - span / 2) / stepD) * stepD
  local stop = OTX and start - 1 or start + span + stepD   -- OpenTX: the loop doesn't run
  for d = start, stop, stepD do
    local tx = cx + (d - hdg) * ppd
    local dd = d % 360
    local y0 = (dd % 15 == 0) and y + h - h * 0.3 or y + h - h * 0.15
    if not LEAN then
      lcd.color(C.tape)
      lcd.drawLine(I(tx) + 1, I(y0), I(tx) + 1, I(y + h - 1))
    end
    lcd.color(C.tapeTxt)
    lcd.drawLine(I(tx), I(y0), I(tx), I(y + h - 1))
    if dd % 15 == 0 then
      -- LEAN (EdgeTX): the compass points only; the box below has the exact heading
      local lbl = CARD[dd] or ((dd % 30 == 0 and not LEAN) and tostring(math.floor(dd / 10)) or nil)
      if lbl then outlined(tx, y + 1, lbl, CENTERED, C.tapeTxt) end
    end
  end
  if homeBrg then
    local rel = (homeBrg - hdg + 540) % 360 - 180
    local hx = cx + math.max(-span / 2, math.min(span / 2, rel)) * ppd
    lcd.color(C.home)
    if OTX then
      lcd.drawFilledRectangle(I(hx - 3), I(y + h - 7), 7, 7)   -- OpenTX: a square, not a triangle
    else
      lcd.drawFilledTriangle(I(hx - 5), I(y + h - 1), I(hx), I(y + h - 8), I(hx + 5), I(y + h - 1))
    end
  end
  local W, Hh = lcd.getWindowSize()
  lcd.setClipping(0, 0, W, Hh)
  -- heading box (its frame is in the OpenTX overlay bitmap when there is one)
  local txt = string.format("%03d", math.floor(hdg + 0.5) % 360)
  local tx, ty = headingBox(x, y, w, h, boxFont, not fixedDone)
  lcd.color(C.line)
  lcd.drawText(I(tx), I(ty), txt, CENTERED)
end

-- roll scale ticks: sin, cos, length; worked out once
local ROLL_TICKS = {}
for _, a in ipairs((OTX and { -60, -30, 0, 30, 60 }) or (LEAN and { -60, -30, -20, -10, 0, 10, 20, 30, 60 })
                   or { -60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60 }) do
  local t = math.rad(a)
  ROLL_TICKS[#ROLL_TICKS + 1] = { math.sin(t), math.cos(t), (a % 30 == 0) and 9 or 5 }
end

-- The fixed parts of the HUD: drawn live, or (OpenTX) once into a bitmap with the same code, so
-- both look alike. Colours are set here, so the export needs nothing else.
local function rollTicks(cx, cy, R)
  lcd.color(C.line)
  for _, t in ipairs(ROLL_TICKS) do
    local sn, cs, len = t[1], t[2], t[3]
    local sx, sy = cx + sn * R, cy - cs * R
    local ex, ey = cx + sn * (R + len), cy - cs * (R + len)
    lcd.drawLine(I(sx), I(sy), I(ex), I(ey))
  end
end
local function aircraftSymbol(cx, cy, w)
  lcd.color(C.sym)
  local ww = w * 0.16
  lcd.drawFilledRectangle(I(cx - ww - 2), I(cy - 2), I(ww * 0.7), 4)
  lcd.drawFilledRectangle(I(cx + ww * 0.3 + 2), I(cy - 2), I(ww * 0.7), 4)
  lcd.drawFilledRectangle(I(cx - 3), I(cy - 3), 6, 6)
end

-- horizon + ladder + roll scale inside (x,y,w,h)
local function horizon(x, y, w, h, roll, pitch, font, fixedDone)
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
  elseif OTX then
    groundRects(x, y, w, h, px, py, nx, ny)
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
  for a = -40, 40, LEAN and 10 or 5 do
    if a ~= 0 and math.abs(a - pitch) <= 22 then
      local half = (a % 10 == 0) and w * 0.14 or w * 0.06
      local lx, ly = px - nx * a * ppx, py - ny * a * ppd
      lcd.drawLine(I(lx - dx * half), I(ly - dy * half), I(lx + dx * half), I(ly + dy * half))
      -- OpenTX: rungs without numbers, as Yaapu's horizon there
      if a % 10 == 0 and not OTX then
        lcd.drawText(I(lx + dx * (half + 16)), I(ly + dy * (half + 16) - th / 2), tostring(math.abs(a)), CENTERED)
        if not LEAN then   -- EdgeTX: one side only, to save Lua time
          lcd.drawText(I(lx - dx * (half + 16)), I(ly - dy * (half + 16) - th / 2), tostring(math.abs(a)), CENTERED)
        end
      end
    end
  end

  -- roll scale (fixed) and pointer (turns with the horizon)
  local R = math.min(w, h) * 0.42
  if not fixedDone then rollTicks(cx, cy, R) end
  local pr = math.rad(-roll)
  local tipx, tipy = cx + math.sin(pr) * (R - 1), cy - math.cos(pr) * (R - 1)
  local bxl, byl = cx + math.sin(pr - 0.06) * (R - 11), cy - math.cos(pr - 0.06) * (R - 11)
  local bxr, byr = cx + math.sin(pr + 0.06) * (R - 11), cy - math.cos(pr + 0.06) * (R - 11)
  lcd.color(C.sym)
  if OTX then   -- OpenTX: the pointer as two lines from the tip
    lcd.drawLine(I(tipx), I(tipy), I(bxl), I(byl))
    lcd.drawLine(I(tipx), I(tipy), I(bxr), I(byr))
  else
    lcd.drawFilledTriangle(I(tipx), I(tipy), I(bxl), I(byl), I(bxr), I(byr))
  end

  -- fixed aircraft symbol
  if not fixedDone then aircraftSymbol(cx, cy, w) end

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

-- OpenTX: the HUD's fixed parts (roll scale, aircraft symbol, heading box frame) as one
-- transparent bitmap per HUD size, made by tools/sim_edgetx.py --otx-panels from H.drawFixed;
-- one drawBitmap instead of about ten drawing calls, as Yaapu's hud.png. No file: drawn live.
local overlays = {}
local function overlayFor(w, h)
  local key = math.floor(w) .. "x" .. math.floor(h)
  local b = overlays[key]
  if b == nil then
    local ok, bmp = pcall(lcd.loadBitmap, (OD_ROOT or "") .. "otx/hud_" .. key .. ".png")
    b = (ok and bmp) or false
    overlays[key] = b
  end
  return b or nil
end

-- the layout both H.draw and H.drawFixed use
local function hudLayout(w, h)
  local big, med = h >= 350, h >= 240
  local font = big and FONT_STD or (med and FONT_S or FONT_XS)        -- ladders
  local boxFont = big and FONT_XL or (med and FONT_L or FONT_STD)     -- current speed/altitude
  local hdgFont = big and FONT_L or (med and FONT_STD or FONT_S)      -- current heading
  local tapeW = math.max(46, math.floor(w * 0.17))
  local headH = math.max(18, math.floor(h * 0.08))
  local varW = med and 8 or 6
  return big, med, font, boxFont, hdgFont, tapeW, headH, varW
end

-- the fixed layer alone, on an empty canvas (for the OpenTX bitmap)
function H.drawFixed(x, y, w, h)
  local _, _, _, _, hdgFont, tapeW, headH, varW = hudLayout(w, h)
  local cx, cy = x + w / 2, y + h / 2
  rollTicks(cx, cy, math.min(w, h) * 0.42)
  aircraftSymbol(cx, cy, w)
  headingBox(x + tapeW + 4, y, w - 2 * tapeW - varW - 8, headH, hdgFont, true)
end

-- u: { spd=fn(m/s)->display, spdLbl=, alt=fn(m)->display, altLbl= }
function H.draw(x, y, w, h, s, u)
  -- bodies are ~400 px tall on 800x480 and ~270 px on 480x320
  local big, med, font, boxFont, hdgFont, tapeW, headH, varW = hudLayout(w, h)
  -- Ethos: the telemetry this draws from, checked once (EdgeTX / OpenTX: as it was)
  local roll, pitch, aspd, gspd, alt, vspd, yaw, homeBrg = s.roll, s.pitch, s.aspd, s.gspd, s.alt, s.vspd, s.yaw, s.homeBrg
  if not OD_LITE then
    roll, pitch, aspd, gspd, alt = fin(roll), fin(pitch), fin(aspd), fin(gspd), fin(alt)
    vspd, yaw, homeBrg = fin(vspd), fin(yaw), fin(homeBrg)
  end
  local ov = OTX and overlayFor(w, h) or nil   -- nil (not false) on EdgeTX and Ethos: they draw it all

  local hx, hy, hw, hh = x, y, w, h
  horizon(hx, hy, hw, hh, roll or 0, pitch or 0, big and FONT_S or (med and FONT_XS or FONT_XXS), ov ~= nil)
  if ov then lcd.drawBitmap(I(x), I(y), ov) end

  local spd = aspd or gspd
  if spd then
    local bx, by, bw = vtape(x, y + headH + 16, tapeW, h - headH - 22, u.spd(spd), u.spdStep, u.spdPpu(h), true, font, boxFont,
      (aspd and "AS " or "GS ") .. u.spdLbl)
    if aspd and gspd then
      subReadout(bx, by + 3, bw, string.format("%d", R(u.spd(gspd))), hdgFont)
    end
  end
  if alt then
    local ax, ay, aw, ah = vtape(x + w - tapeW - varW, y + headH + 16, tapeW, h - headH - 22, u.alt(alt), u.altStep, u.altPpu(h), false, font, boxFont,
      "ALT " .. u.altLbl)
    if u.alarmA then   -- below the low altitude alarm: red frame round the altitude box
      lcd.color(C.bad)
      lcd.drawRectangle(I(ax - 2), I(ay - ah - 2), I(aw + 4), I(ah + 4))
      lcd.drawRectangle(I(ax - 3), I(ay - ah - 3), I(aw + 6), I(ah + 6))
    end
  end
  -- OpenTX: no vertical-speed bar (Lua budget); its strip keeps the layout, so the overlay fits
  if not OTX then vario(x + w - varW, y + headH + 16, varW, h - headH - 22, vspd) end
  if yaw then
    headingTape(x + tapeW + 4, y, w - 2 * tapeW - varW - 8, headH, yaw, homeBrg, font, hdgFont, ov ~= nil)
  end
end

return H
