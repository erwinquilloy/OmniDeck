-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck PARAMS page (page 6): read and set a fixed list of ArduPlane parameters (plist.lua)
  by name, over ArduPilot's MAVlite uplink on FrSky passthrough (S.Port / F.Port).

  MAVlite (ArduPilot libraries/AP_Frsky_Telem/AP_Frsky_MAVlite_*.cpp):
    radio -> FC   S.Port physId 0x0D, primId 0x30 (FRSKY_UPLINK_ID 13)
    FC -> radio   primId 0x32
    each frame:   appId low byte = sequence (0 starts a message), then 5 message bytes in
                  appId high byte + value bytes 0-3
    message:      len, msgid, payload (len bytes), checksum
    checksum:     c = c + byte; c = c + (c >> 8); c = c & 0xFF over every sequence and message byte
    PARAM_REQUEST_READ (20): name               PARAM_SET (23): float32 value, name
    PARAM_VALUE (22):        float32 value, name  (also the answer to PARAM_SET, read back
                                                   after ArduPilot saved it)
  A name the FC doesn't have gets no PARAM_VALUE, only the text "Param read failed (NAME)".

  One request at a time. Values are read only while this page is open, the selected row first.
  A save is sent once and never repeated by itself: only a matching read-back says "Saved".
  Editing is refused while armed.
]]

local P = {}
local floor = math.floor

local REQ_READ, PARAM_VALUE, PARAM_SET = 20, 22, 23
local READ_TIMEOUT, READ_TRIES, SET_TIMEOUT = 1.5, 2, 3.0

