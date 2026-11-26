-- EdgeTX: run in the adapter's environment (etx.lua sets OD_ENV). EdgeTX 2.9 breaks loadScript's
-- env argument (_ENV nil), so the module sets it itself; on Ethos OD_ENV is nil and nothing changes.
local _ENV = OD_ENV or _ENV
--[[
  Betaflight rows for the PARAMS page (params.lua, link "MSP"), loaded only once the flight
  controller says it is Betaflight (MSP_FC_VARIANT "BTFL"). Betaflight 4.5 (MSP API 1.46) and
  2025.12 (API 1.47) only: Betaflight has no settings by name over MSP, only fixed blocks of bytes,
  and their layouts change between versions.

  Read: the whole block (MSP_PID, MSP_PID_ADVANCED, MSP_RC_TUNING, MSP_FILTER_CONFIG). Write: the
  block as read with the one field changed, sent only up to the end of that field's group: each
  Betaflight SET handler reads the later groups only "if bytes remain", so everything after the
  group stays as it is. Layouts checked against msp.c of 4.5.5 and 2025.12.5 (GET and SET read the
  same order; byte positions below are 0-based offsets into the reply).
  The PID, rate and filter values are those of the ACTIVE PID / rate profile (MSP_STATUS_EX).

  Row: { group, name, label, unit, min, max, step, decimals, -, -, k = scale, fl = in flight,
         bf = { get cmd, offset, size, prefix length }, rt = rate field (labels follow rates_type) }
  shown value = raw x k; min / max = Betaflight's CLI limits (cli/settings.c), raw.
]]
local B = {}
local PID, ADV, RC, FIL = 112, 94, 111, 92        -- MSP_PID, MSP_PID_ADVANCED, MSP_RC_TUNING, MSP_FILTER_CONFIG
B.SET = { [PID] = 202, [ADV] = 95, [RC] = 204, [FIL] = 93 }
-- the shortest reply taken for each block (a shorter one is not a 4.5 / 2025.12 layout)
B.MINLEN = { [PID] = 15, [ADV] = 61, [RC] = 23, [FIL] = 49 }   -- ADV: 61 bytes on 4.5 / 2025.12 / 2026.6
B.CMDS = { PID, ADV, RC, FIL }

local function row(g, name, label, unit, mn, mx, step, dec, k, bf, fl, rt, opts)
  return { g, name, label, unit, mn * k, mx * k, step, dec, opts, nil, k = k, fl = fl, bf = bf, rt = rt, rmin = mn, rmax = mx }
