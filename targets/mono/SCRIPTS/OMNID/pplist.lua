--[[
  OmniDeck Mono, PARAMS page: the ArduPlane parameters it shows, tab by tab. The same rows as
  the colour OmniDeck's plist.lua (Stratos v2.2 / ArduPlane 4.7.2 names and ranges), with labels
  and option names cut to fit 128x64.

  Returns a function: tab name -> that tab's rows only, so only the open tab is ever built
  (the whole list as tables would take about 16 KB of the radio's 127).
  { name, label, unit, min, max, step, decimals, options, kind, fl = true }
    options  "a|b|c" = value 0, 1, 2 shown by name (nil: a number)
    kind     "bits" = ARMING_SKIPCHK check-by-check editor
    fl       may be saved in flight with Setup AIR EDITS = GAINS+TRIM (as the PID tabs)
]]
return function(g)
  if g == "FLIGHT" then return {
    { "ROLL_LIMIT_DEG", "MAX BANK", "DEG", 0, 90, 1, 0 },
    { "PTCH_LIM_MAX_DEG", "MAX PITCH UP", "DEG", 0, 90, 1, 0 },
    { "PTCH_LIM_MIN_DEG", "MAX PITCH DN", "DEG", -90, 0, 1, 0 },
    { "ARSPD_USE", "USE AIRSPEED", "", 0, 2, 1, 0, "NO|YES|AT 0 THR" },
    { "NAVL1_PERIOD", "NAV PERIOD", "S", 1, 60, 1, 0 },
    { "THR_MIN", "MIN THROTTLE", "%", -100, 100, 1, 0 },
    { "PTCH_TRIM_DEG", "PITCH TRIM", "DEG", -45, 45, 0.1, 1, fl = true },
    { "KFF_THRAT2ELEV", "THR TO ELEV", "US", -500, 500, 1, 0, fl = true },
    { "KFF_RDDRMIX", "RUDDER MIX", "", 0, 1, 0.01, 2 },
    { "YAW2SRV_DAMP", "YAW DAMPER", "", 0, 2, 0.05, 2 },
  } end
  if g == "LAUNCH" then return {
    { "TKOFF_ALT", "TAKEOFF ALT", "M", 0, 200, 1, 0 },
    { "TKOFF_LVL_PITCH", "TAKEOFF PITCH", "DEG", 0, 30, 1, 0 },
    { "TKOFF_THR_MINACC", "LAUNCH ACCEL", "M/S2", 0, 30, 0.1, 1 },
    { "TKOFF_THR_DELAY", "MOTOR DELAY", "DS", 0, 127, 1, 0 },
    { "TKOFF_THR_MAX", "LAUNCH THR", "%", 0, 100, 1, 0 },
  } end
  if g == "RETURN" then return {
    { "RTL_ALTITUDE", "RTL ALTITUDE", "M", -1, 500, 1, 0 },
    { "RTL_RADIUS", "RTL LOITER", "M", -500, 500, 5, 0 },
    { "WP_LOITER_RAD", "LOITER RADIUS", "M", -500, 500, 5, 0 },
    { "RTL_AUTOLAND", "RTL AUTOLAND", "", 0, 4, 1, 0, "OFF|HOME, LAND|DIRECT LAND|GO-AROUND|RETURN PATH" },
  } end
  if g == "FAILSAFE" then return {
    { "FS_SHORT_ACTN", "SHORT FS", "", 0, 4, 1, 0, "CIRC/NO CHG|CIRCLE|FBWA GLIDE|DISABLED|FBWB" },
    { "FS_LONG_ACTN", "LONG FS", "", 0, 4, 1, 0, "CONTINUE|RTL|GLIDE|PARACHUTE|AUTO" },
    { "FS_LONG_TIMEOUT", "LONG FS TIME", "S", 1, 300, 0.5, 1 },
    { "BATT_LOW_VOLT", "LOW VOLT", "V", 0, 60, 0.1, 1 },
    { "BATT_CRT_VOLT", "CRIT VOLT", "V", 0, 60, 0.1, 1 },
    { "BATT_FS_LOW_ACT", "LOW BATT ACT", "", 0, 7, 1, 0, "WARN ONLY|RTL|LAND|TERMINATE|QLAND|PARACHUTE|LOITER-QLAND|AUTOLAND/RTL" },
  } end
  if g == "ARMING" then return {
    { "ARMING_SKIPCHK", "SKIP CHECKS", "", -1, 1048575, 1, 0, nil, "bits" },
    { "ARMING_RUDDER", "RUDDER ARM", "", 0, 2, 1, 0, "OFF|ARM ONLY|ARM+DISARM" },
    { "ARMING_REQUIRE", "REQUIRE ARM", "", 0, 2, 1, 0, "NO|MIN PWM|0 PWM" },
  } end
  if g == "TECS" then return {   -- in the TECS tuning helper's result order
    { "TRIM_THROTTLE", "CRUISE THR", "%", 0, 100, 1, 0 },
    { "AIRSPEED_CRUISE", "CRUISE SPEED", "M/S", 5, 50, 0.5, 1 },
    { "THR_MAX", "MAX THROTTLE", "%", 0, 100, 1, 0 },
    { "AIRSPEED_MAX", "MAX AIRSPEED", "M/S", 5, 100, 1, 0 },
    { "TECS_PITCH_MAX", "MAX PITCH AUTO", "DEG", 0, 45, 1, 0 },
    { "TECS_CLMB_MAX", "MAX CLIMB", "M/S", 0.1, 20, 0.1, 1 },
    { "FBWB_CLIMB_RATE", "FBWB CLIMB", "M/S", 1, 10, 0.1, 1 },
    { "AIRSPEED_MIN", "MIN AIRSPEED", "M/S", 5, 100, 1, 0 },
    { "STAB_PITCH_DOWN", "LOW THR PITCH", "DEG", 0, 15, 0.1, 1 },
    { "TECS_SINK_MIN", "MIN SINK", "M/S", 0.1, 10, 0.1, 1 },
    { "TECS_PITCH_MIN", "MIN PITCH AUTO", "DEG", -45, 0, 1, 0 },
    { "TECS_SINK_MAX", "MAX SINK", "M/S", 0, 20, 0.1, 1 },
    { "KFF_THR2PTCH", "THR TO PITCH", "", -5, 5, 0.01, 2 },
  } end
  if g == "LANDING" then return {
    { "LAND_FLARE_ALT", "FLARE ALT", "M", 0, 30, 0.1, 1 },
    { "LAND_FLARE_SEC", "FLARE TIME", "S", 0, 10, 0.1, 1 },
    { "LAND_PITCH_DEG", "FLARE PITCH", "DEG", -20, 20, 0.5, 1 },
    { "TECS_LAND_ARSPD", "APPROACH SPD", "M/S", -1, 127, 1, 0 },   -- -1: midway between min and cruise
  } end
  if g == "PID" then return {
    { "RLL_RATE_P", "ROLL P", "", 0, 1, 0.005, 3 },
    { "RLL_RATE_I", "ROLL I", "", 0, 1, 0.01, 3 },
    { "RLL_RATE_D", "ROLL D", "", 0, 0.1, 0.001, 4 },
    { "RLL_RATE_FF", "ROLL FF", "", 0, 3, 0.001, 3 },
    { "PTCH_RATE_P", "PITCH P", "", 0, 1, 0.005, 3 },
    { "PTCH_RATE_I", "PITCH I", "", 0, 1, 0.01, 3 },
    { "PTCH_RATE_D", "PITCH D", "", 0, 0.1, 0.001, 4 },
    { "PTCH_RATE_FF", "PITCH FF", "", 0, 3, 0.001, 3 },
    { "RLL2SRV_TCONST", "ROLL TCONST", "S", 0.4, 1, 0.05, 2 },
    { "PTCH2SRV_TCONST", "PITCH TCONST", "S", 0.4, 1, 0.05, 2 },
    { "RLL2SRV_RMAX", "MAX ROLL RATE", "DEG/S", 0, 180, 1, 0 },
    { "PTCH2SRV_RMAX_UP", "PITCH UP RATE", "DEG/S", 0, 100, 1, 0 },
    { "PTCH2SRV_RMAX_DN", "PITCH DN RATE", "DEG/S", 0, 100, 1, 0 },
    { "AUTOTUNE_LEVEL", "AUTOTUNE LEVEL", "", 0, 10, 1, 0 },
  } end
  if g == "VTOL" then return {
    { "Q_ASSIST_SPEED", "ASSIST SPEED", "M/S", -1, 100, 0.1, 1 },   -- -1: Q_ASSIST off
    { "Q_ASSIST_ALT", "ASSIST ALT", "M", 0, 120, 1, 0 },            -- 0: off
    { "Q_RTL_MODE", "VTOL RTL", "", 0, 3, 1, 0, "OFF|ON|VTOL APPR|QRTL ALWAYS" },
    { "Q_TRANSITION_MS", "TRANSITION", "MS", 500, 30000, 100, 0 },
    { "Q_LAND_FINAL_SPD", "FINAL DESCENT", "M/S", 0.3, 2, 0.1, 1 },
    { "Q_FS_EKF_HOLD", "EKF FS HOLD", "S", 0, 60, 1, 0 },
    { "Q_A_ANGLE_MAX", "MAX LEAN", "DEG", 10, 80, 1, 0 },
  } end
  if g == "Q PID" then return {
    { "Q_A_RAT_RLL_P", "HOVER ROLL P", "", 0, 0.5, 0.005, 3 },
    { "Q_A_RAT_RLL_I", "HOVER ROLL I", "", 0, 2, 0.005, 3 },
    { "Q_A_RAT_RLL_D", "HOVER ROLL D", "", 0, 0.05, 0.0005, 4 },
    { "Q_A_RAT_PIT_P", "HOVER PITCH P", "", 0, 0.5, 0.005, 3 },
    { "Q_A_RAT_PIT_I", "HOVER PITCH I", "", 0, 2, 0.005, 3 },
    { "Q_A_RAT_PIT_D", "HOVER PITCH D", "", 0, 0.05, 0.0005, 4 },
    { "Q_A_RAT_YAW_P", "HOVER YAW P", "", 0, 2.5, 0.005, 3 },
    { "Q_A_RAT_YAW_I", "HOVER YAW I", "", 0, 1, 0.001, 3 },
    { "Q_A_ANG_RLL_P", "ROLL ANGLE P", "", 3, 12, 0.1, 2 },
    { "Q_A_ANG_PIT_P", "PITCH ANGLE P", "", 3, 12, 0.1, 2 },
    { "Q_A_ANG_YAW_P", "YAW ANGLE P", "", 3, 12, 0.1, 2 },
  } end
  return {}
end
