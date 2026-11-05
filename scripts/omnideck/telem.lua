-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck telemetry layer.

  Every flight stack and link ends up in one state table (T.s), so the HUD and
  the map never care where a value came from:

    ArduPilot  - FrSky passthrough packets (0x5000-0x500D + 0x0800 lat/lon),
                 carried by CRSF/ELRS (custom frame 0x80/0x7F), by S.Port/F.Port/
                 FBUS, and by mLRS (its Tx module converts MAVLink to the same
                 CRSF passthrough frames).
    INAV, BF   - the radio's own telemetry sensors (CRSF or S.Port), read with
                 system.getSource(). ArduPilot without passthrough also lands here.

  Passthrough bit layouts follow libraries/AP_Frsky_Telem/AP_Frsky_SPort_Passthrough.cpp.
]]

local T = {}

local LINK_AUTO, LINK_CRSF, LINK_SPORT = 0, 1, 2
T.LINK_AUTO, T.LINK_CRSF, T.LINK_SPORT = LINK_AUTO, LINK_CRSF, LINK_SPORT

-- The state of a newly selected model (fresh() again on a model switch, see T.wakeup)
local function fresh() return {
  fc = nil,        -- "ArduPilot" | "INAV/BF" | nil (nothing heard yet)
  link = nil,      -- "CRSF" | "S.Port"
  lat = nil, lon = nil, fix = 0, sats = 0, hdop = nil, altMSL = nil,
  alt = nil,       -- m above home
  vspd = nil,      -- m/s, up positive
  gspd = nil,      -- m/s
  aspd = nil,      -- m/s (ArduPilot with an airspeed estimate)
  yaw = nil,       -- deg 0-360
  roll = 0, pitch = 0,
  volt = nil, curr = nil, mah = nil, cap = nil, thr = nil,
  mode = nil, armed = nil, flying = nil, failsafe = false, ekfBad = false, battFs = false,
  homeLat = nil, homeLon = nil, homeDist = nil, homeBrg = nil,
  wpNum = nil, wpDist = nil, wpBrg = nil,
  windDir = nil, windSpd = nil,
  lq = nil, rssi = nil,
  frame = nil,     -- ArduPilot MAV_TYPE (0x5007 param 1)
  msgs = {},       -- { {text=, sev=, t=}, ... } newest last
  lastRx = -100,   -- os.clock() of the last decoded value
  lastPt = -100,   -- os.clock() of the last passthrough packet
} end
local s = fresh()
T.s = s

local SPEED_STALE_S = 5
-- ArduPilot repeats its PreArm failures every 30 s and has no "ready" flag in telemetry,
-- so ready means disarmed for this long with no PreArm message heard
local PREARM_HOLD_S = 40   -- repeats every 30 s, plus slack for delays on the way

local function now() return os.clock() end
-- bit field of an unsigned 32-bit value; plain arithmetic, so it runs on Lua 5.2 (EdgeTX) and 5.4 (Ethos)
local P2 = {}
for i = 0, 32 do P2[i] = math.floor(2 ^ i) end
-- A passthrough value is 32 bits, kept as two 16-bit halves (lo = bits 0-15, hi = bits 16-31).
-- Never as one number: the TX16S MK2 tester's EdgeTX keeps Lua numbers as 32-bit floats (24-bit
-- mantissa), so a whole value lost its low 6-7 bits there - status text fell apart into 3-letter
-- pieces ("PreA" -> "Pre", "1: B" -> "1: @") and the flight mode (bits 0-4) was gone, 2026-11-03.
-- Halves fit any Lua number exactly. ext() takes len bits from bit start.
-- EdgeTX (Lua 5.2) has bit32, which runs in C: about a third of the Lua instructions per value,
-- and still exact on 16-bit halves. Ethos (Lua 5.4) has none and keeps the arithmetic.
local bx = bit32 and bit32.extract
local function ext(lo, hi, start, len)
  if bx then
    if start >= 16 then return bx(hi, start - 16, len) end
    if start + len <= 16 then return bx(lo, start, len) end
    local lowBits = 16 - start
    return bx(lo, start, lowBits) + bx(hi, 0, len - lowBits) * P2[lowBits]
  end
  if start >= 16 then return math.floor(hi / P2[start - 16]) % P2[len] end
  if start + len <= 16 then return math.floor(lo / P2[start]) % P2[len] end
  local lowBits = 16 - start          -- the field spans both halves
  return math.floor(lo / P2[start]) + (hi % P2[len - lowBits]) * P2[lowBits]
end
local atan2 = math.atan2 or math.atan

-- ---------------------------------------------------------------- geo
local R_EARTH = 6371000
function T.distBrg(lat1, lon1, lat2, lon2)
  local p1, p2 = math.rad(lat1), math.rad(lat2)
  local dp, dl = p2 - p1, math.rad(lon2 - lon1)
  local a = math.sin(dp / 2) ^ 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ^ 2
  local d = 2 * R_EARTH * math.asin(math.min(1, math.sqrt(a)))
  local y = math.sin(dl) * math.cos(p2)
  local x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
  return d, (math.deg(atan2(y, x)) + 360) % 360
end
function T.project(lat, lon, dist, brg)
  local d, b, p1, l1 = dist / R_EARTH, math.rad(brg), math.rad(lat), math.rad(lon)
  local p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b))
  local l2 = l1 + atan2(math.sin(b) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2))
  return math.deg(p2), math.deg(l2)
end

-- ---------------------------------------------------------------- mode names
local PLANE = {
  [0] = "MANUAL", [1] = "CIRCLE", [2] = "STABILIZE", [3] = "TRAINING", [4] = "ACRO",
  [5] = "FBWA", [6] = "FBWB", [7] = "CRUISE", [8] = "AUTOTUNE", [10] = "AUTO",
  [11] = "RTL", [12] = "LOITER", [13] = "TAKEOFF", [14] = "AVOID ADSB", [15] = "GUIDED",
  [16] = "INIT", [17] = "QSTABILIZE", [18] = "QHOVER", [19] = "QLOITER", [20] = "QLAND",
  [21] = "QRTL", [22] = "QAUTOTUNE", [23] = "QACRO", [24] = "THERMAL",
  [25] = "LOITER QLAND", [26] = "COURSE HOLD", [27] = "AUTO TRIM",
}
local COPTER = {
  [0] = "STABILIZE", [1] = "ACRO", [2] = "ALT HOLD", [3] = "AUTO", [4] = "GUIDED",
  [5] = "LOITER", [6] = "RTL", [7] = "CIRCLE", [9] = "LAND", [11] = "DRIFT",
  [13] = "SPORT", [14] = "FLIP", [15] = "AUTOTUNE", [16] = "POSHOLD", [17] = "BRAKE",
  [18] = "THROW", [19] = "AVOID ADSB", [20] = "GUIDED NOGPS", [21] = "SMART RTL",
  [22] = "FLOWHOLD", [23] = "FOLLOW", [24] = "ZIGZAG", [25] = "SYSTEMID",
  [26] = "AUTOROTATE", [27] = "AUTO RTL", [28] = "TURTLE",
}
-- MAV_TYPE values that run ArduCopter (quad, coax, heli, hexa, octo, tri, dodeca, deca)
local COPTER_TYPES = { [2] = true, [3] = true, [4] = true, [13] = true, [14] = true, [15] = true, [29] = true, [35] = true }

