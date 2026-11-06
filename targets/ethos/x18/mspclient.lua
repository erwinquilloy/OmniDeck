-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck INAV mission download over the telemetry link (MSP).

  MSP requests ride the radio link in chunks, as in INAV's msp_shared code:
    chunk   = status byte + body bytes
    status  = 0x20 (MSPv1) | 0x10 on the first chunk | sequence 0-15 (0x80 = error, replies)
    request = size, cmd, payload  (+ XOR of those bytes after the payload on S.Port)
    reply   = size, cmd, payload  on the first chunk, payload continues in later chunks

  S.Port: 6 body bytes per frame, sent as physId 0x0D / primId 0x30
          (appId = bytes 1-2, value = bytes 3-6); replies come back as primId 0x32.
  CRSF:   up to 58 bytes per frame, type 0x7A to the FC (dest 0xC8, origin 0xEA);
          replies are type 0x7B with the two address bytes in front.

  Sequence: MSP_FC_VARIANT (must be "INAV") -> MSP_WP_GETINFO -> MSP_WP for each
  index until the last-waypoint flag 0xA5 -> then MSP_NAV_STATUS every 2 s for the
  active waypoint.
]]

local M = {}

local MSP_FC_VARIANT, MSP_WP_GETINFO, MSP_WP, MSP_NAV_STATUS = 2, 20, 118, 121
local TIMEOUT, RETRIES, NAV_EVERY = 1.0, 6, 2.0
-- after a download, while disarmed: ask for the waypoint count again this often, and download
-- again if it changed (a mission uploaded after the radio started; EdgeTX has no Reload button)
local RECHECK_EVERY = 10.0

local link = nil          -- "S.Port" | "CRSF"

-- byte XOR in plain arithmetic, so this file runs on Lua 5.2 (EdgeTX) and 5.4 (Ethos)
local function bxor(a, b)
  local r, bit = 0, 1
  for _ = 1, 8 do
    if a % 2 ~= b % 2 then r = r + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return r
end
local tx, rx = nil, nil   -- sensors
local state = "off"       -- off | variant | info | wp | done | notinav | error
local waitCmd, sentAt, tries = nil, 0, 0
local seq = 0
local wpCount, wpNext = 0, 1
local wps = {}            -- downloaded: { idx=, action=, lat=, lon=, alt=, p1=, flags= }
local active = nil        -- active waypoint number from MSP_NAV_STATUS
local lastNav = 0
local lastCheck, checking = 0, false   -- count re-check after a download
local wpValid, lastFlag = nil, nil     -- from MSP_WP_GETINFO / the last waypoint received
local stale = 0   -- waypoint replies thrown away: a late answer to a request already repeated
local fcVariant = nil
local rxBuf, rxSize, rxCmd, rxSeq, rxOn, rxErr = {}, 0, 0, 0, false, false
local prevSport = nil     -- duplicate S.Port frame filter

M.state = function() return state end
M.waypoints = function() return wps end
M.active = function() return active end
M.variant = function() return fcVariant end
M.count = function() return wpCount end
-- one line for the sensor check page: what INAV reported and what arrived
M.debug = function()
  return string.format("INAV mission: %s  FC count %d%s  got %d  last flag %s  active %s  stale %d",
    state, wpCount, wpValid == false and " (not valid)" or "", #wps,
    lastFlag and string.format("%02X", lastFlag) or "--", tostring(active or "-"), stale)
end

-- ---------------------------------------------------------------- transport
local function openSensors()
  tx, rx = nil, nil
  if link == "S.Port" then
    if sport and sport.getSensor then
      local ok, s = pcall(sport.getSensor, { primId = 0x32 })
      if ok and s then tx, rx = s, s end
    end
  elseif link == "CRSF" then
    if crsf and crsf.getSensor then
      local ok, s = pcall(crsf.getSensor)
      if ok and s then tx, rx = s, s end
    end
  end
  return tx ~= nil
end

local function sendChunk(c)
  if link == "S.Port" then
    while #c < 6 do c[#c + 1] = 0 end
    local value = c[3] + c[4] * 256 + c[5] * 65536 + c[6] * 16777216
    return pcall(function() return tx:pushFrame({ physId = 0x0D, primId = 0x30, appId = c[1] + c[2] * 256, value = value }) end)
  end
  local d = { 0xC8, 0xEA }
  for i = 1, #c do d[i + 2] = c[i] end
  return pcall(function() return tx:pushFrame(0x7A, d) end)
end

