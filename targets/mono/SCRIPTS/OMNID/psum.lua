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
  -- whole-flight efficiency, as the log: mAh used over distance flown (Wh with the average volts)
  local eff = nil
  if f.used and f.dist > 100 then
    local volts, km = f.voltN and f.voltSum / f.voltN, f.dist / 1000
    if string.find(u.effLbl, "WH", 1, true) then
      if volts then eff = f.used / 1000 * volts / km end
    else
      eff = f.used / km
    end
    if eff and string.find(u.effLbl, "MI", 1, true) then eff = eff * 1.609344 end
  end
  -- seven rows at 8 px: distance flown (the track, added up) and the farthest from home apart
  local rows = {
    { "FLIGHT", string.format("%02d:%02d", floor(t / 60), t % 60) },
    { "DIST FLOWN", u.dist(f.dist) },
    { "MAX HOME", u.dist(f.maxHome) },
    { "MAX ALT", f.maxAlt and (u.alt(f.maxAlt) .. u.altLbl) or "--" },
    { spdLbl, spdVal },
    { "EFFICIENCY", eff and (string.format(eff < 100 and "%.1f" or "%d", eff) .. u.effLbl) or "--" },
    { "MIN VOLT", f.minVolt and string.format("%.1fV", f.minVolt) or "--" },
  }
  for i, r in ipairs(rows) do
    lcd.drawText(1, 1 + i * 8, r[1], 0)
    lcd.drawText(127, 1 + i * 8, r[2], RIGHT)
  end
  if ctx.logName then lcd.drawText(127, 0, "LOG", INVERS + RIGHT) end
end

return { draw = draw }
