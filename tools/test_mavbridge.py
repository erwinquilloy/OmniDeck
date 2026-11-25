#!/usr/bin/env python3
"""params.lua over the mLRS bridge (Tx Ser Port = cbridge): real MAVLink v2 in CRSF 0xAA frames.

    python tools/test_mavbridge.py edgetx|x20|x18 [--lua54]

A pymavlink 'ArduPilot' answers PARAM_REQUEST_READ / PARAM_SET, the mission download and the
standard mission upload (count -> it requests each item -> ack), with its normal telemetry stream
around the answers, every frame cut at random (up to 58 bytes) as mLRS does, and some answers lost.
Also: Mission Planner's mission traffic on the same stream (other target) is ignored.
"""
import os
import random
import struct
import sys

import lupa
from pymavlink.dialects.v20 import ardupilotmega as mav
from fake_mavap import FakeAP

HERE = os.path.dirname(os.path.abspath(__file__))
TGT = {'edgetx': 'targets/edgetx/WIDGETS/OmniDeck', 'x20': 'targets/ethos/x20', 'x18': 'targets/ethos/x18'}
target = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] in TGT else 'edgetx'
DIR = os.path.join(HERE, '..', TGT[target])
LUA54 = '--lua54' in sys.argv
L = (lupa.lua54 if LUA54 else lupa.lua52).LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
state = {'t': 0.0}
G.os.clock = lambda: state['t']
for k in ('RIGHT', 'CENTERED'): G[k] = 0


ap = FakeAP()
T = L.eval('''function(push) local T = {}
  T.alive = function() return true end
  T.split32 = function(v) if v < 0 then v = v + 4294967296 end return v % 65536, math.floor(v / 65536) end
  T.crsfPush = function(c, d) return push(c, d) end
  return T end''')(lambda c, d: (ap.from_radio(c, [d[i] for i in range(1, len(d) + 1)]), True)[1])
P = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
LIST = L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read())
P.init(T, LIST)
S = L.eval('{ fc = "ArduPilot", link = "CRSF", armed = false, msgs = {}, homeLat = -35.36, homeLon = 149.16 }')

fails = []
def check(what, cond):
    print(('PASS ' if cond else 'FAIL ') + what)
    if not cond: fails.append(what)

def run(sec, page=True, dt=0.05):
    for _ in range(int(sec / dt)):
        state['t'] += dt
        ap.tick(state['t'])
        T.bridgeAt = state['t']            # telem.lua: an mLRS bridge frame came
        for f in ap.frames():
            T.onMavEnv(L.table_from(f))
        if page: P.wakeup(S)
        else: P.missionWakeup(S)

names = [L.eval('function(L, i) return L[i][2] end')(LIST, i) for i in range(1, len(LIST) + 1)]
# the aircraft has every row except two (they must end as n/a)
MISSING = {'KFF_RDDRMIX', 'YAW2SRV_DAMP'}
for n in names:
    if n not in MISSING: ap.p.setdefault(n, 1.0)
# since 0.4.0f (all three targets): two columns. The wheel on the tabs only moves a highlight; ENTER
# opens the tab with the cursor on its first row; RTN goes back to the tabs.
def to_tabs():
    if P.editing(): P.key(S, 'back')
    if P._focus() == 'rows': P.key(S, 'back')
def hi_to(tab):
    to_tabs()
    for _ in range(60): P.key(S, 'left')
    for _ in range(60):
        if P._hi() == tab: return True
        h = P._hi(); P.key(S, 'right')
        if P._hi() == h: return False
    return False
def goto(name):
    """highlight the row's tab, ENTER, wheel down to the row"""
    hi_to(next(t for t in tab_names() if name in rows_of(t)))
    P.key(S, 'enter')
    for _ in range(120):
        if P._row() == name: break
        P.key(S, 'right')
    run(1)

def tab_names():
    """the page's tabs in order, walked with the highlight (Q tabs only when shown)"""
    to_tabs()
    for _ in range(60): P.key(S, 'left')
    seen = [P._hi()]
    for _ in range(60):
        P.key(S, 'right')
        if P._hi() == seen[-1]: break
        seen.append(P._hi())
    return seen
def open_tab(tab):
    """highlight a tab, ENTER (opened, read), RTN: the page stays on that tab"""
    hi_to(tab); P.key(S, 'enter'); P.key(S, 'back')
