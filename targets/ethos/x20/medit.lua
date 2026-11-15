-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck mission editor (map page, EDIT): make or change the ArduPilot mission on the radio and
  send it to the aircraft. Only on the TX16S / MK3 (EdgeTX) and the X20 family (Ethos): big touch
  screens. Needs Stratos firmware (MAVlite mission write) and "ArduPilot mission download" On.

  - starts from the downloaded mission, or a new one: a takeoff at home
  - tap the map: a waypoint after the selected item; tap a point: select it
  - tap the left / right of the info line: the previous / next item (also the ones not on the
    map: speed change, land start, RTL)
  - Type: Waypoint, Loiter (unlimited), Loiter turns, Loiter time, Land, RTL, Speed change, Land start, Jump
    (DO_JUMP: target item and repeats, -1 = forever); on a quadplane
    (Q_ENABLE 1) also VTOL land and Transition (to fixed wing / to VTOL), and Type on the first
    item switches Takeoff <-> VTOL takeoff
  - Field: what - / + change (altitude, loiter turns, radius, time, speed)
  - < / >: move the item earlier / later (the takeoff stays first)
  - Del: delete the item; on the takeoff, Del twice starts a new mission
  - Send (disarmed only): params.lua clears the mission, writes every item and downloads it again
    to check it ("Sent and verified")
  A downloaded mission with commands this editor can't keep (servo, camera, VTOL items, ...) is not
  opened for editing: it would lose them.
]]

local ED = {}
local floor = math.floor

-- commands the editor keeps unchanged (everything they use fits the compact item)
local NAME = { [16] = "WAYPOINT", [17] = "LOITER UNLIM", [18] = "LOITER TURNS", [19] = "LOITER TIME", [20] = "RTL",
               [21] = "LAND", [22] = "TAKEOFF", [178] = "SPEED", [189] = "LAND START", [177] = "JUMP",
               [84] = "VTOL TAKEOFF", [85] = "VTOL LAND", [3000] = "TRANSITION" }
local LETTER = { [21] = "L", [22] = "T", [17] = "O", [18] = "O", [19] = "O", [84] = "T", [85] = "L" }
local TYPES = { 16, 17, 18, 19, 21, 20, 178, 189, 177 }   -- what Type steps through
local VTYPES = { 16, 17, 18, 19, 21, 85, 20, 178, 3000, 189, 177 }   -- on a quadplane
local NOPOS = { [20] = true, [178] = true, [189] = true, [3000] = true, [177] = true }   -- no position: not on the map
local function isTakeoff(it) return it and (it.cmd == 22 or it.cmd == 84) end
-- the fields - / + change, per command
local FIELDS = { [16] = { "alt" }, [17] = { "alt", "radius" }, [18] = { "alt", "turns", "radius" }, [19] = { "alt", "time" },
                 [21] = { "alt" }, [22] = { "alt" }, [178] = { "speed" }, [177] = { "target", "repeat" },
                 [84] = { "alt" }, [85] = { "alt" }, [3000] = { "state" } }
-- field: where it lives, step, limits. Loiter time has no radius: ArduPilot stores none for it
-- (AP_Mission: it uses WP_LOITER_RAD)
local SPEC = {
  alt    = { k = "alt", step = 10, lo = 0,  hi = 5000 },
  turns  = { k = "p1",  step = 1,  lo = 1,  hi = 255 },
  radius = { k = "p3",  step = 10, lo = 0,  hi = 2550 },   -- 0 = WP_LOITER_RAD
  time   = { k = "p1",  step = 10, lo = 0,  hi = 3600 },
  speed  = { k = "p2",  step = 1,  lo = 1,  hi = 100, minus1 = true },   -- m/s (airspeed); -1 = no change
  state  = { k = "p1",  step = 1,  lo = 3,  hi = 4 },      -- transition: 3 to VTOL, 4 to fixed wing (- / + toggle)
  target = { k = "p1",  step = 1,  lo = 1,  hi = 99 },     -- DO_JUMP: the item to jump to (its number in the list)
}
SPEC["repeat"] = { k = "p2", step = 1, lo = 0, hi = 100, minus1 = true }   -- DO_JUMP repeats; -1 = forever
local MAX_ITEMS = 60
local DEFAULT_ALT, TAKEOFF_ALT, DEFAULT_SPEED = 100, 50, 18

