local function now() return getTime() / 100 end
local M = (function()
%CORE%
end)()
%UI%
local function push(e) crossfireTelemetryPush(0xAA, e) end
local function pop()
  local cmd, data = crossfireTelemetryPop()
  while cmd do
    if cmd == 0xAA and data then return data end
    cmd, data = crossfireTelemetryPop()
  end
  return nil
end
local function run(event)
  tick(push, pop)
  lcd.clear()
  local y = 4
  for i, l in ipairs(lines()) do
    lcd.drawText(4, y, l, i == 1 and BOLD or 0)
    y = y + (LCD_H > 200 and 22 or 9)
  end
  if event == EVT_VIRTUAL_EXIT then return 1 end
  return 0
end
return { run = run }