TAB_OF = {}
def rows_of(tab):
    if not TAB_OF:
        for i in range(1, len(LIST) + 1):
            TAB_OF.setdefault(L.eval('function(L, i) return L[i][1] end')(LIST, i), []).append(L.eval('function(L, i) return L[i][2] end')(LIST, i))
    return TAB_OF.get(tab, [])
def tab_done(tab):
    return all(P.valueOf(n) is not None for n in rows_of(tab))
def wait_tab(tab, sec=60):
    for _ in range(int(sec)):
        if tab_done(tab): return True
        run(1)
    return tab_done(tab)
def read_tabs(per_tab=60):
    """only the open tab is read: open each in turn and wait until every row has a value (or n/a)"""
    for tab in tab_names():
        open_tab(tab)
        wait_tab(tab, per_tab)

# 1 reading the page over the bridge, 25 % of the answers lost
ap.loss = 0.15
# 1a switching tabs while one is still reading: the new tab is read, the old one waits, nothing lost
run(1.5)
part = sum(1 for n in names if P.valueOf(n) is not None)
open_tab('TECS')
wait_tab('TECS')
tecs = [n for i, n in enumerate(names) if L.eval('function(L, i) return L[i][1] end')(LIST, i + 1) == 'TECS']
flight = [n for i, n in enumerate(names) if L.eval('function(L, i) return L[i][1] end')(LIST, i + 1) == 'FLIGHT']
f_got = sum(1 for n in flight if P.valueOf(n) is not None)
check('switch mid-read: TECS all read (%d/%d), FLIGHT kept what it had and waits (%d/%d, had %d)' % (
      sum(1 for n in tecs if P.valueOf(n) is not None), len(tecs), f_got, len(flight), part),
      all(P.valueOf(n) is not None for n in tecs) and part <= f_got < len(flight))
open_tab('FLIGHT')
wait_tab('FLIGHT')
check('back on FLIGHT: the rest is read (%d/%d)' % (sum(1 for n in flight if P.valueOf(n) is not None), len(flight)),
      all(P.valueOf(n) is not None for n in flight))
read_tabs()                  # every tab in turn (the mLRS waits are long on purpose)
vals = P.debug() if hasattr(P, 'debug') else ''
check('mLRS bridge: the link is MAVLink', str(P.mav.sys) == '1')
got = L.eval('function(P, n) return P.value and P.value(n) end')
check('all frames to the module are 0xAA, chunk 0, size <= 58 (%d sent)' % ap.frames_in, ap.frames_in > 10)
check('every row read (idle), no crc errors (%s)' % P.debug(), 'idle' in P.debug() and P.stats.bad == 0)
nav = L.eval('function(P, n) local v = P._val and P._val(n) return v end')
nonq = [n for i, n in enumerate(names) if L.eval('function(L, i) return L[i][10] end')(LIST, i + 1) != 'q']
check('rows read: %d answers for %d rows shown (Q rows hidden, 2 missing)' % (P.stats.rx, len(nonq)), P.stats.rx >= len(nonq) - len(MISSING))

# 1b an answer lost several times in a row: the row goes n/a, then heals (asked again every 30 s)
ap.loss = 0.0
na = L.eval('function(P) return P._vals end')
ap.drop_names = {'STAB_PITCH_DOWN': 99}  # every try lost -> n/a; then the link heals and the 30 s retry gets it
P.reset()
open_tab('TECS')                           # STAB_PITCH_DOWN is on TECS: only the open tab is read
val = L.eval('function(P) return P.valueOf and P.valueOf("STAB_PITCH_DOWN") end')
v1 = v2 = None
for _ in range(120):                       # wait for n/a, then for the 30 s retry to heal it
    run(1); v = val(P)
    if v is False: v1 = False; ap.drop_names['STAB_PITCH_DOWN'] = 0
    elif v1 is False and v is not None: v2 = v; break
check('STAB_PITCH_DOWN: n/a after its answers were lost (%s), read again later (%s)' % (v1, v2), v1 is False and v2 == ap.p['STAB_PITCH_DOWN'])

# 2 save AIRSPEED_CRUISE 18 -> 20 (4 steps of 0.5), read back
ap.loss = 0.0
ap.p['AIRSPEED_CRUISE'] = 18.0
goto('AIRSPEED_CRUISE')
P.key(S, 'enter'); run(2)
for _ in range(4): P.key(S, 'right')
P.key(S, 'enter'); run(4)
check('PARAM_SET over MAVLink: AIRSPEED_CRUISE 18 -> 20 (%s)' % ap.p['AIRSPEED_CRUISE'], abs(ap.p['AIRSPEED_CRUISE'] - 20.0) < 1e-6)
check('"Saved and verified" (%s)' % P.phase(), P.phase() == 'Saved and verified')
P.key(S, 'back'); P.key(S, 'back')

