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
  mLRS with Tx Ser Port = cbridge passes the aircraft's MAVLink stream to the radio in CRSF frames
  0xAA (chunk byte, size, up to 58 bytes) and takes MAVLink back the same way (telem.lua reads them,
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
-- queue one MAVLink message as mLRS bridge frames (58 bytes each)
local function mavSend(msgid, pl)
  local p = mavPacket(msgid, pl)
  local i = 1
  while i <= #p do
    local n = math.min(58, #p - i + 1)
    local e = { 0, n }
    for k = 0, n - 1 do e[k + 3] = p[i + k] end
    out[#out + 1] = { crsf = e, cmd = 0xAA }
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

local function openSensors()
  tx, rx = nil, nil
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
-- test builds: one line for the X20 map page's diagnostic (a photo of a frozen screen shows it)
function P.diag()
  return string.format("M %s %s/%s q%d tx%d rx%d %s", MS.state, tostring(MS.next), tostring(MS.count),
    #out, P.stats.tx, P.stats.rx, tostring(link))
end
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

local function handle(id, b)
  P.stats.rx = P.stats.rx + 1
  answered, silent, quietAt = true, 0, nil
  if id == MISSION_COUNT or id == MISSION_ITEM_INT or id == MISSION_ACK then missionHandle(id, b) return end
  if id ~= PARAM_VALUE or #b < 5 then return end
  local name = string.char(table.unpack(b, 5, math.min(#b, 20)))
  local bytes = { b[1], b[2], b[3], b[4] }
  local v = b2f(b[1], b[2], b[3], b[4])
  for _, r in ipairs(LIST) do if r[2] == name then if r.free then autoStep(r, v) end break end end
  vals[name], vbytes[name] = v, bytes
  if name == "Q_ENABLE" then qOn = v >= 1 rebuild() end
  if pend and pend.name == name then
    local want = pend.set or pend.check
    if want then
      if sameBytes(bytes, want) then
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

local function poll()
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
local function readReq(name)
  -- an n/a row asked again (mLRS, every 30 s) gets one try, so it never holds up a save for long
  pend = { name = name, tries = (vals[name] == false and link == "MAVLINK") and 3 or 0 }
  send(REQ_READ, nameBytes(name, {}))
end

-- ---------------------------------------------------------------- page state
local sel, top, grp = 0, 0, nil   -- selected row in vis (0 none), list scroll, group shown
local bitCur = 1
local saveReq = nil
local msgAt = 0

function P.init(telem, list, extraPath)
  T, LIST = telem, list
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
  mvSt, mvSkip = 0, 0
  if LIST then rebuild() end
end

-- why the page can't work now (nil = it can)
local function blocked(s)
  if s.fc ~= "ArduPilot" then return "Parameters need ArduPilot", "INAV and Betaflight are not supported" end
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

local function nextRead(rowsShown)
  if qOn == nil then return "Q_ENABLE" end
  if edit then return nil end
  local r = vis[sel]
  if r and vals[r[2]] == nil then return r[2] end
  for i = 1, #rowsShown do local n = rowsShown[i][2] if vals[n] == nil then return n end end
  for _, x in ipairs(vis) do if vals[x[2]] == nil then return x[2] end end
  -- mLRS: answers get lost now and then, so an n/a row is asked again every 30 s
  if link == "MAVLINK" then
    local t = os.clock()
    for _, x in ipairs(vis) do
      local nm = x[2]
      if vals[nm] == false and t - (naAt[nm] or 0) >= 30 then naAt[nm] = t return nm end
    end
  end
  return nil
end
local shown = {}   -- rows on screen at the last paint

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
  if s.link == "CRSF" and T.crsfPush and os.clock() - (MV.hbAt or -10) >= 2 then
    MV.hbAt = os.clock()
    local p = mavPacket(0, { 0, 0, 0, 0, 6, 8, 0, 0, 3 })   -- type GCS, autopilot invalid, MAVLink 3
    local e = { 0, #p }
    for k = 1, #p do e[k + 2] = p[k] end
    pcall(T.crsfPush, 0xAA, e)
  end
  local want = s.link
  if want == "CRSF" and T.bridgeAt and os.clock() - T.bridgeAt < 3 then want = "MAVLINK" end
  if link ~= want then
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
  if pend and pend.m then
    -- mission request: its own retries, never touches the parameter rows or "no answer"
    if not pend.at then pend.at = now end
    local slow = (link == "MAVLINK" and 2) or (link == "CRSF" and 1) or 0
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
    local slow = (link == "MAVLINK" and 2) or (link == "CRSF" and 1) or 0
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
      phase, phaseCol = "No answer: check the value in a GCS", "warn"
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
      send(REQ_READ, nameBytes(name, {}))
    end
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
        local now2, extra = os.clock(), 0
        for _, rows in ipairs({ shown, vis }) do   -- rows on screen first, then the page's order
          for _, r in ipairs(rows) do
            local nm = r[2]
            if extra >= (P.readAhead or 1) then break end
            if nm ~= n and vals[nm] == nil and now2 - (prefAt[nm] or -10) >= 4 then
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
  missionNext(s, now)
end

function P.wakeup(s) service(s, true) end          -- PARAMS page open
function P.missionWakeup(s) service(s, false) end  -- any other page: mission download only

-- ---------------------------------------------------------------- editing
local function flash(t, c) status, statusCol, msgAt = t, c, os.clock() end

-- in flight only the gains and trims can be changed, and only with "Edit in flight" set to
-- "Gains and trim" (P.flightEdit, set by ui.lua); everything else is view only while armed
local FLIGHT_GROUPS = { ["PID"] = true, ["Q PID"] = true, ["TRIM"] = true }
P.flightEdit = false
local function locked(s, r)
  if not s.armed then return false end
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
  if locked(s, r) then phase, phaseCol = "Armed: view only", "warn"
  elseif s.armed then phase, phaseCol = "In flight: saves go to the aircraft now", "warn" end
  -- read it again: the value may have been changed in a GCS since
  if not pend and #out == 0 then readReq(r[2]) end
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
  local stY = btnY - th - 4
  local col = phaseCol == "ok" and C.ok or phaseCol == "bad" and C.bad or C.warn
  if r[10] == "bits" then
    local cur = draft
    lcd.color(cur == 0 and C.ok or cur == -1 and C.bad or C.warn)
    lcd.drawText(bx + bw / 2, by + 4, fmtVal(r, cur), CENTERED)
    lcd.font(fSmall)
    local _, sh = lcd.getTextSize("A")
    local gy, gh = by + th + 10, stY - (by + th + 10) - 2
    local rows = math.ceil(#BITS / 2)
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
    lcd.font(fSmall)
    local _, sh = lcd.getTextSize("A")
    lcd.font(H >= 400 and FONT_XXL or FONT_XL)
    local _, vh = lcd.getTextSize("0")
    local top0 = by + th + 8
    local vy = top0 + math.max(0, floor((stY - top0 - vh - sh - 4) / 2))
    lcd.color(draft == editBase and C.txt or C.home)
    lcd.drawText(bx + bw / 2, vy, fmtNum(r, draft), CENTERED)
    lcd.font(fSmall)
    lcd.color(C.dim)
    local range = r.free and ("step " .. tostring(r[7]) .. ", range checked by ArduPilot")
      or r[9] and ("option " .. floor(draft + 0.5) .. " of 0-" .. floor(r[6]))
      or string.format("%s to %s, step %s", fmtNum(r, r[5]), fmtNum(r, r[6]), tostring(r[7]))
    lcd.drawText(bx + bw / 2, vy + vh + 4, range .. "   was " .. fmtNum(r, editBase), CENTERED)
    lcd.font(fMid)
  end
  lcd.color(col)
  lcd.drawText(bx + bw / 2, stY, phase, CENTERED)
  -- buttons: wheel + ENTER walk them on the check list (cursor past the 18 checks)
  local labels = r[10] == "bits" and { "All on", "Back", "Save" } or { "-", "+", "Back", "Save" }
  local n = #labels
  local gap = 8
  local w1 = floor((bw - 16 - gap * (n - 1)) / n)
  for i, l in ipairs(labels) do
    local x = bx + 8 + (i - 1) * (w1 + gap)
    local hot = r[10] == "bits" and bitCur == #BITS + i
    button(x, btnY, w1, bh2, l, (l == "Save" and C.ok) or (hot and C.home) or C.dim, C)
    if hot then lcd.color(C.home) lcd.drawRectangle(x - 1, btnY - 1, w1 + 2, bh2 + 2) end
    box("btn", l, x, btnY, w1, bh2)
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
    lcd.drawText(W / 2, floor(H * 0.56), more, CENTERED)
    return
  end
  lcd.font(fMid)
  local _, th = lcd.getTextSize("A")
  local botH = th + 6
  local y0, y1 = barH, H - botH
  -- left: the groups
  local tabW = floor(W * 0.2)
  local cur = vis[sel] and vis[sel][1] or grp or groups[1]
  local gh = floor((y1 - y0) / math.max(1, #groups))
  lcd.font(gh < th + 2 and fSmall or fMid)
  local _, gth = lcd.getTextSize("A")
  for i, g in ipairs(groups) do
    local gy = y0 + (i - 1) * gh
    if g == cur then
      lcd.color(C.tile) lcd.drawFilledRectangle(0, gy, tabW, gh)
      lcd.color(C.home) lcd.drawFilledRectangle(0, gy, 3, gh)
    end
    lcd.color(g == cur and C.txt or C.dim)
    lcd.drawText(8, gy + floor((gh - gth) / 2), g)
    box("grp", g, 0, gy, tabW, gh)
  end
  lcd.color(C.tile)
  lcd.drawFilledRectangle(tabW, y0, 1, y1 - y0)
  -- right: the selected group's rows
  lcd.font(fMid)
  local rowH = th + 8
  local rows = {}
  for i, r in ipairs(vis) do if r[1] == cur then rows[#rows + 1] = i end end
  local fit = math.max(1, floor((y1 - y0) / rowH))
  local selPos = 0
  for k, i in ipairs(rows) do if i == sel then selPos = k end end
  if selPos > 0 then
    if selPos <= top then top = selPos - 1 end
    if selPos > top + fit then top = selPos - fit end
  end
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
  -- bottom: what the keys do, or the last notice; how far the reading is
  lcd.color(C.bar)
  lcd.drawFilledRectangle(0, y1, W, botH)
  lcd.font(fSmall)
  local _, sh = lcd.getTextSize("A")
  local by = y1 + floor((botH - sh) / 2)
  local got = 0
  for _, r in ipairs(vis) do if vals[r[2]] ~= nil then got = got + 1 end end
  if os.clock() - msgAt < 3 and status ~= "" then
    lcd.color(statusCol == "warn" and C.warn or C.txt)
    lcd.drawText(6, by, status)
  else
    lcd.color(C.dim)
    local hint = sel == 0 and "Wheel: pick a row   ENTER: next page" or "ENTER: edit   RTN: unselect"
    if edit then
      hint = edit[10] == "bits" and "Wheel: move   ENTER: CHECK/SKIP or button   RTN: back"
        or "Wheel: change   ENTER: save   RTN: back"
    end
    if s.armed then hint = (P.flightEdit and "ARMED: gains/trim only   " or "ARMED: view only   ") .. hint end
    lcd.drawText(6, by, hint)
  end
  lcd.color(got < #vis and C.warn or C.ok)
  lcd.drawText(W - 6, by, got < #vis and string.format("reading %d/%d", got, #vis) or (#vis .. " read"), RIGHT)
  if edit then drawEditor(W, H, y0, y1, s, ctx) end
end

-- ---------------------------------------------------------------- input
local function bitsMax() return #BITS + 3 end

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
      elseif bitCur == #BITS + 2 then edit = nil
      else save(s) end
    end
    return true
  end
  if key == "left" then nudge(-1) elseif key == "right" then nudge(1)
  elseif key == "enter" then save(s) end   -- unchanged (or just saved): closes
  return true
end

-- key: "left" | "right" | "enter" | "back"; returns true (used), false (not), or "next" (turn the page)
function P.key(s, key)
  if blocked(s) then return key == "enter" and "next" or false end
  if edit then return editKey(s, key) end
  if key == "right" then sel = math.min(#vis, sel + 1) return true end
  if key == "left" then sel = math.max(0, sel - 1) return true end
  if key == "enter" then
    if sel == 0 then return "next" end
    openEdit(s)
    return true
  end
  if key == "back" and sel > 0 then sel = 0 return true end
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
      elseif b.i == "All on" then draft, phase = 0, ""
      elseif b.i == "Back" then edit = nil
      elseif b.i == "Save" then save(s) end
    end
    return true
  end
  if not b then return "next" end
  if b.k == "grp" then
    grp = b.i
    sel, top = 0, 0
    return true
  end
  if b.k == "row" then
    sel = b.i
    openEdit(s)
    return true
  end
  return true
end

function P.editing() return edit ~= nil end
function P.phase() return phase end
function P.valueOf(name) return vals[name] end   -- test harness
function P._draft() return draft, editBase, edit and edit[2] end

-- sensor check page line
local function pendName()
  if not pend then return "idle" end
  if pend.m == "count" then return "waiting mission count" end
  if pend.m == "item" then return "waiting mission item " .. pend.seq end
  if pend.m == "clear" then return "waiting mission clear" end
  if pend.m == "write" then return "waiting mission write " .. pend.seq end
  return "waiting " .. pend.name
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
    return string.format("Params: %s%s tx %d rx %d bad %d  %s%s  params.txt +%d skipped %d%s", tostring(link or "-"),
      (T and ((T.bridgeN or 0) > 0 or T.bridgeInfo)) and (" bridge " .. (T.bridgeN or 0) .. (T.bridgeInfo and (" (" .. T.bridgeInfo .. ")") or "")) or "",
      P.stats.tx, P.stats.rx, P.stats.bad, pendName(), quietAt and "  NO ANSWER" or "",
      X.added, X.skipped,
      X.badLine and (" (line " .. X.badLine .. ")") or "")
  end
  return string.format("Params: %s%s tx %d rx %d bad %d  %s%s", tostring(link or "-"),
    (T and ((T.bridgeN or 0) > 0 or T.bridgeInfo)) and (" bridge " .. (T.bridgeN or 0) .. (T.bridgeInfo and (" (" .. T.bridgeInfo .. ")") or "")) or "", P.stats.tx, P.stats.rx,
    P.stats.bad, pendName(), quietAt and "  NO ANSWER" or "")
end

return P
