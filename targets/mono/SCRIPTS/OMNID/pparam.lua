--[[
  OmniDeck Mono, PARAMS page (128x64): read and change ArduPlane parameters (pplist.lua) from
  the radio, one tab at a time. In the page cycle with Setup PARAMS PAGE = SHOW, ArduPilot only.

  Links (CRSF only; S.Port / F.Port are not done on Mono):
    ELRS / Crossfire   ArduPlane Stratos v2.2.1 or later (MAVlite over CRSF). Request: CRSF frame
                       0x80 C8 EA F4 len msgid payload; answer 0x80 F4 len msgid payload, handed
                       over by telem.lua (T.onMavlite). Other firmware does not answer.
    mLRS               Tx Ser Port = cbridge, any ArduPilot: real MAVLink v2 in CRSF frames 0xAA
                       (chunk byte, size, up to 58 bytes) both ways; etx.lua keeps them while this
                       page is loaded (E.envOn). The mLRS module sends nothing over the bridge until
                       the radio has sent something, so a GCS HEARTBEAT goes out every 2 s (ELRS and
                       Crossfire ignore the frame type).
  PARAM_REQUEST_READ 20 / PARAM_SET 23 -> PARAM_VALUE 22 (float32 value, name). Over MAVlite a name
  the FC doesn't have gets only the text "Param read failed (NAME)"; over MAVLink nothing (n/a after
  the tries).

  The colour OmniDeck's rules: the VTOL tabs only with Q_ENABLE 1; only the open tab is read; one
  request at a time; a save is sent once and is "SAVED" only when the value read back is the same
  four bytes; view only while armed, except the PID tabs and the trim rows with Setup AIR EDITS =
  GAINS+TRIM.

  Keys: wheel or +/- moves (in the editor: changes the value), ENTER opens a tab / a row / saves,
  RTN goes back (from the tab list: next page), long ENTER turns the page from anywhere but the
  editor. Nothing of this page stays in memory once another page is shown (close()).
]]

local floor = math.floor
local ROOT = "/SCRIPTS/OMNID/"
local GROUPS = { "FLIGHT", "LAUNCH", "RETURN", "FAILSAFE", "ARMING", "TECS", "LANDING", "PID", "VTOL", "Q PID" }
local QG = { VTOL = true, ["Q PID"] = true }
local AIR = { PID = true, ["Q PID"] = true }
local REQ_READ, PARAM_VALUE, PARAM_SET = 20, 22, 23

local ctx, T, E

-- ---------------------------------------------------------------- float32 <-> bytes
-- byte by byte, so every step stays below 2^24 (exact where Lua numbers are 32-bit floats)
local LN2 = math.log(2)
local function f2b(x)
  if x ~= x or x == 0 then return { 0, 0, 0, 0 } end
  local sign = 0
  if x < 0 then sign, x = 1, -x end
  local e = floor(math.log(x) / LN2)
  local m = x / 2 ^ e
  if m >= 2 then m, e = m / 2, e + 1 elseif m < 1 then m, e = m * 2, e - 1 end
  if e < -126 then return { 0, 0, 0, sign * 128 } end
  if e > 127 then e, m = 127, 2 - 2 ^ -23 end
  local frac = floor((m - 1) * 8388608 + 0.5)
  if frac >= 8388608 then frac, e = 0, e + 1 end
  local be = e + 127
  return { frac % 256, floor(frac / 256) % 256, (be % 2) * 128 + floor(frac / 65536), sign * 128 + floor(be / 2) }
end
local function b2f(b0, b1, b2, b3)
  local sign = b3 >= 128 and -1 or 1
  local be = (b3 % 128) * 2 + floor(b2 / 128)
  local frac = (b2 % 128) * 65536 + b1 * 256 + b0
  if be == 0 then return sign * frac * 2 ^ -149 end
  if be == 255 then return 0 end
  return sign * (1 + frac / 8388608) * 2 ^ (be - 127)
end

local out = {}   -- frames waiting to go: { cmd, data }; pmav.lua fills it too, so never replaced
local function clearOut() for i = #out, 1, -1 do out[i] = nil end end
local mav = nil  -- pmav.lua (MAVLink v2), loaded only while the mLRS bridge is on
-- GCS HEARTBEAT (255/25, type GCS, autopilot invalid) as one bridge frame, worked out beforehand
-- (tools/sim_mono.py checks it): it wakes the mLRS bridge, so it goes out on every CRSF link
local HB = { 0, 21, 253, 9, 0, 0, 0, 255, 25, 0, 0, 0, 0, 0, 0, 0, 6, 8, 0, 0, 3, 186, 120 }

