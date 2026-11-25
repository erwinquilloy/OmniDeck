--[[
  OmniDeck Mono, link and sensor check (128x64): what a tester photographs for a report.
  Link, flight controller, passthrough, link quality, GPS, and the Lua memory in use against the
  ~127 KB EdgeTX gives a telemetry script on a TX12 MK2.
]]

local floor = math.floor

local function row(y, a, b)
  lcd.drawText(1, y, a, 0)
  lcd.drawText(127, y, b, RIGHT)
end

local function draw(ctx)
  local T = ctx.T
  local s = T.s
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  lcd.drawText(1, 1, "OmniDeck Mono v" .. ctx.version, INVERS)
  local now = ctx.clock()
  local pt = now - (s.lastPt or -100) <= 3
  row(10, "LINK", s.link and string.upper(s.link) or "---")
  row(19, "FC", s.fc and string.upper(s.fc) or "---")
  row(28, "PASSTHRU", pt and "YES" or "NO")
  local lq = s.lq and tostring(floor(s.lq)) or "--"
  local rssi = s.rssi and tostring(floor(s.rssi)) or "--"
  row(37, "LQ / RSSI", lq .. " " .. rssi)
  local gps = (s.fix or 0) >= 3 and "3D" or ((s.fix or 0) == 2 and "2D" or "NO")
  row(46, "SATS", string.format("%d %s", s.sats or 0, gps))
  row(55, "LUA MEM", string.format("%d/127K", floor(collectgarbage("count") + 0.5)))
end

return { draw = draw }
