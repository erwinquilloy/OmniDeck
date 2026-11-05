<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo/omnideck-logo-dark.png">
    <img src="docs/logo/omnideck-logo-light.png" alt="OmniDeck: ArduPilot, INAV and Betaflight" width="480">
  </picture>
</p>

One telemetry display for ArduPilot, INAV and Betaflight, on FrSky Ethos and EdgeTX colour radios, with OpenTX 2.3 (in progress).

A full-screen widget with a horizon and tapes, a moving map with optional satellite tiles, status messages, voice call-outs and a flight summary, the same on every flight controller and every radio link.

![Main page in flight](docs/screens/main.png)

**Status:** 0.2.0, the first public release (beta).

## What it does

- **Avionics:** artificial horizon with pitch ladder and roll scale, speed and altitude tapes, heading tape with a home marker, vertical speed bar.
- **Map:** vector map with range rings, flight trail, home and the next waypoint, or satellite and street tiles on the SD card. Aircraft-centred or home-centred, north up or heading up.
- **Flight data blocks:** distance to home with an arrow, total distance, flight time, max airspeed and ground speed, battery gauge, mAh used, current, throttle and efficiency.
- **Status messages** from ArduPilot, with severity colours and a beep per message. The same message repeated shows once with a count.
- **Ready to arm** while disarmed, and voice call-outs for flight modes, arming, battery, failsafes and GPS.
- **Flight summary** on disarm: flight time, distance, furthest from home, max altitude and speeds, energy used, lowest voltage and link quality.
- **Missions:** ArduPilot waypoint files or waypoints learned from telemetry; INAV missions downloaded over the telemetry link.

## Radios tested

| Radio | System | Screen | Status |
|---|---|---|---|
| FrSky X20S (X20 family) | Ethos | 800 x 480 | Tested |
| FrSky X18 | Ethos | 480 x 320 | Tested |
| FrSky X14 | Ethos | 640 x 360 | Simulator only |
| RadioMaster TX16S MK2 | EdgeTX | 480 x 272 | Tested |
| RadioMaster TX16S MK3 / MK3 Max | EdgeTX | 800 x 480 | Tested |
| OpenTX colour radios | OpenTX 2.3 | 480 x 272 | (in progress) |

### EdgeTX versions and performance

EdgeTX stops a widget whose screen update runs more than about 20,000 Lua instructions (the "CPU limit" message). It counts instructions, not time, so a faster radio such as the TX16S MK3 gets no extra room. Ethos has no such limit.

To stay well inside it, OmniDeck lets EdgeTX itself draw the horizon's ground and every line that runs off the edge of the horizon or the map, in C, with the same calls Yaapu uses. How much of that is possible depends on the EdgeTX version:

| EdgeTX | Horizon ground drawn by EdgeTX | Clipped lines drawn by EdgeTX | Main page, heaviest update | Room left |
|---|---|---|---|---|
| 2.11, 2.12 | Yes | All | 82 % | 18 % |
| 2.9, 2.10 | Yes | Only lines with no part left of or above the screen (these versions read coordinates as unsigned numbers) | 85 % | 15 % |

Measured with the EdgeTX simulator in this repo (`tools/sim_edgetx.py`) in the worst case: ArduPilot over S.Port with a 120-waypoint mission and a telemetry backlog. INAV and Betaflight are lighter (77 % on 2.12). Before 0.2.0-test35 the same case was 89 % on every version. The oldest version tested is 2.9.4.

**Recommendation:** use EdgeTX 2.11 or later, ideally the latest 2.12.x, for the most room below the limit. This applies to the TX16S MK3 and MK3 Max as much as to the MK2. On every version, keep the radio's own telemetry alarms and the flight controller's failsafes as your safety net; OmniDeck is a display. Since 2.11.1, EdgeTX refuses sound files whose path is longer than 45 characters: the voice packs that come with OmniDeck stay under it, and your own pack's folder name should be 4 letters or fewer.

## Radio links and flight controllers

ArduPilot sends FrSky passthrough telemetry (the same data Yaapu uses) over every link. INAV and Betaflight are read from the radio's own telemetry sensors.

