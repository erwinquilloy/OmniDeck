--[[
  OmniDeck Mono, messages page (128x64): the flight controller's status texts, newest at the
  bottom, long ones wrapped to 21 characters a line, warnings and errors marked "!".
  Only in the page cycle for ArduPilot (INAV and Betaflight send no status texts this way).
  The wheel (or the +/- keys) scrolls back; the view stays put while new messages arrive,
  and returns to the newest when scrolled to the bottom again.
]]

local W = (LCD_W or 128) >= 200 and 212 or 128   -- 212x64: Taranis X9D / X9D+ / X9E
local R = W - 1
local ROWS, COLS = 6, W == 212 and 34 or 21   -- characters a line (6 px each, the scroll bar at the right)

local scroll = 0       -- lines above the newest
local seenTotal = nil  -- s.msgTotal when last drawn, to hold a scrolled view in place

-- one message to display lines; the first line carries the mark
local function wrap(m, out)
  local text = ((m.sev or 6) <= 4 and "! " or "") .. m.text
  while #text > COLS do
    local cut = COLS
    local sp = string.find(string.sub(text, 1, COLS + 1), " [^ ]*$")
    if sp and sp > 8 then cut = sp - 1 end
    out[#out + 1] = string.sub(text, 1, cut)
    text = "  " .. string.gsub(string.sub(text, cut + 1), "^ +", "")
  end
  out[#out + 1] = text
end

local function draw(ctx, event)
  local s = ctx.T.s
  local msgs = s.msgs or {}
  lcd.drawFilledRectangle(0, 0, W, 9, FORCE)
  lcd.drawText(1, 1, "MESSAGES", INVERS)
  lcd.drawText(R, 1, tostring(#msgs), INVERS + RIGHT)
  if #msgs == 0 then
    lcd.drawText(1, 30, "NO MESSAGES YET", 0)
    return
  end
  local lines = {}
  for i = 1, #msgs do wrap(msgs[i], lines) end

  -- a scrolled view keeps its place when new lines arrive below it
  local total = s.msgTotal or #msgs
  if scroll > 0 and seenTotal and total > seenTotal then
    local added = {}
    for i = #msgs - (total - seenTotal) + 1, #msgs do if i >= 1 then wrap(msgs[i], added) end end
    scroll = scroll + #added
  end
  seenTotal = total

  local maxScroll = math.max(0, #lines - ROWS)
  -- wheel up / minus: back to older lines; wheel down / plus: towards the newest
  local e = (event ~= 0) and event or -1   -- a key constant this radio lacks is nil: never matches
  if e == EVT_VIRTUAL_PREV or e == EVT_VIRTUAL_DEC or e == EVT_ROT_LEFT or e == EVT_MINUS_FIRST
     or e == EVT_MINUS_REPT then scroll = scroll + 1
  elseif e == EVT_VIRTUAL_NEXT or e == EVT_VIRTUAL_INC or e == EVT_ROT_RIGHT or e == EVT_PLUS_FIRST
     or e == EVT_PLUS_REPT then scroll = scroll - 1 end
  if scroll < 0 then scroll = 0 elseif scroll > maxScroll then scroll = maxScroll end

  local first = #lines - ROWS + 1 - scroll
  for r = 0, ROWS - 1 do
    local i = first + r
    if i >= 1 and lines[i] then lcd.drawText(0, 10 + r * 9, lines[i], 0) end
  end

  -- scroll bar
  if maxScroll > 0 then
    lcd.drawLine(R, 10, R, 63, DOTTED, FORCE)
    local h = math.max(4, math.floor(54 * ROWS / #lines))
    local y = 10 + math.floor((54 - h) * (maxScroll - scroll) / maxScroll)
    lcd.drawFilledRectangle(R - 1, y, 2, h, FORCE)
  end
end

return { draw = draw }
