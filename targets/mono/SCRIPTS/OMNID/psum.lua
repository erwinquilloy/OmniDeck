--[[
  OmniDeck Mono, flight summary (128x64): opens by itself at disarm after at least 10 s armed
  (Setup: SUMMARY); ENTER then goes back to the start page. With STATS PAGE on it is also in the
  page cycle, showing the flight in progress (or the last one). The same figures go into the
  flight log file.
]]

local floor = math.floor

local function draw(ctx)
  local f, u = ctx.F.live(), ctx.u
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  lcd.drawText(1, 1, ctx.F.last() == f and "FLIGHT SUMMARY" or "FLIGHT STATS", INVERS)
  if not f then
    lcd.drawText(1, 30, "NO FLIGHT YET", 0)
    return
  end
  local t = floor(f.time or ctx.flightT or 0)
  local spd = f.maxAspd or f.maxGspd
  local rows = {
    { "FLIGHT", string.format("%02d:%02d", floor(t / 60), t % 60) },
    { "DISTANCE", u.dist(f.dist) },
    { "MAX ALT", f.maxAlt and (u.alt(f.maxAlt) .. u.altLbl) or "--" },
    { f.maxAspd and "MAX AS" or "MAX GS", spd and (u.spd(spd) .. u.spdLbl) or "--" },
    { "USED", f.used and (floor(f.used + 0.5) .. "MAH") or "--" },
    { "MIN VOLT", f.minVolt and string.format("%.1fV", f.minVolt) or "--" },
  }
  for i, r in ipairs(rows) do
    lcd.drawText(1, 1 + i * 9, r[1], 0)
    lcd.drawText(127, 1 + i * 9, r[2], RIGHT)
  end
  if ctx.logName then lcd.drawText(127, 1, "LOG", INVERS + RIGHT) end
end

return { draw = draw }
