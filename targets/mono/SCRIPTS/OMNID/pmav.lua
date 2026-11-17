--[[
  OmniDeck Mono, PARAMS page over mLRS (Tx Ser Port = cbridge): MAVLink v2 in CRSF frames 0xAA
  (chunk byte, size, up to 58 MAVLink bytes). Loaded by pparam.lua only while the bridge is on, so
  ELRS and Crossfire never carry this code.

  Returns a maker: (out, handle) -> M
    out     pparam.lua's send queue ({ cmd, data } frames)
    handle  pparam.lua's answer handler, called as handle(22, { value bytes 1-4, name bytes })
  M.read(name)      PARAM_REQUEST_READ (20)
  M.set(name, vb)   PARAM_SET (23), vb = the float32's 4 bytes
  M.feed(data)      one bridge frame from the aircraft
  Only HEARTBEAT (until the autopilot is known: whom to ask) and PARAM_VALUE (22) are read; the rest
  of the stream (about 1.3 kB/s, attitude and position for nobody here) is stepped over a whole
  packet at a time.
]]

local floor = math.floor

-- CRC-16/MCRF4XX worked out per byte: a 256-entry table would be 2 KB more of the radio's 127, and
-- the CPU it would save is capped anyway (pparam.lua reads bridge frames only while the update has
-- used under 40 % of EdgeTX's per-call limit). EdgeTX's Lua 5.3 has the operators, the PC test's
-- Lua 5.2 has bit32.
local crcAcc
if bit32 then
  local band, bxor, shl, shr = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift
  crcAcc = function(b, c)
    local t = band(bxor(b, c), 0xFF)
    t = band(bxor(t, shl(t, 4)), 0xFF)
    return band(bxor(bxor(shr(c, 8), shl(t, 8)), bxor(shl(t, 3), shr(t, 4))), 0xFFFF)
  end
else
  crcAcc = load("return function(b, c) local t = (b ~ c) & 0xFF t = (t ~ (t << 4)) & 0xFF "
    .. "return ((c >> 8) ~ (t << 8) ~ (t << 3) ~ (t >> 4)) & 0xFFFF end")()
end
local CRCX = { [0] = 50, [20] = 214, [22] = 220, [23] = 168 }   -- CRC_EXTRA of the messages used

return function(out, handle)
  local MV = { sys = 1, comp = 1, seq = 1, found = false }   -- the autopilot; our sequence

  local function queue(msgid, pl)
    local p = { 0xFD, #pl, 0, 0, MV.seq, 255, 25, msgid, 0, 0 }   -- we are a GCS, 255/25
    MV.seq = (MV.seq + 1) % 256
    for i = 1, #pl do p[#p + 1] = pl[i] end
    local crc = 0xFFFF
    for i = 2, #p do crc = crcAcc(p[i], crc) end
    crc = crcAcc(CRCX[msgid], crc)
    p[#p + 1] = crc % 256
    p[#p + 1] = floor(crc / 256)
    local i = 1
    while i <= #p do   -- bridge frames: chunk byte 0, size, up to 58 bytes
      local n = math.min(58, #p - i + 1)
      local e = { 0, n }
      for k = 0, n - 1 do e[k + 3] = p[i + k] end
      out[#out + 1] = { 0xAA, e }
      i = i + n
    end
  end
  local function name16(name, t)
    for k = 1, 16 do t[#t + 1] = string.byte(name, k) or 0 end
    return t
  end

  local M = {}
  function M.read(name)          -- index -1, target, name[16]
    queue(20, name16(name, { 0xFF, 0xFF, MV.sys, MV.comp }))
  end
  function M.set(name, vb)       -- value, target, name[16], type REAL32
    local t = name16(name, { vb[1], vb[2], vb[3], vb[4], MV.sys, MV.comp })
    t[#t + 1] = 9
    queue(23, t)
  end

  local function u8(b, i) return b[i] or 0 end   -- MAVLink 2 leaves out trailing zero bytes
  local function message(id, b, sys, comp)
    if id == 0 then
      if u8(b, 6) == 3 and comp == 1 then MV.sys, MV.comp, MV.found = sys, comp, true end
      return
    end
    if sys ~= MV.sys then return end
    local nb = { u8(b, 1), u8(b, 2), u8(b, 3), u8(b, 4) }
    for i = 9, 24 do
      local c = u8(b, i)
      if c == 0 then break end
      nb[#nb + 1] = c
    end
    handle(22, nb)
  end

  -- packets run across frames: header (10 bytes), then the body read or skipped
  local st, hn, hdr, skip, need, got, body, id = 0, 0, {}, 0, 0, 0, {}, 0
  function M.feed(data)
    local e = 2 + (data[2] or 0)
    if e > #data then e = #data end
    local i = 3
    while i <= e do
      if skip > 0 then
        local k = e - i + 1
        if k > skip then k = skip end
        skip, i = skip - k, i + k
      elseif st == 0 then
        if data[i] == 0xFD then st, hn, hdr[1] = 1, 1, 0xFD end
        i = i + 1
      elseif st == 1 then
        hn = hn + 1
        hdr[hn] = data[i]
        i = i + 1
        if hn == 10 then
          local len, signed = hdr[2], hdr[3] % 2 == 1
          local mid = (hdr[9] == 0 and hdr[10] == 0) and hdr[8] or -1
          if not signed and (mid == 22 or (mid == 0 and not MV.found)) then
            st, need, got, body, id = 2, len + 2, 0, {}, mid
          else
            st, skip = 0, len + 2 + (signed and 13 or 0)
          end
        end
      else
        got = got + 1
        body[got] = data[i]
        i = i + 1
        if got == need then
          st = 0
          local len = need - 2
          local crc = 0xFFFF
          for k = 2, 10 do crc = crcAcc(hdr[k], crc) end
          for k = 1, len do crc = crcAcc(body[k], crc) end
          crc = crcAcc(CRCX[id], crc)
          if crc == body[len + 1] + body[len + 2] * 256 then
            body[len + 1], body[len + 2] = nil, nil
            message(id, body, hdr[6], hdr[7])
          end
        end
      end
    end
  end
  return M
end