local T = nil
local LIST = nil                 -- plist.lua rows
local vis, groups = {}, {}       -- rows shown (Q rows only with Q_ENABLE 1), their groups in order
local vals, vbytes = {}, {}      -- name -> value (false = the FC doesn't have it), its 4 bytes

-- ---------------------------------------------------------------- float32 <-> bytes
-- byte by byte, so every step stays below 2^24 (exact even where Lua numbers are 32-bit floats)
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
P._f2b, P._b2f = f2b, b2f   -- test harness

-- ---------------------------------------------------------------- MAVlite transport
local tx, rx, link = nil, nil, nil
local out = {}          -- 6-byte chunks waiting to be pushed
local pend = nil        -- { name=, set=bytes|nil, tries=, at= (when the last chunk went out) }
local rxSt, rxExp, rxLen, rxId, rxSum, rxBuf = nil, 0, 0, 0, 0, {}
local prev = nil        -- last frame (F.Port sends each one twice)
local answered, silent, quietAt = false, 0, nil   -- this link answered yet; reads lost in a row; "no answer" since
P.stats = { tx = 0, rx = 0, bad = 0 }

local function ck(c, b) c = c + b c = c + floor(c / 256) return c % 256 end

-- ---------------------------------------------------------------- MAVLink (mLRS cbridge)
--[[
  mLRS with Tx Ser Port = cbridge passes the aircraft's MAVLink stream to the radio in mLRS "mb"
  envelope frames 0x82 (0x66, seq, size, up to 57 bytes) and takes MAVLink from it in 0x81 (same
  layout). 0xAA (the CRSF MAVLink envelope) is read too, never sent: mLRS answers in the type it
  last got, and 1.5.00 sends broken 0xAA frames (telem.lua reads them,
  T.bridgeAt / T.onMavEnv). Then this page speaks real MAVLink v2 and works with any ArduPilot:
  the MAVlite requests below are translated on the way out and the answers on the way in, so the
  page, the mission download and the editor's Send are the same code for every link.
    PARAM_REQUEST_READ 20 / PARAM_SET 23 -> PARAM_VALUE 22
    MISSION_REQUEST_LIST 43 -> MISSION_COUNT 44;  MISSION_REQUEST_INT 51 -> MISSION_ITEM_INT 73
    Send: MISSION_COUNT 44 -> the aircraft asks for each item (MISSION_REQUEST_INT 51 or
          MISSION_REQUEST 40) -> MISSION_ITEM_INT 73 ... -> MISSION_ACK 47
  Only the messages above are read; the rest of the stream is stepped over a whole packet at a
  time (about 1.3 kB/s on mLRS, most of it attitude and position for nobody here).
]]
local band, bxor, shl, shr
if bit32 then
  band, bxor, shl, shr = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift
else
  band = load("return function(a, b) return a & b end")()
  bxor = load("return function(a, b) return a ~ b end")()
  shl = load("return function(a, n) return (a << n) & 0xFFFFFFFF end")()
  shr = load("return function(a, n) return a >> n end")()
end
-- CRC-16/MCRF4XX (X.25), MAVLink's, from a table: crc = (crc >> 8) ~ TBL[(crc ~ b) & 0xFF].
-- The table is written out (working it out on the radio would cost one update ~20k Lua steps).
local CRC_T = {
  0, 4489, 8978, 12955, 17956, 22445, 25910, 29887, 35912, 40385, 44890, 48851, 51820, 56293, 59774, 63735,
  4225, 264, 13203, 8730, 22181, 18220, 30135, 25662, 40137, 36160, 49115, 44626, 56045, 52068, 63999, 59510,
  8450, 12427, 528, 5017, 26406, 30383, 17460, 21949, 44362, 48323, 36440, 40913, 60270, 64231, 51324, 55797,
  12675, 8202, 4753, 792, 30631, 26158, 21685, 17724, 48587, 44098, 40665, 36688, 64495, 60006, 55549, 51572,
  16900, 21389, 24854, 28831, 1056, 5545, 10034, 14011, 52812, 57285, 60766, 64727, 34920, 39393, 43898, 47859,
  21125, 17164, 29079, 24606, 5281, 1320, 14259, 9786, 57037, 53060, 64991, 60502, 39145, 35168, 48123, 43634,
  25350, 29327, 16404, 20893, 9506, 13483, 1584, 6073, 61262, 65223, 52316, 56789, 43370, 47331, 35448, 39921,
  29575, 25102, 20629, 16668, 13731, 9258, 5809, 1848, 65487, 60998, 56541, 52564, 47595, 43106, 39673, 35696,
  33800, 38273, 42778, 46739, 49708, 54181, 57662, 61623, 2112, 6601, 11090, 15067, 20068, 24557, 28022, 31999,
  38025, 34048, 47003, 42514, 53933, 49956, 61887, 57398, 6337, 2376, 15315, 10842, 24293, 20332, 32247, 27774,
  42250, 46211, 34328, 38801, 58158, 62119, 49212, 53685, 10562, 14539, 2640, 7129, 28518, 32495, 19572, 24061,
  46475, 41986, 38553, 34576, 62383, 57894, 53437, 49460, 14787, 10314, 6865, 2904, 32743, 28270, 23797, 19836,
  50700, 55173, 58654, 62615, 32808, 37281, 41786, 45747, 19012, 23501, 26966, 30943, 3168, 7657, 12146, 16123,
  54925, 50948, 62879, 58390, 37033, 33056, 46011, 41522, 23237, 19276, 31191, 26718, 7393, 3432, 16371, 11898,
  59150, 63111, 50204, 54677, 41258, 45219, 33336, 37809, 27462, 31439, 18516, 23005, 11618, 15595, 3696, 8185,
  63375, 58886, 54429, 50452, 45483, 40994, 37561, 33584, 31687, 27214, 22741, 18780, 15843, 11370, 7921, 3960,
}
local crcAcc
if bit32 then
  crcAcc = function(b, crc) return bxor(shr(crc, 8), CRC_T[band(bxor(crc, b), 0xFF) + 1]) end
else
  crcAcc = load("local T = ... return function(b, crc) return (crc >> 8) ~ T[((crc ~ b) & 0xFF) + 1] end")(CRC_T)
end
-- CRC_EXTRA of the messages used, and the ones read (the rest are stepped over)
local CRCX = { [0] = 50, [20] = 214, [22] = 220, [23] = 168, [40] = 230, [43] = 132, [44] = 221,
               [47] = 153, [51] = 196, [73] = 38 }
local MV = { sys = 1, comp = 1, seq = 0, found = false, usedAt = -100 }   -- the autopilot (HEARTBEAT), our sequence
local MY_SYS, MY_COMP = 255, 25                -- we are a GCS; MAV_COMP_ID_USER1, not Mission Planner's 190
P.mav = MV

local function mavPacket(msgid, pl)
  local p = { 0xFD, #pl, 0, 0, MV.seq, MY_SYS, MY_COMP, msgid % 256, floor(msgid / 256) % 256, floor(msgid / 65536) }
  MV.seq = (MV.seq + 1) % 256
  for i = 1, #pl do p[#p + 1] = pl[i] end
  local crc = 0xFFFF
  for i = 2, #p do crc = crcAcc(p[i], crc) end
  crc = crcAcc(CRCX[msgid], crc)
  p[#p + 1] = crc % 256
  p[#p + 1] = floor(crc / 256)
  return p
end
-- queue one MAVLink message as mLRS bridge frames (57 bytes each)
local function mavSend(msgid, pl)
  local p = mavPacket(msgid, pl)
  local i = 1
  while i <= #p do
    local n = math.min(57, #p - i + 1)
    local e = { 0x66, 0, n }   -- mLRS "mb" envelope 0x81 (see T.envFrame in telem.lua)
    for k = 0, n - 1 do e[k + 4] = p[i + k] end
    out[#out + 1] = { crsf = e, cmd = 0x81 }
    i = i + n
  end
end
local function name16(name, t)
  for k = 1, 16 do t[#t + 1] = string.byte(name, k) or 0 end
  return t
end
-- a MAVlite request (msgid, payload) as the MAVLink message that asks the same
local function mavFromLite(msgid, pl)
  if msgid == 20 then           -- PARAM_REQUEST_READ: index -1, target, name[16]
    mavSend(20, name16(string.char((table.unpack or unpack)(pl)), { 0xFF, 0xFF, MV.sys, MV.comp }))
  elseif msgid == 23 then       -- PARAM_SET: value, target, name[16], type REAL32
    local t = name16(string.char((table.unpack or unpack)(pl, 5)), { pl[1], pl[2], pl[3], pl[4], MV.sys, MV.comp })
    t[#t + 1] = 9
    mavSend(23, t)
  elseif msgid == 43 then       -- MISSION_REQUEST_LIST: target, mission type 0
    mavSend(43, { MV.sys, MV.comp, 0 })
  elseif msgid == 51 then       -- MISSION_REQUEST_INT: seq, target, mission type 0
    mavSend(51, { pl[1], pl[2], MV.sys, MV.comp, 0 })
  end
end

local function send(msgid, payload)
  if link == "MAVLINK" then mavFromLite(msgid, payload) return end
  -- CRSF (ELRS / TBS, Stratos firmware): the whole message in one custom frame addressed to the
  -- flight controller - destination, origin, sub type 0xF4, len, msgid, payload. The CRSF CRC
  -- covers it, so no sequence numbers or checksum
  if link == "CRSF" then
    local d = { 0xC8, 0xEA, 0xF4, #payload, msgid }
    for i = 1, #payload do d[#d + 1] = payload[i] end
    out[#out + 1] = { crsf = d }
    return
  end
  local bytes = { #payload, msgid }
  for i = 1, #payload do bytes[#bytes + 1] = payload[i] end
  local c, seq, i, done = 0, 0, 1, false
  repeat
    local ch = { seq }
    c = ck(c, seq)
    seq = seq + 1
    while #ch < 6 and i <= #bytes do ch[#ch + 1] = bytes[i] c = ck(c, bytes[i]) i = i + 1 end
    if i > #bytes and #ch < 6 then ch[#ch + 1] = c done = true end
    while #ch < 6 do ch[#ch + 1] = 0 end
    out[#out + 1] = ch
  until done
end

local function nameBytes(name, t)
  for k = 1, math.min(16, #name) do t[#t + 1] = string.byte(name, k) end
  return t
end

local mspViaNow = nil   -- set by service(): the radio link the MSP chunks go over
-- INAV MSP over the mLRS bridge: path ("native" / "bridge" / nil), raw-frame parser state (see mspSend)
local BR = { path = nil, st = 0, v2 = true, err = false, hdr = {}, need = 0, buf = {}, crc_ = 0 }
local function openSensors()
  tx, rx = nil, nil
  if link == "MSP" and mspViaNow == "CRSF" then
    -- INAV: a CRSF reader of its own for the 0x7B replies, as mspclient.lua has (on Ethos every
    -- crsf.getSensor() object gets every frame); requests go out through it too
    if crsf and crsf.getSensor then
      local ok, sn = pcall(crsf.getSensor)
      if ok and sn then tx, rx = sn, sn end
    end
    return tx ~= nil
  end
  if link == "CRSF" or link == "MAVLINK" then
    -- telem.lua owns the one CRSF sensor: requests go out through it (T.crsfPush) and replies
    -- come back through it (P.onCrsf below). Never a second crsf.getSensor() (see telem.lua)
    if T.crsfPush then tx = { pushFrame = function(self, c, d) return T.crsfPush(c, d) end } end
    return tx ~= nil
  end
  if sport and sport.getSensor then
    local ok, sn = pcall(sport.getSensor, { primId = 0x32 })
    if ok and sn then tx, rx = sn, sn end
  end
  return tx ~= nil
end

local function pushOne()
  local ch = out[1]
  if not ch then return end
  if ch.crsf then
    local ok, r = pcall(function() return tx:pushFrame(ch.cmd or 0x80, ch.crsf) end)
    if ok and r ~= false then
      table.remove(out, 1)
      P.stats.tx = P.stats.tx + 1
    end
    return
  end
  local value = ch[3] + ch[4] * 256 + ch[5] * 65536 + ch[6] * 16777216
  local ok, r = pcall(function() return tx:pushFrame({ physId = 0x0D, primId = 0x30, appId = ch[1] + ch[2] * 256, value = value }) end)
  if ok and r ~= false then
    table.remove(out, 1)
    P.stats.tx = P.stats.tx + 1
  end
end

local status, statusCol = "", nil
local edit, draft, editBase = nil, nil, nil
local phase, phaseCol = "", nil
local qOn = nil      -- Q_ENABLE read: nil not yet, true / false

-- rows tab by tab (tabs in first-seen order), so the wheel walks one tab after the other even
-- when params.txt adds rows to a built-in tab
local function rebuild()
  vis, groups = {}, {}
  local by = {}
  for _, r in ipairs(LIST) do
    if r[10] ~= "q" or qOn == true then
      if not by[r[1]] then by[r[1]] = {} groups[#groups + 1] = r[1] end
      local t = by[r[1]]
      t[#t + 1] = r
    end
  end
  for _, g in ipairs(groups) do
    for _, r in ipairs(by[g]) do vis[#vis + 1] = r end
  end
end

-- ---------------------------------------------------------------- params.txt (added rows)
--[[
  One shared file next to the widget (EdgeTX /WIDGETS/OmniDeck/params.txt, Ethos
  /scripts/omnideck/params.txt). It only ADDS rows to the built-in list:
    # comment
    [GROUP]            rows below go to this tab (a built-in tab name adds to that tab)
    [GROUP] flight     ...and may be changed in flight ("Params: edit in flight" on)
    NAME               a parameter by its ArduPilot name (16 characters at most)
    NAME | label | step   optional label and wheel step
  Names before any [GROUP] go to OTHER. A name already listed is skipped. Q_ names show only
  with Q_ENABLE 1. A row from the file has no range of its own (ArduPilot keeps its limits);
  without a step the wheel moves 1 for whole numbers, else about 1 % of the value.
]]
local MAX_EXTRA, MAX_GROUPS = 100, 14
P.extra = { file = false, added = 0, skipped = 0, badLine = nil }
local function trim(x) return (string.match(x, "^%s*(.-)%s*$")) end

local function parseExtra(text)
  local known, tabs, nTabs = {}, {}, 0
  for _, r in ipairs(LIST) do
    known[r[2]] = true
    if not tabs[r[1]] then tabs[r[1]] = true nTabs = nTabs + 1 end
  end
  local X = P.extra
  local cur, curFlight, n = "OTHER", false, 0
  for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
    n = n + 1
    line = trim(string.gsub(string.gsub(line, "\r", ""), "#.*$", ""))
    if line ~= "" then
      local g, rest = string.match(line, "^%[([^%]]+)%](.*)$")
      if g then
        g, rest = string.upper(trim(g)), string.lower(trim(rest))
        if g == "" or (rest ~= "" and rest ~= "flight") then
          X.skipped, X.badLine = X.skipped + 1, X.badLine or n
        else
          cur, curFlight = string.sub(g, 1, 12), rest == "flight"
        end
      else
        local f = {}
        for part in string.gmatch(line .. "|", "([^|]*)|") do f[#f + 1] = trim(part) end
        local name = string.upper(f[1] or "")
        local step = tonumber(f[3] or "")
        if not string.match(name, "^[A-Z][A-Z0-9_]*$") or #name > 16 or (f[3] and f[3] ~= "" and not (step and step > 0))
           or X.added >= MAX_EXTRA then
          X.skipped, X.badLine = X.skipped + 1, X.badLine or n
        elseif known[name] then
          X.skipped = X.skipped + 1          -- already in the list: the first one counts
        else
          local g = cur
          if not tabs[g] then
            if nTabs >= MAX_GROUPS then g = "OTHER" end
            if not tabs[g] then tabs[g] = true nTabs = nTabs + 1 end
          end
          local dec = nil
          if step then
            dec = 0
            while dec < 6 and math.abs(step * 10 ^ dec - floor(step * 10 ^ dec + 0.5)) > 1e-6 do dec = dec + 1 end
          end
          LIST[#LIST + 1] = { g, name, (f[2] and f[2] ~= "") and f[2] or name, "", nil, nil, step, dec, nil,
                              string.sub(name, 1, 2) == "Q_" and "q" or nil, free = true, fl = curFlight or nil }
          known[name] = true
          X.added = X.added + 1
        end
      end
    end
  end
end

-- a row from params.txt without a step: decided by the first value read
local function autoStep(r, v)
  if r[7] or v == nil or v == false then return end
  if v == floor(v) and math.abs(v) < 1000000 then r[7], r[8] = 1, 0 return end
  local e = floor(math.log(math.abs(v)) / math.log(10)) - 2
  r[7], r[8] = 10 ^ e, math.max(0, -e)
end

local function sameBytes(a, b) return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4] end

local function fmtNum(r, v)
  if r[10] == "bits" then
    if v == 0 then return "All checks on" end
    if v == -1 then return "ALL SKIPPED" end
  end
  if r[9] then
    if not r.o then
      r.o = {}
      for o in string.gmatch(r[9], "[^|]+") do r.o[#r.o + 1] = o end
    end
    return r.o[floor(v + 0.5) + 1] or tostring(floor(v + 0.5))
  end
  local t = string.format("%." .. (r[8] or 3) .. "f", v)
  if r[4] ~= "" then t = t .. " " .. r[4] end
  return t
end

-- ARMING_SKIPCHK (Plane bits, AP_Arming.cpp); a set bit = that check is skipped
local BITS = { { 1, "Barometer" }, { 2, "Compass" }, { 3, "GPS lock" }, { 4, "INS" }, { 5, "Parameters" },
  { 6, "RC channels" }, { 7, "Board voltage" }, { 8, "Battery level" }, { 9, "Airspeed" }, { 10, "Logging" },
  { 11, "Safety switch" }, { 12, "GPS config" }, { 13, "System" }, { 14, "Mission" }, { 15, "Rangefinder" },
  { 16, "Camera" }, { 17, "AuxAuth" }, { 19, "FFT" } }
local ALL_MASK = 0
for _, b in ipairs(BITS) do ALL_MASK = ALL_MASK + 2 ^ b[1] end
local function skipped(v, bit) return v == -1 or (v >= 0 and floor(v / 2 ^ bit) % 2 == 1) end
local function skipCount(v)
  local n = 0
  for _, b in ipairs(BITS) do if skipped(v, b[1]) then n = n + 1 end end
  return n
end
local function fmtVal(r, v)
  if v == nil then return "..." end
  if v == false then return "n/a" end
  if r[10] == "bits" and v ~= 0 and v ~= -1 then return skipCount(v) .. " skipped" end
  return fmtNum(r, v)
end

-- ---------------------------------------------------------------- ArduPilot mission download
--[[
  Stratos firmware answers two more MAVlite requests (AP_Frsky_MAVliteMsgHandler, compact replies):
    MISSION_REQUEST_LIST (43), no payload -> MISSION_COUNT (44): count u16, last change ms u32
    MISSION_REQUEST_INT (51): seq u16     -> MISSION_ITEM_INT (73): seq u16, command u16, frame u8,
                                             lat i32, lon i32 (1e7), alt float, param1, param3,
                                             param2 (29 bytes; older test firmware sent 25)
                                          or MISSION_ACK (47): seq u16, error u8
  Read only. Sent through the same queue as the parameters, one request at a time; parameter
  saves and the open PARAMS page go first. While disarmed the count is checked every 10 s and the
  mission downloaded again when it changed (a new upload from a GCS). P.onMission(list) hands the
  finished list to mission.lua.
]]
local MISSION_REQUEST_LIST, MISSION_COUNT, MISSION_REQUEST_INT, MISSION_ITEM_INT, MISSION_ACK = 43, 44, 51, 73, 47
local MISSION_RECHECK_S, MISSION_MAX, MISSION_TRIES = 10, 100, 3
local MISSION_CLEAR_ALL = 45
--[[
  Mission send (EdgeTX / X20 mission editor, medit.lua), Stratos firmware, refused there while armed:
    MISSION_CLEAR_ALL (45)            -> MISSION_ACK: 0xFFFF, result
    MISSION_ITEM_INT (73), compact as above, seq 1.. -> MISSION_ACK: seq, result
  then the mission is downloaded again and compared with what was sent ("Sent and verified").
  A repeated write is harmless (the item just replaces itself), so writes are retried.
]]
local SND = { state = "off", items = nil, i = 0, msg = "" }
P.sendState = SND
local RESULT = { [1] = "error", [2] = "bad frame", [3] = "not supported", [4] = "no space", [5] = "invalid",
  [10] = "bad latitude", [11] = "bad longitude", [12] = "bad altitude", [13] = "wrong order", [14] = "aircraft armed",
  [15] = "operation cancelled" }
local function refused(res) return "Refused: " .. (RESULT[res] or ("code " .. tostring(res))) end

-- items: { { cmd=, frame=, lat=, lon=, alt=, p1=, p3= }, ... } become mission items 1..n
function P.missionSend(items)
  SND.state, SND.items, SND.i, SND.msg = "clear", items, 0, "Sending..."
end

local function u32bytes(v, t)
  v = v % 4294967296
  for _ = 1, 4 do t[#t + 1] = v % 256 v = math.floor(v / 256) end
end
local function itemPayload(seq, it)
  local t = { seq % 256, math.floor(seq / 256), it.cmd % 256, math.floor(it.cmd / 256), it.frame or 3 }
  u32bytes(math.floor(it.lat * 1e7 + 0.5), t)
  u32bytes(math.floor(it.lon * 1e7 + 0.5), t)
  for _, f in ipairs({ it.alt or 0, it.p1 or 0, it.p3 or 0, it.p2 or 0 }) do   -- 29 bytes: param2 last
    local b = f2b(f)
    t[#t + 1], t[#t + 2], t[#t + 3], t[#t + 4] = b[1], b[2], b[3], b[4]
  end
  return t
end

-- the download after a send: is it what was sent?
local function verifySend(list)
  local want = SND.items
  if not list or #list ~= #want then
    return false, string.format("Read back %d items, sent %d", list and #list or 0, #want)
  end
  for i, it in ipairs(want) do
    local g = list[i]
    if g.cmd ~= it.cmd then return false, "Item " .. i .. " differs" end
    local pos = it.cmd ~= 20 and it.cmd ~= 178 and it.cmd ~= 189 and it.cmd ~= 3000
    if pos and (math.abs(g.lat - it.lat) > 2e-5 or math.abs(g.lon - it.lon) > 2e-5
       or math.abs(g.alt - (it.alt or 0)) > 0.5) then
      return false, "Item " .. i .. " differs"
    end
    -- the parameters the editor sets: loiter turns / radius / time, speed
    if math.abs((g.p1 or 0) - (it.p1 or 0)) > 0.01 or math.abs((g.p2 or 0) - (it.p2 or 0)) > 0.01
       or ((it.cmd == 17 or it.cmd == 18) and math.abs(math.abs(g.p3 or 0) - math.abs(it.p3 or 0)) > 0.5) then
      return false, "Item " .. i .. " settings differ"
    end
  end
  return true
end
local MS = { state = "off", count = nil, stamp = nil, items = {}, next = 1, last = 0, checkAt = -100 }
-- the downloaded mission for the editor (medit.lua): items when complete, and the state
function P.missionItems() return MS.state == "done" and MS.items or nil, MS.state end
P.missionOn = false   -- ui.lua: "ArduPilot mission download" setting
P.onMission = nil     -- function(list or nil)

local function i32(b, o)
  local v = b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216
  if b[o + 3] >= 128 then v = v - 4294967296 end
  return v
end

local function missionDone(list)
  MS.state = "done"
  if link == "MAVLINK" then mavSend(47, { MV.sys, MV.comp, 0, 0 }) end   -- download finished (MISSION_ACK)
  if SND.state == "verify" then
    local ok, why = verifySend(list)
    SND.state, SND.msg = ok and "done" or "failed", ok and "Sent and verified" or ("Not verified: " .. why)
  end
  if P.onMission then P.onMission(list) end
end

local function missionHandle(id, b)
  local mine = pend and pend.m
  if id == MISSION_COUNT and #b >= 6 then
    if mine == "count" then pend = nil end
    local count = b[1] + b[2] * 256
    local stamp = b[3] .. "." .. b[4] .. "." .. b[5] .. "." .. b[6]
    if MS.state == "done" and count == MS.count and stamp == MS.stamp then return end
    MS.count, MS.stamp, MS.items, MS.next = count, stamp, {}, 1
    MS.last = math.min(count - 1, MISSION_MAX)   -- item 0 is home
    if MS.last < 1 then missionDone(nil) else MS.state = "items" end
  elseif id == MISSION_ITEM_INT and #b >= 25 then
    local seq = b[1] + b[2] * 256
    if mine == "item" and pend.seq == seq then pend = nil end
    if MS.state ~= "items" or seq ~= MS.next then return end   -- late answer to a repeated request
    MS.items[#MS.items + 1] = { seq = seq, cmd = b[3] + b[4] * 256, frame = b[5],
      lat = i32(b, 6) / 1e7, lon = i32(b, 10) / 1e7, alt = b2f(b[14], b[15], b[16], b[17]),
      p1 = b2f(b[18], b[19], b[20], b[21]), p3 = b2f(b[22], b[23], b[24], b[25]),
      p2 = #b >= 29 and b2f(b[26], b[27], b[28], b[29]) or 0 }   -- param2: e.g. DO_CHANGE_SPEED speed
    MS.next = seq + 1
    if MS.next > MS.last then missionDone(MS.items) end
  elseif id == MISSION_ACK and #b >= 3 then
    local seq, res = b[1] + b[2] * 256, b[3]
    if mine == "clear" and seq == 65535 then
      pend = nil
      if res == 0 then SND.state, SND.i = "write", 0 else SND.state, SND.msg = "failed", refused(res) end
      return
    end
    if mine == "write" and seq == pend.seq then
      pend = nil
      if res ~= 0 then SND.state, SND.msg = "failed", refused(res) return end
      SND.i = seq
      if SND.i >= #SND.items then
        -- all written: download it again and compare
        SND.state, SND.msg = "verify", "Checking..."
        MS.state, MS.stamp, MS.checkAt = "idle", nil, -100
      end
      return
    end
    if mine == "clear" or mine == "write" then return end   -- an answer to an earlier try
    -- the mission changed under the download: start again with a fresh count
    if mine then pend = nil end
    MS.state, MS.checkAt = "idle", -100
  end
end

-- a value that arrived (ArduPilot PARAM_VALUE, or INAV's answer through the MSP link). same: the
-- MSP link compares the raw values itself (nil = compare the float32 bytes)
-- row: the caller's row when it has it (a Betaflight block hands over up to 24 values at once;
-- looking each one up in LIST again made that one wakeup cost ~2k instructions more)
local function gotValue(name, v, bytes, same, row)
  if row then
    if row.free then autoStep(row, v) end
  else
    for _, r in ipairs(LIST) do if r[2] == name then if r.free then autoStep(r, v) end break end end
  end
  vals[name], vbytes[name] = v, bytes
  if name == "Q_ENABLE" then qOn = v >= 1 rebuild() end
  if pend and pend.name == name then
    local want = pend.set or pend.check
    if want then
      if same == nil then same = sameBytes(bytes, want) end
      if same then
        phase, phaseCol = "Saved and verified", "ok"
        editBase = v
      else
        local r = edit
        phase, phaseCol = "Not saved: FC has " .. (r and fmtVal(r, v) or tostring(v)), "bad"
        if edit and edit[2] == name then editBase = v end
      end
    elseif edit and edit[2] == name and draft == editBase then
      draft, editBase = v, v       -- a fresh read while the value is not being changed
    end
    pend = nil
  end
end

local function handle(id, b)
  P.stats.rx = P.stats.rx + 1
  answered, silent, quietAt = true, 0, nil
  if id == MISSION_COUNT or id == MISSION_ITEM_INT or id == MISSION_ACK then missionHandle(id, b) return end
  if id ~= PARAM_VALUE or #b < 5 then return end
  local name = string.char(table.unpack(b, 5, math.min(#b, 20)))
  gotValue(name, b2f(b[1], b[2], b[3], b[4]), { b[1], b[2], b[3], b[4] })
end

local function onFrame(b)
  local seq = b[1] % 64
  if seq == 0 then rxSt, rxExp, rxSum, rxBuf = 1, 0, 0, {} end
  if rxSt == nil or seq ~= rxExp then rxSt = nil return end
  rxSum = ck(rxSum, seq)
  rxExp = seq + 1
  for i = 2, 6 do
    local x = b[i]
    if rxSt == 1 then rxLen, rxSt = x, 2 rxSum = ck(rxSum, x)
    elseif rxSt == 2 then rxId, rxSt = x, (rxLen == 0 and 4 or 3) rxSum = ck(rxSum, x)
    elseif rxSt == 3 then
      rxBuf[#rxBuf + 1] = x rxSum = ck(rxSum, x)
      if #rxBuf >= rxLen then rxSt = 4 end
    elseif rxSt == 4 then
      rxSt = nil
      if x == rxSum then handle(rxId, rxBuf) else P.stats.bad = P.stats.bad + 1 end
      return
    end
  end
end
P._onFrame = onFrame

local mspPollNow = nil   -- the MSP link's reader (INAV), set below
local function poll()
  if link == "MSP" then mspPollNow() return end
  if link == "CRSF" or link == "MAVLINK" then return end   -- these arrive through P.onCrsf / P.onMavEnv
  for _ = 1, 12 do
    local ok, f = pcall(function() return rx:popFrame() end)
    if not ok or not f then return end
    if f:primId() == 0x32 then
      local a = f:appId()
      local lo, hi = T.split32(f:value())
      local b = { a % 256, floor(a / 256) % 256, lo % 256, floor(lo / 256), hi % 256, floor(hi / 256) }
      local p = prev
      if not (p and p[1] == b[1] and p[2] == b[2] and p[3] == b[3] and p[4] == b[4] and p[5] == b[5] and p[6] == b[6]) then
        prev = b
        onFrame(b)
      end
    end
  end
end

-- a CRSF custom frame with sub type 0xF4 (telem.lua hands it over): len, msgid, payload
function P.onCrsf(data)
  if link ~= "CRSF" or not data or #data < 3 then return end
  local n = data[2]
  if #data < 3 + n then P.stats.bad = P.stats.bad + 1 return end
  local b = {}
  for i = 1, n do b[i] = data[3 + i] end
  handle(data[3], b)
end

-- ---------------------------------------------------------------- MAVLink receive (mLRS cbridge)
local READ_IDS = { [0] = true, [22] = true, [40] = true, [44] = true, [47] = true, [51] = true, [73] = true }
local mvSt, mvHn, mvHdr, mvSkip, mvNeed, mvGot, mvBody, mvId = 0, 0, {}, 0, 0, 0, {}, 0
local function u8(b, i) return b[i] or 0 end   -- MAVLink 2 leaves out trailing zero bytes

local function itemFloat(t, v) local b = f2b(v or 0) t[#t + 1], t[#t + 2], t[#t + 3], t[#t + 4] = b[1], b[2], b[3], b[4] end
-- MISSION_ITEM_INT for the upload: params 1-4, x, y, z, seq, command, target, frame, current,
-- autocontinue, mission type
local function mavItem(seq, it)
  local t = {}
  itemFloat(t, it.p1) itemFloat(t, it.p2) itemFloat(t, it.p3) itemFloat(t, 0)
  u32bytes(floor(it.lat * 1e7 + 0.5), t)
  u32bytes(floor(it.lon * 1e7 + 0.5), t)
  itemFloat(t, it.alt)
  t[#t + 1], t[#t + 2], t[#t + 3], t[#t + 4] = seq % 256, floor(seq / 256), it.cmd % 256, floor(it.cmd / 256)
  t[#t + 1], t[#t + 2], t[#t + 3], t[#t + 4], t[#t + 5], t[#t + 6] = MV.sys, MV.comp, it.frame or 3, 0, 1, 0
  return t
end
local function sendUploadItem(seq)
  local it = seq == 0 and { cmd = 16, frame = 0, lat = SND.home[1], lon = SND.home[2], alt = 0 } or SND.items[seq]
  mavSend(73, mavItem(seq, it))
end
-- the aircraft asks for item seq of the mission being sent
local function mavUploadRequest(seq)
  if SND.state ~= "write" or not SND.items or seq > #SND.items then return end
  SND.req, SND.i = seq, seq
  pend = { m = "upload", tries = 0 }
  sendUploadItem(seq)
end
local function mavUploadAck(res)
  if SND.state ~= "write" then return end
  pend = nil
  if res ~= 0 then SND.state, SND.msg = "failed", refused(res) return end
  SND.i = #SND.items
  SND.state, SND.msg = "verify", "Checking..."
  MS.state, MS.stamp, MS.checkAt = "idle", nil, -100
end

local function mavMessage(id, b, sys, comp)
  if id == 0 then
    -- HEARTBEAT of the autopilot (autopilot 3 = ArduPilot, component 1): who to ask
    if u8(b, 6) == 3 and comp == 1 then MV.sys, MV.comp, MV.found = sys, comp, true end
    return
  end
  if sys ~= MV.sys then return end
  if id == 22 then
    local nb = { u8(b, 1), u8(b, 2), u8(b, 3), u8(b, 4) }
    for i = 9, 24 do local c = u8(b, i) if c == 0 then break end nb[#nb + 1] = c end
    handle(22, nb)
    return
  end
  -- mission messages: only those addressed to us (Mission Planner may be on the same stream)
  local ts, tc
  if id == 73 then ts, tc = u8(b, 33), u8(b, 34)
  elseif id == 47 then ts, tc = u8(b, 1), u8(b, 2)
  else ts, tc = u8(b, 3), u8(b, 4) end   -- 40, 44, 51
  if ts ~= MY_SYS or (tc ~= MY_COMP and tc ~= 0) then return end
  if id == 44 then
    handle(44, { u8(b, 1), u8(b, 2), u8(b, 6), u8(b, 7), u8(b, 8), u8(b, 9) })   -- count, opaque id as the change stamp
  elseif id == 73 then
    handle(73, { u8(b, 29), u8(b, 30), u8(b, 31), u8(b, 32), u8(b, 35),
      u8(b, 17), u8(b, 18), u8(b, 19), u8(b, 20), u8(b, 21), u8(b, 22), u8(b, 23), u8(b, 24),
      u8(b, 25), u8(b, 26), u8(b, 27), u8(b, 28), u8(b, 1), u8(b, 2), u8(b, 3), u8(b, 4),
      u8(b, 9), u8(b, 10), u8(b, 11), u8(b, 12), u8(b, 5), u8(b, 6), u8(b, 7), u8(b, 8) })
  elseif id == 40 or id == 51 then
    mavUploadRequest(u8(b, 1) + u8(b, 2) * 256)
  elseif id == 47 then
    mavUploadAck(u8(b, 3))
  end
end

-- an mLRS bridge frame (telem.lua): chunk byte, size, MAVLink bytes. Packets run across frames.
function P.onMavEnv(data)
  if link == "MSP" and data and mspViaNow == "CRSF" then BR.input(data) return end
  if link ~= "MAVLINK" or not data then return end
  -- read only while the page, the mission download or a send uses it (service() ran lately);
  -- otherwise the stream is let go and picked up again at the next packet start
  if os.clock() - MV.usedAt > 2 then mvSt, mvSkip = 0, 0 return end
  local e = 2 + (data[2] or 0)
  if e > #data then e = #data end
  local i = 3
  while i <= e do
    if mvSkip > 0 then
      local k = e - i + 1
      if k > mvSkip then k = mvSkip end
      mvSkip, i = mvSkip - k, i + k
    elseif mvSt == 0 then
      if data[i] == 0xFD then mvSt, mvHn, mvHdr[1] = 1, 1, 0xFD end
      i = i + 1
    elseif mvSt == 1 then
      mvHn = mvHn + 1
      mvHdr[mvHn] = data[i]
      i = i + 1
      if mvHn == 10 then
        local len, id = mvHdr[2], mvHdr[8] + mvHdr[9] * 256 + mvHdr[10] * 65536
        local signed = mvHdr[3] % 2 == 1
        if READ_IDS[id] and not signed and (id ~= 0 or not MV.found) then mvSt, mvNeed, mvGot, mvBody, mvId = 2, len + 2, 0, {}, id
        else mvSt, mvSkip = 0, len + 2 + (signed and 13 or 0) end
      end
    else
      mvGot = mvGot + 1
      mvBody[mvGot] = data[i]
      i = i + 1
      if mvGot == mvNeed then
        mvSt = 0
        local len = mvNeed - 2
        local crc = 0xFFFF
        for k = 2, 10 do crc = crcAcc(mvHdr[k], crc) end
        for k = 1, len do crc = crcAcc(mvBody[k], crc) end
        crc = crcAcc(CRCX[mvId], crc)
        if crc == mvBody[len + 1] + mvBody[len + 2] * 256 then
          mvBody[len + 1], mvBody[len + 2] = nil, nil
          mavMessage(mvId, mvBody, mvHdr[6], mvHdr[7])
        else
          P.stats.bad = P.stats.bad + 1
        end
      end
    end
  end
end

local prefAt = {}   -- mLRS: when a row was last asked ahead of its turn (see service)
local naAt = {}     -- when a row became n/a (or was last asked again, mLRS)
local readReqMsp = nil   -- the MSP link's read (INAV), set below
local function readReq(name)
  if link == "MSP" then readReqMsp(name) return end
  -- an n/a row asked again (mLRS, every 30 s) gets one try, so it never holds up a save for long
  pend = { name = name, tries = (vals[name] == false and link == "MAVLINK") and 3 or 0 }
  send(REQ_READ, nameBytes(name, {}))
end

-- ---------------------------------------------------------------- INAV (link "MSP"), INAV 9.0+
--[[
  INAV settings by their CLI name, MSPv2 over the telemetry link (INAV msp_shared.c; MSPv2 over
  CRSF and SmartPort since INAV 9.0, before that version 1 only, which can't carry these commands):
    chunk:  status (0x40 = v2 | 0x10 first chunk | sequence 0-15; 0x80 = error, replies) + bytes
    first:  flags, cmd lo, cmd hi, size lo, size hi, payload ...   (no checksum)
    CRSF:   type 0x7A to the FC (dest 0xC8, origin 0xEA), replies 0x7B; up to 57 bytes a chunk
    S.Port: physId 0x0D primId 0x30 (appId = bytes 1-2, value = bytes 3-6), replies primId 0x32
  MSP2_COMMON_SETTING_INFO 0x1007 (name\0) -> name\0, pgn u16, type u8, section u8, mode u8,
      min i32, max u32, index u16, profile u8, profile count u8, [lookup names\0 ...], value
  MSP2_COMMON_SET_SETTING 0x1004 (name\0, value) -> empty, or an error (INAV checks min / max)
  MSP2_COMMON_SETTING 0x1003 (name\0) -> value           (the read-back after a save)
  MSP_EEPROM_WRITE 250 -> stores everything; INAV refuses it while armed
  A value changed in flight works at once but is stored only by the EEPROM write after landing.
  Control-profile settings (the PIDs) are read and written in the ACTIVE profile only; with
  mixer_control_profile_linking the VTOL switch picks it, so a PID group is editable only while
  its platform (platform_type of the active mixer profile) is the active one.
]]
local MSP_FC_VARIANT, MSP_FC_VERSION, MSP_EEPROM_WRITE = 2, 3, 250
-- MSP2_INAV_STATUS 0x2000 -> cycle u16, i2c errors u16, sensors u16, load u16, profiles u8,
-- armingFlags u32 (bytes 10-13; ARMED = bit 2), box modes, mixer profile. The arming state comes from
-- INAV itself: the radio's flight mode sensor can read disarmed in flight, and then an in-flight
-- change was not locked and its EEPROM write went out armed, was refused and never repeated (X20S +
-- ELRS + INAV 9.1, 2026-11-24: the change was gone after the reboot)
local MSP2_INAV_STATUS, STATUS_EVERY = 0x2000, 2
local M_SETTING, M_SET_SETTING, M_SETTING_INFO = 0x1003, 0x1004, 0x1007
local IN = { state = "off", variant = nil, ver = nil, meta = {}, profile = nil, plat = nil,
             dirty = false, storeReq = false, stored = nil, armed = nil, armedAt = nil, statusAt = -10 }
P.inav = IN
local mSeq, mLast = 0, nil  -- request sequence; the last request (repeated on a timeout)
-- over CRSF the MSP goes one of two ways: "native" (CRSF MSP frames 0x7A / 0x7B: ELRS, Crossfire) or
-- "bridge" (raw MSP frames inside mLRS bridge frames 0x81 / 0x82: mLRS with Tx Ser Port = cbridge and the
-- MSP-over-cbridge Tx firmware). nil = not known yet: each request goes both ways, the first
-- answer decides. ELRS / Crossfire ignore 0x81; mLRS drops 0x7A.
local mOn, mSize, mCmd, mErr, mBuf, mRxSeq, mPrev = false, 0, 0, false, {}, 0, nil
local APLIST, ILIST = nil, nil
-- Betaflight (MSP_FC_VARIANT "BTFL", 4.5 / 2025.12 / 2026.6): bfplist.lua, loaded only when one answers;
-- BLK = the last reply of each block (MSP_PID, _PID_ADVANCED, _RC_TUNING, _FILTER_CONFIG)
-- (one table: the main chunk is at Lua's limit of 200 locals)
local BFX = { mod = nil, load = nil, blk = {}, API = 1, STATUS_EX = 150 }
function BFX.fcName() return IN.variant == "BTFL" and "Betaflight" or "INAV" end

local function zname(name)
  local t = {}
  for k = 1, #name do t[k] = string.byte(name, k) end
  t[#t + 1] = 0
  return t
end
-- MSPv2 checksum (crc8 dvb-s2) over flag .. payload
function BR.crc(c, b)
  c = c ~ b
  for _ = 1, 8 do c = (c & 0x80) ~= 0 and (((c << 1) ~ 0xD5) & 0xFF) or ((c << 1) & 0xFF) end
  return c
end
-- one request as a raw MSPv2 frame ($X<) in mLRS bridge frames (0x66, seq, size, up to 57 bytes)
function BR.send(body)
  local f, c = { 36, 88, 60 }, 0
  for i = 1, #body do f[#f + 1] = body[i] c = BR.crc(c, body[i]) end
  f[#f + 1] = c
  local i = 1
  while i <= #f do
    local n = math.min(57, #f - i + 1)
    local e = { 0x66, 0, n }   -- mLRS "mb" envelope 0x81 (see T.envFrame in telem.lua)
    for k = 0, n - 1 do e[k + 4] = f[i + k] end
    out[#out + 1] = { crsf = e, cmd = 0x81 }
    i = i + n
  end
end
local function mspSend(cmd, payload)
  payload = payload or {}
  mLast = { cmd, payload }
  local body = { 0, cmd % 256, floor(cmd / 256), #payload % 256, floor(#payload / 256) }
  for i = 1, #payload do body[#body + 1] = payload[i] end
  if mspViaNow == "CRSF" and BR.path ~= "native" then
    BR.send(body)
    if BR.path == "bridge" then mOn = false return end
  end
  local per = mspViaNow == "S.Port" and 5 or 57
  local i, first = 1, true
  repeat
    local c = { 0x40 + (first and 0x10 or 0) + mSeq }
    mSeq = (mSeq + 1) % 16
    for k = i, math.min(#body, i + per - 1) do c[#c + 1] = body[k] end
    i, first = i + per, false
    if mspViaNow == "S.Port" then
      while #c < 6 do c[#c + 1] = 0 end
      out[#out + 1] = c
    else
      local d = { 0xC8, 0xEA }
      for k = 1, #c do d[k + 2] = c[k] end
      out[#out + 1] = { crsf = d, cmd = 0x7A }
    end
  until i > #body
  mOn = false
end
local function mspRepeat() if mLast then mspSend(mLast[1], mLast[2]) end end

local function rowOf(name)
  for _, r in ipairs(LIST) do if r[2] == name then return r end end
  return nil
end
local function u16(b, o) return (b[o] or 0) + (b[o + 1] or 0) * 256 end
local function u32(b, o) return u16(b, o) + u16(b, o + 2) * 65536 end
local VSIZE = { [0] = 1, [1] = 1, [2] = 2, [3] = 2, [4] = 4, [5] = 4 }
local function decode(t, b, o)
  if t == 0 then return b[o] or 0 end
  if t == 1 then local v = b[o] or 0 return v >= 128 and v - 256 or v end
  if t == 2 then return u16(b, o) end
  if t == 3 then local v = u16(b, o) return v >= 32768 and v - 65536 or v end
  if t == 4 then return u32(b, o) end
  if t == 5 then return b2f(b[o] or 0, b[o + 1] or 0, b[o + 2] or 0, b[o + 3] or 0) end
  return nil
end
local function encode(t, raw, into)
  if t == 5 then local f = f2b(raw) for k = 1, 4 do into[#into + 1] = f[k] end return into end
  local n = VSIZE[t] or 1
  raw = floor(raw + 0.5)
  if raw < 0 then raw = raw + 2 ^ (8 * n) end
  for _ = 1, n do into[#into + 1] = raw % 256 raw = floor(raw / 256) end
  return into
end
local MC_PLAT = { MULTIROTOR = true, TRICOPTER = true, HELICOPTER = true }
local function forgetPids()
  for _, r in ipairs(LIST) do if r.pid then vals[r[2]] = nil end end
end

-- a Betaflight reply for a row: the block read (all its rows get their values), the block read just
-- before a save (the save goes out on fresh bytes), the SET's answer, the read-back after it
function BFX.reply(cmd, b, err)
  local name = pend and pend.name
  local r = name and rowOf(name)
  if not r or not r.bf then return end
  local get = r.bf[1]
  if pend.bfset then
    if cmd ~= pend.bfset then return end
    if err then phase, phaseCol = "Not saved: Betaflight refused the value", "bad" pend = nil return end
    IN.dirty = true   -- set in RAM: stored by the EEPROM write (disarmed)
    pend = { name = name, check = pend.set, checkRaw = pend.setRaw, tries = 0, bfget = get }
    mspSend(get)
    return
  end
  if cmd ~= get then return end
  if err or #b < (BFX.mod.MINLEN[get] or 0) then
    if not err then P.stats.bad = P.stats.bad + 1 end
    if pend.check or pend.bfpre then phase, phaseCol = "No answer: check the value in Betaflight Configurator", "warn" end
    pend = nil
    vals[name], naAt[name] = false, os.clock()
    return
  end
  BFX.blk[get] = b
  if get == 111 then IN.rtype = b[23] or 0 BFX.mod.ratesType(IN.rtype) end
  if pend.bfpre then
    -- the save, on the bytes just read: only this row's field changes
    local set = BFX.mod.SET[get]
    pend.bfpre, pend.bfset = nil, set
    mspSend(set, BFX.mod.patch(r, b, pend.setRaw))
    return
  end
  for _, x in ipairs(LIST) do
    if x.bf and x.bf[1] == get and x[2] ~= name then
      if BFX.mod.present(x, b) then
        local v = BFX.mod.raw(x, b) * x.k
        gotValue(x[2], v, f2b(v), nil, x)
      else
        vals[x[2]], naAt[x[2]] = false, os.clock()   -- not in this build (no dyn notch / RPM filter)
      end
    end
  end
  if not BFX.mod.present(r, b) then
    if pend.check then phase, phaseCol = "Not in this Betaflight build", "warn" end
    pend = nil
    vals[name], naAt[name] = false, os.clock()
    return
  end
  local raw = BFX.mod.raw(r, b)
  local same = nil
  if pend.check then same = raw == pend.checkRaw end
  gotValue(name, raw * r.k, f2b(raw * r.k), same)
end

-- one complete INAV reply
local function mspReply(cmd, b, err)
  P.stats.rx = P.stats.rx + 1
  answered, silent, quietAt = true, 0, nil
  if not pend then return end
  local m = pend.m
  -- each housekeeping answer must be for its own command: over ELRS a late or repeated reply to an
  -- earlier request can arrive in between (an error with command 0 is INAV refusing the MSP version)
  if m == "variant" then
    if cmd ~= MSP_FC_VARIANT and not (err and cmd == 0) then return end
    pend = nil
    if err then IN.state = "old" return end   -- an INAV before 9.0 answers a v2 request with an error
    IN.variant = string.char(b[1] or 63, b[2] or 63, b[3] or 63, b[4] or 63)
    IN.state = (IN.variant == "INAV" and "version") or (IN.variant == "BTFL" and BFX.load and "bfapi") or "notinav"
    return
  end
  if m == "bfapi" then
    -- MSP_API_VERSION -> protocol, major, minor: 1.46 = Betaflight 4.5, 1.47 = 2025.12, 1.48 = 2026.6
    -- (2026.6 only appends to the blocks read here: RPM filter fields after byte 49 of
    -- MSP_FILTER_CONFIG, battery profile after MSP_STATUS_EX; checked against msp.c 2026.6.2)
    if cmd ~= BFX.API and not (err and cmd == 0) then return end
    pend = nil
    local maj, mnr = b[2] or 0, b[3] or 0
    IN.bfapi = string.format("%d.%d", maj, mnr)
    if err or maj ~= 1 or mnr < 46 or mnr > 48 then IN.state = "bfold" return end
    if not BFX.mod then
      local ok, mod = pcall(BFX.load)
      if not ok or type(mod) ~= "table" then IN.state, IN.bfErr = "bfold", tostring(mod) return end
      BFX.mod = mod
    end
    BFX.mod.forVersion(mnr)
    LIST, BFX.blk = BFX.mod.rows, {}
    vals, vbytes, edit = {}, {}, nil
    sel, top, grp, focus, tabCur, lastSel = 0, 0, nil, "tabs", nil, nil
    rebuild()
    IN.state = "version"
    return
  end
  if m == "version" and IN.variant == "BTFL" then
    if cmd ~= MSP_FC_VERSION and not (err and cmd == 0) then return end
    pend = nil
    -- 4.5 sends 4.5.5; 2025.12 and later send the year since 2000 (25.12.5, build/version.h FC_CALVER_BASE_YEAR)
    local y = b[1] or 0
    if IN.bfapi ~= "1.46" then y = y + 2000 end
    IN.ver = err and "?" or string.format("%d.%d.%d", y, b[2] or 0, b[3] or 0)
    IN.state = "ready"
    return
  end
  if m == "version" then
    if cmd ~= MSP_FC_VERSION and not (err and cmd == 0) then return end
    pend = nil
    if err then IN.state = "old" return end
    IN.ver = string.format("%d.%d.%d", b[1] or 0, b[2] or 0, b[3] or 0)
    -- INAV 9.0.x speaks MSPv2 over the radio link but answers the setting commands without the
    -- setting's name and value: msp_shared.c gave each reply a buffer of size 0, and the "Safe"
    -- writes those two use skip a full buffer (fixed in 9.1.0-RC1, INAV commit 922536955).
    -- X20S + ELRS + INAV 9.0.0, 2026-11-23: every value read as 0.
    local maj, mnr = b[1] or 0, b[2] or 0
    IN.state = (maj > 9 or (maj == 9 and mnr >= 1)) and "ready" or (maj == 9 and "buggy" or "old")
    return
  end
  if m == "status" and IN.variant == "BTFL" then
    -- MSP_STATUS_EX -> cycle u16, i2c u16, sensors u16, flight mode flags u32 (bit 0 = ARM, always
    -- the first box), PID profile u8, load u16, profile count u8, rate profile u8
    if cmd ~= BFX.STATUS_EX then return end
    pend = nil
    if not err and #b >= 15 then
      IN.armed, IN.armedAt = (b[7] or 0) % 2 == 1, os.clock()
      local pp, rp = b[11], b[15]
      -- another profile became active (a radio switch, the OSD): its values are read again
      if (IN.profile ~= nil and IN.profile ~= pp) or (IN.rprof ~= nil and IN.rprof ~= rp) then
        vals, vbytes, BFX.blk = {}, {}, {}
      end
      IN.profile, IN.rprof = pp, rp
    end
    return
  end
  if m == "status" then
    if cmd ~= MSP2_INAV_STATUS then return end
    pend = nil
    if not err and #b >= 13 then
      IN.armed, IN.armedAt = floor(u32(b, 10) / 4) % 2 == 1, os.clock()
    end
    return
  end
  if m == "store" then
    -- only the EEPROM write's own answer (X20S + ELRS + INAV 9.1, 2026-11-24: another reply taken
    -- as it said "NOT stored", yet the value was there after a reboot)
    if cmd ~= MSP_EEPROM_WRITE then return end
    pend = nil
    if err then
      -- INAV refuses the write only while armed: the change stays pending and is written once
      -- INAV itself says it is disarmed (never given up)
      IN.armed, IN.armedAt, IN.storeHold = true, os.clock(), os.clock() + STATUS_EVERY
      IN.stored = "wait"
      if edit then phase, phaseCol = "Set in " .. BFX.fcName() .. " now, stored after the disarm", "warn" end
      return
    end
    IN.dirty, IN.stored = false, "ok"
    if edit then phase, phaseCol = "Saved, verified and stored", "ok" end
    return
  end
  if IN.variant == "BTFL" then BFX.reply(cmd, b, err) return end
  local name = pend.name
  if not name then return end
  if pend.set then
    if cmd ~= M_SET_SETTING then return end
    if err then
      phase, phaseCol = "Not saved: INAV refused the value", "bad"
      pend = nil
      return
    end
    -- INAV took the value (in RAM): it needs the EEPROM write, whatever the read-back says
    IN.dirty = true
    pend = { name = name, check = pend.set, checkRaw = pend.setRaw, tries = 0 }
    mspSend(M_SETTING, zname(name))
    return
  end
  if pend.check then
    if cmd ~= M_SETTING then return end
    local mt, r = IN.meta[name], rowOf(name)
    if err or not mt or #b < (VSIZE[mt.t] or 1) then
      if not err then P.stats.bad = P.stats.bad + 1 end
      pend = nil phase, phaseCol = "No answer: check the value in INAV Configurator", "warn" return
    end
    local raw = decode(mt.t, b, 1)
    local same = (mt.t == 5) and sameBytes(f2b(raw), f2b(pend.checkRaw)) or raw == pend.checkRaw
    gotValue(name, raw * ((r and r.k) or 1), f2b(raw), same)
    return
  end
  if cmd ~= M_SETTING_INFO then return end
  if err then
    pend = nil
    if name == "platform_type" then IN.plat = "?" return end
    vals[name], naAt[name] = false, os.clock()
    return
  end
  -- name, pgn, type, section, mode, min, max, index, profile, count, [names], value. A reply
  -- for another name, or without its value, is not taken (n/a, counted as bad): never a 0 made up
  local i = 1
  while b[i] and b[i] ~= 0 do i = i + 1 end
  local bad = not b[i] or string.char((table.unpack or unpack)(b, 1, i - 1)) ~= name
  i = i + 1
  local t, sec, mode = (b[i + 2] or 0) % 8, (b[i + 3] or 0), (b[i + 4] or 0)
  local mn = u32(b, i + 5)
  if mn >= 2147483648 then mn = mn - 4294967296 end
  local mx = u32(b, i + 9)
  local prof = b[i + 15]
  i = i + 17
  local look = nil
  if mode == 0x40 then
    look = {}
    for _ = mn, mx do
      local s0 = i
      while b[i] and b[i] ~= 0 do i = i + 1 end
      look[#look + 1] = string.char((table.unpack or unpack)(b, s0, i - 1))
      i = i + 1
    end
  end
  if bad or #b < i + (VSIZE[t] or 1) - 1 or not VSIZE[t] then
    P.stats.bad = P.stats.bad + 1
    pend = nil
    if name == "platform_type" then IN.plat = "?" return end
    vals[name], naAt[name] = false, os.clock()
    return
  end
  local raw = decode(t, b, i)
  if sec == 0x10 and prof and IN.profile ~= prof then   -- CONTROL_VALUE: the active control profile
    if IN.profile ~= nil then forgetPids() end
    IN.profile = prof
  end
  if name == "platform_type" then
    pend = nil
    local p = look and look[(raw or 0) - mn + 1] or tostring(raw)
    if IN.plat ~= nil and IN.plat ~= "?" and IN.plat ~= p then forgetPids() end
    IN.plat = p
    return
  end
  IN.meta[name] = { t = t, min = mn, max = mx, look = look }
  local r = rowOf(name)
  if r then
    local k = r.k or 1
    if look then
      r[9], r.o, r[5], r[6], r[7], r[8] = "lookup", look, 0, #look - 1, 1, 0
    elseif t ~= 5 then
      r[5], r[6] = mn * k, mx * k
    end
  end
  if look then raw = (raw or 0) - mn end
  gotValue(name, (raw or 0) * ((r and not look and r.k) or 1), f2b(raw or 0))
end

-- one MSP chunk from the FC
local function mspChunk(c)
  if #c < 1 then return end
  local st = c[1]
  local start, sq = floor(st / 16) % 2 == 1, st % 16
  local i = 2
  if start then
    local ver = floor(st / 32) % 4
    mErr, mBuf, mOn = st >= 128, {}, true
    if ver == 2 then
      mCmd, mSize, i = u16(c, 3), u16(c, 5), 7
    else
      mCmd, mSize, i = c[3] or 0, c[2] or 0, 4
    end
  elseif not mOn or ((mRxSeq + 1) % 16) ~= sq then
    mOn = false
    return
  end
  mRxSeq = sq
  while i <= #c and #mBuf < mSize do mBuf[#mBuf + 1] = c[i] i = i + 1 end
  if #mBuf >= mSize then
    mOn = false
    if BR.path == nil and mspViaNow == "CRSF" then BR.path = "native" end
    if BR.path ~= "bridge" then mspReply(mCmd, mBuf, mErr) end
  end
end

-- raw MSP from the mLRS bridge ($X> / $X! version 2, $M> / $M! version 1), byte by byte
function BR.byte(x)
  if BR.st == 0 then if x == 36 then BR.st = 1 end return end
  if BR.st == 1 then
    if x == 88 or x == 77 then BR.v2, BR.st = x == 88, 2 else BR.st = 0 end
    return
  end
  if BR.st == 2 then
    if x == 62 or x == 33 then BR.err, BR.st, BR.hdr, BR.crc_ = x == 33, 3, {}, 0 else BR.st = 0 end
    return
  end
  if BR.st == 3 then   -- header: v2 flag, cmd lo, cmd hi, size lo, size hi; v1 size, cmd
    BR.hdr[#BR.hdr + 1] = x
    BR.crc_ = BR.v2 and BR.crc(BR.crc_, x) or (BR.crc_ ~ x)
    if #BR.hdr == (BR.v2 and 5 or 2) then
      BR.need = BR.v2 and (BR.hdr[4] + BR.hdr[5] * 256) or BR.hdr[1]
      BR.buf, BR.st = {}, BR.need > 0 and 4 or 5
      if BR.need > 1024 then BR.st = 0 end
    end
    return
  end
  if BR.st == 4 then
    BR.buf[#BR.buf + 1] = x
    BR.crc_ = BR.v2 and BR.crc(BR.crc_, x) or (BR.crc_ ~ x)
    if #BR.buf >= BR.need then BR.st = 5 end
    return
  end
  BR.st = 0
  if x ~= BR.crc_ then P.stats.bad = P.stats.bad + 1 return end
  if BR.path == nil then BR.path = "bridge" end
  if BR.path ~= "bridge" then return end
  mspReply(BR.v2 and (BR.hdr[2] + BR.hdr[3] * 256) or BR.hdr[2], BR.buf, BR.err)
end
function BR.input(data)
  local e = 2 + (data[2] or 0)
  if e > #data then e = #data end
  for i = 3, e do BR.byte(data[i]) end
end
P._mspChunk = mspChunk   -- test harness

local function mspPoll()
  for _ = 1, 12 do
    if mspViaNow == "S.Port" then
      local ok, f = pcall(function() return rx:popFrame() end)
      if not ok or not f then return end
      if f:primId() == 0x32 then
        local a = f:appId()
        local lo, hi = T.split32(f:value())
        local c = { a % 256, floor(a / 256) % 256, lo % 256, floor(lo / 256), hi % 256, floor(hi / 256) }
        local key = table.concat(c, ",")
        if key ~= mPrev then mPrev = key mspChunk(c) end   -- receivers can repeat a frame
      end
    else
      local ok, cmd, data = pcall(function() return rx:popFrame(0x7B, 0x7B) end)
      if not ok or cmd == nil then return end
      if cmd == 0x7B and data and #data >= 3 then
        local c = {}
        for k = 3, #data do c[#c + 1] = data[k] end
        mspChunk(c)
      end
    end
  end
end

local function mspRead(name)
  if BFX.mod and IN.variant == "BTFL" then
    local r = rowOf(name)
    if not r or not r.bf then vals[name], naAt[name] = false, os.clock() return end
    pend = { name = name, tries = 0 }
    mspSend(r.bf[1])
    return
  end
  pend = { name = name, tries = 0 }
  mspSend(M_SETTING_INFO, zname(name))
end
local function mspSave(name, bytes)
  if BFX.mod and IN.variant == "BTFL" then
    -- the block is read again first and the field set on those fresh bytes (bfReply), so a
    -- change made elsewhere since (Configurator, another profile) is never written back old
    local r = rowOf(name)
    if not r or not r.bf then return end
    local raw = floor(b2f(bytes[1], bytes[2], bytes[3], bytes[4]) / r.k + 0.5)
    raw = math.max(r.rmin, math.min(r.rmax, raw))
    pend = { name = name, set = bytes, setRaw = raw, tries = 0, bfpre = true }
    mspSend(r.bf[1])
    return
  end
  local mt, r = IN.meta[name], rowOf(name)
  if not mt then phase, phaseCol = "Read it first", "warn" return end
  local v = b2f(bytes[1], bytes[2], bytes[3], bytes[4])
  local raw
  if mt.look then raw = floor(v + 0.5) + mt.min
  else raw = v / ((r and r.k) or 1) if mt.t ~= 5 then raw = floor(raw + 0.5) end end
  if mt.t ~= 5 then raw = math.max(mt.min, math.min(mt.max, raw)) end
  pend = { name = name, set = bytes, setRaw = raw, tries = 0 }
  mspSend(M_SET_SETTING, encode(mt.t, raw, zname(name)))
end
-- the profile line for the page: "INAV 9.1.0  profile 2 MULTIROTOR"
function P.inavLine()
  if link ~= "MSP" then return nil end
  if IN.variant == "BTFL" then
    local rt = BFX.mod and IN.rtype and BFX.mod.RATES_TYPES[IN.rtype]   -- known once the rates are read
    return string.format("Betaflight %s  PID profile %s  rate profile %s%s", IN.ver or "?",
      IN.profile and tostring(IN.profile + 1) or "?", IN.rprof and tostring(IN.rprof + 1) or "?",
      rt and ("  " .. rt .. " rates") or "")
  end
  return string.format("INAV %s  profile %s %s", IN.ver or "?", IN.profile and tostring(IN.profile + 1) or "?", IN.plat or "?")
end
-- a PID row of the profile that isn't active: why it can't be edited (nil = it can)
local function pidLock(r)
  if link ~= "MSP" or not r or not r.pid or not IN.plat or IN.plat == "?" then return nil end
  local mc = MC_PLAT[IN.plat] == true
  if r.pid == "mc" and not mc then return "Hover PIDs: switch the VTOL to multirotor to edit" end
  if r.pid == "fw" and mc then return "Plane PIDs: switch the VTOL to fixed wing to edit" end
  return nil
end
readReqMsp, mspPollNow = mspRead, mspPoll
-- armed as the radio's telemetry says, or as INAV itself said in its last status (MSP link)
local function armedEff(s)
  return s.armed == true or (link == "MSP" and IN.armed == true)
end

-- ---------------------------------------------------------------- page state
local sel, top, grp = 0, 0, nil   -- selected row in vis (0 none), list scroll, group shown
-- two columns (Marcin 2026-11-15): the cursor is on the tabs (the wheel moves a highlight, nothing
-- is opened or read until ENTER) or on the open tab's rows (the wheel stays inside that tab)
local focus, tabCur, lastSel = "tabs", nil, nil
local bitCur = 1
local saveReq = nil
local msgAt = 0

function P.init(telem, list, extraPath, ilist, bfLoad)
  T, LIST = telem, list
  APLIST, ILIST, BFX.load = list, ilist, bfLoad
  T.onMavlite = P.onCrsf   -- telem.lua reads the CRSF queue and hands MAVlite replies here
  T.onMavEnv = P.onMavEnv  -- ... and the mLRS bridge frames (MAVLink)
  if extraPath then
    local f = io.open(extraPath, "r")
    if f then
      local lines = {}
      for _ = 1, 2000 do
        local ok, l = pcall(f.read, f, "*l")
        if not ok or l == nil then break end
        lines[#lines + 1] = l
      end
      pcall(f.close, f)
      P.extra.file = true
      parseExtra(table.concat(lines, "\n"))
    end
  end
  rebuild()
end

function P.missionReset()
  SND.state, SND.items, SND.i, SND.msg = "off", nil, 0, ""
  MS.state, MS.count, MS.stamp, MS.items, MS.next, MS.last, MS.checkAt = "off", nil, nil, {}, 1, 0, -100
  if pend and pend.m then pend = nil end
end

function P.reset()
  SND.state, SND.items, SND.i, SND.msg = "off", nil, 0, ""
  MS.state, MS.count, MS.stamp, MS.items, MS.next, MS.last, MS.checkAt = "off", nil, nil, {}, 1, 0, -100
  answered, silent, quietAt = false, 0, nil
  vals, vbytes, out, pend, qOn = {}, {}, {}, nil, nil
  edit, draft, editBase, phase, saveReq = nil, nil, nil, "", nil
  sel, top, grp, link, prev, rxSt = 0, 0, nil, nil, nil, nil
  focus, tabCur, lastSel = "tabs", nil, nil
  mvSt, mvSkip = 0, 0
  IN.state, IN.variant, IN.ver, IN.meta, IN.profile, IN.plat = "off", nil, nil, {}, nil, nil
  IN.dirty, IN.storeReq, IN.stored, mspViaNow, mLast, BR.path = false, false, nil, nil, nil, nil
  IN.bfapi, IN.rprof, IN.rtype, BFX.blk, IN.bfErr = nil, nil, nil, {}, nil
  IN.armed, IN.armedAt, IN.statusAt = nil, nil, -10
  if APLIST then LIST = APLIST end
  if LIST then rebuild() end
end

-- why the page can't work now (nil = it can)
local function blocked(s)
  if s.fc == "INAV/BF" and ILIST then
    if s.link ~= "S.Port" and s.link ~= "CRSF" then
      return "Parameters need S.Port, F.Port, ELRS or Crossfire", "This link: " .. tostring(s.link or "none")
    end
    if T.alive() == false then return "No telemetry", "" end
    if IN.state == "bfold" then
      if IN.bfErr then   -- the version is fine, bfplist.lua did not load (missing file, memory)
        return "Betaflight parameter list did not load", "bfplist.lua: " .. IN.bfErr
      end
      return "Parameters need Betaflight 4.5, 2025.12 or 2026.6", "This one answers MSP API " .. tostring(IN.bfapi or "?") .. " (4.5 = 1.46, 2025.12 = 1.47, 2026.6 = 1.48).\nOther versions: Betaflight Configurator."
    end
    if IN.state == "notinav" then
      return "Parameters need ArduPilot, INAV or Betaflight", "This flight controller is " .. tostring(IN.variant) .. "."
    end
    if IN.state == "buggy" then
      return "Parameters need INAV 9.1 or later", "This one is INAV " .. tostring(IN.ver) .. ": 9.0 sends setting values over the radio link empty (fixed in INAV 9.1.0)."
    end
    if IN.state == "old" then
      return "Parameters need INAV 9.1 or later", (IN.ver and ("This one is INAV " .. IN.ver) or "This INAV answers MSP version 1 only over the radio link") .. ". Update INAV, or use INAV Configurator."
    end
    if quietAt then
      return "The flight controller doesn't answer", "INAV 9.1+ over ELRS / Crossfire 150 Hz or S.Port / F.Port.\nmLRS: Tx Ser Port = cbridge with the MSP-over-cbridge Tx firmware."
    end
    return nil
  end
  if s.fc ~= "ArduPilot" then return "Parameters need ArduPilot, INAV or Betaflight", "" end
  if s.link ~= "S.Port" and s.link ~= "CRSF" then
    return "Parameters need S.Port, F.Port, ELRS or Crossfire", "This link: " .. tostring(s.link or "none")
  end
  if T.alive() == false then return "No telemetry", "" end
  if quietAt then
    if link == "MAVLINK" then
      return "The flight controller doesn't answer", "mLRS cbridge: MAVLink arrives, but no parameter answers yet."
    end
    if s.link == "CRSF" then
      return "The flight controller doesn't answer",
        "ELRS / Crossfire: needs ArduPlane Stratos firmware (MAVlite over CRSF). mLRS: set Tx Ser Port = cbridge. ELRS MAVLink mode can't carry it."
    end
    return "The flight controller doesn't answer", "S.Port / F.Port: check SERIALn_PROTOCOL 10 (passthrough) on the receiver's port."
  end
  return nil
end

local function failedText(s, name)
  local m = s.msgs
  for i = #m, math.max(1, #m - 4), -1 do
    if string.find(m[i].text, "failed (" .. name .. ")", 1, true) then return true end
  end
  return false
end

-- the tab on screen; only its rows are read (Marcin 2026-11-14: the other tabs are read when opened,
-- so the link is free again as soon as the open tab is in; values already read are kept)
local function curGroup() return vis[sel] and vis[sel][1] or grp or groups[1] end

local function nextRead(rowsShown)
  if link == "MSP" then
    if IN.plat == nil and IN.variant ~= "BTFL" then return "platform_type" end   -- INAV VTOL only
  elseif qOn == nil then return "Q_ENABLE" end
  if edit then return nil end
  local g = curGroup()
  local r = vis[sel]
  if r and vals[r[2]] == nil then return r[2] end
  for i = 1, #rowsShown do local n = rowsShown[i][2] if vals[n] == nil then return n end end
  for _, x in ipairs(vis) do if x[1] == g and vals[x[2]] == nil then return x[2] end end
  -- mLRS: answers get lost now and then, so an n/a row is asked again every 30 s
  if link == "MAVLINK" then
    local t = os.clock()
    for _, x in ipairs(vis) do
      local nm = x[2]
      if x[1] == g and vals[nm] == false and t - (naAt[nm] or 0) >= 30 then naAt[nm] = t return nm end
    end
  end
  return nil
end
local shown = {}   -- rows on screen at the last paint

-- seconds added to the timeouts: ELRS / Crossfire wait for an uplink slot and a telemetry slot
local function slowness()
  if link == "MAVLINK" or (link == "MSP" and BR.path == "bridge") then return 2 end
  if link == "CRSF" or (link == "MSP" and mspViaNow == "CRSF") then return 1 end
  return 0
end
local QUIET_RETRY_S = 15   -- with no answer at all, try again this often (firmware just flashed)

-- next mission request, if any is due; true when one was sent
-- the editor asks whether the aircraft is a quadplane (VTOL items): Q_ENABLE is read again each
-- time the editor opens (it may have been changed on the PARAMS page or in a GCS)
local qWanted = false
function P.isQuadplane() return qOn end
function P.requestQ() qWanted = true end

local function missionNext(s, now)
  if qWanted then
    qWanted = false
    pend = { name = "Q_ENABLE", tries = 0 }
    send(REQ_READ, nameBytes("Q_ENABLE", {}))
    return true
  end
  if SND.state == "clear" and link == "MAVLINK" then
    -- standard ArduPilot: the count (home + the items), then the aircraft asks for each one.
    -- ArduPilot takes an upload while armed; the editor doesn't send one then (as on Stratos)
    if s.armed then SND.state, SND.msg = "failed", refused(14) return false end
    SND.state, SND.i, SND.req, SND.home = "write", 0, nil, { s.homeLat or 0, s.homeLon or 0 }
    pend = { m = "upload", tries = 0 }
    mavSend(44, { (#SND.items + 1) % 256, floor((#SND.items + 1) / 256), MV.sys, MV.comp, 0 })
    return true
  end
  if SND.state == "write" and link == "MAVLINK" then return false end   -- waiting for the aircraft's requests
  if SND.state == "clear" then
    pend = { m = "clear", tries = 0 }
    send(MISSION_CLEAR_ALL, {})
    return true
  end
  if SND.state == "write" then
    local seq = SND.i + 1
    pend = { m = "write", seq = seq, tries = 0 }
    send(MISSION_ITEM_INT, itemPayload(seq, SND.items[seq]))
    return true
  end
  if not P.missionOn and SND.state ~= "verify" then return false end
  if MS.state == "items" then
    pend = { m = "item", seq = MS.next, tries = 0 }
    send(MISSION_REQUEST_INT, { MS.next % 256, math.floor(MS.next / 256) })
    return true
  end
  -- the count again every 10 s while disarmed (a GCS may have uploaded a new mission); in flight
  -- only until there is a first mission
  if now >= MS.checkAt and (not s.armed or MS.count == nil) then
    MS.checkAt = now + MISSION_RECHECK_S
    pend = { m = "count", tries = 0 }
    send(MISSION_REQUEST_LIST, {})
    return true
  end
  return false
end

local function service(s, pageOpen)
  if quietAt and os.clock() - quietAt >= QUIET_RETRY_S then quietAt, silent = nil, 0 end
  if blocked(s) then
    if pend or #out > 0 then out, pend = {}, nil end
    return
  end
  -- mLRS with Tx Ser Port = cbridge: MAVLink through the bridge (any ArduPilot)
  MV.usedAt = os.clock()
  -- The mLRS module sends nothing over the bridge until the radio has sent it something
  -- (X20S + Nomad 2026-11-14: no 0xAA at all until the test widget's first request). So a GCS
  -- HEARTBEAT goes out every 2 s on CRSF, as Mission Planner sends one: it wakes the bridge, and
  -- ELRS / TBS ignore the frame type.
  P.armedNow = armedEff(s)
  local inav = s.fc == "INAV/BF" and ILIST ~= nil
  if not inav and s.link == "CRSF" and T.crsfPush and os.clock() - (MV.hbAt or -10) >= 2 then
    MV.hbAt = os.clock()
    local p = mavPacket(0, { 0, 0, 0, 0, 6, 8, 0, 0, 3 })   -- type GCS, autopilot invalid, MAVLink 3
    local e = { 0x66, 0, #p }
    for k = 1, #p do e[k + 3] = p[k] end
    pcall(T.crsfPush, 0x81, e)
  end
  local want = s.link
  if want == "CRSF" and T.bridgeAt and os.clock() - T.bridgeAt < 3 then want = "MAVLINK" end
  if inav then want = "MSP" end
  if link ~= want or (want == "MSP" and mspViaNow ~= s.link) then
    if (link == "MSP") ~= (want == "MSP") or LIST ~= (want == "MSP" and ILIST or APLIST) then
      -- ArduPilot <-> INAV: the other list, nothing read yet
      LIST = want == "MSP" and ILIST or APLIST
      vals, vbytes, qOn, edit = {}, {}, nil, nil
      sel, top, grp, focus, tabCur, lastSel = 0, 0, nil, "tabs", nil, nil
      rebuild()
    end
    if want == "MSP" then
      mspViaNow, mOn, mPrev, BR.path, BR.st = s.link, false, nil, nil, 0
      IN.state, IN.meta, IN.profile, IN.plat = "variant", {}, nil, nil
    end
    link = want
    mvSt, mvSkip, MV.found = 0, 0, false
    out, pend = {}, nil
    answered, silent, quietAt = false, 0, nil
    if not openSensors() then link = nil return end
  end
  poll()
  local now = os.clock()
  if #out > 0 then
    pushOne()
    if #out == 0 and pend then pend.at = now end
    return
  end
  if link == "MSP" then
    if pend and pend.m then
      -- INAV housekeeping (variant, version, EEPROM write): three tries
      if not pend.at then pend.at = now end
      if now - pend.at < READ_TIMEOUT + slowness() then return end
      pend.tries = pend.tries + 1
      if pend.tries >= 3 then
        local m = pend.m
        pend = nil
        if m == "store" then
          IN.stored, IN.storeHold = "fail", now + 10
          if edit then phase, phaseCol = "Saved, NOT stored yet (no answer): trying again", "warn" end
        else
          silent = silent + 1
          if silent >= 2 then quietAt = now end
        end
        return
      end
      pend.at = nil
      mspRepeat()
      return
    end
    if not pend then
      if IN.state == "variant" then pend = { m = "variant", tries = 0 } mspSend(MSP_FC_VARIANT) return end
      if IN.state == "bfapi" then pend = { m = "bfapi", tries = 0 } mspSend(BFX.API) return end
      if IN.state == "version" then pend = { m = "version", tries = 0 } mspSend(MSP_FC_VERSION) return end
      if IN.state ~= "ready" then return end
      -- INAV's own arming state, every 2 s (1 s while a change waits for its EEPROM write)
      if now - IN.statusAt >= (IN.dirty and 1 or STATUS_EVERY) then
        IN.statusAt = now
        pend = { m = "status", tries = 0 }
        mspSend(IN.variant == "BTFL" and BFX.STATUS_EX or MSP2_INAV_STATUS)
        return
      end
      -- stored only when INAV said "disarmed" within the last 3 s (and the radio agrees)
      if IN.dirty and not s.armed and IN.armed == false and now - (IN.armedAt or -10) < 3
         and now >= (IN.storeHold or 0) then
        pend = { m = "store", tries = 0 }
        mspSend(MSP_EEPROM_WRITE)
        return
      end
    end
  end
  if pend and pend.m then
    -- mission request: its own retries, never touches the parameter rows or "no answer"
    if not pend.at then pend.at = now end
    local slow = slowness()
    if now - pend.at < READ_TIMEOUT + slow then return end
    pend.tries = pend.tries + 1
    -- mLRS: an answer lost now and then, so two more tries
    local tries = link == "MAVLINK" and MISSION_TRIES + 2 or MISSION_TRIES
    if pend.tries >= tries and (pend.m == "clear" or pend.m == "write" or pend.m == "upload") then
      pend = nil
      SND.state, SND.msg = "failed", "No answer: check the mission in a GCS"
      return
    end
    if pend.tries >= tries then
      pend = nil
      MS.state, MS.checkAt = (MS.state == "items") and "error" or MS.state, now + MISSION_RECHECK_S
      if MS.state == "error" then MS.state = "idle" end
      return
    end
    pend.at = nil
    if pend.m == "upload" then
      if SND.req and SND.req >= #SND.items then
        -- the last item went out but its MISSION_ACK was lost (the aircraft is done and won't
        -- send it again): read the mission back and compare, as after every send
        pend = nil
        SND.state, SND.msg = "verify", "Checking..."
        MS.state, MS.stamp, MS.checkAt = "idle", nil, -100
        return
      end
      if SND.req then sendUploadItem(SND.req)
      else mavSend(44, { (#SND.items + 1) % 256, floor((#SND.items + 1) / 256), MV.sys, MV.comp, 0 }) end
    elseif pend.m == "count" then send(MISSION_REQUEST_LIST, {})
    elseif pend.m == "clear" then send(MISSION_CLEAR_ALL, {})
    elseif pend.m == "write" then send(MISSION_ITEM_INT, itemPayload(pend.seq, SND.items[pend.seq]))
    else send(MISSION_REQUEST_INT, { pend.seq % 256, math.floor(pend.seq / 256) }) end
    return
  end
  -- a save goes first: a row read still waiting for its answer is dropped (only the open tab is
  -- read now, so one is often waiting); it is asked again later, and a late answer is kept anyway.
  -- Not a read of the row being saved: its old value would then look like the save's answer.
  if saveReq and pend and pend.name and not pend.set and not pend.check and pend.name ~= saveReq.name then pend = nil end
  if pend then
    if not pend.at then pend.at = now end
    local name = pend.name
    -- ArduPilot answers a name it doesn't have with a text only: take it as soon as it is here
    if not pend.set and failedText(s, name) then
      answered, silent = true, 0
      vals[name], pend, naAt[name] = false, nil, os.clock()
      if name == "Q_ENABLE" then qOn = false rebuild() end
      return
    end
    -- ELRS / Crossfire: the request waits for an uplink slot and the answer for a telemetry slot
    local slow = slowness()
    if now - pend.at < (pend.set and SET_TIMEOUT or READ_TIMEOUT) + slow then return end
    if pend.set then
      -- mLRS: ArduPilot saves at once but sends its answer only when the link has room, so it
      -- can be lost on a full link: read the value back instead (a read is safe to repeat)
      if link == "MAVLINK" then
        pend = { name = name, check = pend.set, tries = 0 }
        phase, phaseCol = "Checking...", "warn"
        send(REQ_READ, nameBytes(name, {}))
        return
      end
      -- never sent again by itself: the save may have happened
      phase, phaseCol = link == "MSP" and ("No answer: check the value in " .. BFX.fcName() .. " Configurator") or "No answer: check the value in a GCS", "warn"
      vals[name], pend = nil, nil
      return
    end
    pend.tries = pend.tries + 1
    -- mLRS: a reply lost now and then on the slower link, so more tries before "n/a"
    if pend.tries >= (link == "MAVLINK" and 4 or READ_TRIES) or failedText(s, name) then
      if pend.check then   -- the read-back after a save got no answer either
        phase, phaseCol = "No answer: check the value in a GCS", "warn"
        vals[name], pend = nil, nil
        return
      end
      if not answered then
        -- nothing ever came back on this link: say so, keep the values unread, retry later
        silent = silent + 1
        pend = nil
        if silent >= 2 then quietAt = now end
        return
      end
      vals[name], pend, naAt[name] = false, nil, os.clock()
      if name == "Q_ENABLE" then qOn = false rebuild() end
    else
      pend.at = nil
      if link == "MSP" then mspRepeat() else send(REQ_READ, nameBytes(name, {})) end
    end
    return
  end
  if saveReq and link == "MSP" then
    mspSave(saveReq.name, saveReq.bytes)
    saveReq = nil
    return
  end
  if saveReq then
    pend = { name = saveReq.name, set = saveReq.bytes, tries = 0 }
    send(PARAM_SET, nameBytes(saveReq.name, { saveReq.bytes[1], saveReq.bytes[2], saveReq.bytes[3], saveReq.bytes[4] }))
    saveReq = nil
    return
  end
  if pageOpen then
    local n = nextRead(shown)
    if n then
      readReq(n)
      -- mLRS: each answer waits behind the telemetry stream, so 1 more unread row (P.readAhead) is
      -- asked at once. Not more: ArduPilot queues parameter answers and sends them only when the
      -- link has room, so piling up requests on a full mLRS link loses answers (X20S 2026-11-14).
      -- Its answer fills in whenever it comes; a lost one is asked again later.
      if link == "MAVLINK" then
        local now2, extra, g = os.clock(), 0, curGroup()
        for _, rows in ipairs({ shown, vis }) do   -- rows on screen first, then the rest of the tab
          for _, r in ipairs(rows) do
            local nm = r[2]
            if extra >= (P.readAhead or 1) then break end
            if r[1] == g and nm ~= n and vals[nm] == nil and now2 - (prefAt[nm] or -10) >= 4 then
              prefAt[nm] = now2
              send(REQ_READ, nameBytes(nm, {}))
              extra = extra + 1
            end
          end
        end
      end
      return
    end
  end
  if link ~= "MSP" then missionNext(s, now) end
end

function P.wakeup(s) service(s, true) end          -- PARAMS page open
function P.missionWakeup(s) service(s, false) end  -- any other page: mission download only

-- ---------------------------------------------------------------- editing
local function flash(t, c) status, statusCol, msgAt = t, c, os.clock() end

-- in flight only the gains and trims can be changed, and only with "Edit in flight" set to
-- "Gains and trim" (P.flightEdit, set by ui.lua); everything else is view only while armed
local FLIGHT_GROUPS = { ["PID"] = true, ["Q PID"] = true, ["TRIM"] = true, ["FW PID"] = true, ["MC PID"] = true }
P.flightEdit = false
local function locked(s, r)
  if pidLock(r) then return true end   -- INAV VTOL: the other profile's PIDs
  if not armedEff(s) then return false end
  return not (P.flightEdit and r and (FLIGHT_GROUPS[r[1]] or r.fl))
end

local function openEdit(s)
  local r = vis[sel]
  if not r then return end
  local v = vals[r[2]]
  if v == nil then flash("Reading " .. r[2] .. "...", "warn") return end
  if v == false then
    -- n/a may also be answers lost on the way (mLRS): ENTER asks once more
    vals[r[2]] = nil
    flash("Reading " .. r[2] .. " again...", "warn")
    if not pend and #out == 0 then readReq(r[2]) end
    return
  end
  edit, draft, editBase, phase, bitCur = r, v, v, "", 1
  if pidLock(r) then phase, phaseCol = pidLock(r), "warn"
  elseif locked(s, r) then phase, phaseCol = "Armed: view only", "warn"
  elseif armedEff(s) then phase, phaseCol = "In flight: saves go to the aircraft now", "warn" end
  -- read it again: the value may have been changed in a GCS since
  if not pend and #out == 0 then readReq(r[2]) end
  -- INAV PID row: the active platform is read again too (the VTOL switch may have moved it)
  if r.pid and link == "MSP" then IN.plat = nil end
end

local function nudge(d)
  local r = edit
  -- one step from the value as it is (an autotuned 0.0036 goes to 0.0041, not onto a 0.0005 grid);
  -- rounded to a thousandth of the step only to drop float noise
  local v = draft + d * r[7]
  v = floor(v / r[7] * 1000 + 0.5) * r[7] / 1000
  -- a row whose minimum is -1 (e.g. Q_ASSIST_SPEED, RTL_ALTITUDE): -1 is a setting of its own, so
  -- the step below 0 goes to -1 and the step up from -1 to 0 (never -0.1 and the like)
  if r[5] == -1 then
    if d < 0 and draft <= 0 then v = -1 elseif d > 0 and draft < 0 then v = 0 end
  end
  if r[5] then v = math.max(r[5], math.min(r[6], v)) end
  draft = v
  phase = ""
end

local function toggleBit(i)
  local bit = BITS[i][1]
  local v = draft == -1 and ALL_MASK or draft
  if v < 0 then v = ALL_MASK end
  if floor(v / 2 ^ bit) % 2 == 1 then v = v - 2 ^ bit else v = v + 2 ^ bit end
  draft, phase = v, ""
end

local function save(s)
  if pidLock(edit) then phase, phaseCol = pidLock(edit), "bad" return end
  if locked(s, edit) then phase, phaseCol = "Disarm to save", "bad" return end
  if pend and pend.set then return end
  local b = f2b(draft)
  if sameBytes(b, vbytes[edit[2]]) then edit = nil return end   -- unchanged: just close
  saveReq = { name = edit[2], bytes = b }
  phase, phaseCol = "Saving...", "warn"
end

-- ---------------------------------------------------------------- drawing
local boxes = {}
local function box(kind, i, x, y, w, h) boxes[#boxes + 1] = { k = kind, i = i, x = x, y = y, w = w, h = h } end

local function button(x, y, w, h, label, col, C)
  lcd.color(C.tile)
  lcd.drawFilledRectangle(x, y, w, h)
  lcd.color(col)
  lcd.drawRectangle(x, y, w, h)
  local tw, th = lcd.getTextSize(label)
  lcd.drawText(x + floor((w - tw) / 2), y + floor((h - th) / 2), label)
end

local function drawEditor(W, H, y0, y1, s, ctx)
  local C = ctx.COL
  local fBig, fMid, fSmall = ctx.fontFor(H)
  local r = edit
  local bx, bw = floor(W * 0.06), W - 2 * floor(W * 0.06)
  local by, bh = y0 + 4, y1 - y0 - 8
  lcd.color(C.panel)
  lcd.drawFilledRectangle(bx, by, bw, bh)
  lcd.color(C.home)
  lcd.drawRectangle(bx, by, bw, bh)
  lcd.font(fMid)
  local _, th = lcd.getTextSize("A")
  lcd.color(C.txt)
  lcd.drawText(bx + 8, by + 4, r[2])
  lcd.color(C.dim)
  lcd.drawText(bx + bw - 8, by + 4, r[3], RIGHT)
  local bh2 = th + 8
  local btnY = by + bh - bh2 - 6
  -- a number gets a second row above (Marcin 2026-11-28, as the X18): ten steps, labelled with
  -- that jump in the row's units (+500 on a 50 ms step, +5 on 0.5 m); only when the large value,
  -- the range line and the status still fit, else just - / + (and the hold) as before
  local big
  if r[10] ~= "bits" and not r[9] and r[7] then
    lcd.font(H >= 400 and FONT_XXL or FONT_XL)
    local _, vh = lcd.getTextSize("0")
    lcd.font(fMid)
    if bh - (th + 8) - (bh2 + 6) - (th + 4) - (bh2 + 6) >= vh + 2 * th + 8 then
      local v, dec = 10 * r[7], 0
      while dec < 6 and math.abs(v * 10 ^ dec - floor(v * 10 ^ dec + 0.5)) > 1e-6 do dec = dec + 1 end
      big = string.format("%." .. dec .. "f", v)
    end
  end
  local btn1Y = big and (btnY - bh2 - 6) or btnY
  local stY = btn1Y - th - 4
  local col = phaseCol == "ok" and C.ok or phaseCol == "bad" and C.bad or C.warn
  if r[10] == "bits" then
    local cur = draft
    lcd.color(cur == 0 and C.ok or cur == -1 and C.bad or C.warn)
    lcd.drawText(bx + bw / 2, by + 4, fmtVal(r, cur), CENTERED)
    local gy, gh = by + th + 10, stY - (by + th + 10) - 2
    local rows = math.ceil(#BITS / 2)
    -- the checks in the mid font (one size up) when the rows have room, else the small one
    lcd.font(th + 2 <= floor(gh / rows) and fMid or fSmall)
    local _, sh = lcd.getTextSize("A")
    local rh = math.max(sh, floor(gh / rows))
    local cw = floor((bw - 24) / 2)
    for i, b in ipairs(BITS) do
      local cx = bx + 8 + (i > rows and cw + 8 or 0)
      local cy = gy + ((i - 1) % rows) * rh
      if i == bitCur then
        lcd.color(C.tile) lcd.drawFilledRectangle(cx - 2, cy, cw, rh)
        lcd.color(C.home) lcd.drawRectangle(cx - 2, cy, cw, rh)
      end
      local sk = skipped(cur, b[1])
      lcd.color(C.txt)
      lcd.drawText(cx + 2, cy + floor((rh - sh) / 2), b[2])
      lcd.color(sk and C.warn or C.ok)
      lcd.drawText(cx + cw - 6, cy + floor((rh - sh) / 2), sk and "SKIP" or "CHECK", RIGHT)
      box("bit", i, cx - 2, cy, cw, rh)
    end
    lcd.font(fMid)
  else
    -- the value large, in the middle of the free space; range and the value before under it
    lcd.font(fMid)
    local _, sh = lcd.getTextSize("A")
    lcd.font(H >= 400 and FONT_XXL or FONT_XL)
    local _, vh = lcd.getTextSize("0")
    local top0 = by + th + 8
    -- range + previous value in the mid font: one line when it fits, else two
    local range = r.free and ("step " .. tostring(r[7]) .. ", range checked by ArduPilot")
      or r[9] and ("option " .. floor(draft + 0.5) .. " of 0-" .. floor(r[6]))
      or string.format("%s to %s, step %s", fmtNum(r, r[5]), fmtNum(r, r[6]), tostring(r[7]))
    local was = "was " .. fmtNum(r, editBase)
    lcd.font(fMid)
    local one = lcd.getTextSize(range .. "   " .. was) <= bw - 12
    local nl = one and 1 or 2
    lcd.font(H >= 400 and FONT_XXL or FONT_XL)
    local vy = top0 + math.max(0, floor((stY - top0 - vh - sh * nl - 4) / 2))
    lcd.color(draft == editBase and C.txt or C.home)
    lcd.drawText(bx + bw / 2, vy, fmtNum(r, draft), CENTERED)
    lcd.font(fMid)
    lcd.color(C.dim)
    if one then
      lcd.drawText(bx + bw / 2, vy + vh + 4, range .. "   " .. was, CENTERED)
    else
      lcd.drawText(bx + bw / 2, vy + vh + 4, range, CENTERED)
      lcd.drawText(bx + bw / 2, vy + vh + 4 + sh, was, CENTERED)
    end
  end
  lcd.color(col)
  lcd.drawText(bx + bw / 2, stY, phase, CENTERED)
  -- buttons: wheel + ENTER walk them on the check list (cursor past the 18 checks)
  local labels = r[10] == "bits" and { "All on", "All off", "Back", "Save" } or { "-", "+", "Back", "Save" }
  local n = #labels
  local gap = 8
  local w1 = floor((bw - 16 - gap * (n - 1)) / n)
  for i, l in ipairs(labels) do
    local x = bx + 8 + (i - 1) * (w1 + gap)
    local hot = r[10] == "bits" and bitCur == #BITS + i
    button(x, btnY, w1, bh2, l, (l == "Save" and C.ok) or (hot and C.home) or C.dim, C)
    if hot then lcd.color(C.home) lcd.drawRectangle(x - 1, btnY - 1, w1 + 2, bh2 + 2) end
    box("btn", l, x, btnY, w1, bh2)
    -- the ten-step buttons over - and +
    if big and i <= 2 then
      local id = i == 1 and "-10" or "+10"
      button(x, btn1Y, w1, bh2, (i == 1 and "-" or "+") .. big, C.dim, C)
      box("btn", id, x, btn1Y, w1, bh2)
    end
  end
end

function P.paint(w, W, H, s, u, ctx)
  local C = ctx.COL
  local fBig, fMid, fSmall = ctx.fontFor(H)
  boxes = {}
  local barH = floor(H * 0.09)
  ctx.topBar(w, 0, 0, W, barH, s, u, H)
  lcd.color(C.panel)
  lcd.drawFilledRectangle(0, barH, W, H - barH)
  local why, more = blocked(s)
  if why then
    lcd.font(fMid)
    lcd.color(C.warn)
    lcd.drawText(W / 2, floor(H * 0.42), why, CENTERED)
    lcd.font(fSmall)
    lcd.color(C.dim)
    -- the explanation in lines that fit the screen ("\n" starts a new one, long ones wrap at a
    -- space), as on the X18 (2026-11-25: the INAV / mLRS text ran off the sides)
    local lines, maxW = {}, W - 12
    for part in string.gmatch((more or "") .. "\n", "(.-)\n") do
      local cur = ""
      for word in string.gmatch(part, "%S+") do
        local try = cur == "" and word or (cur .. " " .. word)
        if cur ~= "" and lcd.getTextSize(try) > maxW then lines[#lines + 1] = cur cur = word else cur = try end
      end
      if cur ~= "" then lines[#lines + 1] = cur end
    end
    local _, lh = lcd.getTextSize("A")
    for i, t in ipairs(lines) do lcd.drawText(W / 2, floor(H * 0.56) + (i - 1) * (lh + 2), t, CENTERED) end
    return
  end
  lcd.font(fMid)
  local _, th = lcd.getTextSize("A")
  lcd.font(fSmall)
  local _, sh = lcd.getTextSize("A")
  lcd.font(fMid)
  -- bottom: a thin hint line; above it, under the rows only, one touch-high row with the row arrows
  -- and BACK (Marcin 2026-11-15). The tab column runs down to the hint line.
  local hintH = sh + 6
  local botH = math.max(th + 10, floor(H * 0.1))
  local hy = H - hintH
  local y0, y1 = barH, hy - botH
  -- left: the groups
  local tabW = floor(W * 0.2)
  local cur = vis[sel] and vis[sel][1] or grp or groups[1]
  local hiTab = focus == "tabs" and (tabCur or cur) or nil   -- the wheel's highlight on the tabs
  local gh = floor((hy - y0) / math.max(1, #groups))
  lcd.font(gh < th + 2 and fSmall or fMid)
  local _, gth = lcd.getTextSize("A")
  for i, g in ipairs(groups) do
    local gy = y0 + (i - 1) * gh
    if g == cur then
      lcd.color(C.tile) lcd.drawFilledRectangle(0, gy, tabW, gh)
      lcd.color(C.home) lcd.drawFilledRectangle(0, gy, 3, gh)
    end
    if g == hiTab then
      lcd.color(C.home) lcd.drawRectangle(1, gy + 1, tabW - 2, gh - 2)
      lcd.drawRectangle(2, gy + 2, tabW - 4, gh - 4)
    end
    lcd.color((g == cur or g == hiTab) and C.txt or C.dim)
    lcd.drawText(8, gy + floor((gh - gth) / 2), g)
    box("grp", g, 0, gy, tabW, gh)
  end
  lcd.color(C.tile)
  lcd.drawFilledRectangle(tabW, y0, 1, hy - y0)
  -- right: the selected group's rows
  lcd.font(fMid)
  local rowH = th + 8
  local rows = {}
  for i, r in ipairs(vis) do if r[1] == cur then rows[#rows + 1] = i end end
  local fit = math.max(1, floor((y1 - y0) / rowH))
  local hidden = #rows > fit   -- rows that don't all fit: up / down arrows in the bottom row
  local selPos = 0
  for k, i in ipairs(rows) do if i == sel then selPos = k end end
  if selPos > 0 and sel ~= lastSel then   -- follow the wheel; the arrows move the list freely
    if selPos <= top then top = selPos - 1 end
    if selPos > top + fit then top = selPos - fit end
  end
  lastSel = sel
  top = math.max(0, math.min(top, #rows - fit))
  shown = {}
  local lx = tabW + 8
  for k = top + 1, math.min(#rows, top + fit) do
    local i = rows[k]
    local r = vis[i]
    local ry = y0 + (k - top - 1) * rowH
    if i == sel then
      lcd.color(C.tile) lcd.drawFilledRectangle(tabW + 1, ry, W - tabW - 1, rowH)
      lcd.color(C.home) lcd.drawRectangle(tabW + 1, ry, W - tabW - 1, rowH)
    end
    local v = vals[r[2]]
    lcd.color(v == false and C.dim or C.txt)
    lcd.drawText(lx, ry + 4, r[2])
    local vc = C.txt
    if v == nil or v == false then vc = C.dim
    elseif r[10] == "bits" then vc = v == 0 and C.ok or v == -1 and C.bad or C.warn end
    lcd.color(vc)
    lcd.drawText(W - 8, ry + 4, fmtVal(r, v), RIGHT)
    box("row", i, tabW + 1, ry, W - tabW - 1, rowH)
    shown[#shown + 1] = r
  end
  -- bottom row (row column): BACK at the right end; left of it, only when rows are hidden, the up
  -- (left half) and down (right half) arrows, split like the X18 tab strip, bright while rows are hidden
  lcd.color(C.bar) lcd.drawFilledRectangle(tabW + 1, y1, W - tabW - 1, botH)
  local bw = floor(W * 0.16)
  local bx = W - bw - 4
  lcd.color(C.tile) lcd.drawFilledRectangle(bx, y1 + 4, bw, botH - 8)
  lcd.color(C.home) lcd.drawRectangle(bx, y1 + 4, bw, botH - 8)
  lcd.font(fMid)
  lcd.drawText(bx + floor(bw / 2), y1 + floor((botH - th) / 2), "< BACK", CENTERED)
  box("back", 0, bx, y1, bw + 4, botH)
  if hidden then
    local rx = tabW + 1
    local rw = bx - 4 - rx
    local hw = floor(rw / 2)
    lcd.color(C.tile)
    lcd.drawFilledRectangle(rx + hw, y1 + 4, 1, botH - 8)
    lcd.drawFilledRectangle(bx - 3, y1 + 4, 1, botH - 8)
    local cy, sz = y1 + floor(botH / 2), math.max(5, floor(botH / 5))
    local ux, dx = rx + floor(hw / 2), rx + hw + floor(hw / 2)
    lcd.color(top > 0 and C.txt or C.tile)
    lcd.drawFilledTriangle(ux - sz, cy + floor(sz / 2), ux, cy - floor(sz / 2), ux + sz, cy + floor(sz / 2))
    lcd.color(top + fit < #rows and C.txt or C.tile)
    lcd.drawFilledTriangle(dx - sz, cy - floor(sz / 2), dx, cy + floor(sz / 2), dx + sz, cy - floor(sz / 2))
    box("rowup", 0, rx, y1, hw, botH)
    box("rowdn", #rows - fit, rx + hw, y1, rw - hw, botH)   -- i = the largest top
  end
  -- hint line: what the keys do, or the last notice; how far the reading is
  lcd.color(C.bar) lcd.drawFilledRectangle(0, hy, W, hintH)
  lcd.color(C.tile) lcd.drawFilledRectangle(0, hy, W, 1)
  lcd.font(fSmall)
  local by = hy + floor((hintH - sh) / 2)
  -- the open tab only: the others are read when they are opened
  local got, nTab = 0, 0
  for _, r in ipairs(vis) do
    if r[1] == cur then nTab = nTab + 1 if vals[r[2]] ~= nil then got = got + 1 end end
  end
  if os.clock() - msgAt < 3 and status ~= "" then
    lcd.color(statusCol == "warn" and C.warn or C.txt)
    lcd.drawText(6, by, status)
  else
    lcd.color(C.dim)
    local hint = focus == "tabs" and "Wheel: pick group   ENTER: open   RTN: next page" or "ENTER: edit   RTN: groups"
    if edit then
      hint = edit[10] == "bits" and "Wheel: move   ENTER: CHECK/SKIP or button   RTN: back"
        or "Wheel: change   ENTER: save   RTN: back"
    end
    if armedEff(s) then hint = (P.flightEdit and "ARMED: gains/trim only   " or "ARMED: view only   ") .. hint end
    local il = P.inavLine()
    if il then hint = il .. (IN.dirty and "  NOT STORED" or "") .. "   " .. hint end
    lcd.drawText(6, by, hint)
  end
  lcd.color(got < nTab and C.warn or C.ok)
  lcd.drawText(W - 6, by, got < nTab and string.format("reading %d/%d", got, nTab) or (nTab .. " read"), RIGHT)
  -- while reading: a thin bar under the top bar, filled as far as the reading is
  if got < nTab and nTab > 0 then
    local pbH = math.max(3, floor(H * 0.012))
    lcd.color(C.tile) lcd.drawFilledRectangle(0, y0, W, pbH)
    if got > 0 then lcd.color(C.home) lcd.drawFilledRectangle(0, y0, floor(W * got / nTab), pbH) end
  end
  if edit then drawEditor(W, H, y0, hy, s, ctx) end
end

-- ---------------------------------------------------------------- input
local function bitsMax() return #BITS + 4 end

local function editKey(s, key)
  local bits = edit[10] == "bits"
  if key == "back" then edit = nil return true end
  -- armed: view only (the wheel moves nothing, ENTER closes), unless a gain/trim may be set in flight
  if locked(s, edit) then
    if key == "enter" then edit = nil else phase, phaseCol = "Armed: view only", "warn" end
    return true
  end
  if bits then
    if key == "left" then bitCur = (bitCur - 2) % bitsMax() + 1
    elseif key == "right" then bitCur = bitCur % bitsMax() + 1
    elseif key == "enter" then
      if bitCur <= #BITS then toggleBit(bitCur)
      elseif bitCur == #BITS + 1 then draft, phase = 0, ""
      elseif bitCur == #BITS + 2 then draft, phase = -1, ""   -- All off: ArduPilot's -1 skips every check
      elseif bitCur == #BITS + 3 then edit = nil
      else save(s) end
    end
    return true
  end
  if key == "left" then nudge(-1) elseif key == "right" then nudge(1)
  elseif key == "enter" then save(s) end   -- unchanged (or just saved): closes
  return true
end

-- the open tab's rows as vis indexes
local function rowsOf(g)
  local t = {}
  for i, r in ipairs(vis) do if r[1] == g then t[#t + 1] = i end end
  return t
end

-- open a tab: its rows get the cursor, first row selected (and only now is it read)
local function openTab(g)
  grp, tabCur, top = g, g, 0
  local rs = rowsOf(g)
  if rs[1] then sel, focus = rs[1], "rows" else sel, focus = 0, "tabs" end
end

-- RTN / BACK: rows -> the tab column (highlight on the open tab), tab column -> next page
local function goBack()
  if focus == "rows" then
    grp = curGroup()
    focus, tabCur, sel = "tabs", grp, 0
    return true
  end
  return "next"
end

-- key: "left" | "right" | "enter" | "back"; returns true (used), false (not), or "next" (turn the page)
function P.key(s, key)
  -- "doesn't answer" and the like: ENTER or RTN turns the page
  if blocked(s) then return (key == "enter" or key == "back") and "next" or false end
  if edit then return editKey(s, key) end
  local d = key == "right" and 1 or key == "left" and -1 or 0
  if focus == "tabs" then
    -- the wheel only moves the highlight: nothing is opened or read until ENTER
    local cur = tabCur or curGroup()
    if d ~= 0 then
      for i, g in ipairs(groups) do
        if g == cur then tabCur = groups[math.max(1, math.min(#groups, i + d))] break end
      end
      return true
    end
    if key == "enter" then openTab(tabCur or curGroup()) return true end
    if key == "back" then return goBack() end
    return false
  end
  -- rows: the wheel stays inside the open tab
  if d ~= 0 then
    local rs = rowsOf(curGroup())
    for k, i in ipairs(rs) do
      if i == sel then sel = rs[math.max(1, math.min(#rs, k + d))] break end
    end
    return true
  end
  if key == "enter" then openEdit(s) return true end
  if key == "back" then return goBack() end
  return false
end

local function hit(x, y)
  for i = #boxes, 1, -1 do
    local b = boxes[i]
    if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then return b end
  end
  return nil
end

-- a tap; returns true or "next"
function P.tap(s, x, y)
  if blocked(s) then return "next" end
  local b = hit(x, y)
  if edit then
    if not b then return true end
    if locked(s, edit) then
      if b.k == "btn" and b.i == "Back" then edit = nil else phase, phaseCol = "Armed: view only", "warn" end
      return true
    end
    if b.k == "bit" then bitCur = b.i toggleBit(b.i)
    elseif b.k == "btn" then
      if b.i == "-" then nudge(-1) elseif b.i == "+" then nudge(1)
      elseif b.i == "-10" then nudge(-10) elseif b.i == "+10" then nudge(10)
      elseif b.i == "All on" then draft, phase = 0, ""
      elseif b.i == "All off" then draft, phase = -1, ""
      elseif b.i == "Back" then edit = nil
      elseif b.i == "Save" then save(s) end
    end
    return true
  end
  -- a tap next to the buttons does nothing (user 2026-11-15: a near-miss on an arrow turned the
  -- page); the page is left with RTN or BACK only, twice from the rows
  if not b then return true end
  if b.k == "back" then return goBack() end
  if b.k == "rowup" then top = math.max(0, top - 1) return true end
  if b.k == "rowdn" then top = math.min(b.i, top + 1) return true end
  if b.k == "grp" then openTab(b.i) return true end
  if b.k == "row" then
    sel, focus, grp, tabCur = b.i, "rows", vis[b.i][1], vis[b.i][1]
    openEdit(s)
    return true
  end
  return true
end

-- holding - / + (user 2026-11-26): after HOLD_DELAY s the step repeats until the finger lifts,
-- faster after HOLD_FAST s. Only the draft changes: nothing goes to the flight controller before Save.
-- The UI calls P.holdStart at the touch, P.holdEnd at the lift or a drag; the steps run in P.wakeup.
local HOLD = { delay = 0.5, fast = 2.5, slowS = 0.1, fastS = 0.05, cur = nil, wake = P.wakeup,
  btn = { ["-"] = -1, ["+"] = 1, ["-10"] = -10, ["+10"] = 10 } }   -- cur: { d, row, at, nextAt, fired }
function P.holdStart(s, x, y)
  HOLD.cur = nil
  if not edit or blocked(s) or locked(s, edit) then return end
  local b = hit(x, y)
  local d = b and b.k == "btn" and HOLD.btn[b.i]
  if d then
    local t = os.clock()
    HOLD.cur = { d = d, row = edit, at = t, nextAt = t + HOLD.delay }
  end
end
-- true when the hold has repeated: the lift then adds no step of its own
function P.holdEnd()
  local h = HOLD.cur
  HOLD.cur = nil
  return h ~= nil and h.fired == true
end
function P.wakeup(s)
  HOLD.wake(s)
  local h = HOLD.cur
  if not h then return end
  if edit ~= h.row or blocked(s) or locked(s, edit) then HOLD.cur = nil return end
  local t = os.clock()
  if t - h.at > 60 then HOLD.cur = nil return end   -- a lift that never arrived
  if t < h.nextAt then return end
  nudge(h.d)
  h.fired = true
  h.nextAt = t + ((t - h.at >= HOLD.fast) and HOLD.fastS or HOLD.slowS)
  if lcd and lcd.invalidate then pcall(lcd.invalidate) end
end

-- the PARAMS page was left (user 2026-11-27): a value changed but not saved is dropped, and the
-- editor is closed, so coming back shows the flight controller's value. A Save already pressed
-- (queued, or sent and waiting for its answer) still goes through.
function P.leave()
  HOLD.cur = nil
  if saveReq or (pend and pend.set) then return end
  if edit then edit, draft, editBase, phase = nil, nil, nil, "" end
end

function P.editing() return edit ~= nil end
function P.phase() return phase end
function P.valueOf(name) return vals[name] end   -- test harness
function P._draft() return draft, editBase, edit and edit[2] end
function P._tab() return curGroup() end   -- test harness
function P._list() return LIST end   -- test harness
function P._focus() return focus end   -- test harness
function P._hi() return focus == "tabs" and (tabCur or curGroup()) or nil end   -- test harness
function P._row() return vis[sel] and vis[sel][2] or nil end   -- test harness

-- sensor check page line
local function pendName()
  if not pend then return "idle" end
  if pend.m == "count" then return "waiting mission count" end
  if pend.m == "item" then return "waiting mission item " .. pend.seq end
  if pend.m == "clear" then return "waiting mission clear" end
  if pend.m == "write" then return "waiting mission write " .. pend.seq end
  -- INAV steps (variant, version, status, store) and the mission upload carry no name, only
  -- their step (TX16S MK3 + INAV 2026-11-25: the Sensor check page stopped on a nil name)
  return "waiting " .. tostring(pend.name or pend.m or "?")
end
function P.missionDebug()
  if not P.missionOn then return nil end
  if MS.state == "items" then return string.format("mission: %d/%d", MS.next - 1, MS.last) end
  if MS.state == "done" then return string.format("mission: %d items", #MS.items) end
  return "mission: " .. MS.state
end
function P.debug()
  local md = P.missionDebug()
  return P.debugCore() .. (md and ("  " .. md) or "")
end
function P.debugCore()
  local X = P.extra
  if X.file then
    return string.format("Params: %s%s tx %d rx %d bad %d  %s%s  params.txt +%d skipped %d%s", (link == "MSP" and BR.path) and ("MSP " .. BR.path) or tostring(link or "-"),
      (T and ((T.bridgeN or 0) > 0 or T.bridgeInfo)) and (" bridge " .. (T.bridgeN or 0) .. (T.bridgeInfo and (" (" .. T.bridgeInfo .. ")") or "")) or "",
      P.stats.tx, P.stats.rx, P.stats.bad, pendName(), quietAt and "  NO ANSWER" or "",
      X.added, X.skipped,
      X.badLine and (" (line " .. X.badLine .. ")") or "")
  end
  return string.format("Params: %s%s tx %d rx %d bad %d  %s%s", (link == "MSP" and BR.path) and ("MSP " .. BR.path) or tostring(link or "-"),
    (T and ((T.bridgeN or 0) > 0 or T.bridgeInfo)) and (" bridge " .. (T.bridgeN or 0) .. (T.bridgeInfo and (" (" .. T.bridgeInfo .. ")") or "")) or "", P.stats.tx, P.stats.rx,
    P.stats.bad, pendName(), quietAt and "  NO ANSWER" or "")
end

return P
