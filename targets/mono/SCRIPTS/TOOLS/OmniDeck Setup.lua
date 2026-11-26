-- OmniDeck Mono Setup (SYS > Tools): settings for the current model, saved at once to
-- /SCRIPTS/OMNID/<model>.cfg. Wheel / +- moves; ENTER edits (the wheel then changes the value,
-- ENTER keeps it); RTN leaves. EdgeTX stops telemetry scripts while a tool runs and starts them
-- again afterwards, so the changes apply as soon as you leave.

-- EdgeTX on this radio may run without Lua's table library ("attempt to index a nil value (field
-- 'table')", TX12 MK2, EdgeTX 2.12, 2026-11-13). The few calls OmniDeck makes, in plain Lua, only
-- where the library is missing.
if rawget(_G, "table") == nil then
  local T = {}
  function T.insert(t, a, b)
    if b == nil then t[#t + 1] = a return end
    for i = #t, a, -1 do t[i + 1] = t[i] end
    t[a] = b
  end
  function T.remove(t, pos)
    local n = #t
    if n == 0 then return nil end
    pos = pos or n
    local v = t[pos]
    for i = pos, n - 1 do t[i] = t[i + 1] end
    t[n] = nil
    return v
  end
  function T.concat(t, sep, i, j)
    sep, i, j = sep or "", i or 1, j or #t
    local out = ""
    for k = i, j do out = out .. t[k] .. (k < j and sep or "") end
    return out
  end
  function T.sort(t, lt)
    lt = lt or function(a, b) return a < b end
    for i = 2, #t do
      local v, k = t[i], i - 1
      while k >= 1 and lt(v, t[k]) do t[k + 1] = t[k] k = k - 1 end
      t[k + 1] = v
    end
  end
  local function unpack(t, i, j)
    i, j = i or 1, j or #t
    if i > j then return end
    return t[i], unpack(t, i + 1, j)
  end
  T.unpack = unpack
  table = T
end

local C, vals, items = nil, nil, {}
local sel, top, editing, msg = 1, 1, false, ""
local ROWS = 5

local function choicesOf(it)
  if it[3] == "packs" then
    local out = { { "", "OFF" } }
    for _, p in ipairs(C.packs()) do out[#out + 1] = { p, string.upper(p) } end
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
    return string.upper(tostring(v))
  end
  local r = it[3]
  if v == 0 and C.NOTE[it[1]] then return (it[1] == "cells") and "AUTO" or "OFF" end
  if r[5] ~= 1 then return string.format("%.2f%s", v / r[5], r[4]) end
  if r[4] == "ALT" then return tostring(v) .. (vals.altUnit == 1 and "FT" or "M") end
  return tostring(v) .. r[4]
end

local function step(it, d)
  local k = it[1]
  local ch = choicesOf(it)
  if ch then
    local idx = 1
    for i, c in ipairs(ch) do if c[1] == vals[k] then idx = i end end
    vals[k] = ch[(idx - 1 + d) % #ch + 1][1]
  else
    local r = it[3]
    vals[k] = math.max(r[1], math.min(r[2], (vals[k] or 0) + d * r[3]))
  end
  msg = C.write(vals) and "SAVED" or "COULD NOT SAVE"
end

local function init()
  local chunk = loadScript("/SCRIPTS/OMNID/cfg.lua")
  if not chunk then msg = "MISSING /SCRIPTS/OMNID" return end
  C = chunk()
  items = C.ITEMS
  vals = C.read()
end

local function run(event)
  lcd.clear()
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  lcd.drawText(1, 1, "OMNIDECK SETUP", INVERS)
  if not C then
    lcd.drawText(1, 20, msg, 0)
    return (event == EVT_VIRTUAL_EXIT) and 1 or 0
  end
  if event == EVT_VIRTUAL_EXIT then
    if editing then editing = false else return 1 end
  elseif event == EVT_VIRTUAL_ENTER then
    editing = not editing
  elseif event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
    local d = (event == EVT_VIRTUAL_NEXT) and 1 or -1
    if editing then step(items[sel], d) else sel = math.max(1, math.min(#items, sel + d)) end
  end
  if sel < top then top = sel elseif sel >= top + ROWS then top = sel - ROWS + 1 end

  for r = 0, ROWS - 1 do
    local i = top + r
    local it = items[i]
    if not it then break end
    local y = 10 + r * 9
    local v = valueText(it)
    if i == sel and not editing then
      lcd.drawFilledRectangle(0, y - 1, 128, 9, FORCE)
      lcd.drawText(1, y, it[2], INVERS)
      lcd.drawText(127, y, v, INVERS + RIGHT)
    else
      lcd.drawText(1, y, it[2], 0)
      lcd.drawText(127, y, v, RIGHT + ((i == sel) and (INVERS + BLINK) or 0))
    end
  end
  -- bottom line: what the setting means, or what to press
  local note = C.NOTE[items[sel][1]]
  local hint = editing and "WHEEL CHANGE, ENT KEEP" or (note or "ENT EDIT, RTN EXIT")
  lcd.drawLine(0, 55, 127, 55, DOTTED, FORCE)
  lcd.drawText(1, 57, hint, SMLSIZE)
  return 0
end

return { init = init, run = run }