local function request(cmd, payload)
  payload = payload or {}
  local body = { #payload, cmd }
  for _, b in ipairs(payload) do body[#body + 1] = b % 256 end
  if link == "S.Port" then
    local crc = 0
    for _, b in ipairs(body) do crc = bxor(crc, b) end
    body[#body + 1] = crc
  end
  local per = link == "S.Port" and 5 or 57
  local i, first = 1, true
  repeat
    local c = { 0x20 + (first and 0x10 or 0) + seq }
    seq = (seq + 1) % 16
    for k = i, math.min(#body, i + per - 1) do c[#c + 1] = body[k] end
    i = i + per
    sendChunk(c)
    first = false
  until i > #body
  waitCmd, sentAt = cmd, os.clock()
  rxOn = false
end

-- one reply chunk (status byte first); returns true when a reply is complete
local function onChunk(c)
  if #c < 1 then return false end
  local st = c[1]
  local start, sq = math.floor(st / 16) % 2 == 1, st % 16
  local i = 2
  if start then
    if math.floor(st / 32) % 4 ~= 1 then rxOn = false return false end   -- only MSPv1 here
    rxSize, rxCmd = c[2] or 0, c[3] or 0
    rxBuf, rxErr, rxOn = {}, st >= 128, true
    i = 4
  elseif not rxOn or ((rxSeq + 1) % 16) ~= sq then
    rxOn = false
    return false
  end
  rxSeq = sq
  while i <= #c and #rxBuf < rxSize do rxBuf[#rxBuf + 1] = c[i] i = i + 1 end
  if #rxBuf >= rxSize then rxOn = false return true end
  return false
end

local function pollChunk()
  if link == "S.Port" then
    local ok, f = pcall(function() return rx:popFrame() end)
    if not ok or not f then return nil end
    if f:primId() ~= 0x32 then return false end
    local a, v = f:appId(), f:value() % 4294967296
    local key = a .. ":" .. v
    if key == prevSport then return false end   -- the receiver can repeat a frame
    prevSport = key
    return { a % 256, math.floor(a / 256) % 256, v % 256, math.floor(v / 256) % 256,
             math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256 }
  end
  local ok, cmd, data = pcall(function() return rx:popFrame(0x7B, 0x7B) end)
  if not ok or cmd == nil then return nil end
  if cmd ~= 0x7B or not data or #data < 3 then return false end
  local c = {}
  for k = 3, #data do c[#c + 1] = data[k] end
  return c
end

-- ---------------------------------------------------------------- replies
local function i32(b, o)
  local v = b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216
  if v >= 0x80000000 then v = v - 0x100000000 end
  return v
end
local function i16(b, o)
  local v = b[o] + b[o + 1] * 256
  if v >= 0x8000 then v = v - 0x10000 end
  return v
end

local function handle(cmd, b, err)
  if cmd ~= waitCmd then return end
  -- a waypoint reply must be for the waypoint asked for. On a slow link (TBS Crossfire, TX16S,
  -- 2026-11-05) the answer to a repeated request arrives twice, and taking the second copy as
  -- the next waypoint turned a 6-WP mission into 1,1,4,4,...: only WP1 and WP4 on the map.
  if cmd == MSP_WP and not err and (#b < 21 or b[1] ~= wpNext) then
    stale = stale + 1
    return
  end
  waitCmd, tries = nil, 0
  if err then state = "error" return end
  if cmd == MSP_FC_VARIANT and #b >= 4 then
    fcVariant = string.char(b[1], b[2], b[3], b[4])
    state = fcVariant == "INAV" and "info" or "notinav"
  elseif cmd == MSP_WP_GETINFO and #b >= 4 then
    wpValid = b[3] ~= 0
    if checking then
      checking = false
      if b[4] == wpCount then return end   -- same mission size: keep what we have
    end
    wpCount = b[4]
    wps, wpNext, lastFlag = {}, 1, nil
    state = wpCount > 0 and "wp" or "done"
  elseif cmd == MSP_WP and #b >= 21 then
    local wp = { idx = b[1], action = b[2], lat = i32(b, 3) / 1e7, lon = i32(b, 7) / 1e7,
                 alt = i32(b, 11) / 100, p1 = i16(b, 15), p2 = i16(b, 17), p3 = i16(b, 19), flags = b[21] }
    wps[#wps + 1] = wp
    lastFlag = wp.flags
    wpNext = wpNext + 1
    if wp.flags == 0xA5 or wpNext > wpCount then state = "done" end
  elseif cmd == MSP_NAV_STATUS and #b >= 4 then
    active = (b[4] and b[4] > 0) and b[4] or nil
  end
end

-- ---------------------------------------------------------------- per wakeup
-- linkName: the link the telemetry arrives on ("S.Port"/"CRSF"); nil stops the client
-- armed: the mission is only re-checked while disarmed (it can't change in flight)
function M.wakeup(linkName, armed)
  if linkName ~= link then
    link = linkName
    state = "off"
    if link and openSensors() then state = "variant" end
    waitCmd, tries = nil, 0
  end
  if state == "off" or state == "notinav" then return end

  for _ = 1, 12 do
    local c = pollChunk()
    if c == nil then break end
    if c and onChunk(c) then handle(rxCmd, rxBuf, rxErr) end
  end

  local now = os.clock()
  if waitCmd then
    if now - sentAt < TIMEOUT then return end
    tries = tries + 1
    if tries > RETRIES then
      if state ~= "done" then state = "error" end
      waitCmd, tries, checking = nil, 0, false
      M.retryAt = now + 5
      return
    end
    request(waitCmd, waitCmd == MSP_WP and { wpNext } or nil)   -- resend the same request
    return
  end
  if state == "error" then
    if now >= (M.retryAt or 0) then state = "variant" end
    return
  end
  if state == "variant" then request(MSP_FC_VARIANT)
  elseif state == "info" then request(MSP_WP_GETINFO)
  elseif state == "wp" then request(MSP_WP, { wpNext })
  elseif state == "done" and armed ~= true and now - lastCheck >= RECHECK_EVERY then
    lastCheck, checking = now, true
    request(MSP_WP_GETINFO)
  elseif state == "done" and now - lastNav >= NAV_EVERY then
    lastNav = now
    request(MSP_NAV_STATUS)
  end
end

-- start over (new mission uploaded)
function M.restart()
  link, state, wps, active, wpCount = nil, "off", {}, nil, 0
  checking, wpValid, lastFlag, stale = false, nil, nil, 0
end

-- exposed for the test harness
M._onChunk, M._handle = onChunk, handle

return M