local MAP, PR, COL = nil, nil, nil
local draft, sel, field = nil, 0, 1
local status, statusCol = "", nil
local clearAt = nil          -- Del on the takeoff: a second Del within 4 s starts a new mission
local showSend = false       -- the send status shows only for a Send since the last change
local boxes = {}

ED.active = false

function ED.init(map, params, col)
  MAP, PR, COL = map, params, col
end

local function hasPos(it) return not NOPOS[it.cmd] end
local function onMap(it) return hasPos(it) and (it.lat ~= 0 or it.lon ~= 0) end

local function selectItem(i)
  if not draft or #draft == 0 then sel = 0 return end
  sel = math.max(1, math.min(#draft, i))
  field = 1
end

-- open: from the downloaded mission, or a new one (true), or not (false, why)
function ED.start(s, fresh)
  local items = not fresh and PR.missionItems() or nil
  draft = {}
  if items and #items > 0 then
    for _, it in ipairs(items) do
      if not NAME[it.cmd] then
        draft = nil
        return false, "Mission has commands the editor can't keep (" .. it.cmd .. ")"
      end
      draft[#draft + 1] = { cmd = it.cmd, frame = it.frame, lat = it.lat, lon = it.lon, alt = it.alt,
                            p1 = it.p1, p2 = it.p2 or 0, p3 = it.p3 }
    end
  else
    -- a quadplane starts with a VTOL takeoff
    local hl, ho = s.homeLat or s.lat or 0, s.homeLon or s.lon or 0
    draft[1] = { cmd = PR.isQuadplane() and 84 or 22, frame = 3, lat = hl, lon = ho, alt = TAKEOFF_ALT, p1 = 0, p2 = 0, p3 = 0 }
  end
  PR.requestQ()   -- quadplane? (the VTOL items), read once
  selectItem(#draft)
  clearAt, showSend = nil, false
  status, statusCol = (items and #items > 0) and "Editing the downloaded mission" or "New mission", "dim"
  ED.active = true
  return true
end

function ED.stop() ED.active, draft = false, nil end


-- the last real waypoint's altitude before i: not the takeoff's, not a landing's (0 m)
local function lastAlt(i)
  for k = i, 1, -1 do
    local it = draft[k]
    if it and onMap(it) and not isTakeoff(it) and it.cmd ~= 21 and (it.alt or 0) > 0 then return it.alt end
  end
  return DEFAULT_ALT
end
-- the position of the nearest item on the map before i (for an item that gets a position again)
local function lastPos(i)
  for k = i, 1, -1 do
    local it = draft[k]
    if it and onMap(it) then return it.lat, it.lon end
  end
  return draft[1] and draft[1].lat or 0, draft[1] and draft[1].lon or 0
end
-- where the map centres while editing: the selected item, or for one without a position (speed,
-- jump, RTL, ...) the nearest item before it that has one; nil = the map's usual centre
function ED.focus()
  if not draft or not draft[sel] then return nil end
  local it = draft[sel]
  if onMap(it) then return { it.lat, it.lon } end
  local la, lo = lastPos(sel)
  if la and (la ~= 0 or lo ~= 0) then return { la, lo } end
  return nil
end


local function addAt(lat, lon)
  if #draft >= MAX_ITEMS then status, statusCol = "At most " .. MAX_ITEMS .. " items", "warn" return end
  local i = (sel > 0 and sel or #draft) + 1
  table.insert(draft, i, { cmd = 16, frame = 3, lat = lat, lon = lon, alt = lastAlt(i - 1), p1 = 0, p2 = 0, p3 = 0 })
  selectItem(i)
  status, showSend = "", false
end

local function nearest(px, py, r)
  local best, bd = nil, r * r
  for i, it in ipairs(draft) do
    if onMap(it) then
      local x, y = MAP.toScreen(it.lat, it.lon)
      local d = (x - px) * (x - px) + (y - py) * (y - py)
      if d <= bd then best, bd = i, d end
    end
  end
  return best
end

local function cycleType()
  local it = draft[sel]
  if not it then return end
  local quad = PR.isQuadplane()
  if isTakeoff(it) then
    -- the first item: Takeoff <-> VTOL takeoff on a quadplane
    if quad then it.cmd = it.cmd == 22 and 84 or 22 status, showSend = "", false return end
    status, statusCol = quad == nil and "Checking for a quadplane..." or "Takeoff keeps its type", "warn"
    return
  end
  local list = quad and VTYPES or TYPES
  local k = 1
  for i, c in ipairs(list) do if c == it.cmd then k = i % #list + 1 end end
  local was = it.cmd
  it.cmd = list[k]
  it.p1, it.p2, it.p3 = 0, 0, 0
  if it.cmd == 18 then it.p1 = 3                              -- 3 turns, radius 0 = WP_LOITER_RAD
  elseif it.cmd == 19 then it.p1 = 30                         -- 30 s
  elseif it.cmd == 178 then it.p2, it.p3 = DEFAULT_SPEED, -1  -- airspeed, throttle unchanged
  elseif it.cmd == 21 then it.alt = 0
  elseif it.cmd == 3000 then it.p1 = 4                       -- transition to fixed wing
  elseif it.cmd == 177 then it.p1, it.p2 = math.min(2, sel), 1 end   -- jump to item 2 (after the takeoff), once
  it.frame = NOPOS[it.cmd] and 2 or 3
  if NOPOS[was] and hasPos(it) and not onMap(it) then
    it.lat, it.lon = lastPos(sel - 1)
    if it.cmd ~= 21 then it.alt = lastAlt(sel - 1) end
  end
  field = 1
  status, showSend = "", false
end

local function nextField()
  local f = draft[sel] and FIELDS[draft[sel].cmd]
  if not f or #f < 2 then return end
  field = field % #f + 1
end

local function changeField(dir, half)
  local it = draft[sel]
  local f = it and FIELDS[it.cmd]
  if not f then return end
  local name = f[field] or f[1]
  local sp = SPEC[name]
  if name == "state" then it.p1 = it.p1 == 4 and 3 or 4 status, showSend = "", false return end   -- to FW <-> to VTOL
  local step = half and math.max(1, sp.step / 2) or sp.step
  local cur = it[sp.k] or 0
  local hi = name == "target" and #draft or sp.hi   -- a jump goes to an item that exists
  if sp.minus1 and (cur < 0 or (dir < 0 and cur <= sp.lo)) then
    -- -1 is a setting of its own (speed: no change; jump: forever): one step below the lowest
    -- value, and one step up from -1 is the lowest value again
    it[sp.k] = (dir < 0) and -1 or sp.lo
  else
    local v = math.abs(cur) + dir * step
    it[sp.k] = math.max(sp.lo, math.min(hi, v))
  end
  status, showSend = "", false
end

local function move(dir)
  local i = sel
  local j = i + dir
  if not draft[i] or not draft[j] then return end
  if isTakeoff(draft[i]) or isTakeoff(draft[j]) then status, statusCol = "The takeoff stays first", "warn" return end
  draft[i], draft[j] = draft[j], draft[i]
  sel = j
  status, showSend = "", false
end

local function delete(s)
  local it = draft[sel]
  if not it then return end
  if isTakeoff(it) then
    if clearAt and os.clock() - clearAt < 4 then
      ED.start(s, true)
      return
    end
    clearAt = os.clock()
    status, statusCol = "Del again: new mission", "warn"
    return
  end
  table.remove(draft, sel)
  -- the item before it stays selected: a tap on the map then puts a new point back in the same place
  selectItem(math.max(1, sel - 1))
  status, showSend = "", false
end

local function sendIt(s)
  if s.armed then status, statusCol = "Disarm to send", "bad" return end
  if #draft == 0 then status, statusCol = "Nothing to send", "warn" return end
  local out = {}
  for _, it in ipairs(draft) do
    local pos = hasPos(it)
    out[#out + 1] = { cmd = it.cmd, frame = it.frame or (pos and 3 or 2), lat = pos and it.lat or 0, lon = pos and it.lon or 0,
                      alt = pos and it.alt or 0, p1 = it.p1 or 0, p2 = it.p2 or 0, p3 = it.p3 or 0 }
  end
  PR.missionSend(out)
  status, showSend = "", true
end

-- ---------------------------------------------------------------- drawing
local function button(x, y, w, h, label, col)
  lcd.color(COL.tile)
  lcd.drawFilledRectangle(x, y, w, h)
  lcd.color(col)
  lcd.drawRectangle(x, y, w, h)
  local tw, th = lcd.getTextSize(label)
  lcd.drawText(x + floor((w - tw) / 2), y + floor((h - th) / 2), label)
  boxes[#boxes + 1] = { k = label, x = x, y = y, w = w, h = h }
end

local function fieldText(it, name, u)
  local sp = SPEC[name]
  if name == "repeat" then local r = it.p2 or 0 return r < 0 and "REPEAT FOREVER" or ("REPEAT " .. floor(r + 0.5)) end
  local v = math.abs(it[sp.k] or 0)
  if name == "alt" then return "ALT " .. floor(u.alt(v) + 0.5) .. u.altLbl end
  if name == "turns" then return "TURNS " .. floor(v + 0.5) end
  if name == "radius" then return v == 0 and "RAD default" or ("RAD " .. floor(v + 0.5) .. "m") end
  if name == "time" then return "TIME " .. floor(v + 0.5) .. "s" end
  if name == "speed" then return (it.p2 or 0) < 0 and "SPD no change" or ("SPD " .. floor(u.spd(v) + 0.5) .. u.spdLbl) end
  if name == "state" then return v == 3 and "TO VTOL" or "TO FW" end
  if name == "target" then return "TO #" .. floor(v + 0.5) end
  return ""
end

-- over the map page: the draft on the map, an info line at the top, the buttons at the bottom
function ED.paint(W, H, barH, s, u, fMid, fSmall)
  boxes = {}
  if not draft then return end
  local v = MAP.view
  -- route and points (items without a position are skipped)
  if v.ok then
    local px, py
    lcd.color(COL.warn)
    -- the route stays inside the map: a leg to a point off the map would cross the top bar
    -- (X20S 2026-11-15); the map page clips the same way
    lcd.setClipping(floor(v.x), floor(v.y), floor(v.w), floor(v.h))
    for _, it in ipairs(draft) do
      if onMap(it) then
        local x, y = MAP.toScreen(it.lat, it.lon)
        if px then lcd.drawLine(floor(px), floor(py), floor(x), floor(y)) end
        px, py = x, y
      end
    end
    lcd.setClipping(0, 0, W, H)
    lcd.font(fSmall)
    local r = H >= 400 and 7 or 5
    for i, it in ipairs(draft) do
      if onMap(it) then
        local x, y = MAP.toScreen(it.lat, it.lon)
        if x > v.x and x < v.x + v.w and y > v.y and y < v.y + v.h then
          lcd.color(i == sel and COL.ok or COL.warn)
          lcd.drawFilledRectangle(floor(x - r), floor(y - r), 2 * r, 2 * r)
          if i == sel then lcd.color(COL.txt) lcd.drawRectangle(floor(x - r - 2), floor(y - r - 2), 2 * r + 4, 2 * r + 4) end
          lcd.color(COL.txt)
          lcd.drawText(floor(x + r + 2), floor(y - r), (LETTER[it.cmd] or "") .. i)
        end
      end
    end
  end
  -- info line under the top bar: < item, type, fields (the one - / + change in brackets) >
  lcd.font(fMid)
  local _, th = lcd.getTextSize("0")
  local iy = barH
  lcd.color(COL.panel)
  lcd.drawFilledRectangle(0, iy, W, th + 4)
  local it = draft[sel]
  local info = #draft .. " items"
  if it then
    info = string.format("%d/%d %s", sel, #draft, NAME[it.cmd] or tostring(it.cmd))
    local f = FIELDS[it.cmd]
    if f then
      for k, name in ipairs(f) do
        local t = fieldText(it, name, u)
        info = info .. "  " .. (k == field and ("[" .. t .. "]") or t)
      end
    end
  end
  -- status: the send's, else the editor's own
  local snd = PR.sendState
  local msg, mc = status, statusCol
  if showSend and snd.state ~= "off" and snd.msg ~= "" and status == "" then
    msg = snd.msg
    mc = (snd.state == "done" and "ok") or (snd.state == "failed" and "bad") or "warn"
    if snd.state == "write" then msg = string.format("Sending %d/%d", snd.i, #snd.items) end
  end
  local aw = lcd.getTextSize("<")
  local mw = msg ~= "" and lcd.getTextSize(msg) or 0
  if lcd.getTextSize(info) + mw + 2 * aw + 24 > W then lcd.font(fSmall) end   -- long lines in the small font
  lcd.color(COL.home)
  lcd.drawText(4, iy + 2, "<")
  lcd.drawText(W - 4, iy + 2, ">", RIGHT)
  lcd.color(COL.txt)
  lcd.drawText(aw + 10, iy + 2, info)
  if msg ~= "" then
    lcd.color(mc == "ok" and COL.ok or mc == "bad" and COL.bad or mc == "warn" and COL.warn or COL.dim)
    lcd.drawText(W - aw - 10, iy + 2, msg, RIGHT)
  end
  ED.infoY, ED.infoH = iy, th + 4
  -- buttons
  lcd.font(fMid)
  -- tall buttons: about 38 px on a TX16S, 67 px on an X20 (easier to hit than the text height)
  local bh = math.max(th + 10, floor(H * 0.14))
  local by = H - bh - 2
  lcd.color(COL.bar)
  lcd.drawFilledRectangle(0, by - 2, W, bh + 4)
  local labels = { "Type", "Field", "-", "+", "<", ">", "Del", "Send", "Done" }
  local n, gap = #labels, 3
  local bw = floor((W - 6 - gap * (n - 1)) / n)
  ED.barY, ED.barN, ED.barW = by - 2, n, (bw + gap)
  for i, l in ipairs(labels) do
    button(3 + (i - 1) * (bw + gap), by, bw, bh, l, (l == "Send" and COL.ok) or (l == "Done" and COL.home) or COL.dim)
  end
  ED.top, ED.bottom = iy + th + 4, by - 2
end

-- ---------------------------------------------------------------- input
-- is (x, y) on one of the editor's buttons or the info line? (they win over the map's zoom buttons)
function ED.onButton(x, y)
  if ED.infoY and y >= ED.infoY and y <= ED.infoY + ED.infoH then return true end
  if ED.barY and y >= ED.barY then return true end
  for i = #boxes, 1, -1 do
    local b = boxes[i]
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then return true end
  end
  return false
end

-- a tap on the map page while editing; "exit" when Done
function ED.tap(s, x, y, W)
  if not draft then return true end
  if ED.infoY and y >= ED.infoY and y <= ED.infoY + ED.infoH then
    -- left third: the previous item, right third: the next one
    if x < W / 3 then selectItem(sel - 1) elseif x > W * 2 / 3 then selectItem(sel + 1) end
    status = ""
    return true
  end
  -- the button bar: anywhere in it counts, by column (the gaps and edges too)
  if ED.barY and y >= ED.barY and #boxes > 0 then
    local col = math.max(1, math.min(ED.barN, floor((x - 3) / ED.barW) + 1))
    x, y = boxes[col].x + 1, boxes[col].y + 1
  end
  for i = #boxes, 1, -1 do
    local b = boxes[i]
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
      local k = b.k
      if k ~= "Del" then clearAt = nil end
      if k == "Type" then cycleType()
      elseif k == "Field" then nextField()
      elseif k == "-" then changeField(-1)
      elseif k == "+" then changeField(1)
      elseif k == "<" then move(-1)
      elseif k == ">" then move(1)
      elseif k == "Del" then delete(s)
      elseif k == "Send" then sendIt(s)
      elseif k == "Done" then ED.stop() return "exit" end
      return true
    end
  end
  if not MAP.view.ok then return true end
  if y < (ED.top or 0) or y > (ED.bottom or 1e9) then return true end
  clearAt = nil
  local r = W >= 700 and 30 or 18
  local i = nearest(x, y, r)
  if i then selectItem(i) status = "" return true end
  local la, lo = MAP.toLatLon(x, y)
  addAt(la, lo)
  return true
end

-- keys while editing: the wheel changes the selected field (half steps), ENTER selects the next
-- item, RTN leaves
function ED.key(s, k)
  if not draft then return true end
  if k == "left" then changeField(-1, true)
  elseif k == "right" then changeField(1, true)
  elseif k == "enter" then selectItem(sel % #draft + 1)
  elseif k == "back" then ED.stop() return "exit" end
  return true
end

-- test harness
function ED._draft() return draft, sel, field end
function ED._boxes() return boxes end

return ED
