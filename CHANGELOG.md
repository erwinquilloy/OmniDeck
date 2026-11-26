# Changelog

OmniDeck for colour radios (FrSky Ethos and EdgeTX) and OmniDeck Mono for black-and-white EdgeTX radios. Newest first. Each entry lists what changed since the previous public release, as it behaves in that version.

- [OmniDeck 1.0.0f](#omnideck-100f--in-testing) (in testing)
- [OmniDeck Mono 0.1.2](#omnideck-mono-012--in-testing) (in testing)
- [OmniDeck 0.4.1](#omnideck-041--2026-11-23)
- [OmniDeck Mono 0.1.1](#omnideck-mono-011--2026-11-23)
- [OmniDeck Mono 0.1.0](#omnideck-mono-010--2026-11-20)
- [OmniDeck 0.3.0](#omnideck-030--2026-11-12)

## OmniDeck 1.0.0f — in testing

Changes since 0.4.1. Ethos (X20 family, X18 and other 480 × 320 screens) and EdgeTX colour radios (TX16S MK2 480 × 272, TX16S MK3 800 × 480).

### PARAMS page for INAV (new)

- Change INAV settings from the radio, on the X20, X18 and EdgeTX. Needs **INAV 9.1.0 or later**: INAV 7 and 8 can't carry the setting commands over the radio link, and INAV 9.0.x answers them without the values (fixed in 9.1.0). Those versions get "Parameters need INAV 9.1 or later".
- Links: ExpressLRS (Link Mode Normal) and TBS Crossfire at 150 Hz, S.Port / F.Port, and mLRS with a test mLRS Tx firmware ("MSP over cbridge"; stock mLRS drops the radio's MSP).
- 62 settings in 8 groups: FLIGHT, LAUNCH, NAV THR, RTH, LANDING, MISSION, FW PID, MC PID. Named as in the CLI and shown in plain units (degrees, m, m/s) where INAV stores decidegrees, cm and cm/s. Ranges and choice names come from the flight controller; a setting it doesn't have shows n/a.
- Save: INAV sets the value, OmniDeck reads it back, then stores it in EEPROM while disarmed ("Saved, verified and stored").
- In flight: OmniDeck asks INAV itself whether it is armed. With "Gains and trim" the PID groups, level trim and hover throttle can be changed; they work at once and are stored after the disarm, on any page ("NOT STORED" on the hint line until then).
- VTOL (`mixer_control_profile_linking` ON): the active profile only, shown on the hint line. Hover PIDs can be changed only in multirotor mode and plane PIDs only in fixed-wing mode.
- The INAV mission download pauses while the page talks to INAV.

### PARAMS page for Betaflight (new)

- Change Betaflight settings from the radio, on the X20, X18 and EdgeTX: **Betaflight 4.5, 2025.12 and 2026.6** (MSP API 1.46, 1.47, 1.48), over ExpressLRS / TBS Crossfire (150 Hz) and S.Port / F.Port. Checked on a quad with Betaflight 2026.6 over ExpressLRS.
- Betaflight sends its settings as fixed blocks of bytes whose layout can change between versions. Another version gets "Parameters need Betaflight 4.5, 2025.12 or 2026.6" with the version it found, and nothing is written.
- 58 settings in 5 groups, named as in the Betaflight CLI:
  - **PID:** P, I, D for roll, pitch and yaw.
  - **FF D:** feedforward per axis; D max per axis and D max gain (4.5 calls these D min); FF transition, averaging, smoothing, jitter reduction, boost and max rate limit.
  - **TUNE:** anti gravity, I-term relax cutoff, TPA mode, rate and breakpoint, throttle boost, dynamic idle (in rpm), motor output limit, vbat sag compensation, thrust linear, angle limit.
  - **RATES:** RC rate, super rate and expo per axis (labels follow the rates type: Actual shows center / max rate in deg/s), throttle mid and expo, throttle limit type and percent.
  - **FILTERS:** gyro and D-term lowpass, dynamic notch (count, Q, min, max), RPM filter (harmonics, min). A build without the dynamic notch or RPM filter shows those as n/a.
- Choice settings show by name (TPA mode PD / D, throttle limit OFF / SCALE / CLIP, FF averaging OFF / 2_POINT / 3_POINT / 4_POINT).
- The active PID and rate profile only; the hint line shows the version, both profiles and the rates type. Switch profiles in Betaflight; the page follows.
- Save: the block is read fresh, only that setting changed, sent back up to the end of its group, read back, then stored in EEPROM while disarmed. Everything else in the block stays as it was.
- In flight: as INAV. With "Gains and trim", PID, FF D (FF averaging aside) and the TUNE gains (anti gravity, I-term relax cutoff, TPA rate and breakpoint, throttle boost) can be changed; the rest is view only while armed.
- If the radio can't load the Betaflight list, the page says so and gives the reason.

### PARAMS editor (all flight controllers)

- Hold **-** or **+** (and -10 / +10 on the X18) and the value keeps stepping: after half a second, 10 steps a second, faster after 2.5 s, until the finger lifts or slides off the button. A tap is still one step; nothing is sent before Save.
- Two settings renamed: "Params page (ArduPilot, INAV)" (was "ArduPilot params page"; it covers Betaflight too) and "Params: edit in flight".
- The "doesn't answer" explanation wraps to fit the screen.

### mLRS

- The PARAMS page, the ArduPilot mission download and the mission editor's Send use mLRS's own bridge frames (0x81 / 0x82) with Tx Ser Port = cbridge. The CRSF MAVLink frames (0xAA) used before were sent wrong by the first mLRS 1.5.00 build (fixed in the re-released 1.5), and the mLRS developer recommends 0x81 / 0x82.
- Works with mLRS 1.4.04, 1.5 and later. mLRS 1.4.00 and 1.4.02 have no bridge: telemetry works there, but no PARAMS page or mission transfer.
- INAV over mLRS: OmniDeck tries the CRSF MSP frames and the mLRS bridge by itself and keeps the one INAV answers on; the Sensor check page shows which.

### TX16S MK3 (800 × 480)

- Main page: the bottom blocks no longer run under the message line.
- Top bar: smaller text, so the TX battery shows.
- OmniDeck Setup: rows no longer overlap, and are taller to tap.
- Touch: a tap that moved a little was taken for a drag and ignored; the limit now scales with the screen.
- The mission editor and the PARAMS page act on the press, so a button no longer needs a second tap.

### All radios

- **Battery block:** a small line above the gauge shows the average cell voltage ("AVE CELL 3.95V"). New setting "Battery block shows": Battery voltage (default) or Average cell, which swaps the two ("BATT 15.8V" on the small line). Cell count from "Battery cells", or worked out from the voltage.
- **Logo panel:** the logo (OmniDeck, Stratos or your own PNG in `logos/`) fills the top-right panel as far as it can and keeps its proportions.
- **Top bar:** the model name follows a model switch. On EdgeTX, when space is short the model name is shortened first, then left out; the TX battery always stays.
- **Sensor check page:** no longer stops with "attempt to concatenate a nil value (field 'name')" while INAV is connecting or an ArduPilot mission is uploading.

## OmniDeck Mono 0.1.2 — in testing

- **212 × 64 screens** (FrSky Taranis X9D, X9D+, X9E) use the whole width: the horizon and a wider data column side by side, a full-width map at the same scale, 34-character message lines, wider sensor names and values, and full-width summary, link check, Setup tool and start-failure screens.
- On 128 × 64 every page is the same as in 0.1.1.
- Checked in the simulator at both sizes; not yet on a Taranis.

## OmniDeck 0.4.1 — 2026-11-23

The first public release since 0.3.0. All new features are ArduPilot only and Off by default.

- **PARAMS page:** read and change 77 ArduPlane parameters from the radio, in groups (FLIGHT, LAUNCH, RETURN, FAILSAFE, ARMING, TECS, LANDING, PID, and on a quadplane VTOL and Q PID). Two columns, only the open group read, every save read back ("Saved and verified"), `ARMING_SKIPCHK` as a list of checks, view only while armed unless "Gains and trim", your own rows in `params.txt`. X18: larger rows, drag to scroll, -10 / +10.
- **ArduPilot mission on the map:** downloaded from the aircraft (setting "ArduPilot mission download"), checked every 10 s while disarmed.
- **Mission editor** (EdgeTX colour and the Ethos X20 family): EDIT on the map page; add, move and delete items by touch, item types from waypoint to VTOL land, Send with read-back ("Sent and verified").
- **Settings list grouped** the same way on Ethos and EdgeTX.
- Paths: FrSky MAVlite over S.Port / F.Port (any ArduPilot), MAVlite over CRSF (ArduPlane Stratos v2.2.1 or later), mLRS CRSF bridge (any ArduPilot, mLRS 1.4.04 or later).

## OmniDeck Mono 0.1.1 — 2026-11-23

- **Map like the colour builds:** "MAP VIEW" keeps the aircraft (default) or home in the centre; wheel zoom from 50 m to 50 km; the aircraft's coordinates on the bottom line.
- **Low-altitude alarm:** "Terrain, pull up" when armed and below the "LOW ALT" setting, after having been above it once.
- **About 15 KB less Lua memory** than 0.1.0, which fixes the freezes and "not enough memory" seen on the TX12 MK2, mostly over mLRS. The Link check page shows LUA MEM live and its peak.
- A failed start shows "OmniDeck: not started" with the reason and LUA MEM, and retries every 5 s.

## OmniDeck Mono 0.1.0 — 2026-11-20

First release, beta: OmniDeck for 128 × 64 black-and-white EdgeTX radios as a telemetry screen script. Main page (horizon, heading, labelled data column), map, ArduPilot messages, flight stats, link check, sensor check, flight summary and log, voice with the Aria and Guy packs, settings per model in OmniDeck Setup.

## OmniDeck 0.3.0 — 2026-11-12

- **TBS Crossfire at 50 Hz with ArduPilot:** no false NO TELEMETRY flashes between telemetry bursts; ground speed, satellites, home distance and battery keep updating between them. Force 150 Hz for a live horizon.
- **More than 15 satellites with ArduPilot:** the real count over Crossfire and ELRS, "15+" over S.Port and F.Port.
- **Map + and - buttons** accept taps near them instead of turning the page.
- **Sensor check page scrolls**, so the last sensors are reachable on smaller screens.
- **Ethos Suite install package**, and x.y.z version numbers.
