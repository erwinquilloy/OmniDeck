--[[
  OmniDeck Mono voice call-outs (the colour build's audio.lua): flight modes, arm/disarm,
  battery, failsafes, GPS, telemetry link, the status messages worth hearing, and the low and
  critical voltage alarms.

  A voice pack is a folder of .wav files in /SCRIPTS/OMNID/audio/<name>/. File
  names follow Yaapu's sounds, so a Yaapu language folder works as a pack.
  Clips play one at a time and urgent ones jump the queue, so a burst of events
  never turns into a long backlog of stale announcements.
]]

local A = {}

local BASE = "/SCRIPTS/OMNID/"
local DIR = BASE .. "audio/"
local TONES = BASE .. "tones/"   -- message beeps; outside audio/ so they never show up as a voice
local BEEP_GAP_S = 2       -- a burst of messages gives one beep, unless a more serious one follows
local READY_HOLD_S = 2     -- ready / not ready must hold this long before it is spoken
local GAP_S = 0.8          -- Ethos queues clips itself; this only stops us flooding it
local QUEUE_MAX = 6
local MODE_HOLD_S = 0.4    -- a mode must hold this long, so a mode switch sweeping through isn't read out
local GPS_HOLD_S = 2       -- same for a fix that flickers
local BAT_STEPS = { 5, 10, 15, 20, 25, 30, 40, 50 }

-- the mode and message phrase tables live in aphr.lua, loaded only when needed (memory)
local function phrases()
  local f = loadScript(BASE .. "aphr.lua", "bt")
  if not f then return nil end
  local ok, t = pcall(f)
  return ok and t or nil
end

local voice = nil
local beepMode = 1         -- 1 every message, 2 warnings and worse, 0 off
local lastBeep, lastBeepSev = -100, 7
local queue = {}
local lastPlay = -100
local st = nil     -- last state seen; nil until the first telemetry

function A.setVoice(name)
  voice = (name ~= nil and name ~= "" and name ~= "off") and name or nil
  queue = {}
end

function A.setBeep(m) beepMode = m end

-- items are voice clip names, or full paths for the tones
local function enqueue(item, urgent)
  for _, q in ipairs(queue) do if q == item then return end end
  if #queue >= QUEUE_MAX then table.remove(queue) end
  if urgent then table.insert(queue, 1, item) else queue[#queue + 1] = item end
end

local function say(file, urgent)
  if voice then enqueue(file, urgent) end
end

-- MAVLink severity: 0-3 emergency to error, 4 warning, 5-7 notice, info, debug.
-- Works with the voice off; it has its own setting, like Yaapu's message beep.
local function beep(sev, now)
  if beepMode == 0 or (beepMode == 2 and sev >= 5) then return end
  -- the gap only holds back beeps that are no more serious than the last one
  if now - lastBeep < BEEP_GAP_S and sev >= lastBeepSev then return end
  lastBeep, lastBeepSev = now, sev
  enqueue(TONES .. (sev <= 3 and "crit" or (sev == 4 and "warn" or "info")) .. ".wav", sev <= 3)
end

-- alarms raised by the screen logic (low voltage, terrain): urgent, so they jump the queue
function A.alert(file) say(file, true) end

local function modeFile(mode)
  local P = phrases()
  local f = P and P.MODE_FILES[mode]
  if f ~= nil then return f end
  return (string.gsub(string.lower(mode), "[%s_]", ""))
end

local function messageFile(P, text)
  if not P then return nil end
  local t = string.lower(text)
  for _, m in ipairs(P.MESSAGES) do
    if string.find(t, m[1], 1, true) == 1 then return m[2] end
  end
  return nil
end

local function rising(s, key, file)
  local v = s[key] == true
  if v and not st[key] then say(file, true) end
  st[key] = v
end

local function battery(s)
  if not (s.cap and s.cap > 0 and s.mah) then return end
  local pct = math.max(0, 100 - 100 * s.mah / s.cap)
  if st.bat == nil or pct > st.bat + 5 then st.bat = pct return end   -- first reading, or a fresh pack
  for _, step in ipairs(BAT_STEPS) do
    if pct <= step then
      if st.bat > step then
        st.bat = step
        say("bat" .. step, step <= 15)
      end
      return
    end
  end
end

local function pump(now)
  if #queue == 0 or now - lastPlay < GAP_S then return end
  lastPlay = now
  local item = table.remove(queue, 1)
  if string.sub(item, 1, 1) == "/" then pcall(playFile, item)
  elseif voice then pcall(playFile, DIR .. voice .. "/" .. item .. ".wav") end
end

local greeted = false
-- "OmniDeck telemetry ready" straight away when the script starts (radio power-on or a model
-- selected), as the colour builds and Yaapu do: played directly, not queued behind telemetry,
-- and before any telemetry arrives
-- now: the same clock A.update gets (the adapter's, from 0 at script start). It was stamped with
-- getTime()/100, the radio's time since power-on: the queue then held every clip until the
-- script's own clock caught up, minutes on a radio that had been on a while (TX12 2026-11-13).
function A.greetNow(now)
  if greeted or not voice then return end
  greeted = true
  lastPlay = now or 0
  pcall(playFile, DIR .. voice .. "/omniready.wav")
end

-- voltage per cell, in two stages: low ("Low voltage", again every 30 s) and critical
-- ("Critical voltage", every 15 s); each must hold 5 s, so a dip under load doesn't count.
-- Cells: the setting, else the most cells the highest voltage seen could be (4.35 V max).
local VOLT_HOLD_S, VOLT_REPEAT_S, CRIT_REPEAT_S = 5, 30, 15
local al = { cells = 0, stage = 0, said = -100 }
A.cells, A.vLow, A.vCrit, A.stage = 0, 0, 0, 0
local function voltAlarm(s, alive, now)
  if s.volt and s.volt > 0 then al.cells = math.max(al.cells, math.ceil(s.volt / 4.35)) end
  local cells = A.cells > 0 and A.cells or al.cells
  local cell = (alive and s.armed and s.volt and cells > 0) and s.volt / cells or nil
  if cell and A.vLow > 0 and cell < A.vLow then al.low = al.low or now else al.low = nil end
  if cell and A.vCrit > 0 and cell < A.vCrit then al.crit = al.crit or now else al.crit = nil end
  local stage = 0
  if al.crit and now - al.crit >= VOLT_HOLD_S then stage = 2
  elseif al.low and now - al.low >= VOLT_HOLD_S then stage = 1 end
  A.stage = stage
  if stage > 0 and (stage > al.stage or now - al.said >= (stage == 2 and CRIT_REPEAT_S or VOLT_REPEAT_S)) then
    al.said = now
    say(stage == 2 and "critvolt" or "lowvoltage", true)
  end
  al.stage = stage
end

-- low altitude ("Terrain, pull up"), as the colour builds: armed, and only once the aircraft has
-- been more than 2 m above the setting, so the take-off and a landing approach from below don't
-- count; again every 15 s while low. A.altLim in metres (0 = off); A.altLow for the main page.
local ALT_REPEAT_S = 15
local alt = { armed = false, said = -100 }
A.altLim, A.altLow = 0, false
local function altAlarm(s, alive, now)
  A.altLow = false
  if not s.armed then alt.armed = false end
  if alive and s.armed == true and A.altLim > 0 and s.alt then
    if s.alt > A.altLim + 2 then alt.armed = true end
    if alt.armed and s.alt < A.altLim then
      A.altLow = true
      if now - alt.said >= ALT_REPEAT_S then alt.said = now say("pullup", true) end
    end
  end
end

function A.update(s, alive, now)
  -- "Omni Deck telemetry ready" once when the widget starts (as Yaapu does), as soon as the
  -- saved voice is loaded; it does not wait for telemetry
  if not greeted and voice then
    greeted = true
    say("omniready")
  end
  if st == nil then
    if alive then
      st = { up = true, armed = s.armed, mode = s.mode, msgs = s.msgTotal or 0,
             failsafe = s.failsafe == true, ekfBad = s.ekfBad == true, battFs = s.battFs == true,
             fix = (s.fix or 0) >= 3 }
    end
    pump(now)
    return
  end

  if alive ~= st.up then
    st.up = alive
    if st.armed then say(alive and "telemok" or "telemlost", true) end
  end
  if not alive then pump(now) return end    -- everything else in s is stale until the link returns

  if s.armed ~= nil and s.armed ~= st.armed then
    st.armed = s.armed
    say(s.armed and "armed" or "disarmed", true)
  end

  if s.mode ~= st.mode then
    if s.mode ~= st.modeNew then st.modeNew, st.modeT = s.mode, now end
    if s.mode and now - st.modeT >= MODE_HOLD_S then
      st.mode = s.mode
      local file = modeFile(s.mode)
      if file then say(file) end
    end
  else
    st.modeNew = nil
  end

  rising(s, "failsafe", "failsafe")
  rising(s, "ekfBad", "ekf")
  rising(s, "battFs", "lowbat")

  local fix = (s.fix or 0) >= 3
  if fix ~= st.fix then
    st.fixT = st.fixT or now
    if now - st.fixT >= GPS_HOLD_S then
      st.fix, st.fixT = fix, nil
      say(fix and "gpsfix" or "gpsnofix", not fix)
    end
  else
    st.fixT = nil
  end

  if s.armed then battery(s) end
  voltAlarm(s, alive, now)
  altAlarm(s, alive, now)

  -- ready to arm: spoken when it changes while disarmed, like the INAV dashboard's
  -- "ready to arm" / "arming prevented"; arming forgets it, so it is said again after landing
  if s.armed then
    st.ready, st.readyNew = nil, nil
  elseif s.armReady ~= nil and s.armReady ~= st.ready then
    if s.armReady ~= st.readyNew then st.readyNew, st.readyT = s.armReady, now end
    if now - st.readyT >= READY_HOLD_S then
      st.ready, st.readyNew = s.armReady, nil
      say(st.ready and "readytoarm" or "notready")   -- "notready": EdgeTX limits sound paths to 45 characters
    end
  else
    st.readyNew = nil
  end

  local total = s.msgTotal or 0
  if total > st.msgs then
    local worst = 7
    local first = math.max(1, #s.msgs - (total - st.msgs) + 1)
    for i = first, #s.msgs do worst = math.min(worst, s.msgs[i].sev or 6) end
    if first <= #s.msgs then beep(worst, now) end
    local P = first <= #s.msgs and phrases() or nil   -- loaded once for the batch, dropped after
    for i = first, #s.msgs do
      local file = messageFile(P, s.msgs[i].text)
      if file then say(file) end
    end
    st.msgs = total
  end

  pump(now)
end

return A