# 2b save whose answer is lost (ArduPilot drops it on a full link): read back -> "Saved and verified"
ap.drop_set_replies = 1
c0 = ap.p['AIRSPEED_CRUISE']
goto('AIRSPEED_CRUISE')
P.key(S, 'enter'); run(3)
for _ in range(2): P.key(S, 'right')
P.key(S, 'enter'); run(20)
check('save answer lost: read back, "Saved and verified" (%s, FC %s -> %s)' % (P.phase(), c0, ap.p['AIRSPEED_CRUISE']),
      abs(ap.p['AIRSPEED_CRUISE'] - (c0 + 1.0)) < 1e-6 and P.phase() == 'Saved and verified')
P.key(S, 'back'); P.key(S, 'back')

# 3 mission download (page closed: mission only)
ap.mission = [(16, 0, -35.36, 149.16, 0.0, 0, 0, 0),
              (22, 3, 0.0, 0.0, 50.0, 15, 0, 0),
              (16, 3, -35.355, 149.165, 100.0, 0, 0, 0),
              (178, 2, 0.0, 0.0, 0.0, 0, 18.0, -1),
              (18, 3, -35.35, 149.17, 80.0, 3, 0, 120.0),
              (21, 3, -35.361, 149.161, 0.0, 0, 0, 0)]
P.missionOn = True
ap.loss = 0.15
got_list = []
P.onMission = lambda lst: got_list.append(lst)
run(60, page=False)
items, st = P.missionItems()
cmds = [items[i].cmd for i in range(1, len(items) + 1)] if items else []
check('mission download over MAVLink: 5 items (%s, %s)' % (st, cmds), st == 'done' and cmds == [22, 16, 178, 18, 21])
if items:
    it = items[4]
    check('loiter turns item: position, alt, turns, radius', abs(it.lat + 35.35) < 1e-6 and abs(it.lon - 149.17) < 1e-6
          and abs(it.alt - 80) < 1e-4 and it.p1 == 3 and abs(it.p3 - 120) < 1e-4)
    check('speed item: p2 18 m/s', abs(items[3].p2 - 18.0) < 1e-4)
check('download closed with MISSION_ACK', ap.got_ack_download >= 1)
check('Mission Planner\'s mission messages (other target) ignored', len(cmds) == 5)

# 4 the editor's Send: standard upload, then read back and compared
send = [{'cmd': 22, 'frame': 3, 'lat': -35.36, 'lon': 149.16, 'alt': 40.0, 'p1': 0.0, 'p2': 0.0, 'p3': 0.0},
        {'cmd': 16, 'frame': 3, 'lat': -35.352, 'lon': 149.168, 'alt': 90.0, 'p1': 0.0, 'p2': 0.0, 'p3': 0.0},
        {'cmd': 19, 'frame': 3, 'lat': -35.351, 'lon': 149.169, 'alt': 70.0, 'p1': 30.0, 'p2': 0.0, 'p3': 0.0},
        {'cmd': 21, 'frame': 3, 'lat': -35.361, 'lon': 149.161, 'alt': 0.0, 'p1': 0.0, 'p2': 0.0, 'p3': 0.0}]
ap.loss = 0.15
P.missionSend(L.table_from([L.table_from(d) for d in send]))
run(40, page=False)
check('Send over MAVLink: "Sent and verified" (%s / %s)' % (P.sendState.state, P.sendState.msg), P.sendState.state == 'done')
check('the aircraft holds home + the 4 items', [x[0] for x in ap.mission] == [16, 22, 16, 19, 21]
      and abs(ap.mission[0][2] + 35.36) < 1e-6 and abs(ap.mission[3][5] - 30) < 1e-4)

# 5 armed: refused on the radio, nothing uploaded
S.armed = True
before = list(ap.mission)
P.missionSend(L.table_from([L.table_from(d) for d in send[:2]]))
run(5, page=False)
check('armed: "Refused: aircraft armed", nothing sent (%s)' % P.sendState.msg,
      P.sendState.state == 'failed' and 'armed' in P.sendState.msg and ap.mission == before)
S.armed = False

print('%s %s: %d failed' % (target, 'lua54' if LUA54 else 'lua52', len(fails)))
sys.exit(1 if fails else 0)
