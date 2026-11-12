--[[
  OmniDeck Mono, sensor check (page 5, OmniDeck Setup: SENSOR PAGE): every value the telemetry
  code reads from the radio's own sensors, with the sensor it found and its raw value, so a
  tester's photo shows what the radio actually provides. The wheel (or +/-) scrolls.
]]

local ROWS = 7
local top, rows, at = 1, nil, -100

local function scrollDir(e)
  if not e or e == 0 then return 0 end   -- a key constant this radio lacks is nil
  if e == EVT_VIRTUAL_NEXT or e == EVT_VIRTUAL_INC or e == EVT_ROT_RIGHT or e == EVT_PLUS_FIRST
     or e == EVT_PLUS_REPT then return 1 end
  if e == EVT_VIRTUAL_PREV or e == EVT_VIRTUAL_DEC or e == EVT_ROT_LEFT or e == EVT_MINUS_FIRST
     or e == EVT_MINUS_REPT then return -1 end
  return 0
end

local function draw(ctx, event)
  local T = ctx.T
  local now = ctx.clock()
  if not rows or now - at >= 0.5 then rows, at = T.sensorCheck(), now end   -- twice a second
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  lcd.drawText(1, 1, "SENSORS", INVERS)
  lcd.drawText(127, 1, rows.kind and string.upper(rows.kind) or "NO LINK", INVERS + RIGHT)
  if #rows == 0 then
    lcd.drawText(1, 30, "NO SENSORS FOUND", 0)
    return
  end
  top = top + scrollDir(event)
  local maxTop = math.max(1, #rows - ROWS + 1)
  if top < 1 then top = 1 elseif top > maxTop then top = maxTop end
  for r = 0, ROWS - 1 do
    local row = rows[top + r]
    if not row then break end
    local y = 11 + r * 7
    lcd.drawText(0, y, string.upper(row.key), SMLSIZE)
    lcd.drawText(31, y, string.sub(row.name, 1, 6), SMLSIZE)
    lcd.drawText(124, y, string.sub(row.value, 1, 11), SMLSIZE + RIGHT)
  end
  if maxTop > 1 then
    lcd.drawLine(127, 10, 127, 63, DOTTED, FORCE)
    local h = math.max(4, math.floor(54 * ROWS / #rows))
    lcd.drawFilledRectangle(126, 10 + math.floor((54 - h) * (top - 1) / (maxTop - 1)), 2, h, FORCE)
  end
end

return { draw = draw }
