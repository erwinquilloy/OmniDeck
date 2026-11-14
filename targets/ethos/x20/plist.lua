-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  OmniDeck PARAMS page: the ArduPlane parameters it shows, in this order.
  Names, ranges and option names are from the Stratos v2.2 source (ArduPlane 4.7.2 base).

  { group, name, label, unit, min, max, step, decimals, options, kind }
    options  "a|b|c" = value 0, 1, 2 shown by name (nil: a number)
    kind     "bits" = ARMING_SKIPCHK check-by-check editor, "q" = only with Q_ENABLE 1
  A parameter the flight controller doesn't have shows "n/a" and can't be edited.
]]
return {
  { "FLIGHT", "ROLL_LIMIT_DEG", "Max bank", "deg", 0, 90, 1, 0 },
  { "FLIGHT", "PTCH_LIM_MAX_DEG", "Max pitch up", "deg", 0, 90, 1, 0 },
  { "FLIGHT", "PTCH_LIM_MIN_DEG", "Max pitch down", "deg", -90, 0, 1, 0 },
  { "FLIGHT", "ARSPD_USE", "Use airspeed", "", 0, 2, 1, 0, "Don't use|Use|Use at 0 thr" },
  { "FLIGHT", "NAVL1_PERIOD", "Nav period (L1)", "s", 1, 60, 1, 0 },
  { "FLIGHT", "THR_MIN", "Min throttle", "%", -100, 100, 1, 0 },
  { "FLIGHT", "PTCH_TRIM_DEG", "Pitch trim", "deg", -45, 45, 0.1, 1, fl = true },
  { "FLIGHT", "KFF_THRAT2ELEV", "Thrust to elevator", "us", -500, 500, 1, 0, fl = true },
  { "FLIGHT", "KFF_RDDRMIX", "Rudder mix", "", 0, 1, 0.01, 2 },
  { "FLIGHT", "YAW2SRV_DAMP", "Yaw damper", "", 0, 2, 0.05, 2 },
  { "LAUNCH", "TKOFF_ALT", "Takeoff alt", "m", 0, 200, 1, 0 },
  { "LAUNCH", "TKOFF_LVL_PITCH", "Takeoff pitch", "deg", 0, 30, 1, 0 },
  { "LAUNCH", "TKOFF_THR_MINACC", "Launch accel", "m/s/s", 0, 30, 0.1, 1 },
  { "LAUNCH", "TKOFF_THR_DELAY", "Motor delay", "ds", 0, 127, 1, 0 },
  { "LAUNCH", "TKOFF_THR_MAX", "Launch throttle", "%", 0, 100, 1, 0 },
  { "RETURN", "RTL_ALTITUDE", "RTL altitude", "m", -1, 500, 1, 0 },
  { "RETURN", "RTL_RADIUS", "RTL loiter", "m", -500, 500, 5, 0 },
  { "RETURN", "WP_LOITER_RAD", "Loiter radius", "m", -500, 500, 5, 0 },
  { "RETURN", "RTL_AUTOLAND", "RTL autoland", "", 0, 4, 1, 0, "Disable|Fly home, land|Direct to land|Go-around only|Return path" },
  { "FAILSAFE", "FS_SHORT_ACTN", "Short FS", "", 0, 4, 1, 0, "Circle/no change|Circle|FBWA glide|Disabled|FBWB" },
  { "FAILSAFE", "FS_LONG_ACTN", "Long FS", "", 0, 4, 1, 0, "Continue|RTL|Glide|Parachute|Auto" },
  { "FAILSAFE", "FS_LONG_TIMEOUT", "Long FS time", "s", 1, 300, 0.5, 1 },
  { "FAILSAFE", "BATT_LOW_VOLT", "Low volt", "V", 0, 60, 0.1, 1 },
  { "FAILSAFE", "BATT_CRT_VOLT", "Critical volt", "V", 0, 60, 0.1, 1 },
  { "FAILSAFE", "BATT_FS_LOW_ACT", "Low batt action", "", 0, 7, 1, 0, "Warn only|RTL|Land|Terminate|QLand|Parachute|Loiter to QLand|AUTOLAND or RTL" },
  { "ARMING", "ARMING_SKIPCHK", "Skip checks", "", -1, 1048575, 1, 0, nil, "bits" },
  { "ARMING", "ARMING_RUDDER", "Rudder arming", "", 0, 2, 1, 0, "Disabled|Arming only|Arm or disarm" },
  { "ARMING", "ARMING_REQUIRE", "Require arming", "", 0, 2, 1, 0, "Disabled|Yes (min PWM)|Yes (0 PWM)" },
  -- TECS: what the TECS tuning helper (Arduplane_TECS_tuning_helper_ETHOS_ETX) works out, in the
  -- order of its result screen / tecs_<time>.txt (listed here only, not in FLIGHT).
  { "TECS", "TRIM_THROTTLE", "Cruise throttle", "%", 0, 100, 1, 0 },
  { "TECS", "AIRSPEED_CRUISE", "Cruise speed", "m/s", 5, 50, 0.5, 1 },
  { "TECS", "THR_MAX", "Max throttle", "%", 0, 100, 1, 0 },
  { "TECS", "AIRSPEED_MAX", "Max airspeed", "m/s", 5, 100, 1, 0 },
  { "TECS", "TECS_PITCH_MAX", "Max pitch (auto)", "deg", 0, 45, 1, 0 },
  { "TECS", "TECS_CLMB_MAX", "Max climb", "m/s", 0.1, 20, 0.1, 1 },
  { "TECS", "FBWB_CLIMB_RATE", "FBWB climb rate", "m/s", 1, 10, 0.1, 1 },
  { "TECS", "AIRSPEED_MIN", "Min airspeed", "m/s", 5, 100, 1, 0 },
  { "TECS", "STAB_PITCH_DOWN", "Low-thr pitch down", "deg", 0, 15, 0.1, 1 },
  { "TECS", "TECS_SINK_MIN", "Min sink", "m/s", 0.1, 10, 0.1, 1 },
  { "TECS", "TECS_PITCH_MIN", "Min pitch (auto)", "deg", -45, 0, 1, 0 },
  { "TECS", "TECS_SINK_MAX", "Max sink", "m/s", 0, 20, 0.1, 1 },
  { "TECS", "KFF_THR2PTCH", "Throttle to pitch", "", -5, 5, 0.01, 2 },
  -- LANDING (replaces TRIM): fixed-wing autoland flare and approach
  { "LANDING", "LAND_FLARE_ALT", "Flare altitude", "m", 0, 30, 0.1, 1 },
  { "LANDING", "LAND_FLARE_SEC", "Flare time", "s", 0, 10, 0.1, 1 },
  { "LANDING", "LAND_PITCH_DEG", "Flare pitch", "deg", -20, 20, 0.5, 1 },
  { "LANDING", "TECS_LAND_ARSPD", "Approach speed", "m/s", -1, 127, 1, 0 },   -- -1: midway between min and cruise
  { "PID", "RLL_RATE_P", "Roll P", "", 0, 1, 0.005, 3 },
  { "PID", "RLL_RATE_I", "Roll I", "", 0, 1, 0.01, 3 },
  { "PID", "RLL_RATE_D", "Roll D", "", 0, 0.1, 0.001, 4 },
  { "PID", "RLL_RATE_FF", "Roll FF", "", 0, 3, 0.001, 3 },
  { "PID", "PTCH_RATE_P", "Pitch P", "", 0, 1, 0.005, 3 },
  { "PID", "PTCH_RATE_I", "Pitch I", "", 0, 1, 0.01, 3 },
  { "PID", "PTCH_RATE_D", "Pitch D", "", 0, 0.1, 0.001, 4 },
  { "PID", "PTCH_RATE_FF", "Pitch FF", "", 0, 3, 0.001, 3 },
  { "PID", "RLL2SRV_TCONST", "Roll time const", "s", 0.4, 1, 0.05, 2 },
  { "PID", "PTCH2SRV_TCONST", "Pitch time const", "s", 0.4, 1, 0.05, 2 },
  { "PID", "RLL2SRV_RMAX", "Max roll rate", "deg/s", 0, 180, 1, 0 },
  { "PID", "PTCH2SRV_RMAX_UP", "Max pitch up rate", "deg/s", 0, 100, 1, 0 },
  { "PID", "PTCH2SRV_RMAX_DN", "Max pitch dn rate", "deg/s", 0, 100, 1, 0 },
  { "PID", "AUTOTUNE_LEVEL", "Autotune level", "", 0, 10, 1, 0 },
  { "VTOL", "Q_ASSIST_SPEED", "Assist speed", "m/s", -1, 100, 0.1, 1, nil, "q" },   -- -1: Q_ASSIST off (no pre-arm failure)
  { "VTOL", "Q_ASSIST_ALT", "Assist altitude", "m", 0, 120, 1, 0, nil, "q" },     -- 0: off
  { "VTOL", "Q_RTL_MODE", "VTOL RTL", "", 0, 3, 1, 0, "Disabled|Enabled|VTOL approach|QRTL always", "q" },
  { "VTOL", "Q_TRANSITION_MS", "Transition time", "ms", 500, 30000, 100, 0, nil, "q" },
  { "VTOL", "Q_LAND_FINAL_SPD", "Final descent", "m/s", 0.3, 2, 0.1, 1, nil, "q" },
  { "VTOL", "Q_FS_EKF_HOLD", "EKF FS hold", "s", 0, 60, 1, 0, nil, "q" },
  { "VTOL", "Q_A_ANGLE_MAX", "Max hover lean", "deg", 10, 80, 1, 0, nil, "q" },
  { "Q PID", "Q_A_RAT_RLL_P", "Hover roll P", "", 0, 0.5, 0.005, 3, nil, "q" },
  { "Q PID", "Q_A_RAT_RLL_I", "Hover roll I", "", 0, 2, 0.005, 3, nil, "q" },
  { "Q PID", "Q_A_RAT_RLL_D", "Hover roll D", "", 0, 0.05, 0.0005, 4, nil, "q" },
  { "Q PID", "Q_A_RAT_PIT_P", "Hover pitch P", "", 0, 0.5, 0.005, 3, nil, "q" },
  { "Q PID", "Q_A_RAT_PIT_I", "Hover pitch I", "", 0, 2, 0.005, 3, nil, "q" },
  { "Q PID", "Q_A_RAT_PIT_D", "Hover pitch D", "", 0, 0.05, 0.0005, 4, nil, "q" },
  { "Q PID", "Q_A_RAT_YAW_P", "Hover yaw P", "", 0, 2.5, 0.005, 3, nil, "q" },
  { "Q PID", "Q_A_RAT_YAW_I", "Hover yaw I", "", 0, 1, 0.001, 3, nil, "q" },
  { "Q PID", "Q_A_ANG_RLL_P", "Hover roll angle P", "", 3, 12, 0.1, 2, nil, "q" },
  { "Q PID", "Q_A_ANG_PIT_P", "Hover pitch angle P", "", 3, 12, 0.1, 2, nil, "q" },
  { "Q PID", "Q_A_ANG_YAW_P", "Hover yaw angle P", "", 3, 12, 0.1, 2, nil, "q" },
}