| Link | Radio | ArduPilot | INAV | Betaflight |
|---|---|---|---|---|
| TBS Crossfire (CRSF) | Ethos | Tested | Tested | Tested |
| TBS Crossfire (CRSF) | EdgeTX | Tested | Tested | Tested |
| ExpressLRS (CRSF) | Ethos | Tested | Tested | Tested |
| ExpressLRS (CRSF) | EdgeTX | Tested | Tested | Tested |
| mLRS (CRSF passthrough) | Ethos | Tested | Tested | Not tested |
| mLRS (CRSF passthrough) | EdgeTX | Tested | Tested | Not tested |
| FrSky R9 / S.Port | Ethos | Not tested | Not tested | Not tested |
| FrSky F.Port | Ethos | Tested | Tested | Not tested |

"Not tested" means the combination has not been checked on a radio yet, not that it is known not to work.

- **ArduPilot** (Plane, including QuadPlane; Copter mode names included): attitude, GPS, home, battery and capacity, flight mode, armed and flying flags, failsafes, waypoint, wind and status messages. Flight time counts only while ArduPilot reports it is flying. ArduPilot sends no ready-to-arm flag, so OmniDeck works it out from PreArm messages and the GPS, EKF and failsafe state.
- **INAV** (tested with 7 and 9): attitude, GPS, altitude, speeds, battery, flight mode and ready to arm, straight from INAV. Airspeed only with a pitot, real or virtual. No status messages over these links. Flight time counts from arming. Missions are downloaded over the telemetry link (see [Missions](#missions)).
- **Betaflight:** attitude, GPS, speed, battery, flight mode, and ready to arm from the CRSF flight mode text. No airspeed and no status messages. Flight time counts from arming.
- **Battery capacity:** ArduPilot sends `BATT_CAPACITY`. INAV and Betaflight don't, so enter the pack size under **Battery mAh (INAV/BF only)**. The battery bar also needs a working current sensor.

## The screens

Tap the screen or press ENTER for the next page: **Main**, **Map**, **Messages**, the **Flight summary** once a flight has ended, and **Sensor check**. The wheel zooms the map and scrolls the messages. On EdgeTX, touch and keys only reach the widget in full screen.

| | |
|---|---|
| ![Disarmed, not ready to arm](docs/screens/main_disarmed.png) | ![INAV in ANGLE mode](docs/screens/main_inav.png) |
| Disarmed: the arming state sits under the aircraft symbol; the last flight time stays, dimmed. | INAV: no airspeed without a pitot, so the tape shows ground speed. |
| ![Map page](docs/screens/map.png) | ![Messages page](docs/screens/messages.png) |
| Map: + / − zoom, PLANE / HOME switches the map view, position along the bottom. | Messages (ArduPilot): errors in red; repeats fold into one line. |
| ![Flight summary](docs/screens/summary.png) | ![Sensor check](docs/screens/sensor_check.png) |
| Flight summary, about 1 s after the disarm (armed at least 10 s). | Sensor check: where each value comes from. Send a photo of it with any report. |

### Main page

- **Top bar:** flight mode, ARMED or DISARMED, model name, radio battery, GPS fix and satellites, link quality and RSSI.
- **Horizon:** speed tape on the left (airspeed when the aircraft sends it, else ground speed) with ground speed in the green box under it, altitude tape on the right.
- **HOME:** distance to home and an arrow pointing to home from the nose. The small note is the total distance flown.
- **FLIGHT TIME:** white while the clock runs. After the disarm the last flight's time stays, dimmed, until the next arming.
- **MAX AS / MAX GS:** highest speeds this flight; the bar shows the speed now against that maximum.
- **Battery:** capacity left as a bar with the voltage on top. Green, amber below 30 %, red below 15 % or on a battery failsafe.
- **USED, CURR, THR:** mAh used, current with its maximum, throttle with the live efficiency.

### On EdgeTX

| | | |
|---|---|---|
| ![EdgeTX main](docs/screens/edgetx_main.png) | ![EdgeTX map](docs/screens/edgetx_map.png) | ![EdgeTX summary](docs/screens/edgetx_summary.png) |

The same pages, drawn a little lighter: the minimap on the main page has no trail or mission (the Map page has both), and the tapes label every other step. Outside full screen the flight summary goes back to the main page by itself after 15 s.

## Install

### Ethos

1. Connect the radio by USB and choose the SD card, or use a card reader.
2. Copy the `scripts` and `bitmaps` folders from the package to the root of the card. You should have `scripts/omnideck/main.lua` and the other files.
3. Updating: overwrite the `.lua` files in `scripts/omnideck/`.
4. Eject the card and restart the radio.
5. Add **OmniDeck** to a screen with a full-screen layout. In a smaller slot it shows only the minimap.
6. Long-press the widget and choose **Configure widget** for the settings.

### EdgeTX

1. Connect the radio by USB and pick **USB Storage (SD)**, or use a card reader.
2. Copy the `WIDGETS` and `SCRIPTS` folders to the root of the card: `WIDGETS/OmniDeck/`, and `SCRIPTS/TOOLS/OmniDeck Setup.lua` and `OmniDeck Check.lua`.
3. Updating: delete the `.luac` files in `WIDGETS/OmniDeck/` first, so the radio compiles the new version.
4. Eject the card and restart the radio.
5. Add a screen with a one-zone layout (no top bar, sliders or trims) and pick OmniDeck for the zone.
6. Long-press the widget and choose **Full screen** to change pages. Long-press RTN to leave.
7. Settings: **SYS › Tools › OmniDeck Setup**.

Not in the widget list? Run **SYS › Tools › OmniDeck Check**: it loads the widget the way EdgeTX does and shows the exact error.

## Flight controller setup

| Flight controller | Link | Setting |
|---|---|---|
| ArduPilot | CRSF (ELRS, Crossfire) | `RC_OPTIONS` bit 8, CRSF passthrough. With ELRS keep packet rate × telemetry ratio above about 30 telemetry frames a second. |
| ArduPilot | S.Port (R9 and others) | `SERIALn_PROTOCOL 10` |
| ArduPilot | F.Port | `SERIALn_PROTOCOL 23` |
| ArduPilot | mLRS | Set the Tx module to send CRSF passthrough to the radio. |
| INAV, Betaflight | CRSF | Normal CRSF telemetry. |
| INAV | S.Port, F.Port | Serial RX, provider `FPORT` (F.Port), half-duplex ON, signal on the UART's TX pad. Turn on **Use Pitch & Roll sensors in telemetry** for the horizon. |

INAV and Betaflight: power the aircraft and run **Model › Telemetry › Discover new sensors** on the radio before using OmniDeck. After changing links, delete the old sensors and discover again.

- Ground speed with INAV appears once the GPS has a fix.
- A virtual pitot on INAV sends an estimate as if it were airspeed. Set Pitot tube to NONE on a plane without a sensor if you would rather see ground speed on the tape.
- ArduPilot ground speed next to airspeed needs `FRSKY_OPTIONS` bit 0 on; otherwise only one of the two is sent.

## Settings

On Ethos the settings are in the widget's **Configure widget** form. On EdgeTX they are in the **OmniDeck Setup** tool, saved per model to `WIDGETS/OmniDeck/<model name>.cfg`; the widget itself has one option, **Page**, to fix a page per screen.

| | |
|---|---|
| ![OmniDeck Setup, top](docs/screens/edgetx_setup_1.png) | ![OmniDeck Setup, lower rows](docs/screens/edgetx_setup_2.png) |

| Setting | Choices | Notes |
|---|---|---|
| Telemetry link | Auto · CRSF / ELRS / mLRS · S.Port / F.Port / FBUS | Auto picks the link whose sensors are receiving. |
| Map orientation | North up · Heading up | A tiled map is always north up. |
| Map view | Aircraft centred · Home centred | Also the PLANE / HOME button on the map. |
| Zoom source (Ethos) · Map zoom control (EdgeTX) | A pot, slider or switch | Optional manual zoom. |
| Map tiles | Off · the tile sets found on the card | EdgeTX also has Auto, the first set found. |
| Mission file (Ethos) | None · `.waypoints` files | ArduPilot; without a file, waypoints are learned from telemetry. |
| INAV mission download | On · Off | Ethos also has a Reload button. |
| Speed units | km/h · m/s · knots · mph | |
| Altitude units | metres · feet | |
| Efficiency units | Wh/km · mAh/km · Wh/mi · mAh/mi | Shown in the THR block and the summary. |
| Flight trail | On · Off | Ethos has a button to clear the trail and learned waypoints. |
| Voice | Off · voice packs on the card | Picking one plays a test clip. |
| Battery mAh (INAV/BF only) | 0 to 50,000 | ArduPilot sends its own capacity. |
| Low / Critical voltage alarm | Volts per cell, 0 = off | "Low voltage" every 30 s, "Critical voltage" every 15 s, after 5 s below. |
| Battery cells | 0 = auto, up to 14 | Set it for Li-ion or a part-charged pack. |
| Low altitude alarm | 0 = off, up to 3,000 | "Terrain, pull up" when armed and below it, after having been above it once. |
| Message beep | Every message · Warnings and errors · Off | Works with the voice off. |
| Flight summary on disarm | On · Off | |
| Start page | Main · Map | |
| Page switch, Page switch action (EdgeTX) | A switch · next page or position picks the page | Changes page outside full screen too. |

## Map tiles

Without tiles you get a vector map with range rings. For satellite or street maps, OmniDeck reads the tile folders used by the [ETHOS Mapping Widget](https://github.com/b14ckyy/ETHOSMappingWidget-Revisited), so tiles made for it, and old Yaapu Google tiles, work as they are.

1. On a PC open the [High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/) in Chrome or Edge.
2. Set **Output Target** to **b14ckyy ETHOS Mapping Widget**.
3. Pick the provider and map type, for example Google Satellite, and a zoom range such as 12 to 17. Draw a box larger than the area you fly in.
4. Save to the root of the SD card, or extract the ZIP there.
5. Restart the radio and pick the set under **Map tiles**. Only sets found on the card are listed, with their zoom range.

| Radio | Tile folder |
|---|---|
| Ethos | `bitmaps/ethosmaps/maps/GOOGLE/Satellite/15/...` (also ESRI, OSM, MAPTILER) and `bitmaps/yaapu/maps/...` (Yaapu Google tiles) |
| EdgeTX | `IMAGES/ethosmaps/maps/GOOGLE/Satellite/15/...` and `IMAGES/yaapu/maps/...` |

- Folder names are case-sensitive: `GOOGLE/Satellite`, not `google/satellite`.
- JPG tiles load fastest. Tiles load two per update, nearest the aircraft first.
- Map tiles work on EdgeTX too (checked on a TX16S MK2).

## Missions

- **INAV:** OmniDeck downloads the mission from the flight controller over the telemetry link (CRSF/ELRS or S.Port), a few seconds after the link comes up. Checked over TBS Crossfire on a TX16S MK2.
  - Waypoints show numbered, holds as H and landings as L; the active waypoint is green.
  - A mission uploaded after the radio started shows within about 10 s while the aircraft is disarmed, without a restart.
  - Only the first mission on the flight controller is shown. Upload it and **save it to EEPROM** in INAV Configurator, or the flight controller won't have it after a power cycle.
  - **INAV mission download** in the settings turns it off. The Sensor check page shows what INAV reported and how many waypoints arrived.
- **ArduPilot:** ArduPilot's radio telemetry has no mission download.
  - **Ethos:** copy a Mission Planner / QGC `.waypoints` file to `scripts/omnideck/missions/` and pick it under **Mission file**; the whole route draws, with the active waypoint in green.
  - **Without a file, and on EdgeTX** (which has no Mission file setting yet): each waypoint is placed on the map when it becomes active, from ArduPilot's distance and bearing to it, so the route builds up as you fly.
- **Betaflight:** no missions.

## Voice and alarms

- **Call-outs:** flight modes, arm and disarm, battery percent (50, 40, 30, 25, 20, 15, 10 and 5 % while armed), failsafes, GPS fix changes, telemetry lost and recovered, ready and not ready to arm, and status messages worth hearing, such as "Takeoff complete".
- **Voice packs:** Aria, Christopher and Michelle come with the release packages. A copy of Yaapu's English sound folder in the audio folder also works, because the file names match. Ethos: `scripts/omnideck/audio/`. EdgeTX: `WIDGETS/OmniDeck/audio/`.
- **Message beep:** one blip for info, a double beep for a warning, a two-tone alarm for an error. A burst of messages gives one beep.
- **Ready to arm on ArduPilot:** NOT READY TO ARM holds for 40 s after a PreArm message or any critical message, and while a fitted GPS has no 3D fix, the EKF reports a problem or a failsafe is active. READY TO ARM needs 40 s disarmed with none of these. The flight controller still has the last word.

## Reporting a problem

Please send the radio model and its Ethos or EdgeTX version, the flight controller and its version, the link, and a photo of the **Sensor check** page (page 5). For a script error, send the exact text.

- **No telemetry on INAV or Betaflight:** discover the sensors again on the radio with the aircraft powered.
- **Horizon level on INAV over S.Port or F.Port:** turn on **Use Pitch & Roll sensors in telemetry** in INAV.
- **Flight time 00:00 on ArduPilot on the bench:** expected. It only counts while ArduPilot reports it is flying.
- **No flight summary:** the aircraft has to be armed for at least 10 s.

## Development

The shared code in `scripts/omnideck/` runs on Ethos as it is. On EdgeTX, `edgetx/WIDGETS/OmniDeck/etx.lua` provides the Ethos-style calls over EdgeTX's, and all shared modules stay valid Lua 5.2.

- **Ethos simulator:** `python tools/sim.py [outdir] [--sport] [--native] [--tiles] [--res 800x480|480x320|480x272]` runs the widget in Lua 5.4 (lupa) against a stubbed Ethos API, feeds a simulated flight encoded as `AP_Frsky_SPort_Passthrough.cpp` does (or native sensors with `--native`), checks the decoded values and renders every page to PNG.
- **EdgeTX simulator:** `python tools/sim_edgetx.py [outdir] [--sport] [--native]` runs it in Lua 5.2 with EdgeTX's instruction limit (about 20,000 Lua instructions per widget call) and checks decoding, pages, touch, sound, link loss, the Setup tool and a 120-waypoint mission. The heaviest page must stay within 88 % of the limit.
- **EdgeTX build:** `python tools/build_edgetx.py <SD root> [--audio <voice folders>]` writes `WIDGETS/OmniDeck/` and the tools.
- **Voice packs:** `python tools/voicepack.py <folder> Aria Christopher Michelle` builds packs from `tools/phrases.psv`.

## Credits

OmniDeck is written by Erwin Quilloy. It builds on what these projects worked out first; their code was read as reference.

- **[Yaapu FrSky Telemetry Script](https://github.com/yaapu/FrskyTelemetryScript)** by Alessandro Apostoli (yaapu): ArduPilot passthrough decoding, status-text and sound handling, and the flight timer that follows ArduPilot's flying flag. Its sound file names let Yaapu voice folders work as OmniDeck packs.
- **[ETHOS Mapping Widget Revisited](https://github.com/b14ckyy/ETHOSMappingWidget-Revisited)** by Marc Hoffmann (b14ckyy): the tile folder layout OmniDeck reads, and Ethos file and settings-storage behaviour. Originally by yaapu.
- **[High Resolution Map Generator](https://github.com/MartinovEm/High-Resolution-Map-Generator)** by Emiliyan Martinov (MartinovEm): the web tool that makes the map tiles.
- **[INAV Telemetry Dashboard for Ethos](https://github.com/iNavFlight/ETHOS-Telemetry-Dashboard)** by Rob Thomson (iNavFlight): INAV and Betaflight sensor names over CRSF and S.Port, flight-mode and arming decoding, and creating the sensors Ethos doesn't discover on R9.
- **[iNav OpenTX Telemetry Widget](https://github.com/iNavFlight/OpenTX-Telemetry-Widget)** (iNavFlight): how INAV flight time is counted, from arming.
- **dashx Project:** reading Ethos's own telemetry-lost flag, so a lost link shows at once.
- **[LeoBar (leobarua)](https://github.com/leobarua):** hardware for development and testing.
- **Testers, [Marcin J (jaroszmm)](https://github.com/jaroszmm), [Carticiak](https://github.com/Carticiak), Pete Davey and [Leslie Yagin (molokaiboy)](https://github.com/molokaiboy):** testing the pre-release builds and their valuable feedback.
- **Voices:** Aria, Christopher and Michelle are generated with Microsoft Edge text-to-speech voices.

## Licence

OmniDeck is free software under the [GNU General Public License v3.0](LICENSE).

## Support

OmniDeck is free. If it helps you fly, a coffee keeps it going: PayPal [$10](https://paypal.me/iamwinq/10USD) · [any amount](https://paypal.me/iamwinq), or [Ko-fi](https://ko-fi.com/windfpv).
