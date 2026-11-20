--[[
  OmniDeck Mono voice phrases, loaded by aud.lua only when a flight mode changes or a status
  message arrives, and dropped right after: kept resident they cost about 6 KB of the TX12 MK2's
  ~127 KB of Lua memory (2026-11-20).
]]

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

return { MODE_FILES = MODE_FILES, MESSAGES = MESSAGES }
