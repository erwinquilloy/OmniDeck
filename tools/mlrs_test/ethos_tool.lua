local function now() return os.clock() end
local M = (function()
%CORE%
end)()
%UI%
local sensor = nil
local function push(e) if sensor then sensor:pushFrame(0xAA, e) end end
local function pop()
  if not sensor then return nil end
  local cmd, data = sensor:popFrame(0xAA, 0xAA)
  if cmd == 0xAA and data then return data end
  return nil
end
-- a widget (as OmniDeck and the TECS helper): put it on a full-screen layout
local function create() sensor = crsf.getSensor() return {} end
local lastPaint = 0
local function wakeup(w)
  tick(push, pop)
  if now() - lastPaint >= 0.5 then lastPaint = now() lcd.invalidate() end
end
local function paint(w)
  local W, H = lcd.getWindowSize()
  lcd.color(lcd.RGB(0, 0, 0))
  lcd.drawFilledRectangle(0, 0, W, H)
  local rows = lines()
  lcd.font(H >= 300 and FONT_STD or FONT_S)
  local _, th = lcd.getTextSize("A")
  local y = 4
  for i, l in ipairs(rows) do
    lcd.color(i == 1 and lcd.RGB(255, 200, 0) or lcd.RGB(255, 255, 255))
    lcd.drawText(6, y, l)
    y = y + th + 4
  end
end
local function init()
  system.registerWidget({ key = "mlrstst", name = "mLRS cbridge test", create = create, wakeup = wakeup, paint = paint })
end
return { init = init }
