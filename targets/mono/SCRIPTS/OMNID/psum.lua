--[[
  OmniDeck Mono, flight summary (128x64): opens by itself at disarm after at least 10 s armed
  (Setup: SUMMARY); ENTER then goes back to the start page. With STATS PAGE on it is also in the
  page cycle, showing the flight in progress (or the last one). The same figures go into the
  flight log file.
]]

local floor = math.floor

local function draw(ctx)
  local f, u = ctx.F.live(), ctx.u
  lcd.drawFilledRectangle(0, 0, 128, 8, FORCE)   -- 8 px: seven rows fit below
  lcd.drawText(1, 0, ctx.F.last() == f and "FLIGHT SUMMARY" or "FLIGHT STATS", INVERS)
  if not f then
    lcd.drawText(1, 30, "NO FLIGHT YET", 0)
    return
  end
  local t = floor(f.time or ctx.flightT or 0)
  -- airspeed and ground speed side by side when there is an airspeed sensor
  local spdLbl, spdVal = "MAX GS", f.maxGspd and (u.spd(f.maxGspd) .. u.spdLbl) or "--"
  if f.maxAspd then
    spdLbl = "MAX AS/GS"
    spdVal = u.spd(f.maxAspd) .. "/" .. (f.maxGspd and u.spd(f.maxGspd) or "--") .. u.spdLbl
  end
  -- seven rows at 8 px: distance flown (the track, added up) and the farthest from home apart
  local rows = {
    { "FLIGHT", string.format("%02d:%02d", floor(t / 60), t % 60) },
    { "DIST FLOWN", u.dist(f.dist) },
    { "MAX HOME", u.dist(f.maxHome) },
    { "MAX ALT", f.maxAlt and (u.alt(f.maxAlt) .. u.altLbl) or "--" },
    { spdLbl, spdVal },
    { "USED", f.used and (floor(f.used + 0.5) .. "MAH") or "--" },
    { "MIN VOLT", f.minVolt and string.format("%.1fV", f.minVolt) or "--" },
  }
  for i, r in ipairs(rows) do
    lcd.drawText(1, 1 + i * 8, r[1], 0)
    lcd.drawText(127, 1 + i * 8, r[2], RIGHT)
  end
  if ctx.logName then lcd.drawText(127, 0, "LOG", INVERS + RIGHT) end
end

return { draw = draw }
