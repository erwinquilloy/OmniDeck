-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  INAV rows for the PARAMS page (params.lua, link "MSP"), INAV 9.0 or later: the settings are read
  and set by their CLI name over MSPv2 (MSP2_COMMON_SETTING_INFO / _SET_SETTING). Same layout as
  plist.lua:
    { group, name, label, unit, min, max, step, decimals, choices, -, k = scale, fl = true, pid = }
  k:   shown value = INAV's raw value x k (INAV keeps decidegrees, cm, cm/s, tens of deg/s)
  min / max: placeholders; the flight controller's own limits replace them on the first read
  choices: nil here; a lookup setting gets INAV's own names on the first read (as the CLI shows)
  fl:  may be changed in flight with "Params: edit in flight" = "Gains and trim"
  pid: "fw" / "mc" - lives in the control profile; editable only while that profile's platform
       is active (VTOL with mixer_control_profile_linking: the radio's VTOL switch picks it)
]]
return {
  { "FLIGHT", "max_angle_inclination_rll", "Max bank (angle)", "deg", 10, 90, 1, 0, k = 0.1 },
  { "FLIGHT", "max_angle_inclination_pit", "Max pitch (angle)", "deg", 10, 90, 1, 0, k = 0.1 },
  { "FLIGHT", "fw_level_pitch_trim", "Level pitch trim", "deg", -10, 10, 0.1, 1, fl = true },
  { "FLIGHT", "roll_rate", "Roll rate", "deg/s", 40, 1800, 10, 0, k = 10 },
  { "FLIGHT", "pitch_rate", "Pitch rate", "deg/s", 40, 1800, 10, 0, k = 10 },
  { "FLIGHT", "yaw_rate", "Yaw rate", "deg/s", 10, 1800, 10, 0, k = 10 },
  { "FLIGHT", "fw_turn_assist_pitch_gain", "Turn assist pitch", "", 0, 2, 0.05, 2 },

  { "LAUNCH", "nav_fw_launch_thr", "Launch throttle", "us", 1000, 2000, 10, 0 },
  { "LAUNCH", "nav_fw_launch_idle_thr", "Idle throttle", "us", 1000, 2000, 10, 0 },
  { "LAUNCH", "nav_fw_launch_accel", "Launch accel", "m/s/s", 13.5, 200, 0.1, 1, k = 0.01 },
  { "LAUNCH", "nav_fw_launch_climb_angle", "Climb angle", "deg", 5, 45, 1, 0 },
  { "LAUNCH", "nav_fw_launch_motor_delay", "Motor delay", "ms", 0, 5000, 50, 0 },
  { "LAUNCH", "nav_fw_launch_max_altitude", "Launch end alt", "m", 0, 600, 1, 0, k = 0.01 },
  { "LAUNCH", "nav_fw_launch_max_angle", "Max launch tilt", "deg", 5, 180, 1, 0 },

  { "NAV THR", "nav_fw_cruise_thr", "Cruise throttle", "us", 1000, 2000, 10, 0 },
  { "NAV THR", "nav_fw_min_thr", "Min throttle", "us", 1000, 2000, 10, 0 },
  { "NAV THR", "nav_fw_max_thr", "Max throttle", "us", 1000, 2000, 10, 0 },
  { "NAV THR", "nav_fw_pitch2thr", "Pitch to throttle", "", 0, 100, 1, 0 },
  { "NAV THR", "nav_fw_climb_angle", "Max climb angle", "deg", 5, 80, 1, 0 },
  { "NAV THR", "nav_fw_dive_angle", "Max dive angle", "deg", 5, 80, 1, 0 },
  { "NAV THR", "nav_fw_bank_angle", "Max nav bank", "deg", 5, 80, 1, 0 },
  { "NAV THR", "nav_fw_cruise_speed", "Cruise speed", "m/s", 0, 655, 0.5, 1, k = 0.01 },
  { "NAV THR", "nav_fw_allow_manual_thr_increase", "Manual thr increase", "", 0, 1, 1, 0 },

  { "RTH", "nav_rth_altitude", "RTH altitude", "m", 0, 650, 1, 0, k = 0.01 },
  { "RTH", "nav_rth_alt_mode", "RTH alt mode", "", 0, 4, 1, 0 },
  { "RTH", "nav_rth_home_altitude", "Home altitude", "m", 0, 650, 1, 0, k = 0.01 },
  { "RTH", "nav_rth_climb_first", "Climb first", "", 0, 2, 1, 0 },
  { "RTH", "nav_fw_loiter_radius", "Loiter radius", "m", 0, 300, 5, 0, k = 0.01 },

  { "LANDING", "nav_fw_land_approach_length", "Approach length", "m", 1, 1000, 5, 0, k = 0.01 },
  { "LANDING", "nav_fw_land_glide_alt", "Glide altitude", "m", 1, 50, 0.5, 1, k = 0.01 },
  { "LANDING", "nav_fw_land_flare_alt", "Flare altitude", "m", 0, 100, 0.5, 1, k = 0.01 },
  { "LANDING", "nav_fw_land_glide_pitch", "Glide pitch", "deg", -15, 45, 1, 0 },
  { "LANDING", "nav_fw_land_flare_pitch", "Flare pitch", "deg", -15, 45, 1, 0 },

  { "MISSION", "nav_wp_radius", "WP radius", "m", 0.1, 100, 1, 1, k = 0.01 },
  { "MISSION", "nav_auto_speed", "Auto speed", "m/s", 0.1, 20, 0.5, 1, k = 0.01 },
  { "MISSION", "nav_max_auto_speed", "Max auto speed (MC)", "m/s", 0.1, 20, 0.5, 1, k = 0.01 },
  { "MISSION", "nav_extra_arming_safety", "Nav arming safety", "", 0, 1, 1, 0 },

  { "FW PID", "fw_p_roll", "Roll P", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_i_roll", "Roll I", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_d_roll", "Roll D", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_ff_roll", "Roll FF", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_p_pitch", "Pitch P", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_i_pitch", "Pitch I", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_d_pitch", "Pitch D", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_ff_pitch", "Pitch FF", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_p_yaw", "Yaw P", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_i_yaw", "Yaw I", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_ff_yaw", "Yaw FF", "", 0, 255, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "tpa_rate", "TPA rate", "%", 0, 200, 1, 0, fl = true, pid = "fw" },
  { "FW PID", "tpa_breakpoint", "TPA breakpoint", "us", 1000, 2000, 10, 0, fl = true, pid = "fw" },
  { "FW PID", "fw_tpa_time_constant", "TPA time const", "ms", 0, 5000, 50, 0, fl = true, pid = "fw" },

  { "MC PID", "mc_p_roll", "Hover roll P", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "mc_i_roll", "Hover roll I", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "mc_d_roll", "Hover roll D", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "mc_p_pitch", "Hover pitch P", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "mc_i_pitch", "Hover pitch I", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "mc_d_pitch", "Hover pitch D", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "mc_p_yaw", "Hover yaw P", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "mc_i_yaw", "Hover yaw I", "", 0, 255, 1, 0, fl = true, pid = "mc" },
  { "MC PID", "nav_mc_hover_thr", "Hover throttle", "us", 1000, 2000, 10, 0, fl = true },
  { "MC PID", "nav_land_maxalt_vspd", "Land speed high", "m/s", 1, 20, 0.1, 1, k = 0.01 },
  { "MC PID", "nav_land_minalt_vspd", "Land speed low", "m/s", 0.5, 5, 0.1, 1, k = 0.01 },
}
