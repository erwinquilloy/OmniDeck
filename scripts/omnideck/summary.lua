-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck flight summary: records one flight from arm to disarm.

  update() runs every wakeup and returns "armed" when a flight starts and "done"
  when a flight worth showing has ended. Telemetry goes stale when the link
  drops, so nothing is sampled until it returns, and a lost link never ends a
  flight: only seeing the aircraft disarmed does.
]]

local F = {}

local MIN_FLIGHT_S = 10    -- shorter arm/disarm cycles (bench, ground checks) are ignored
local DISARM_HOLD_S = 1    -- disarmed must hold this long, so a bad frame can't end a flight
local STEP_M = 5           -- track length only counts moves this big, to skip GPS noise on the ground
local MAX_MPS = 150        -- faster than this between two fixes is a GPS jump, not flight
local LINK_TIMEOUT_S = 3   -- T.alive() turns false this long after the last frame
local EFF_TAU_S = 10       -- smoothing of the live efficiency inputs

local cur = nil    -- flight in progress
local last = nil   -- last finished flight

local function higher(old, v) if v == nil then return old end return (old == nil or v > old) and v or old end
local function lower(old, v) if v == nil then return old end return (old == nil or v < old) and v or old end

-- Current, voltage and ground speed are smoothed apart, not their ratio, so a moment of
-- low speed can't throw the figure off for the next 10 s.
local function smoothEff(s, now)
  if not (s.curr and s.volt and s.gspd) then return end
  if cur.effT == nil then
    cur.effAmps, cur.effVolts, cur.effSpd = s.curr, s.volt, s.gspd
  else
    local dt = now - cur.effT
    local k = dt / (EFF_TAU_S + dt)
    cur.effAmps = cur.effAmps + k * (s.curr - cur.effAmps)
    cur.effVolts = cur.effVolts + k * (s.volt - cur.effVolts)
    cur.effSpd = cur.effSpd + k * (s.gspd - cur.effSpd)
  end
  cur.effT = now
end

local function sample(s, now, distBrg)
  smoothEff(s, now)
  cur.maxAlt = higher(cur.maxAlt, s.alt)
  cur.maxGspd = higher(cur.maxGspd, s.gspd)
  cur.maxAspd = higher(cur.maxAspd, s.aspd)
  cur.maxHome = higher(cur.maxHome, s.homeDist)
  cur.maxCurr = higher(cur.maxCurr, s.curr)
  if s.volt and s.volt > 0 then
    cur.minVolt = lower(cur.minVolt, s.volt)
    cur.voltSum, cur.voltN = (cur.voltSum or 0) + s.volt, (cur.voltN or 0) + 1
  end
  cur.minLq = lower(cur.minLq, s.lq)
  cur.minRssi = lower(cur.minRssi, s.rssi)
  -- the FC's counter runs from its own boot, so use the rise since arming;
  -- keeping the highest value survives the counter resetting if the FC reboots
  if s.mah then
    cur.mah0 = cur.mah0 or s.mah
    cur.used = higher(cur.used, s.mah - cur.mah0)
  end
  if s.lat and s.lon then
    if cur.lat == nil then
      cur.lat, cur.lon, cur.posT = s.lat, s.lon, now
    else
      local d = distBrg(cur.lat, cur.lon, s.lat, s.lon)
      if d >= STEP_M then
        if d <= MAX_MPS * math.max(now - cur.posT, 0.1) then cur.dist = cur.dist + d end
        cur.lat, cur.lon, cur.posT = s.lat, s.lon, now
      end
    end
  end
end

function F.update(s, alive, now, distBrg)
  if cur == nil then
    if alive and s.armed == true then
      -- ArduPilot says when it is flying (0x5001 bit 7, AP_Notify flying): the flight time counts
      -- only then, like Yaapu, so time armed on the ground is left out. INAV and Betaflight send
      -- no such flag: their time counts from arming, like the iNav OpenTX widget's Auto timer.
      cur = { startT = now, armedT = now, lost = 0, dist = 0, byFlying = s.fc == "ArduPilot", fly = 0 }
      return "armed"
    end
    return nil
  end

  if not alive then
    if not cur.down then
      cur.down, cur.downT = true, now
      cur.lost = cur.lost + LINK_TIMEOUT_S
    end
    cur.offT = nil
    return nil
  end
  if cur.down then
    cur.lost = cur.lost + (now - cur.downT)
    cur.down = false
  end

  if s.armed == false then
    cur.offT = cur.offT or now
    if now - cur.offT < DISARM_HOLD_S then return nil end
    local done = cur
    cur = nil
    if done.flyFrom then   -- still flying at the disarm: count up to the last armed frame
      done.fly = done.fly + math.max(0, done.armedT - done.flyFrom)
      done.flyFrom = nil
    end
    -- the 10 s minimum goes by time armed, so a bench arm that never flew still opens the summary
    local armedFor = done.armedT - done.startT
    done.time = done.byFlying and done.fly or armedFor
    if armedFor < MIN_FLIGHT_S then return nil end
    last = done
    return "done"
  end

  cur.offT = nil
  cur.armedT = s.lastRx or now   -- the last frame, not now: "armed" can be 3 s stale before alive drops
  -- flying time (ArduPilot): starts and pauses with the flag. While the link is down the last state
  -- holds (this point is not reached then), so a flight that loses telemetry keeps counting.
  if cur.byFlying then
    if s.flying == true and not cur.flyFrom then cur.flyFrom = now
    elseif s.flying ~= true and cur.flyFrom then
      cur.fly = cur.fly + (now - cur.flyFrom)
      cur.flyFrom = nil
    end
  end
  sample(s, now, distBrg)
  return nil
end

function F.last() return last end

-- the flight in progress, or the last one until the next arming
function F.live() return cur or last end

-- flight time for the main page, and true while the clock runs (armed, and for ArduPilot flying);
-- after the disarm the last flight's time and false, until the next arming; nil before the first
-- flight
function F.timer(now)
  if cur then
    if not cur.byFlying then return now - cur.startT, true end
    if cur.flyFrom then return cur.fly + (now - cur.flyFrom), true end
    return cur.fly, false
  end
  if last then return last.time, false end
  return nil
end

return F