end
local rows = {}
local function add(r) rows[#rows + 1] = r end
-- PIDs: MSP_PID, 3 bytes per axis (P, I, D), roll / pitch / yaw / level / mag = 15 bytes, all
-- read by SET without a length check: the whole block goes back
for i, ax in ipairs({ "roll", "pitch", "yaw" }) do
  local o = (i - 1) * 3
  local L = string.upper(string.sub(ax, 1, 1)) .. string.sub(ax, 2)
  add(row("PID", "p_" .. ax, L .. " P", "", 0, 250, 1, 0, 1, { PID, o, 1, 15 }, true))
  add(row("PID", "i_" .. ax, L .. " I", "", 0, 250, 1, 0, 1, { PID, o + 1, 1, 15 }, true))
  add(row("PID", "d_" .. ax, L .. " D", "", 0, 250, 1, 0, 1, { PID, o + 2, 1, 15 }, true))
end
-- feedforward (u16 at 32 / 34 / 36, group ends at 39) and D max (4.5: "D min") at 39-42 (to 46)
add(row("FF D", "f_roll", "Roll F", "", 0, 1000, 1, 0, 1, { ADV, 32, 2, 39 }, true))
add(row("FF D", "f_pitch", "Pitch F", "", 0, 1000, 1, 0, 1, { ADV, 34, 2, 39 }, true))
add(row("FF D", "f_yaw", "Yaw F", "", 0, 1000, 1, 0, 1, { ADV, 36, 2, 39 }, true))
add(row("FF D", "d_max_roll", "Roll D max", "", 0, 250, 1, 0, 1, { ADV, 39, 1, 46 }, true))
add(row("FF D", "d_max_pitch", "Pitch D max", "", 0, 250, 1, 0, 1, { ADV, 40, 1, 46 }, true))
add(row("FF D", "d_max_yaw", "Yaw D max", "", 0, 250, 1, 0, 1, { ADV, 41, 1, 46 }, true))
add(row("FF D", "d_max_gain", "D max gain", "", 0, 100, 1, 0, 1, { ADV, 42, 1, 46 }, true))
-- MSP_PID_ADVANCED, the same 61-byte layout on 4.5.2 / 2025.12.5 / 2026.6.2 (msp.c GET and SET).
-- SET groups (each read only if enough bytes remain): 0-16 always, then 17-18, 19-22, 23-24,
-- 25-38, 39-45, 46, 47-49, 50-56, 57-60. The last number in bf is the end of the field's group.
-- Ranges: cli/settings.c of the three versions (the same, angle_limit aside: see forVersion).
add(row("FF D", "feedforward_transition", "FF transition", "", 0, 100, 1, 0, 1, { ADV, 8, 1, 17 }, true))
add(row("FF D", "feedforward_averaging", "FF averaging", "", 0, 3, 1, 0, 1, { ADV, 50, 1, 57 }, false, nil,
  "OFF|2_POINT|3_POINT|4_POINT"))
add(row("FF D", "feedforward_smooth_factor", "FF smoothing", "", 0, 95, 1, 0, 1, { ADV, 51, 1, 57 }, true))
add(row("FF D", "feedforward_jitter_factor", "FF jitter reduction", "", 0, 20, 1, 0, 1, { ADV, 54, 1, 57 }, true))
add(row("FF D", "feedforward_boost", "FF boost", "", 0, 50, 1, 0, 1, { ADV, 52, 1, 57 }, true))
add(row("FF D", "feedforward_max_rate_limit", "FF max rate limit", "%", 0, 200, 1, 0, 1, { ADV, 53, 1, 57 }, true))
-- TUNE: anti-gravity, I-term relax, TPA, throttle and motor settings of the PID profile
add(row("TUNE", "anti_gravity_gain", "Anti gravity", "", 0, 250, 5, 0, 1, { ADV, 21, 2, 23 }, true))
add(row("TUNE", "iterm_relax_cutoff", "I-term relax cutoff", "", 1, 50, 1, 0, 1, { ADV, 46, 1, 47 }, true))
add(row("TUNE", "tpa_mode", "TPA mode", "", 0, 1, 1, 0, 1, { ADV, 57, 1, 61 }, false, nil, "PD|D|PDS"))
add(row("TUNE", "tpa_rate", "TPA rate", "%", 0, 100, 1, 0, 1, { ADV, 58, 1, 61 }, true))
add(row("TUNE", "tpa_breakpoint", "TPA breakpoint", "us", 1000, 2000, 10, 0, 1, { ADV, 59, 2, 61 }, true))
add(row("TUNE", "throttle_boost", "Throttle boost", "", 0, 100, 1, 0, 1, { ADV, 30, 1, 39 }, true))
add(row("TUNE", "dyn_idle_min_rpm", "Dyn idle min", "rpm", 0, 200, 100, 0, 100, { ADV, 49, 1, 50 }, false))
add(row("TUNE", "motor_output_limit", "Motor output limit", "%", 1, 100, 1, 0, 1, { ADV, 47, 1, 50 }, false))
add(row("TUNE", "vbat_sag_compensation", "Vbat sag comp", "%", 0, 150, 1, 0, 1, { ADV, 55, 1, 57 }, false))
add(row("TUNE", "thrust_linear", "Thrust linear", "%", 0, 150, 1, 0, 1, { ADV, 56, 1, 57 }, false))
add(row("TUNE", "angle_limit", "Angle limit", "deg", 10, 80, 1, 0, 1, { ADV, 17, 1, 19 }, false))
-- rates: MSP_RC_TUNING; everything edited sits in the first 14 bytes (SET needs 10, then one
-- byte at a time). Roll: rc rate 0, expo 1, rate 2; pitch: rate 3, rc rate 12, expo 13;
-- yaw: rate 4, expo 10, rc rate 11. Throttle mid 6, expo 7. rates_type at 22 (labels).
local RATE = { roll = { 0, 2, 1 }, pitch = { 12, 3, 13 }, yaw = { 11, 4, 10 } }
for _, ax in ipairs({ "roll", "pitch", "yaw" }) do
  local o = RATE[ax]
  local L = string.upper(string.sub(ax, 1, 1)) .. string.sub(ax, 2)
  add(row("RATES", ax .. "_rc_rate", L .. " RC rate", "", 1, 255, 0.01, 2, 0.01, { RC, o[1], 1, 14 }, false, "rc"))
  add(row("RATES", ax .. "_srate", L .. " super rate", "", 0, 255, 0.01, 2, 0.01, { RC, o[2], 1, 14 }, false, "sr"))
  add(row("RATES", ax .. "_expo", L .. " expo", "", 0, 100, 0.01, 2, 0.01, { RC, o[3], 1, 14 }, false))
end
add(row("RATES", "thr_mid", "Throttle mid", "", 0, 100, 0.01, 2, 0.01, { RC, 6, 1, 14 }, false))
add(row("RATES", "thr_expo", "Throttle expo", "", 0, 100, 0.01, 2, 0.01, { RC, 7, 1, 14 }, false))
-- throttle limit: type at 14, percent at 15 (one SET group, 14-15)
add(row("RATES", "throttle_limit_type", "Throttle limit", "", 0, 2, 1, 0, 1, { RC, 14, 1, 16 }, false, nil,
  "OFF|SCALE|CLIP"))
add(row("RATES", "throttle_limit_percent", "Throttle limit %", "%", 25, 100, 1, 0, 1, { RC, 15, 1, 16 }, false))
-- filters: MSP_FILTER_CONFIG (49 bytes in both versions). Groups end at 28 / 37 / 45 / 47 / 49.
-- Gyro and RPM filters are global, the D-term ones belong to the PID profile.
add(row("FILTERS", "gyro_lpf1_dyn_min_hz", "Gyro LPF1 dyn min", "Hz", 0, 1000, 5, 0, 1, { FIL, 29, 2, 37 }, false))
add(row("FILTERS", "gyro_lpf1_dyn_max_hz", "Gyro LPF1 dyn max", "Hz", 0, 1000, 5, 0, 1, { FIL, 31, 2, 37 }, false))
add(row("FILTERS", "gyro_lpf2_static_hz", "Gyro LPF2", "Hz", 0, 1000, 5, 0, 1, { FIL, 22, 2, 28 }, false))
add(row("FILTERS", "dterm_lpf1_dyn_min_hz", "D-term LPF1 dyn min", "Hz", 0, 1000, 5, 0, 1, { FIL, 33, 2, 37 }, false))
add(row("FILTERS", "dterm_lpf1_dyn_max_hz", "D-term LPF1 dyn max", "Hz", 0, 1000, 5, 0, 1, { FIL, 35, 2, 37 }, false))
add(row("FILTERS", "dterm_lpf2_static_hz", "D-term LPF2", "Hz", 0, 1000, 5, 0, 1, { FIL, 26, 2, 28 }, false))
add(row("FILTERS", "dyn_notch_count", "Dyn notch count", "", 0, 7, 1, 0, 1, { FIL, 48, 1, 49 }, false))
add(row("FILTERS", "dyn_notch_q", "Dyn notch Q", "", 1, 1000, 10, 0, 1, { FIL, 39, 2, 45 }, false))
add(row("FILTERS", "dyn_notch_min_hz", "Dyn notch min", "Hz", 20, 250, 5, 0, 1, { FIL, 41, 2, 45 }, false))
add(row("FILTERS", "dyn_notch_max_hz", "Dyn notch max", "Hz", 200, 1000, 10, 0, 1, { FIL, 45, 2, 47 }, false))
add(row("FILTERS", "rpm_filter_harmonics", "RPM harmonics", "", 0, 3, 1, 0, 1, { FIL, 43, 1, 45 }, false))
add(row("FILTERS", "rpm_filter_min_hz", "RPM min", "Hz", 30, 200, 5, 0, 1, { FIL, 44, 1, 45 }, false))
-- a build without the dynamic notch (USE_DYN_NOTCH_FILTER) or the RPM filter (USE_RPM_FILTER) reads
-- 0 there and ignores writes (msp.c); those zeros are out of range (notch max >= 200 Hz, RPM min
-- >= 30 Hz), so the rows show n/a instead of a made-up 0 (seen on the SITL builds)
for i = #rows - 5, #rows - 2 do rows[i].feat = "notch" end
for i = #rows - 1, #rows do rows[i].feat = "rpm" end
B.rows = rows

local function rowOf(name) for _, r in ipairs(rows) do if r[2] == name then return r end end end
local function setRange(r, mn, mx) r.rmin, r.rmax, r[5], r[6] = mn, mx, mn * r.k, mx * r.k end

-- version differences: 4.5 calls the extra D term "D min" (2025.12: "D max"); the dynamic notch
-- count goes to 5 on 4.5, 7 on 2025.12. api = MSP API minor (46 / 47).
-- The rows carry Betaflight's own CLI names, so they read as in the CLI and Configurator: the axes
-- are d_min_roll ... on 4.5 and d_max_roll ... on 2025.12; the gain is d_max_gain on both (4.5's
-- CLI already names it so, cli/settings.c PARAM_NAME_D_MAX_GAIN). Checked against both SITL builds.
function B.forVersion(api)
  local old = api == 46
  local w = old and "min" or "max"
  for _, ax in ipairs({ "roll", "pitch", "yaw" }) do
    local r = rowOf("d_min_" .. ax) or rowOf("d_max_" .. ax)
    r[2] = "d_" .. w .. "_" .. ax
    r[3] = string.upper(string.sub(ax, 1, 1)) .. string.sub(ax, 2) .. " D " .. w
  end
  rowOf("d_max_gain")[3] = old and "D min gain" or "D max gain"
  setRange(rowOf("dyn_notch_count"), 0, old and 5 or 7)
  setRange(rowOf("angle_limit"), 10, old and 85 or 80)   -- 4.5: 10-85, 2025.12 and later: 10-80
end

-- rates_type (0 BETAFLIGHT, 1 RACEFLIGHT, 2 KISS, 3 ACTUAL, 4 QUICK): the same bytes mean
-- different things, so the labels and units of the rate rows follow it (as Configurator shows them)
B.RATES_TYPES = { [0] = "BETAFLIGHT", "RACEFLIGHT", "KISS", "ACTUAL", "QUICK" }
local RT = {   -- rc rate: label, unit, k, dec; super rate: label, unit, k, dec
  [0] = { "RC rate", "", 0.01, 2, "super rate", "", 0.01, 2 },
  [1] = { "rate", "deg/s", 10, 0, "acro+", "", 1, 0 },
  [2] = { "RC rate", "", 0.01, 2, "rate", "", 0.01, 2 },
  [3] = { "center", "deg/s", 10, 0, "max rate", "deg/s", 10, 0 },
  [4] = { "RC rate", "", 0.01, 2, "max rate", "deg/s", 10, 0 },
}
function B.ratesType(t)
  local d = RT[t] or RT[0]
  for _, r in ipairs(rows) do
    if r.rt then
      local ax = string.match(r[2], "^(%a+)_")
      local L = string.upper(string.sub(ax, 1, 1)) .. string.sub(ax, 2)
      local o = r.rt == "rc" and 0 or 4
      r[3], r[4], r.k, r[8] = L .. " " .. d[o + 1], d[o + 2], d[o + 3], d[o + 4]
      r[7] = d[o + 3]
      r[5], r[6] = r.rmin * r.k, r.rmax * r.k
    end
  end
end

-- false when the block shows the row's feature is not in this build (see .feat above)
function B.present(r, blk)
  if r.feat == "notch" then return (blk[46] or 0) + (blk[47] or 0) * 256 >= 200 end
  if r.feat == "rpm" then return (blk[45] or 0) >= 30 end
  return true
end
-- the raw value of a row from its block (unsigned, little-endian)
function B.raw(r, blk)
  local o = r.bf[2] + 1
  if r.bf[3] == 2 then return (blk[o] or 0) + (blk[o + 1] or 0) * 256 end
  return blk[o] or 0
end
-- the SET payload: the block as read with this row's field changed, cut at the end of its group
function B.patch(r, blk, raw)
  local n, o = r.bf[4], r.bf[2] + 1
  local p = {}
  for i = 1, n do p[i] = blk[i] or 0 end
  raw = math.floor(raw + 0.5)
  if r.bf[3] == 2 then p[o], p[o + 1] = raw % 256, math.floor(raw / 256) % 256
  else p[o] = raw % 256 end
  return p
end

return B
