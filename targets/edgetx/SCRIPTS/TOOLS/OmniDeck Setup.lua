-- OmniDeck Setup: the widget's settings for the current model, by name instead of the widget
-- options' bare numbers. Wheel / +- to move, ENTER to change (wheel then picks the value,
-- ENTER again to keep it), or tap a row to select it and tap it again for the next value.
-- Saved to /WIDGETS/OmniDeck/<model>.cfg at once; the widget picks it up when its screen
-- is shown again. RTN leaves.

local CFG = nil
local vals, items, sel, editing, top, msg = nil, {}, 1, false, 1, ""
-- row height, list top and footer height: 22 / 30 / 20 at 480x272, else from the fonts' own line
-- height (800x480, TX16S MK3: the standard line is 27 px and the rows ran into each other)
local ROW_H, TOP_Y, FOOT_H, TXT_DY = 22, 30, 20, 2
local function measure()
  if not lcd.sizeText then return end
  local function lh(f) local ok, _, h = pcall(lcd.sizeText, "Ag", f) return ok and h or 0 end
  ROW_H = math.max(22, lh(0) + 1, math.floor(LCD_H / 14))   -- 34 px on 800x480: a finger-sized row
  if ROW_H > 22 then TXT_DY = math.floor((ROW_H - 1 - lh(0)) / 2) end   -- the text in the row's middle
  TOP_Y = math.max(30, lh(MIDSIZE) + 1)
  FOOT_H = math.max(20, lh(SMLSIZE) + 1)
end

-- the tile sets on the card, found by the widget's own scanner (tiles.lua, via etx.lua), once
local tileLabels = nil
local function tileSets()
  if tileLabels then return tileLabels end
  tileLabels = {}
  pcall(function()
    local E = loadScript("/WIDGETS/OmniDeck/etx.lua", "bt")()
    local TL = E.loadfile("tiles.lua")()
    for _, ts in ipairs(TL.scan()) do tileLabels[#tileLabels + 1] = ts.label end
  end)
  return tileLabels
end

local function choicesOf(it)
  if it[3] == "packs" then
    local out = { { "", "Off" } }
    for _, p in ipairs(CFG.packs()) do out[#out + 1] = { p, p } end
    return out
  end
  if it[3] == "tilesets" then
    local out = { { "*", "Auto (first found)" }, { "", "Off" } }
    for _, label in ipairs(tileSets()) do out[#out + 1] = { label, label } end
    return out
  end
  if it[3] == "pots" then
    local out = { { "", "Off" } }
    for _, n in ipairs(CFG.pots()) do out[#out + 1] = { n, string.upper(n) } end
    return out
  end
  if it[3] == "switches" then
    local out = { { "", "Off" } }
    for _, n in ipairs(CFG.switches()) do out[#out + 1] = { n, string.upper(n) } end
    return out
  end
  if type(it[3][1]) == "table" then return it[3] end
  return nil
end

local function valueText(it)
  local v = vals[it[1]]
  local ch = choicesOf(it)
  if ch then
    for _, c in ipairs(ch) do if c[1] == v then return c[2] end end
    return tostring(v)
  end
  local r = it[3]
  if v == 0 and (it[1] == "lowVolt" or it[1] == "critVolt" or it[1] == "lowAlt") then return "Off" end
  if r[5] and r[5] ~= 1 then return string.format("%.2f %s", v / r[5], r[4]) end
  return tostring(v) .. (r[4] ~= "" and (" " .. r[4]) or "")
end

local function step(it, d)
  local k = it[1]
  local ch = choicesOf(it)
  if ch then
    local idx = 1
    for i, c in ipairs(ch) do if c[1] == vals[k] then idx = i end end
    idx = (idx - 1 + d) % #ch + 1
    vals[k] = ch[idx][1]
  else
    local r = it[3]
    vals[k] = math.max(r[1], math.min(r[2], (vals[k] or 0) + d * r[3]))
  end
  msg = CFG.write(vals) and "saved" or "COULD NOT SAVE"
end

local function init()
  local chunk, err = loadScript("/WIDGETS/OmniDeck/cfg.lua")
  if not chunk then msg = "missing /WIDGETS/OmniDeck/cfg.lua: " .. tostring(err) return end
  CFG = chunk()
  items = CFG.ITEMS
  vals = CFG.read()
  measure()
end

local function run(event, touch)
  lcd.clear()
  if not CFG then
    lcd.drawText(6, 6, "OmniDeck Setup", MIDSIZE)
    lcd.drawText(6, 40, msg, SMLSIZE)
    return (event == EVT_VIRTUAL_EXIT) and 1 or 0
  end
  local rows = math.floor((LCD_H - TOP_Y - FOOT_H) / ROW_H)
  if event == EVT_VIRTUAL_EXIT then
    if editing then editing = false else return 1 end
  elseif event == EVT_VIRTUAL_ENTER then
    editing = not editing
  elseif event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
    local d = (event == EVT_VIRTUAL_NEXT) and 1 or -1
    if editing then step(items[sel], d) else sel = math.max(1, math.min(#items, sel + d)) end
  elseif touch and EVT_TOUCH_TAP and event == EVT_TOUCH_TAP then
    local i = top + math.floor((touch.y - TOP_Y) / ROW_H)
    if touch.y >= TOP_Y and i >= 1 and i <= #items then
      if i == sel then step(items[i], 1) else sel = i end
      editing = false
    end
  end
  if sel < top then top = sel elseif sel >= top + rows then top = sel - rows + 1 end

  -- own colours (theme constants differ between EdgeTX versions)
  local function col(r, g, b) lcd.setColor(CUSTOM_COLOR, lcd.RGB(r, g, b)) end
  col(16, 16, 16)
  lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, CUSTOM_COLOR)
  local okI, info = pcall(function() return model.getInfo() end)
  col(240, 240, 240)
  lcd.drawText(6, 4, "OmniDeck Setup", MIDSIZE + CUSTOM_COLOR)
  col(150, 150, 150)
  lcd.drawText(LCD_W - 6, math.max(4, TOP_Y - FOOT_H - 2), "model: " .. tostring((okI and info and info.name) or "?"), SMLSIZE + RIGHT + CUSTOM_COLOR)
  for r = 0, rows - 1 do
    local i = top + r
    local it = items[i]
    if not it then break end
    local y = TOP_Y + r * ROW_H
    if i == sel then
      if editing then col(200, 120, 20) else col(30, 90, 170) end
      lcd.drawFilledRectangle(0, y - 1, LCD_W, ROW_H, CUSTOM_COLOR)
    end
    col(240, 240, 240)
    lcd.drawText(8, y + TXT_DY, it[2], CUSTOM_COLOR)
    if i ~= sel then col(120, 220, 120) end
    lcd.drawText(LCD_W - 8, y + TXT_DY, valueText(it), RIGHT + CUSTOM_COLOR)
  end
  col(150, 150, 150)
  lcd.drawText(6, LCD_H - FOOT_H + 2, (editing and "wheel: change  ENTER: keep" or "ENTER: change  tap: next value  RTN: exit") ..
    (msg ~= "" and ("   " .. msg) or ""), SMLSIZE + CUSTOM_COLOR)
  return 0
end

return { init = init, run = run }