local link = nil   -- "CRSF" (MAVlite, Stratos) / "MAVLINK" (mLRS cbridge)
local function send(msgid, name, vb)
  if link == "MAVLINK" then
    if msgid == REQ_READ then mav.read(name) else mav.set(name, vb) end
    return
  end
  -- MAVlite over CRSF: the whole message in one frame addressed to the flight controller
  local d = { 0xC8, 0xEA, 0xF4, 0, msgid }
  if vb then d[6], d[7], d[8], d[9] = vb[1], vb[2], vb[3], vb[4] end
  for k = 1, math.min(16, #name) do d[#d + 1] = string.byte(name, k) end
  d[4] = #d - 5
  out[#out + 1] = { 0x80, d }
end

-- ---------------------------------------------------------------- values
local vals, vbs, txt = {}, {}, {}   -- name -> value (false: n/a), its 4 bytes as a string, shown text
local qOn = nil                     -- Q_ENABLE: nil not read yet, true / false
local GV = {}                       -- tabs shown
local function buildTabs()
  GV = {}
  for _, g in ipairs(GROUPS) do if not QG[g] or qOn == true then GV[#GV + 1] = g end end
end
buildTabs()

local tab, rows, rowsBy = nil, nil, {}   -- open tab, its rows (pplist.lua), name -> row
local view = "tabs"                      -- "tabs", "rows", "edit"
local tabSel, sel, top = 1, 1, 1
local edit, draft, base, phase = nil, nil, nil, ""
local bitCur = 1
local pend, saveReq = nil, nil   -- request waiting for its answer { name, set|check = bytes, tries, at }
local answered, silent, quietAt = false, 0, nil
local hbAt, prefAt = -10, {}

-- ARMING_SKIPCHK (Plane bits, AP_Arming.cpp): a set bit = that check is skipped
local BITS = { { 1, "BAROMETER" }, { 2, "COMPASS" }, { 3, "GPS LOCK" }, { 4, "INS" }, { 5, "PARAMETERS" },
  { 6, "RC CHANNELS" }, { 7, "BOARD VOLTAGE" }, { 8, "BATTERY LEVEL" }, { 9, "AIRSPEED" }, { 10, "LOGGING" },
  { 11, "SAFETY SWITCH" }, { 12, "GPS CONFIG" }, { 13, "SYSTEM" }, { 14, "MISSION" }, { 15, "RANGEFINDER" },
  { 16, "CAMERA" }, { 17, "AUXAUTH" }, { 19, "FFT" } }
local ALL_MASK = 0
for _, b in ipairs(BITS) do ALL_MASK = ALL_MASK + 2 ^ b[1] end
local function skipped(v, bit) return v == -1 or (v >= 0 and floor(v / 2 ^ bit) % 2 == 1) end
local function skipCount(v)
  local n = 0
  for _, b in ipairs(BITS) do if skipped(v, b[1]) then n = n + 1 end end
  return n
end

local function fmt(r, v)
  if v == nil then return "..." end
  if v == false then return "N/A" end
  if r[9] == "bits" then
    if v == 0 then return "ALL ON" end
    if v == -1 then return "ALL SKIP" end
    return skipCount(v) .. " SKIP"
  end
  if r[8] then
    local i, k = floor(v + 0.5), 0
    for o in string.gmatch(r[8], "[^|]+") do
      if k == i then return o end
      k = k + 1
    end
    return tostring(i)
  end
  local t = string.format("%." .. r[7] .. "f", v)
  if r[3] ~= "" then t = t .. (#t + #r[3] < 10 and " " or "") .. r[3] end
  return t
end

local function setVal(name, v, bytes)
  vals[name], vbs[name] = v, bytes
  local r = rowsBy[name]
  txt[name] = r and fmt(r, v) or nil
  if name == "Q_ENABLE" then
    qOn = v ~= false and v >= 1
    buildTabs()
    if tabSel > #GV then tabSel = #GV end
  end
end

-- a PARAM_VALUE (or another answer): 4 value bytes, then the name
local function handle(id, b)
  answered, silent, quietAt = true, 0, nil
  if id ~= PARAM_VALUE or #b < 5 then return end
  local name = string.char((table.unpack or unpack)(b, 5, math.min(#b, 20)))
  if name ~= "Q_ENABLE" and not rowsBy[name] then return end   -- another tab, or a GCS's request
  local bytes = string.char(b[1], b[2], b[3], b[4])
  local v = b2f(b[1], b[2], b[3], b[4])
  setVal(name, v, bytes)
  if pend and pend.name == name then
    local want = pend.set or pend.check
    if want then
      if want == bytes then phase = "SAVED AND VERIFIED" else phase = "NOT SAVED: FC HAS " .. fmt(rowsBy[name], v) end
      if edit and edit[1] == name then base = v end
    elseif edit and edit[1] == name and draft == base then
      draft, base = v, v       -- a fresh read while the value is not being changed
    end
    pend = nil
  end
end

-- MAVlite answer over CRSF (telem.lua): F4, len, msgid, payload
local function onMavlite(data)
  if link ~= "CRSF" or not data then return end
  local n = data[2] or 0
  if #data < 3 + n then return end
  local b = {}
  for i = 1, n do b[i] = data[3 + i] end
  handle(data[3], b)
end

-- ---------------------------------------------------------------- requests
local function readReq(name)
  pend = { name = name, tries = 0 }
  send(REQ_READ, name)
end
local function setNA(name)
  setVal(name, false, nil)
end

-- why the page can't work now (nil = it can): up to four lines of 21 characters
local function blocked(s)
  if s.fc ~= "ArduPilot" then return { "NEEDS ARDUPILOT" } end
  if s.link ~= "CRSF" then return { "NEEDS ELRS, CROSSFIRE", "OR MLRS (CRSF LINK)", "S.PORT: NOT ON MONO" } end
  if T.alive() == false then return { "NO TELEMETRY" } end
  if quietAt then
    if link == "MAVLINK" then return { "NO ANSWER", "MLRS BRIDGE ON, NO", "PARAMETER ANSWERS YET" } end
    return { "NO ANSWER", "ELRS/TBS: NEEDS", "STRATOS V2.2.1 FW", "MLRS: TX SER=CBRIDGE" }
  end
  return nil
end

local function failedText(s, name)
  local m = s.msgs
  if not m then return false end
  for i = #m, math.max(1, #m - 4), -1 do
    if string.find(m[i].text, "failed (" .. name .. ")", 1, true) then return true end
  end
  return false
end

local function nextRead()
  if qOn == nil then return "Q_ENABLE" end
  if view == "tabs" or not rows or edit then return nil end
  local r = rows[sel]
  if r and vals[r[1]] == nil then return r[1] end
  for i = top, math.min(#rows, top + 6) do if vals[rows[i][1]] == nil then return rows[i][1] end end
  for i = 1, #rows do if vals[rows[i][1]] == nil then return rows[i][1] end end
  return nil
end

local function timeout(set)
  -- ELRS / Crossfire: the request waits for an uplink slot and the answer for a telemetry slot
  return (set and 4 or 2.5) + (link == "MAVLINK" and 1 or 0)
end

local function pushOne()
  local f = out[1]
  local ok, r = pcall(T.crsfPush, f[1], f[2])
  if ok and r ~= false then table.remove(out, 1) end
end

local blockedNow = nil
local function service(s)
  local now = E.os.clock()
  if quietAt and now - quietAt >= 15 then quietAt, silent = nil, 0 end
  blockedNow = blocked(s)
  if blockedNow then
    if pend or #out > 0 then clearOut() pend = nil end
    return
  end
  if now - hbAt >= 2 then   -- GCS HEARTBEAT: wakes the mLRS bridge
    hbAt = now
    pcall(T.crsfPush, 0xAA, HB)
  end
  local want = (E.envAt and now - E.envAt < 3) and "MAVLINK" or "CRSF"
  if link ~= want then
    link = want
    clearOut()
    pend, mav = nil, nil
    collectgarbage()
    if link == "MAVLINK" then
      local chunk = loadScript(ROOT .. "pmav.lua", OD_DEBUGLOAD and "T" or "bt")
      mav = chunk and chunk()(out, handle)
      if not mav then link = "CRSF" end
    end
    answered, silent, quietAt = false, 0, nil
  end
  if link == "MAVLINK" then
    -- ~1.3 kB/s on mLRS: about one frame per update, up to 4 to catch up after a pause, but only
    -- while the update has used under 40 % of EdgeTX's per-call Lua limit (getUsage(), percent);
    -- the rest waits for the next update in etx.lua's queue
    for _ = 1, 4 do
      if getUsage and getUsage() >= 40 then break end
      local d = E.popEnv()
      if not d then break end
      mav.feed(d)
    end
  end
  if #out > 0 then
    pushOne()
    if #out == 0 and pend then pend.at = now end
    return
  end
  -- a save goes first: a row read still waiting is dropped (asked again later; a late answer is
  -- kept anyway). Not a read of the row being saved: its old value would look like the answer.
  if saveReq and pend and not pend.set and not pend.check and pend.name ~= saveReq.name then pend = nil end
  if pend then
    if not pend.at then pend.at = now end
    local name = pend.name
    -- ArduPilot answers a name it doesn't have with a text only: taken as soon as it is here
    if not pend.set and link == "CRSF" and failedText(s, name) then
      answered, silent = true, 0
      setNA(name)
      pend = nil
      return
    end
    if now - pend.at < timeout(pend.set) then return end
    if pend.set then
      if link == "MAVLINK" then
        -- mLRS: ArduPilot saves at once but its answer can be lost on a full link: read it back
        pend = { name = name, check = pend.set, tries = 0 }
        phase = "CHECKING..."
        send(REQ_READ, name)
        return
      end
      phase = "NO ANSWER: CHECK IN A GCS"   -- never sent again by itself: the save may have happened
      vals[name], pend = nil, nil
      return
    end
    pend.tries = pend.tries + 1
    if pend.tries >= (link == "MAVLINK" and 4 or 3) then
      if pend.check then
        phase = "NO ANSWER: CHECK IN A GCS"
        vals[name], pend = nil, nil
        return
      end
      if not answered then   -- nothing ever came back on this link: say so, try again later
        silent = silent + 1
        pend = nil
        if silent >= 2 then quietAt = now end
        return
      end
      setNA(name)
      pend = nil
    else
      pend.at = nil
      send(REQ_READ, name)
    end
    return
  end
  if saveReq then
    pend = { name = saveReq.name, set = saveReq.bytes, tries = 0 }
    send(PARAM_SET, saveReq.name, saveReq.b)
    saveReq = nil
    return
  end
  local n = nextRead()
  if n then
    readReq(n)
    -- mLRS: each answer waits behind the telemetry stream, so one more unread row is asked at once
    if link == "MAVLINK" and rows and view ~= "tabs" then
      for _, r in ipairs(rows) do
        local nm = r[1]
        if nm ~= n and vals[nm] == nil and now - (prefAt[nm] or -10) >= 4 then
          prefAt[nm] = now
          send(REQ_READ, nm)
          break
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- tabs, editing
local function openTab(g)
  rows = nil
  collectgarbage()
  local chunk = loadScript(ROOT .. "pplist.lua", OD_DEBUGLOAD and "T" or "bt")
  local list = chunk and chunk()
  rows = list and list(g) or {}
  chunk, list = nil, nil
  -- only this tab's values are kept (and Q_ENABLE): another tab is read again when opened
  local q, qb = vals.Q_ENABLE, vbs.Q_ENABLE
  vals, vbs, txt, rowsBy, prefAt = { Q_ENABLE = q }, { Q_ENABLE = qb }, {}, {}, {}
  for _, r in ipairs(rows) do rowsBy[r[1]] = r end
  if pend and pend.name ~= "Q_ENABLE" and not pend.set then pend = nil end
  tab, sel, top, view = g, 1, 1, "rows"
  collectgarbage()
end

local function locked(s, r)
  if not s.armed then return false end
  return not (ctx.cfg and ctx.cfg.paramFlight == 1 and r and (AIR[tab] or r.fl))
end

local function openEdit(s)
  local r = rows and rows[sel]
  if not r then return end
  local v = vals[r[1]]
  if v == nil then phase = "READING..." return end
  if v == false then vals[r[1]] = nil return end   -- n/a: ENTER asks once more
  edit, draft, base, bitCur, view = r, v, v, 1, "edit"
  phase = ""
  if locked(s, r) then phase = "ARMED: VIEW ONLY"
  elseif s.armed then phase = "IN FLIGHT: SAVES AT ONCE" end
  if not pend and #out == 0 then readReq(r[1]) end   -- read again: may have changed in a GCS
end

local function nudge(d)
  local r = edit
  local v = draft + d * r[6]
  v = floor(v / r[6] * 1000 + 0.5) * r[6] / 1000
  -- a minimum of -1 (RTL_ALTITUDE, Q_ASSIST_SPEED...) is a setting of its own: below 0 goes to -1
  if r[4] == -1 then
    if d < 0 and draft <= 0 then v = -1 elseif d > 0 and draft < 0 then v = 0 end
  end
  if r[4] then v = math.max(r[4], math.min(r[5], v)) end
  draft, phase = v, ""
end

local function toggleBit(i)
  local bit = BITS[i][1]
  local v = draft
  if v < 0 then v = ALL_MASK end
  if floor(v / 2 ^ bit) % 2 == 1 then v = v - 2 ^ bit else v = v + 2 ^ bit end
  draft, phase = v, ""
end

local function save(s)
  if locked(s, edit) then phase = "DISARM TO SAVE" return end
  if pend and pend.set then return end
  local b = f2b(draft)
  local bytes = string.char(b[1], b[2], b[3], b[4])
  if bytes == vbs[edit[1]] then edit, view = nil, "rows" return end   -- unchanged: just close
  saveReq = { name = edit[1], b = b, bytes = bytes }
  phase = "SAVING..."
end

-- ---------------------------------------------------------------- keys and drawing
local function wheel(e)
  if e == EVT_VIRTUAL_NEXT or e == EVT_VIRTUAL_INC or e == EVT_ROT_RIGHT or e == EVT_PLUS_FIRST
     or e == EVT_PLUS_REPT then return 1 end
  if e == EVT_VIRTUAL_PREV or e == EVT_VIRTUAL_DEC or e == EVT_ROT_LEFT or e == EVT_MINUS_FIRST
     or e == EVT_MINUS_REPT then return -1 end
  return 0
end

local function title(left, right)
  lcd.drawFilledRectangle(0, 0, 128, 9, FORCE)
  lcd.drawText(1, 1, left, INVERS)
  if right then lcd.drawText(127, 1, right, INVERS + RIGHT) end
end

local function linkName() return link == "MAVLINK" and "MLRS" or "CRSF" end

local function drawTabs()
  -- the script's Lua memory next to the link (EdgeTX stops all Lua at ~127 KB on a TX12 MK2)
  title("PARAMS", (qOn == nil and "..." or linkName()) .. " " .. floor(collectgarbage("count")) .. "K")
  local first = math.max(1, math.min(tabSel - 2, #GV - 5))
  for k = 0, 5 do
    local i = first + k
    local g = GV[i]
    if not g then break end
    local y = 11 + k * 9
    if i == tabSel then
      lcd.drawFilledRectangle(0, y - 1, 128, 9, FORCE)
      lcd.drawText(2, y, g, INVERS)
      lcd.drawText(126, y, ">", INVERS + RIGHT)
    else
      lcd.drawText(2, y, g, 0)
    end
  end
end

local function drawRows()
  local n, got = #rows, 0
  for _, r in ipairs(rows) do if vals[r[1]] ~= nil then got = got + 1 end end
  title(tab, got < n and (got .. "/" .. n) or linkName())
  if sel < top then top = sel elseif sel > top + 6 then top = sel - 6 end
  for k = 0, 6 do
    local i = top + k
    local r = rows[i]
    if not r then break end
    local y = 10 + k * 7
    local v = txt[r[1]] or (vals[r[1]] == nil and "..." or fmt(r, vals[r[1]]))
    local lbl = r[2]
    if #lbl + #v > 24 then lbl = string.sub(lbl, 1, math.max(4, 24 - #v)) end
    local f = SMLSIZE
    if i == sel then
      lcd.drawFilledRectangle(0, y, 128, 7, FORCE)
      f = SMLSIZE + INVERS
    end
    lcd.drawText(1, y + 1, lbl, f)
    lcd.drawText(127, y + 1, v, f + RIGHT)
  end
end

local function drawBits(s)
  title("SKIP CHECKS", skipCount(draft) .. " SKIP")
  local n = #BITS + 1
  local first = math.max(1, math.min(bitCur - 2, n - 5))
  for k = 0, 5 do
    local i = first + k
    if i > n then break end
    local y = 10 + k * 7
    local f = SMLSIZE
    if i == bitCur then
      lcd.drawFilledRectangle(0, y, 128, 7, FORCE)
      f = SMLSIZE + INVERS
    end
    if i <= #BITS then
      lcd.drawText(1, y + 1, BITS[i][2], f)
      lcd.drawText(127, y + 1, skipped(draft, BITS[i][1]) and "SKIP" or "ON", f + RIGHT)
    else
      lcd.drawText(1, y + 1, locked(s, edit) and "VIEW ONLY" or "SAVE", f)
    end
  end
  lcd.drawText(1, 57, phase ~= "" and phase or "ENT TOGGLE  RTN BACK", SMLSIZE)
end

local function drawEdit(s)
  local r = edit
  if r[9] == "bits" then drawBits(s) return end
  title(r[2], draft ~= base and "*" or nil)
  lcd.drawText(1, 11, r[1], SMLSIZE)
  local t = fmt(r, draft)
  lcd.drawText(2, 20, t, #t <= 9 and MIDSIZE or 0)
  local range
  if r[8] then range = "WHEEL: CHOOSE"
  else
    local f = "%." .. r[7] .. "f"
    range = string.format(f, r[4]) .. ".." .. string.format(f, r[5]) .. " STEP " .. r[6]
  end
  lcd.drawText(1, 38, range, SMLSIZE)
  lcd.drawText(1, 46, phase, SMLSIZE)
  lcd.drawText(1, 57, locked(s, r) and "VIEW ONLY  RTN BACK" or "ENT SAVE  RTN BACK", SMLSIZE)
end

local function drawBlocked(lines)
  title("PARAMS", nil)
  for i, l in ipairs(lines) do lcd.drawText(1, 2 + i * 10, l, 0) end
  lcd.drawText(1, 57, "ENTER: NEXT PAGE", SMLSIZE)
end

local function close()
  if T then T.onMavlite = nil end
  if E then
    E.envOn = false
    if E.envClear then E.envClear() end
  end
end

local function draw(c, event)
  if not T then
    ctx, T, E = c, c.T, c.E
    T.onMavlite = onMavlite
    E.envOn = true
  end
  local s = T.s
  service(s)
  local e = (event ~= 0) and event or -1   -- a key constant this radio lacks is nil: never matches
  if blockedNow then
    -- edits and the open tab are dropped: the link or the flight controller changed
    edit, view = nil, view == "edit" and "rows" or view
    drawBlocked(blockedNow)
    return
  end
  local d = wheel(e)
  if e == EVT_VIRTUAL_ENTER_LONG then
    if killEvents then pcall(killEvents, e) end
    if view == "edit" then edit, view = nil, "rows" else c.wantNext = true end
  elseif view == "tabs" then
    if d ~= 0 then tabSel = math.max(1, math.min(#GV, tabSel + d)) end
    if e == EVT_VIRTUAL_ENTER and GV[tabSel] then openTab(GV[tabSel])
    elseif e == EVT_VIRTUAL_EXIT then c.wantNext = true end
  elseif view == "rows" then
    if d ~= 0 then sel = math.max(1, math.min(#rows, sel + d)) phase = "" end
    if e == EVT_VIRTUAL_ENTER then openEdit(s)
    elseif e == EVT_VIRTUAL_EXIT then view = "tabs" end
  else
    if edit[9] == "bits" then
      if d ~= 0 then bitCur = math.max(1, math.min(#BITS + 1, bitCur + d)) end
      if e == EVT_VIRTUAL_ENTER then
        if bitCur <= #BITS then
          if not locked(s, edit) then toggleBit(bitCur) end
        else save(s) end
      end
    else
      if d ~= 0 and not locked(s, edit) then nudge(d) end
      if e == EVT_VIRTUAL_ENTER then save(s) end
    end
    if e == EVT_VIRTUAL_EXIT then edit, view = nil, "rows" end
  end
  if view == "tabs" then drawTabs()
  elseif view == "rows" then drawRows()
  else drawEdit(s) end
end

-- ENTER is this page's own key unless it can't work now (then ENTER turns the page as everywhere)
local function wantsEnter(c) return blockedNow == nil end

return { draw = draw, close = close, wantsEnter = wantsEnter }
