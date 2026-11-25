--[[
  mLRS "cbridge" test core: MAVLink v2 over the mLRS CRSF MAVLink envelope (CRSF frame 0xAA).
  Shared by the EdgeTX tool and the Ethos tool (Lua 5.2 with bit32, or Lua 5.4).

  Envelope (mLRS crsf_protocol.h tCrsfMavlinkEnvelope), CRSF payload after the frame type:
    byte 1  chunk byte (total_chunks:4 | current_chunk:4), 0 here
    byte 2  data size (max 58)
    byte 3+ MAVLink bytes; a MAVLink packet may be split over several envelopes
  Radio -> TX module: the module takes the bytes as the GCS side of its MAVLink stream (Tx Ser Port
  or Tx Ser Port2 = cbridge). TX module -> radio: every MAVLink byte the aircraft sends.
]]
local M = {}

-- bit operations: bit32 on EdgeTX (Lua 5.2), native operators on Ethos (Lua 5.4)
local band, bxor, shl, shr
if bit32 then
  band, bxor, shl, shr = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift
else
  band = load("return function(a, b) return a & b end")()
  bxor = load("return function(a, b) return a ~ b end")()
  shl = load("return function(a, n) return (a << n) & 0xFFFFFFFF end")()
  shr = load("return function(a, n) return a >> n end")()
end

-- CRC-16/MCRF4XX (MAVLink X.25)
local function crcAcc(b, crc)
  local tmp = bxor(b, band(crc, 0xFF))
  tmp = band(bxor(tmp, shl(tmp, 4)), 0xFF)
  return band(bxor(bxor(bxor(shr(crc, 8), shl(tmp, 8)), shl(tmp, 3)), shr(tmp, 4)), 0xFFFF)
end

local CRC_EXTRA = { [0] = 50, [20] = 214, [22] = 220 }

M.sysid, M.compid = 255, 190        -- what we send as (a GCS)
M.target, M.targetComp = nil, nil   -- the autopilot, from its HEARTBEAT
local txSeq = 0

-- float32 <-> 4 bytes (little endian), without string.pack (EdgeTX 5.2 has none)
local function f2b(v)
  if v == 0 then return { 0, 0, 0, 0 } end
  local sign = 0
  if v < 0 then sign = 1 v = -v end
  local e = math.floor(math.log(v, 2))   -- (no math.frexp on Lua 5.4)
  local m = v / 2 ^ e
  if m >= 2 then m = m / 2 e = e + 1 elseif m < 1 then m = m * 2 e = e - 1 end
  local mant = math.floor((m - 1) * 8388608 + 0.5)
  if mant >= 8388608 then mant = 0 e = e + 1 end
  e = e + 127
  return { mant % 256, math.floor(mant / 256) % 256, math.floor(mant / 65536) % 128 + (e % 2) * 128, sign * 128 + math.floor(e / 2) }
end
local function b2f(b1, b2, b3, b4)
  local sign = b4 >= 128 and -1 or 1
  local e = (b4 % 128) * 2 + math.floor(b3 / 128)
  local m = (b3 % 128) * 65536 + b2 * 256 + b1
  if e == 0 and m == 0 then return 0 end
  if e == 255 then return 0 / 0 end
  return sign * (1 + m / 8388608) * 2 ^ (e - 127)
end
M.f2b, M.b2f = f2b, b2f

-- one MAVLink v2 packet as a byte list
function M.pack(msgid, payload)
  local len = #payload
  local p = { 0xFD, len, 0, 0, txSeq, M.sysid, M.compid, msgid % 256, math.floor(msgid / 256) % 256, math.floor(msgid / 65536) }
  txSeq = (txSeq + 1) % 256
  for i = 1, len do p[#p + 1] = payload[i] end
  local crc = 0xFFFF
  for i = 2, #p do crc = crcAcc(p[i], crc) end
  crc = crcAcc(CRC_EXTRA[msgid], crc)
  p[#p + 1] = crc % 256
  p[#p + 1] = math.floor(crc / 256)
  return p
end

-- PARAM_REQUEST_READ (20): param_index int16 (-1 = by name), target sys, target comp, name[16]
function M.paramRequest(name)
  local pl = { 0xFF, 0xFF, M.target or 1, M.targetComp or 1 }
  for i = 1, 16 do pl[#pl + 1] = string.byte(name, i) or 0 end
  return M.pack(20, pl)
end

-- the bytes split into envelope payloads (chunk byte, size, data); each one is one CRSF 0xAA frame
function M.envelopes(bytes)
  local out = {}
  local i = 1
  while i <= #bytes do
    local n = math.min(58, #bytes - i + 1)
    local e = { 0, n }
    for k = 0, n - 1 do e[#e + 1] = bytes[i + k] end
    out[#out + 1] = e
    i = i + n
  end
  return out
end

-- receive side: a byte stream parser. Counts every packet by message id; decodes HEARTBEAT
-- (the autopilot's ids) and PARAM_VALUE. CRC checked for the decoded ones only.
M.stats = { frames = 0, bytes = 0, packets = 0, bad = 0, byId = {} }
local buf, bn = {}, 0
M.onParam = nil   -- function(name, value)

local function decode(p, len)
  local msgid = p[8] + p[9] * 256 + p[10] * 65536
  local st = M.stats
  st.packets = st.packets + 1
  st.byId[msgid] = (st.byId[msgid] or 0) + 1
  local extra = CRC_EXTRA[msgid]
  if not extra then return end
  local crc = 0xFFFF
  for i = 2, 10 + len do crc = crcAcc(p[i], crc) end
  crc = crcAcc(extra, crc)
  if crc ~= p[11 + len] + p[12 + len] * 256 then st.bad = st.bad + 1 return end
  local function b(i) return p[10 + i] or 0 end   -- payload byte i (1-based); v2 trims trailing zeros
  if msgid == 0 then
    -- HEARTBEAT: custom_mode u32, type u8, autopilot u8, ...; autopilot 3 = ArduPilot
    if b(6) == 3 and not M.target then M.target, M.targetComp = p[6], p[7] end
  elseif msgid == 22 then
    -- PARAM_VALUE: value f32, count u16, index u16, id char[16], type u8
    local name = {}
    for i = 9, 24 do
      local c = b(i)
      if c == 0 then break end
      name[#name + 1] = string.char(c)
    end
    local v = b2f(b(1), b(2), b(3), b(4))
    if M.onParam then M.onParam(table.concat(name), v) end
  end
end

-- feed one envelope payload (as received: chunk byte, size, data...)
function M.feed(data, first)
  first = first or 1
  local n = data[first + 1] or 0
  local st = M.stats
  st.frames = st.frames + 1
  st.bytes = st.bytes + n
  for k = first + 2, first + 1 + n do
    bn = bn + 1
    buf[bn] = data[k]
    -- resync: drop bytes until a v2 start
    if bn > 0 and buf[1] ~= 0xFD then
      local j = 1
      while j <= bn and buf[j] ~= 0xFD do j = j + 1 end
      if j > bn then buf, bn = {}, 0 else
        local nb = {}
        for q = j, bn do nb[#nb + 1] = buf[q] end
        buf, bn = nb, #nb
      end
    end
    while bn >= 3 and buf[1] == 0xFD do
      local len = buf[2]
      local total = 12 + len + ((buf[3] % 2 == 1) and 13 or 0)   -- + signature when signed
      if bn < total then break end
      decode(buf, len)
      local nb = {}
      for q = total + 1, bn do nb[#nb + 1] = buf[q] end
      buf, bn = nb, #nb
    end
  end
end

return M