local function apModeName(n)
  local tbl = (s.frame and COPTER_TYPES[s.frame]) and COPTER or PLANE
  return tbl[n] or ("MODE " .. n)
end

-- ---------------------------------------------------------------- status text
local msgBuf, msgLastLo, msgLastHi = "", nil, nil
local MSG_MAX = 60
local function pushMsg(text, sev)
  if text == "" then return end
  local m = s.msgs
  sev = sev or 6
  local last = m[#m]
  if last and last.base == text and last.sev == sev then
    -- the same message again (ArduPilot repeats PreArm failures, e.g. on every arm attempt):
    -- one line with a count, like Yaapu, not a screen full of copies (TX16S + TBS 2026-11-04)
    last.n = last.n + 1
    last.text, last.t = string.format("%s (x%d)", text, last.n), now()
  else
    m[#m + 1] = { text = text, base = text, n = 1, sev = sev, t = now() }
    s.msgTotal = (s.msgTotal or 0) + 1   -- running count of lines, so a scrolled view can stay put
    if #m > MSG_MAX then table.remove(m, 1) end
  end
  -- ArduPilot sends every PreArm (and Arm:) failure at CRITICAL (AP_Arming::check_failed). The
  -- severity rides in the last chunk, so it still counts when a lost chunk took the "PreArm:"
  -- prefix with it (Ethos + F.Port bench 2026-11-04: "Bad Health" shown, then READY TO ARM).
  if string.find(text, "PreArm", 1, true) or sev <= 2 then s.prearmAt = now() end
end
T.pushMsg = pushMsg

-- Over CRSF ArduPilot also sends each status text whole, in its own frame (0xF1). Once one
-- has arrived the 4-characters-a-packet passthrough copy (0x5000) is ignored: it is slower,
-- loses messages under load, and would show every message twice.
local textViaCrsf = false
local function decodeText(lo, hi)
  if textViaCrsf then return end
  -- each chunk is repeated up to 3 times; a new chunk always differs from the last one
  if lo == msgLastLo and hi == msgLastHi then return end
  msgLastLo, msgLastHi = lo, hi
  local done = false
  for sh = 24, 0, -8 do
    local c = ext(lo, hi, sh, 7)
    if c == 0 then done = true break end
    msgBuf = msgBuf .. string.char(c)
  end
  if done or #msgBuf >= 50 then
    local sev = ext(lo, hi, 23, 1) * 4 + ext(lo, hi, 15, 1) * 2 + ext(lo, hi, 7, 1)
    pushMsg(msgBuf, sev)
    msgBuf = ""
  end
end

-- ---------------------------------------------------------------- ArduPilot home
-- 0x5004 gives distance and bearing to home, quantised (1 m below 1 km, 10 m to
-- 10 km; bearing in 3 deg steps). The fix taken closest to home is the most
-- accurate, so it is kept until a better one arrives or home has clearly moved.
local homeBestDist = nil
local function apHomeUpdate()
  if not (s.lat and s.homeDist and s.homeBrg) then return end
  local hlat, hlon = T.project(s.lat, s.lon, s.homeDist, s.homeBrg)
  local errNew = s.homeDist * 0.027 + (s.homeDist >= 1000 and 5 or 1)  -- 1.5 deg + half a step
  if s.homeLat == nil or homeBestDist == nil or s.homeDist < homeBestDist then
    s.homeLat, s.homeLon, homeBestDist = hlat, hlon, s.homeDist
    return
  end
  local d = T.distBrg(s.homeLat, s.homeLon, hlat, hlon)
  local errOld = homeBestDist * 0.027 + (homeBestDist >= 1000 and 5 or 1)
  if d > 3 * (errNew + errOld) + 20 then   -- home was reset (re-arm somewhere else)
    s.homeLat, s.homeLon, homeBestDist = hlat, hlon, s.homeDist
  end
end

-- ---------------------------------------------------------------- passthrough decode
-- 0x0800 brings latitude and longitude in separate packets; a latitude waits for its
-- longitude, so s.lat is never set without s.lon (the map needs both)
local latPending = nil
-- last raw 0x5000 (text) and 0x5001 (status) values, for the sensor check page
local rawText, rawStatus = nil, nil
local function pt(appId, lo, hi)
  local t = now()
  if appId == 0x5000 then rawText = { lo, hi } elseif appId == 0x5001 then rawStatus = { lo, hi } end
  -- 0x0800 is the standard FrSky GPS ID: INAV and Betaflight send their position with it too
  -- (an R9 with INAV, X18 tester 2026-11-03). Taken as ArduPilot it stopped every native
  -- sensor read. It only proves the link is up; the 0x50xx frames say ArduPilot.
  s.lastRx = t
  if appId ~= 0x0800 then s.lastPt, s.fc = t, "ArduPilot" end
  if appId == 0x0800 then
    local raw = ext(lo, hi, 0, 30)
    local deg
    if raw > 108000000 then
      -- over 180 deg: mLRS (1.4.x) negates the coordinate before packing it, so it sends
      -- (2^32 - |deg x 1e7|) / 50 x 3. Undo that (about 0.5 mm off); ArduPilot never gets here.
      deg = (4294967296 - raw / 3 * 50) / 10000000
    else
      deg = raw / 600000
    end
    if ext(lo, hi, 30, 1) == 1 then deg = -deg end
    if ext(lo, hi, 31, 1) == 1 then
      if latPending then
        -- ArduPilot sends 0,0 until its GPS has had a fix: that is no position, not a place
        if latPending == 0 and deg == 0 then s.lat, s.lon = nil, nil
        else s.lat, s.lon, s.posAt = latPending, deg, now() end
        latPending = nil
      end
    else
      latPending = deg
    end
  elseif appId == 0x5000 then
    decodeText(lo, hi)
  elseif appId == 0x5001 then
    local m = ext(lo, hi, 0, 5) - 1          -- sent as custom_mode + 1
    s.mode = m >= 0 and apModeName(m) or nil
    s.flying = ext(lo, hi, 7, 1) == 1
    s.armed = ext(lo, hi, 8, 1) == 1
    s.battFs = ext(lo, hi, 9, 1) == 1
    s.ekfBad = ext(lo, hi, 10, 1) == 1
    s.failsafe = ext(lo, hi, 12, 1) == 1
    local raw = ext(lo, hi, 19, 6)
    s.thr = (raw > 0 and math.min(100, math.floor(0.5 + (raw + 0.5) / 0.63)) or 0) * (ext(lo, hi, 25, 1) == 1 and -1 or 1)
  elseif appId == 0x5002 then
    s.sats = ext(lo, hi, 0, 4)
    s.fix = ext(lo, hi, 4, 2) + ext(lo, hi, 14, 2)
    s.hdop = ext(lo, hi, 7, 7) * (10 ^ ext(lo, hi, 6, 1)) / 10
    local a = ext(lo, hi, 24, 7) * (10 ^ ext(lo, hi, 22, 2)) / 10
    s.altMSL = ext(lo, hi, 31, 1) == 1 and -a or a
  elseif appId == 0x5003 then
    s.volt = ext(lo, hi, 0, 9) / 10
    s.curr = ext(lo, hi, 10, 7) * (10 ^ ext(lo, hi, 9, 1)) / 10
    s.mah = ext(lo, hi, 17, 15)
  elseif appId == 0x5004 then
    s.homeDist = ext(lo, hi, 2, 10) * (10 ^ ext(lo, hi, 0, 2))
    local a = ext(lo, hi, 14, 10) * (10 ^ ext(lo, hi, 12, 2)) / 10
    s.alt = ext(lo, hi, 24, 1) == 1 and -a or a
    s.homeBrg = ext(lo, hi, 25, 7) * 3
    if s.homeDist == 0 and s.homeBrg == 0 then s.homeBrg = nil end   -- no home yet
    -- pair with a position no older than 0.3 s, so motion between packets stays small
    if s.lat and s.posAt and now() - s.posAt <= 0.3 then apHomeUpdate() end
  elseif appId == 0x5005 then
    local vs = ext(lo, hi, 1, 7) * (10 ^ ext(lo, hi, 0, 1)) / 10
    s.vspd = ext(lo, hi, 8, 1) == 1 and -vs or vs
    local hs = ext(lo, hi, 10, 7) * (10 ^ ext(lo, hi, 9, 1)) / 10
    if ext(lo, hi, 28, 1) == 1 then s.aspd, s.aspdAt = hs, t else s.gspd, s.gspdAt = hs, t end
    s.yaw = ext(lo, hi, 17, 11) * 0.2
  elseif appId == 0x5006 then
    s.roll = (math.min(ext(lo, hi, 0, 11), 1800) - 900) * 0.2
    s.pitch = (math.min(ext(lo, hi, 11, 10), 900) - 450) * 0.2
  elseif appId == 0x5007 then
    local id, val = ext(lo, hi, 24, 8), ext(lo, hi, 0, 24)
    if id == 1 then s.frame = val elseif id == 4 then s.cap = val end
  elseif appId == 0x500C then
    s.windDir = ext(lo, hi, 0, 7) * 3
    s.windSpd = ext(lo, hi, 8, 7) * (10 ^ ext(lo, hi, 7, 1)) / 10
  elseif appId == 0x500D then
    s.wpNum = ext(lo, hi, 0, 11)
    s.wpDist = ext(lo, hi, 13, 10) * (10 ^ ext(lo, hi, 11, 2))
    s.wpBrg = ext(lo, hi, 23, 7) * 3
  end
end
-- for the test harness: one 32-bit value
T.decodePassthrough = function(appId, v) pt(appId, v % 65536, math.floor(v / 65536)) end

-- ---------------------------------------------------------------- CRSF frames
local crsfSensor = nil
-- EdgeTX (OD_LITE): values are collected, newest per kind, and decoded once per screen update
-- (flushPt). A TX16S MK2 updates the widget about 8 times a second while ArduPilot over ELRS
-- sends about 22 passthrough frames a second; decoding every value of every frame costs about
-- 7 % of EdgeTX's per-call Lua limit per frame, so the main page fell about 3 s behind
-- (page-5 link stats, 2026-11-03). Status values are pure state: only the newest counts.
-- Kept apart: text chunks (decoded at once, in order), 0x5005 airspeed vs groundspeed (bit 28),
-- 0x5007 per parameter id, 0x0800 latitude and longitude (bit 31; latitude decoded first).
local pendA, pendL, pendH, pendKeys, pendN = {}, {}, {}, {}, 0
local gpsLat, gpsLon = nil, nil
local function collectPt(appId, lo, hi)
  if appId == 0x5000 then pt(appId, lo, hi) return end
  if appId == 0x0800 then
    if hi >= 32768 then gpsLon = { lo, hi } else gpsLat = { lo, hi } end
    return
  end
  local key = appId
  if appId == 0x5005 then key = appId * 2 + math.floor(hi / 4096) % 2
  elseif appId == 0x5007 then key = appId * 256 + math.floor(hi / 256) end
  if pendA[key] == nil then pendN = pendN + 1 pendKeys[pendN] = key end
  pendA[key], pendL[key], pendH[key] = appId, lo, hi
end
-- attitude, speed + heading and status every update; the slower kinds (GPS status, battery,
-- home, wind, waypoint, parameters) at most maxSlow per update. The ones left wait, newest kept,
-- and go first next time.
local FAST = { [0x5006] = true, [0x5001] = true, [0x5005 * 2] = true, [0x5005 * 2 + 1] = true }
local function flushPt(maxSlow)
  if gpsLat then pt(0x0800, gpsLat[1], gpsLat[2]) gpsLat = nil end
  if gpsLon then pt(0x0800, gpsLon[1], gpsLon[2]) gpsLon = nil end
  maxSlow = maxSlow or 1000
  local slow, keep = 0, 0
  for i = 1, pendN do
    local k = pendKeys[i]
    if FAST[k] or slow < maxSlow then
      if not FAST[k] then slow = slow + 1 end
      pt(pendA[k], pendL[k], pendH[k])
      pendA[k] = nil
    else
      keep = keep + 1
      pendKeys[keep] = k
    end
  end
  for i = keep + 1, pendN do pendKeys[i] = nil end
  pendN = keep
end
T.flushPt = flushPt

local function crsfPop()
  if crsfSensor == nil then
    if crsf == nil then return false end
    if crsf.getSensor then
      local ok, sn = pcall(crsf.getSensor)
      crsfSensor = ok and sn or false
    else
      crsfSensor = { popFrame = function() return crsf.popFrame() end }
    end
  end
  if not crsfSensor then return false end
  -- only the passthrough frame types; MSP replies (0x7B) are left for mspclient.lua
  local ok, cmd, data = pcall(crsfSensor.popFrame, crsfSensor, 0x7F, 0x80)   -- no closure per pop
  if not ok or cmd == nil or data == nil then return false end
  if (cmd == 0x80 or cmd == 0x7F) and data[1] == 0xF1 and #data >= 3 then
    -- ArduPilot status text: severity, then the text up to a 0
    s.link = "CRSF"
    local t = now()
    s.lastPt, s.lastRx, s.fc = t, t, "ArduPilot"
    local chars = {}
    for i = 3, #data do
      if data[i] == 0 then break end
      chars[#chars + 1] = string.char(data[i])
    end
    textViaCrsf = true
    pushMsg(table.concat(chars), data[2])
  elseif (cmd == 0x80 or cmd == 0x7F) and #data >= 7 then
    s.link = "CRSF"
    local put = OD_LITE and collectPt or pt
    if data[1] == 0xF0 then
      put(data[3] * 256 + data[2], data[5] * 256 + data[4], data[7] * 256 + data[6])
    elseif data[1] == 0xF2 and #data >= 8 then
      for i = 0, math.min(data[2] - 1, 9) do
        local b = 3 + 6 * i
        if data[b + 5] == nil then break end
        put(data[b + 1] * 256 + data[b], data[b + 3] * 256 + data[b + 2], data[b + 5] * 256 + data[b + 4])
      end
    end
  end
  return true
end

-- ---------------------------------------------------------------- S.Port frames
local sportReaders, sportTried = {}, false
local function sportInit()
  sportTried = true
  if sport == nil or sport.getSensor == nil then return end
  -- ONE reader, like Yaapu's Ethos widget (it works with internal and external modules, S.Port,
  -- F.Port and FBUS). A second reader (module = 1) may get the same frames out of step, so
  -- text chunks could be spliced out of order (Ethos + F.Port bench 2026-11-04: broken messages).
  for _, arg in ipairs({ { appIdStart = 0x0800, appIdEnd = 0x51FF },
                         { module = 1, appIdStart = 0x0800, appIdEnd = 0x51FF } }) do
    local ok, sn = pcall(sport.getSensor, arg)
    if ok and sn then sportReaders[1] = sn break end
  end
  if #sportReaders == 0 then
    local ok, sn = pcall(sport.getSensor)
    if ok and sn then sportReaders[1] = sn end
  end
end
local function sportPop()
  if #sportReaders == 0 then
    if sportTried then return false end
    sportInit()
  end
  local any = false
  for _, r in ipairs(sportReaders) do
    local ok, f = pcall(function() return r:popFrame() end)
    if ok and f then
      any = true
      if f:primId() == 0x10 then
        local id = f:appId()
        -- only the passthrough window: plain FrSky sensors are read as sources
        if id == 0x0800 or (id >= 0x5000 and id <= 0x50FF) then
          s.link = "S.Port"
          -- S.Port hands the value over as one number: exact on Ethos (Lua 5.4 integers); on a
          -- float-number EdgeTX the radio has rounded it already
          local v = f:value() % 4294967296
          pt(id, v % 65536, math.floor(v / 65536))
        end
      end
    end
  end
  return any
end

-- ---------------------------------------------------------------- native sensors
-- Used when no passthrough has been heard for 3 s (INAV, Betaflight, ArduPilot without
-- passthrough). Each list starts with the INAV ETHOS dashboard's own queries, in its order
-- (iNavFlight/ETHOS-Telemetry-Dashboard sensors/telemetry.lua, which works on the X18 tester's
-- TBS Crossfire and R9); anything after those is an OmniDeck fallback. Looked up the same way
-- the dashboard does: plain system.getSource(query), first hit kept.
local TS = CATEGORY_TELEMETRY_SENSOR     -- nil on EdgeTX, where the field is then left out
local NATIVE = {
  lat   = { crsf = { { name = "GPS", options = OPTION_LATITUDE } },  sport = { { name = "GPS", options = OPTION_LATITUDE } } },
  lon   = { crsf = { { name = "GPS", options = OPTION_LONGITUDE } }, sport = { { name = "GPS", options = OPTION_LONGITUDE } } },
  alt   = { crsf = { "GPS alt", "Altitude" },
            sport = { { category = TS, appId = 0x0100 }, { category = TS, appId = 0x0820 } } },
  vspd  = { crsf = { "VSpeed" },      sport = { { category = TS, appId = 0x0110 } } },
  gspd  = { crsf = { "GPS speed" },   sport = { { category = TS, appId = 0x0830, subId = 0 } } },
  hdg   = { crsf = { "GPS Heading", "GPS heading", "Yaw" }, sport = { { category = TS, appId = 0x0840 } } },
  sats  = { crsf = { "GPS Satellites", "GPS satellites" },
            sport = { { category = TS, appId = 0x0480, subId = 0 }, { category = TS, appId = 0x0410, subId = 0 } } },
  roll  = { crsf = { "Roll" },  sport = { { category = TS, appId = 0x0440, subId = 0, physId = 0x1B },
                                          { category = TS, appId = 0x0730, subId = 0 }, { category = TS, appId = 0x0440 } } },
  pitch = { crsf = { "Pitch" }, sport = { { category = TS, appId = 0x0430, subId = 0, physId = 0x1B },
                                          { category = TS, appId = 0x0730, subId = 1 }, { category = TS, appId = 0x0430 } } },
  volt  = { crsf = { "Rx Batt", "Batt" },
            sport = { { appId = 0x0B50, subId = 0 }, { appId = 0x0210, subId = 0 }, { appId = 0xF103, subId = 0 }, { appId = 0xF103, subId = 1 } } },
  curr  = { crsf = { "Rx Current", "Current" }, sport = { { appId = 0x0B50, subId = 1 }, { appId = 0x0200, subId = 0 } } },
  mah   = { crsf = { "Rx Cons", "Consumption" }, sport = { { category = TS, appId = 0x0600 } } },
  -- INAV sends airspeed only with a pitot (real or virtual); Betaflight never does
  aspd  = { crsf = { "Airspeed", "Air speed", "ASpd", { crsfId = 0x0A, subIdStart = 0, subIdEnd = 1 } }, sport = { { appId = 0x0A00 } } },
  -- Betaflight over S.Port sends its mode in T1 (0x0400)
  mode  = { crsf = { "Flight mode" }, sport = { { category = TS, appId = 0x0470, subId = 0 }, { category = TS, appId = 0x0400 } } },
  -- link sensors. CRSF RSSI is in dBm (negative); FrSky has no LQ, its RSSI (0xF101) is 0-100ish.
  -- S.Port RSSI by app ID only, as the dashboard: a sensor merely NAMED "RSSI" read -1 on the
  -- X18 tester's R9 model (2026-11-03) and was taken as a dead link.
  lq    = { crsf = { "Rx Quality", "RQly" } },
  rssi  = { crsf = { "Rx RSSI1", "1RSS", "Rx RSSI2", "2RSS" },
            sport = { { appId = 0xF101, subId = 0 }, { appId = 0xF010, subId = 0 } } },
}
local srcCache, srcMissAt, srcQuery = {}, {}, {}

-- The model's discovered sensors (Model > Telemetry): lower-case name -> member, read again at
-- most every 5 s. Only used when a by-name lookup hands back a sensor of another name.
local sensorList, sensorListAt = nil, -100
local function sensorMember(name)
  if CATEGORY_TELEMETRY_SENSOR == nil then return nil end
  if not sensorList or now() - sensorListAt >= 5 then
    sensorListAt = now()
    sensorList = {}
    for i = 0, 99 do
      local ok, src = pcall(system.getSource, { category = CATEGORY_TELEMETRY_SENSOR, member = i })
      if ok and src then
        local okN, n = pcall(function() return src:name() end)
        if okN and type(n) == "string" and sensorList[string.lower(n)] == nil then sensorList[string.lower(n)] = i end
      end
    end
  end
  return sensorList[string.lower(name)]
end

-- One guard on top of the dashboard's plain lookup: a by-name hit must carry that name. On the
-- X18 tester's TBS model getSource("Flight mode") once returned the GPS (test6). A wrong hit is
-- looked up again in the model's sensor list by its exact name, else it is a miss (tried again
-- 2 s later). Queries by app ID / crsfId / GPS options are taken as the dashboard takes them.
local function lookup(q)
  local src = system.getSource(q)
  if src and type(q) == "string" then
    local ok, n = pcall(function() return src:name() end)
    if ok and type(n) == "string" and string.lower(n) ~= string.lower(q) then
      local m = sensorMember(q)
      return m and system.getSource({ category = CATEGORY_TELEMETRY_SENSOR, member = m }) or nil
    end
  end
  return src
end

-- INAV over S.Port (R9, ACCST/ACCESS): Ethos doesn't discover INAV's mode, attitude and
-- satellites sensors by itself, so they are created in the model, as the INAV dashboard does
-- (same names, units and IDs). Only on S.Port, once the receiver's voltage sensor (0x0210)
-- is there to copy physId and band from, one sensor per CREATE_GAP_S, after CREATE_AFTER_S.
local CREATE = {
  mode  = { name = "Flight Mode", appId = 0x0470, decimals = 0 },
  roll  = { name = "Roll",        appId = 0x0440, decimals = 1, deg = true },
  pitch = { name = "Pitch",       appId = 0x0430, decimals = 1, deg = true },
  sats  = { name = "Satellites",  appId = 0x0480, decimals = 0 },
}
local CREATE_AFTER_S, CREATE_GAP_S = 5, 5
local createTried, createdAt = {}, -100
local function createSport(key)
  local c = CREATE[key]
  if not c or createTried[key] or not (model and model.createSensor) then return end
  local t = now()
  if t < CREATE_AFTER_S or t - createdAt < CREATE_GAP_S then return end
  local okV, volt = pcall(system.getSource, { appId = 0x0210 })
  if not okV or not volt then return end
  local okP, physId = pcall(function() return volt:physId() end)
  local okB, band = pcall(function() return volt:band() end)
  if not (okP and physId and okB and band) then return end
  createTried[key], createdAt = true, t
  pcall(function()
    local sn = model.createSensor({ type = SENSOR_TYPE_DIY })
    sn:name(c.name)
    sn:unit(c.deg and UNIT_DEGREE or UNIT_RAW)
    sn:decimals(c.decimals)
    sn:protocolDecimals(c.decimals)
    sn:physId(physId)
    sn:band(band)
    sn:minimum(-1000000000)
    sn:maximum(2147483647)
    sn:appId(c.appId)
    sn:subId(0)
  end)
end

-- A hit is kept for SRC_REFRESH_S, then looked up again. The INAV dashboard keeps sources in a
-- weak table, so Ethos's handles are dropped and fetched again now and then; a lookup made
-- before Ethos had discovered the sensor (and that found something else, as "Flight mode"
-- did on the X18 tester's TBS) then mends itself. Kept forever, it never did.
local SRC_REFRESH_S = 5
local srcAt = {}
-- Lookups per wakeup are budgeted on EdgeTX (OD_LITE): all sources at once - at start-up, or
-- re-fetched together every 5 s - pushed that screen update to 89-90 % of EdgeTX's Lua limit.
-- An expired source is kept a call or two longer; a new one shows up a few updates later.
local LOOKUPS_PER_WAKEUP = OD_LITE and 4 or 1000
local lookupBudget = LOOKUPS_PER_WAKEUP
local function findSource(key, kind)
  local ck = kind .. key
  local c = srcCache[ck]
  if c and (now() - srcAt[ck] < SRC_REFRESH_S or lookupBudget <= 0) then return c end
  if lookupBudget <= 0 then return nil end
  lookupBudget = lookupBudget - 1
  srcCache[ck] = nil
  if srcMissAt[ck] and now() - srcMissAt[ck] < 2 then return nil end
  for _, q in ipairs(NATIVE[key][kind] or {}) do
    local ok, src = pcall(lookup, q)
    if ok and src then srcCache[ck], srcQuery[ck], srcAt[ck] = src, q, now() return src end
  end
  if kind == "sport" then createSport(key) end
  srcMissAt[ck] = now()
  return nil
end

-- a sensor's unit does not change: asked once per source object (weak keys, so sources
-- dropped by findSource's refresh go with it). Methods are called without a wrapper
-- function each time - on EdgeTX every instruction counts against the per-update limit.
local srcUnits = setmetatable({}, { __mode = "k" })
local function srcVal(key, kind)
  local src = findSource(key, kind)
  if not src then return nil end
  local ok, v = pcall(src.value, src)
  if not ok then return nil end
  local u = srcUnits[src]
  if u == nil then
    local okU, uu = pcall(src.unit, src)
    u = (okU and uu ~= nil) and uu or false
    srcUnits[src] = u
  end
  return v, u or nil
end

local function toMS(v, u)
  if v == nil then return nil end
  if u == UNIT_KILOMETER_PER_HOUR then return v / 3.6 end
  if u == UNIT_KNOT then return v * 0.514444 end
  if u == UNIT_MILE_PER_HOUR then return v * 0.44704 end
  if u == UNIT_FOOT_PER_SECOND then return v * 0.3048 end
  if u == UNIT_CENTIMETER_PER_SECOND then return v / 100 end
  if u == UNIT_METER_PER_MINUTE then return v / 60 end
  if u == UNIT_FOOT_PER_MINUTE then return v * 0.3048 / 60 end
  return v
end
local function toM(v, u)
  if v == nil then return nil end
  if u == UNIT_FOOT then return v * 0.3048 end
  if u == UNIT_CENTIMETER then return v / 100 end
  if u == UNIT_KILOMETER then return v * 1000 end
  return v
end
local function toDeg(v, u)
  if v == nil then return nil end
  if u == UNIT_RADIAN then return math.deg(v) end
  return v
end

-- INAV/Betaflight S.Port mode number: digits ABCDE (E: 1 ok, 2 prevented, 4 armed;
-- D: 1 angle, 2 horizon, 4 manual; C: 2 alt hold, 4 pos hold; B: 1 RTH, 2 WP, 8 cruise;
-- A: 4 failsafe). Same scheme as the INAV dashboard's flightmodes.lua.
local function has(d, bit) return (d % (bit * 2)) >= bit end
local function sportMode(n)
  n = math.floor(tonumber(n) or 0)
  local E, D, C, B, A = n % 10, math.floor(n / 10) % 10, math.floor(n / 100) % 10, math.floor(n / 1000) % 10, math.floor(n / 10000) % 10
  local armed = has(E, 4)
  local name
  if has(A, 4) then name = "FAILSAFE"
  elseif not armed then name = has(E, 2) and "NOT READY" or (has(E, 1) and "READY" or "DISARMED")
  elseif has(B, 1) then name = "RTH"
  elseif has(B, 2) then name = "WP"
  elseif has(B, 8) then name = has(C, 2) and "CRUISE" or "CRS HOLD"
  elseif has(C, 4) then name = "POS HOLD"
  elseif has(C, 2) then name = "ALT HOLD"
  elseif has(D, 4) then name = "MANUAL"
  elseif has(D, 2) then name = "HORIZON"
  elseif has(D, 1) then name = "ANGLE"
  else name = "ACRO" end
  return name, armed
end

local nativeHomeAlt = nil
-- CRSF flight mode text. Disarmed is shown by a mark after the name: "*" on ArduPilot and
-- Betaflight, and on Betaflight also "!" (arming disabled) or "?" (GPS rescue disabled).
-- INAV sends OK, WAIT or !ERR instead. !FS! says nothing about arming, so keep the last state.
local function crsfMode(raw)
  if raw == "" then return s.mode, s.armed end
  if raw == "!FS!" then return "FAILSAFE", s.armed end
  if raw == "OK" or raw == "WAIT" or raw == "!ERR" then return raw, false end
  local name, mark = string.match(raw, "^(.-)([%*!%?]?)$")
  -- "AIR" is acro with airmode active: INAV 6.x-8.0.x and Betaflight send it in place of
  -- "ACRO" (INAV master no longer does). The pilot selected ACRO, so show and speak ACRO.
  if name == "AIR" then name = "ACRO" end
  return name, mark == ""
end

-- Ready to arm, from the same text: returns ready (nil = unknown) and an optional note.
-- Betaflight's "?" only means GPS rescue is off; arming is still allowed.
-- Betaflight's mode names (telemetry/crsf.c). ArduPilot also ends its CRSF mode text with "*"
-- when disarmed ("RTL*"), where it only means disarmed, so a mark counts only after these.
local BF_MODES = { ACRO = true, AIR = true, ANGL = true, HOR = true, PASS = true, POSH = true,
                   PHFL = true, ALTH = true, CHIR = true, RTH = true }
local function crsfReady(raw)
  if raw == "" or raw == "!FS!" then return nil end
  if raw == "OK" then return true end
  if raw == "WAIT" then return false, "WAITING FOR GPS" end
  if raw == "!ERR" then return false end
  local name, mark = string.sub(raw, 1, -2), string.sub(raw, -1)
  if not BF_MODES[name] then return nil end
  if mark == "*" then return true end
  if mark == "!" then return false end
  if mark == "?" then return true, "NO GPS RESCUE" end
  return nil
end

local lastArmed = nil
-- Ethos: every RF module of the model switched off means no link at all
local moduleCheckAt, modulesOff = -100, false
-- Ethos's module API: model.getModule(i):enable(). EdgeTX has a model.getModule too, but it
-- returns a plain table (Type, protocol ...) without enable(): taken as Ethos, both modules read
-- as off and the link was never detected, so INAV/BF over TBS showed NO TELEM on a TX16S MK2
-- (EdgeTX 2.12, 2026-11-03). Only a module object with enable() counts.
local ethosModules = nil
local function hasEthosModules()
  if ethosModules ~= nil then return ethosModules end
  ethosModules = false
  if not (model and model.getModule) then return false end
  for i = 0, 1 do
    local ok, m = pcall(model.getModule, i)
    if ok and m ~= nil then
      local ok2, f = pcall(function() return m.enable end)
      if ok2 and f ~= nil then ethosModules = true end
    end
  end
  return ethosModules
end
local function rfOff()
  if not hasEthosModules() then return false end
  if now() - moduleCheckAt < 1 then return modulesOff end
  moduleCheckAt = now()
  local found, on = false, false
  for i = 0, 1 do
    local ok, m = pcall(model.getModule, i)
    if ok and m ~= nil then
      local ok2, en = pcall(function() return m:enable() end)
      if ok2 then found = true if en then on = true end end
    end
  end
  modulesOff = found and not on
  return modulesOff
end

-- Ethos's own "telemetry active" flag, the one behind its "telemetry lost" call: true while the
-- receiver's telemetry arrives, false a second or two after it stops. Sensors cannot tell this:
-- Ethos keeps every value, link quality included (LQ / RSSI stayed at 100 with the receiver
-- powered down on the X18 tester's TBS and R9, 2026-11-03). Read as dashx does
-- (CATEGORY_SYSTEM_EVENT / TELEMETRY_ACTIVE, :state()). nil where the radio has no such flag
-- (EdgeTX, older Ethos): then only the link checks below and the frame timeout apply.
local tlmSrc, tlmTriedAt = nil, -100
local function telemActive()
  if CATEGORY_SYSTEM_EVENT == nil or TELEMETRY_ACTIVE == nil then return nil end
  if tlmSrc == nil then
    if now() - tlmTriedAt < 5 then return nil end
    tlmTriedAt = now()
    local ok, src = pcall(system.getSource, { category = CATEGORY_SYSTEM_EVENT, member = TELEMETRY_ACTIVE })
    tlmSrc = ok and src or nil
    if tlmSrc == nil then return nil end
  end
  local ok, st = pcall(function() return tlmSrc:state() end)
  if ok and type(st) == "boolean" then return st end
  return nil
end
T.telemActive = telemActive

local function readNative(kind)
  local t = now()
  local lat, lon = srcVal("lat", kind), srcVal("lon", kind)
  local mode = srcVal("mode", kind)
  -- CRSF: the mode is text ("ANGL", "WAIT", "OK*"). Anything else is not the mode sensor's
  -- value; its text form is tried, and a number is never taken as a mode (it would read armed).
  if kind == "crsf" and mode ~= nil and type(mode) ~= "string" then
    local src = findSource("mode", kind)
    local ok, sv = pcall(function() return src:stringValue() end)
    mode = (ok and type(sv) == "string" and sv ~= "" and tonumber(sv) == nil) and sv or nil
  end
  local roll = srcVal("roll", kind)
  local lq, rssi = srcVal("lq", kind), srcVal("rssi", kind)
  -- nothing at all from this link: no position, mode, attitude, signal or battery
  if lat == nil and mode == nil and roll == nil and rssi == nil and lq == nil
     and srcVal("volt", kind) == nil then return end
  -- link down: Ethos says telemetry is not active (the main test), or, where the radio has no
  -- such flag, CRSF link quality 0 / FrSky RSSI exactly 0. Ethos keeps every sensor's last
  -- value, so nothing here is fresh then: lastRx is left alone and the link shows as lost.
  -- (No "values not changing" test: a craft sitting still reads the same values for minutes.)
  if telemActive() == false
     or (kind == "crsf" and lq ~= nil and lq <= 0) or (kind == "sport" and rssi ~= nil and rssi == 0) then
    s.lq, s.rssi = lq, rssi
    return
  end
  if rfOff() then return end
  -- ArduPilot is read from passthrough; this runs only after 3 s without it, i.e. the link (or
  -- the flight controller) is gone. The radio's own sensors are then last values, and its
  -- flight mode text carries no disarmed "*" unless RC_OPTIONS CRSF_FM_DISARM_STAR is set, so
  -- "QHOV" read as ARMED and the drop that followed opened the flight summary (TX16S + ELRS,
  -- battery pulled on the bench, 2026-11-03). Link figures only; nothing marks it alive.
  if s.fc == "ArduPilot" then
    s.lq, s.rssi = lq, rssi
    return
  end
  s.fc = "INAV/BF"
  s.link = kind == "crsf" and "CRSF" or "S.Port"
  s.lastRx = t
  -- a real fix only: NaN passes "~= 0", and one bad position breaks every map draw after it
  if type(lat) == "number" and type(lon) == "number" and lat == lat and lon == lon
     and math.abs(lat) <= 90 and math.abs(lon) <= 180 and (lat ~= 0 or lon ~= 0) then s.lat, s.lon = lat, lon end
  local v, u
  v, u = srcVal("sats", kind)
  if v then s.sats = kind == "sport" and (math.floor(v) % 100) or math.floor(v) end
  s.fix = (s.lat and (s.sats or 0) >= 5) and 3 or 0
  v, u = srcVal("alt", kind);   local alt = toM(v, u)
  v, u = srcVal("vspd", kind);  s.vspd = toMS(v, u)
  v, u = srcVal("gspd", kind);  s.gspd = toMS(v, u)
  v, u = srcVal("aspd", kind);  if v then s.aspd = toMS(v, u) end
  v, u = srcVal("hdg", kind);   if v then s.yaw = toDeg(v, u) % 360 end
  -- INAV sends roll right-wing-down positive (as used here) and pitch nose-down positive, so
  -- only pitch is flipped. Checked on an X20S with INAV (bench, 2026-11-02): flipping both,
  -- as the INAV dashboard does, reversed roll; flipping neither reversed pitch.
  v, u = srcVal("roll", kind);  if v then s.roll = toDeg(v, u) end
  v, u = srcVal("pitch", kind); if v then s.pitch = -toDeg(v, u) end
  s.volt = srcVal("volt", kind)
  s.curr = srcVal("curr", kind)
  s.mah = srcVal("mah", kind)
  s.lq = srcVal("lq", kind)
  s.rssi = srcVal("rssi", kind)

  local armed
  if mode ~= nil then
    if kind == "crsf" then
      local raw = tostring(mode)
      s.mode, armed = crsfMode(raw)
      s.armReady, s.armNote = crsfReady(raw)
    else
      s.mode, armed = sportMode(mode)
      s.armReady, s.armNote = nil, nil
      if s.mode == "READY" then s.armReady = true elseif s.mode == "NOT READY" then s.armReady = false end
    end
    s.armed = armed
    -- ArduPilot's own CRSF text only marks disarmed with "*"
    if s.fc == "ArduPilot" then s.armReady, s.armNote = nil, nil end
    s.failsafe = s.mode == "FAILSAFE"
  end

  -- home: where it was armed, or the first good fix if arming state is unknown
  if s.lat and s.fix == 3 then
    if (armed and not lastArmed) or (s.homeLat == nil and armed ~= false) then
      s.homeLat, s.homeLon, nativeHomeAlt = s.lat, s.lon, alt
    end
  end
  lastArmed = armed
  if alt then
    -- CRSF "Altitude" is already relative to arming on INAV/BF; GPS alt is MSL
    local src = findSource("alt", kind)
    local isGpsAlt = false
    if src and kind == "crsf" then
      local okN, nm = pcall(function() return src:name() end)
      isGpsAlt = okN and nm == "GPS alt"
    end
    s.alt = (isGpsAlt and nativeHomeAlt) and (alt - nativeHomeAlt) or alt
  end
  if s.lat and s.homeLat then s.homeDist, s.homeBrg = T.distBrg(s.lat, s.lon, s.homeLat, s.homeLon) end
end

-- CRSF link statistics (crsfId 0x14: LQ/RSSI) exist only on CRSF/ELRS links; S.Port has the
-- 0xF101 RSSI sensor instead. A model can keep both (a TBS session, then an R9), so the link
-- whose sensor is receiving (above 0) wins; with neither receiving the last one is kept.
-- With nothing chosen yet, the enabled module
-- decides, as in the INAV dashboard: internal = S.Port (ACCESS/ACCST), external = CRSF when
-- it has CRSF sensors, else S.Port (R9M). Without module info, whichever sensor exists.
local linkKind, linkCheckAt = nil, -100
local function moduleOn(i)
  local ok, on = pcall(function() local m = model.getModule(i) return m ~= nil and m:enable() end)
  return ok and on == true
end
local function liveVal(src)
  if not src then return false end
  local ok, v = pcall(function() return src:value() end)
  return ok and type(v) == "number" and v > 0
end
-- The link, as the INAV dashboard picks it: the internal module on -> S.Port; the external
-- module on -> CRSF if the CRSF link statistics sensor (crsfId 0x14) exists, else S.Port
-- (an R9M). Without Ethos's module API (EdgeTX) the live link sensor decides.
function T.detectLink()
  if now() - linkCheckAt < 2 then return linkKind end
  -- Telemetry lost: keep the link it was. Ethos stops returning the CRSF sensors then, which
  -- read as "no CRSF" and switched a lost TBS link to S.Port (X18 tester, BF + CRSF, 2026-11-03).
  if linkKind ~= nil and telemActive() == false then return linkKind end
  linkCheckAt = now()
  local okC, crsfSrc = pcall(system.getSource, { crsfId = 0x14, subIdStart = 0, subIdEnd = 1 })
  crsfSrc = okC and crsfSrc or nil
  if hasEthosModules() then
    if moduleOn(0) then linkKind = "sport"
    elseif moduleOn(1) then
      -- as the dashboard (CRSF if its link sensor exists), except a CRSF sensor left over from
      -- another link (it reads 0) while FrSky RSSI is live: an R9M on a model that once flew
      -- TBS. Neither live (link lost): the link stays as it was, so its own sensors show the loss.
      local okS, sportSrc = pcall(system.getSource, { appId = 0xF101 })
      sportSrc = okS and sportSrc or nil
      if not crsfSrc then linkKind = "sport"
      elseif liveVal(crsfSrc) then linkKind = "crsf"
      elseif liveVal(sportSrc) then linkKind = "sport"
      else linkKind = linkKind or "crsf" end
    else linkKind = linkKind end         -- both off: keep the last, rfOff() shows the loss
    return linkKind
  end
  local okS, sportSrc = pcall(system.getSource, { appId = 0xF101 })
  sportSrc = okS and sportSrc or nil
  if liveVal(crsfSrc) then linkKind = "crsf"
  elseif liveVal(sportSrc) then linkKind = "sport"
  elseif linkKind ~= nil then return linkKind
  elseif crsfSrc then linkKind = "crsf"
  elseif sportSrc then linkKind = "sport"
  else linkKind = nil end
  return linkKind
end

-- Sensor check (page 5): what every native sensor resolved to on this radio, so a tester's
-- photo shows exactly what the telemetry code reads. kind nil = the detected link.
local CHECK_KEYS = { "lat", "lon", "mode", "roll", "pitch", "hdg", "alt", "vspd", "gspd", "aspd",
                     "sats", "volt", "curr", "mah", "lq", "rssi" }
local function qText(q)
  if type(q) == "string" then return '"' .. q .. '"' end
  if type(q) ~= "table" then return tostring(q) end
  if q.name then return q.name .. (q.options == OPTION_LATITUDE and ".lat" or (q.options == OPTION_LONGITUDE and ".lon" or "")) end
  if q.crsfId then return string.format("crsf %02X", q.crsfId) end
  local t = string.format("%04X", q.appId or 0)
  if q.subId then t = t .. "/" .. q.subId end
  if q.physId then t = t .. string.format(" p%02X", q.physId) end
  return t
end
function T.sensorCheck(kind)
  kind = kind or T.detectLink()
  local rows = {}
  local mod = {}
  for i = 0, 1 do mod[#mod + 1] = moduleOn(i) and "on" or "off" end
  local ta = telemActive()
  rows.header = string.format("link %s  int %s ext %s  pt %s  fc %s  tlm %s", tostring(kind), mod[1], mod[2],
    (now() - s.lastPt <= 3) and "yes" or "no", tostring(s.fc), ta == nil and "n/a" or (ta and "on" or "LOST"))
  if not kind then return rows end
  for _, key in ipairs(CHECK_KEYS) do
    local src = findSource(key, kind)
    local row = { key = key }
    if src then
      local okN, n = pcall(function() return src:name() end)
      local okV, v = pcall(function() return src:value() end)
      local okU, u = pcall(function() return src:unit() end)
      row.query = qText(srcQuery[kind .. key])
      row.name = okN and tostring(n) or "?"
      row.value = okV and (type(v) == "number" and string.format("%.6g", v) or tostring(v)) or "err"
      row.unit = okU and tostring(u) or "?"
    else
      row.query, row.name, row.value, row.unit = "-", "not found", "", ""
    end
    rows[#rows + 1] = row
  end
  return rows
end

-- ---------------------------------------------------------------- per-wakeup entry
local nativeReadAt = -100
-- EdgeTX reads the native sensors 5 times a second (OD_LITE); the attitude alone in between,
-- so the horizon follows the plane (it lagged at 5 Hz on a TX16S MK2 with TBS, 2026-11-03).
-- Only while the last full read was live: a lost link must not move the horizon.
local function readAttitude(kind)
  local v, u = srcVal("roll", kind);  if v then s.roll = toDeg(v, u) end
  v, u = srcVal("pitch", kind);       if v then s.pitch = -toDeg(v, u) end
  v, u = srcVal("hdg", kind);         if v then s.yaw = toDeg(v, u) % 360 end
end

-- Ethos and EdgeTX load the widget script once, so this state outlived a model switch: the
-- X18 tester's Betaflight plane showed "fc ArduPilot" left over from his ArduPilot R9 plane.
-- A new model starts clean; sensor handles belong to the old model, so they go too. Checked when
-- a widget is created (both radios re-create a model's widgets when it is selected), not in
-- wakeup: EdgeTX's mission page already peaks at the 88 % margin of its Lua limit.
local function modelName()
  if not model then return nil end
  if model.name then
    local ok, n = pcall(model.name)
    if ok and type(n) == "string" then return n end
  end
  if model.getInfo then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
  end
  return nil
end
local curModel = nil
function T.resetModel()
  for k in pairs(s) do s[k] = nil end
  for k, v in pairs(fresh()) do s[k] = v end
  textViaCrsf, homeBestDist, latPending, rawText, rawStatus = false, nil, nil, nil, nil
  msgBuf, msgLastLo, msgLastHi = "", nil, nil
  nativeHomeAlt, lastArmed = nil, nil
  linkKind, linkCheckAt = nil, -100
  srcCache, srcMissAt, srcQuery, srcAt = {}, {}, {}, {}
  sensorList, sensorListAt = nil, -100
  createTried, createdAt = {}, -100
end
function T.checkModel()
  local n = modelName()
  if n == nil then return end
  if curModel ~= nil and n ~= curModel then T.resetModel() end
  curModel = n
end
-- the selected model's name for the top bar (read when a widget is created, not every paint)
function T.modelName()
  if curModel == nil then curModel = modelName() end
  return curModel
end

-- EdgeTX: after the screen is drawn, read more queued CRSF frames while the update's Lua budget
-- allows (getUsage() = percent of EdgeTX's per-call limit used so far). The main page reads only
-- one frame before drawing; ArduPilot over ELRS sends more than that, so the queue grew and the
-- display fell behind ("sluggish", TX16S + ELRS + ArduPilot, 2026-11-03).
function T.drainCrsf(limitPct, maxN)
  -- S.Port (or nothing heard yet): no CRSF queue to read, and the call itself costs budget
  -- (the S.Port mission page sits at the 88 % margin)
  if not getUsage or s.link ~= "CRSF" then return 0 end
  local n = 0
  for _ = 1, maxN do
    if getUsage() >= limitPct then break end
    if not crsfPop() then break end
    n = n + 1
  end
  return n
end

function T.wakeup(linkMode)
  local got = false
  lookupBudget = LOOKUPS_PER_WAKEUP
  if linkMode ~= LINK_SPORT then
    for _ = 1, OD_MAX_CRSF or 20 do if not crsfPop() then break end got = true end
    -- with what the last update's drain collected (nothing pending on S.Port: skipped)
    if pendN > 0 or gpsLat or gpsLon then flushPt(2) end
  end
  if linkMode ~= LINK_CRSF then
    for _ = 1, OD_MAX_SPORT or 10 do if not sportPop() then break end got = true end
  end
  if now() - s.lastPt > 3 then
    -- no passthrough: native sensors of the link in use. GPS and most other sensors
    -- exist on either link, so the link is told apart by a CRSF-only sensor.
    local kind = (linkMode == LINK_CRSF and "crsf") or (linkMode == LINK_SPORT and "sport") or T.detectLink()
    s.prearmSince = nil
    -- EdgeTX (OD_LITE): 5 reads a second are plenty (the sensors themselves update about that
    -- often) and keep the screen updates inside EdgeTX's per-call Lua limit
    if kind and (not OD_LITE or now() - nativeReadAt >= 0.2) then
      nativeReadAt = now()
      readNative(kind)
    elseif kind and now() - s.lastRx < 1 then
      readAttitude(kind)
    end
  else
    local kind = s.link == "S.Port" and "sport" or "crsf"
    local lq, rssi = srcVal("lq", kind), srcVal("rssi", kind)
    if lq then s.lq = lq end
    if rssi then s.rssi = rssi end
    -- ArduPilot sends no "ready to arm" flag. Not ready: a PreArm message in the last 35 s, or
    -- what telemetry shows directly (GPS without a 3D fix, EKF not happy, a failsafe). Ready only
    -- after 35 s disarmed with none of that, because PreArm failures repeat only every 30 s and a
    -- repeat can be lost. Fix 0 means no GPS fitted, which ArduPilot doesn't require.
    s.prearmSince = (not s.armed) and (s.prearmSince or now()) or nil
    local block = nil
    if s.prearmAt and now() - s.prearmAt <= PREARM_HOLD_S then block = ""
    elseif s.fix == 1 or s.fix == 2 then block = "NO GPS FIX"
    elseif s.ekfBad then block = "EKF"
    elseif s.failsafe then block = "FAILSAFE" end
    if s.armed then s.armReady, s.armNote = nil, nil
    elseif block then s.armReady, s.armNote = false, (block ~= "" and ("NOT READY: " .. block) or nil)
    elseif s.prearmSince and now() - s.prearmSince >= PREARM_HOLD_S then s.armReady, s.armNote = true, nil
    else s.armReady, s.armNote = nil, nil end
    -- 0x5005 carries only one of the two if FRSKY_OPTIONS bit 0 is off: drop the one that stopped
    -- rather than show it frozen. This branch only runs while packets arrive, so a lost link keeps both.
    if s.aspdAt and now() - s.aspdAt > SPEED_STALE_S then s.aspd = nil end
    if s.gspdAt and now() - s.gspdAt > SPEED_STALE_S then s.gspd = nil end
    if s.lat and s.homeLat and s.homeDist == nil then s.homeDist, s.homeBrg = T.distBrg(s.lat, s.lon, s.homeLat, s.homeLon) end
  end
  return got
end

-- alive: data in the last 3 s, and Ethos not saying telemetry is lost (that is immediate, and
-- also stops a lost ArduPilot passthrough link being revived by the native sensors' old values)
-- check page: can this Lua hold a 32-bit value exactly (a float build cannot: text and modes break),
-- and the last text / status values as received, with what they decode to
function T.rawCheck()
  local big = 16777216
  local exact = (big + 1) - big == 1 and (4294967295 % 256) == 255
  local function hex(v) return v and string.format("%04X%04X", v[2], v[1]) or "--" end
  local chars = ""
  if rawText then
    for sh = 24, 0, -8 do local c = ext(rawText[1], rawText[2], sh, 7) chars = chars .. (c >= 32 and c < 127 and string.char(c) or ".") end
  end
  return string.format("32-bit %s  5000 %s '%s'  5001 %s mode %s", exact and "OK" or "LOST", hex(rawText), chars,
    hex(rawStatus), rawStatus and tostring(ext(rawStatus[1], rawStatus[2], 0, 5) - 1) or "--")
end

function T.alive() return now() - s.lastRx < 3 and telemActive() ~= false end

return T
