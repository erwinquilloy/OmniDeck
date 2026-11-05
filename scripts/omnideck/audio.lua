-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck voice call-outs: flight modes, arm/disarm, battery, failsafes, GPS,
  telemetry link and the status messages worth hearing.

  A voice pack is a folder of .wav files in /scripts/omnideck/audio/<name>/. File
  names follow Yaapu's sounds, so a Yaapu language folder works as a pack.
  Clips play one at a time and urgent ones jump the queue, so a burst of events
  never turns into a long backlog of stale announcements.
]]

local A = {}

local BASE = OD_ROOT or "/scripts/omnideck/"   -- EdgeTX: /WIDGETS/OmniDeck/
local DIR = BASE .. "audio/"
local TONES = BASE .. "tones/"   -- message beeps; outside audio/ so they never show up as a voice
local BEEP_GAP_S = 2       -- a burst of messages gives one beep, unless a more serious one follows
local READY_HOLD_S = 2     -- ready / not ready must hold this long before it is spoken
local GAP_S = 0.8          -- Ethos queues clips itself; this only stops us flooding it
local QUEUE_MAX = 6
local MODE_HOLD_S = 0.4    -- a mode must hold this long, so a mode switch sweeping through isn't read out
local GPS_HOLD_S = 2       -- same for a fix that flickers
local BAT_STEPS = { 5, 10, 15, 20, 25, 30, 40, 50 }

-- mode names that don't match their file name once lowered and despaced; false stays silent.
-- The short names are the CRSF flight mode text from INAV's and Betaflight's telemetry/crsf.c.
local MODE_FILES = {
  FBWA = "flybywirea", FBWB = "flybywireb", INIT = "initializing",
  -- states, not modes (failsafe has its own call-out)
  OK = false, WAIT = false, ["!ERR"] = false, HRST = false, FAILSAFE = false,
  READY = false, ["NOT READY"] = false, DISARMED = false,
  -- INAV
  MANU = "manual", RTH = "rtl", WRTH = "rtl", LOTR = "loiter", HOLD = "poshold", CRUZ = "cruise",
  CRSH = "coursehold", ["CRS HOLD"] = "coursehold", WP = "waypoint", AH = "althold",
  ANGL = "angle", HOR = "horizon", ANGH = "anglehold", TURT = "turtle", GEO = "geozone",
  -- Betaflight
  PASS = "passthrough", POSH = "poshold", PHFL = "posholdfail", ALTH = "althold",
  CHIR = "chirp", AIR = "airmode",
}

-- status text (start of the message, lower case) -> sound; first match wins
local MESSAGES = {
  { "gps glitch cleared", "8828501" }, { "gps glitch", "1061733" },
  { "ekf variance", "9811007" }, { "parachute: released", "7210780" },
  { "prearm: need 3d fix", "14472699" }, { "flight plan received", "14608272" },
  { "mission complete", "6634944" }, { "geofence triggered", "1050361" },
  { "flight mode change failed", "6908206" }, { "autotune: success", "9430632" },
  { "autotune: failed", "2131412" }, { "transition vtol done", "16455510" },
  { "transition done", "1541806" }, { "transition started", "7211373" },
  { "land descend started", "13236108" }, { "land final started", "14444224" },
  { "soaring: not climbing", "13366422" }, { "soaring: drifted too far", "13239693" },
  { "soaring enabled", "1934808" }, { "soaring disabled", "2074081" },
  { "soaring: reached upper", "2397669" }, { "soaring: reached lower", "2246114" },
  { "soaring: thermal weak", "2860491" }, { "reached command", "2262475" },
  { "reached waypoint", "3466823" }, { "passed waypoint", "4597275" },
  { "takeoff complete", "3843641" }, { "smart rtl deactivated", "1865209" },
  { "gps home acquired", "4170928" }, { "smart rtl unavailable", "13077757" },
}

local voice = nil
local beepMode = 1         -- 1 every message, 2 warnings and worse, 0 off
local lastBeep, lastBeepSev = -100, 7
local queue = {}
local lastPlay = -100
local st = nil     -- last state seen; nil until the first telemetry

function A.packs()
  local out = {}
  if not (system and system.listFiles) then return out end
  local ok, entries = pcall(system.listFiles, DIR)
  if not ok or type(entries) ~= "table" then return out end
  for _, n in ipairs(entries) do
    if type(n) == "string" then
      n = string.gsub(n, "/+$", "")
      if n ~= "" and not string.find(n, ".", 1, true) then out[#out + 1] = n end
    end
  end
  table.sort(out)
  return out
end

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

function A.test() say("omniready") end
-- alarms raised by the screen logic (low voltage, terrain): urgent, so they jump the queue
function A.alert(file) say(file, true) end

local function modeFile(mode)
  local f = MODE_FILES[mode]
  if f ~= nil then return f end
  return (string.gsub(string.lower(mode), "[%s_]", ""))
end

local function messageFile(text)
  local t = string.lower(text)
  for _, m in ipairs(MESSAGES) do
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
  if string.sub(item, 1, 1) == "/" then pcall(system.playFile, item)
  elseif voice then pcall(system.playFile, DIR .. voice .. "/" .. item .. ".wav") end
end

local greeted = false

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
    for i = first, #s.msgs do
      local file = messageFile(s.msgs[i].text)
      if file then say(file) end
    end
    st.msgs = total
  end

  pump(now)
end

return A
