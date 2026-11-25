#!/usr/bin/env python3
"""Ethos telem.lua + params.lua over the mLRS bridge, with Ethos's CRSF reader behaviour.

    python tools/test_ethos_bridge.py x20|x18

On the radio (X20S, Ethos 1.6.8, mLRS 2026-11-14) every crsf.getSensor() object gets its own copy
of each frame, and a pop with a type range drops the frames outside the range on the way. The bridge
frames (0xAA) therefore never reached a reader that shares the passthrough reader's object. This
test models exactly that, runs the real telem.lua and params.lua, and needs the PARAMS page to fill
from a pymavlink ArduPilot while passthrough telemetry keeps flowing.
"""
import os
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
sys.argv = [sys.argv[0]] + (sys.argv[1:] or ['x20'])
target = sys.argv[1]
DIR = os.path.join(HERE, '..', 'targets', 'ethos', target)

sys.path.insert(0, HERE)
from fake_mavap import FakeAP
state = {'t': 0.0}
ap = FakeAP()
ap.p.update({'AIRSPEED_CRUISE': 18.0})

L = lupa.lua54.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
G.os.clock = lambda: state['t']

# Ethos CRSF: one queue per sensor object; popFrame(lo, hi) drops frames outside [lo, hi]
sensors = []
def new_sensor():
    q = []
    sensors.append(q)
    return q
def deliver(cmd, data):
    for q in sensors: q.append((cmd, list(data)))
def pop(qi, lo, hi):
    q = sensors[qi]
    while q:
        cmd, data = q.pop(0)
        if lo is None or lo <= cmd <= (hi if hi is not None else lo):
            return cmd, L.table_from(data)
    return None
def pynew():
    new_sensor()
    return len(sensors) - 1
G.PYNEW = pynew
G.PYPOP = pop
G.PYPUSH = lambda c, d: (ap.from_radio(c, [d[i] for i in range(1, len(d) + 1)]) if c in (0x81, 0xAA) else None, True)[1]
L.execute('''
crsf = { getSensor = function()
  local qi = PYNEW()
  return { popFrame = function(self, lo, hi) return PYPOP(qi, lo, hi) end,
           pushFrame = function(self, c, d) return PYPUSH(c, d) end }
end }
sport = nil
system = { getSource = function() return nil end, getVersion = function() return { board = "X20S" } end }
model = { name = function() return "test" end }
CATEGORY_TELEMETRY_SENSOR = 0
RIGHT, CENTERED = 0, 0
''')
G.OD_DIR = DIR + os.sep
T = L.execute(open(os.path.join(DIR, 'telem.lua'), encoding='utf-8').read())
P = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
LIST = L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read())
P.init(T, LIST)
if target == 'x18': P.readAhead = 1   # as x18/ui.lua sets it
names = [L.eval('function(L, i) return L[i][2] end')(LIST, i) for i in range(1, len(LIST) + 1)]
for n in names: ap.p.setdefault(n, 1.0)

fails = []
def check(what, ok):
    print(('PASS ' if ok else 'FAIL ') + what)
    if not ok: fails.append(what)

# passthrough status text and attitude, as mLRS sends CRSF passthrough to the radio
def passthrough(t):
    roll = 300
    v = roll & 0xFFFFFFFF
    deliver(0x80, [0xF0, 0x00, 0x50, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24])   # 0x5006 attitude-ish
    if int(t * 10) % 50 == 0:
        deliver(0x80, [0xF1, 6] + list(b'mLRS bridge test') + [0])

COUNT = os.environ.get('OD_COUNT') == '1'
COSTS = []
CNT = L.execute('''return function(f, ...) local n = 0 debug.sethook(function() n = n + 1 end, "", 1) f(...) debug.sethook() return n end''')
BOTH = L.eval('''function(T, P) T.wakeup(T.LINK_CRSF) local s = T.s s.fc = "ArduPilot" P.wakeup(s) end''')
ap.loss = 0.1
ap.needs_hello = True     # the Nomad sends nothing over the bridge before the radio does
ap.bytes_per_tick = 100   # ~2 kB/s link, shared with the telemetry stream (answers queue behind it)
filled_at = [None]
for _ in range(int(90 / 0.05)):
    state['t'] += 0.05
    ap.tick(state['t'])
    passthrough(state['t'])
    for c, f in ap.frames():
        deliver(c, f)
    if COUNT:
        n = CNT(BOTH, T, P)
        COSTS.append(n)
    else:
        T.wakeup(T.LINK_CRSF)
        s = T.s
        s.fc = 'ArduPilot'          # (the passthrough above is minimal; the FC type is not under test)
        P.wakeup(s)
    if filled_at[0] is None and 'idle' in P.debug() and P.stats.rx > 5: filled_at[0] = state['t']

if COUNT:
    c = sorted(COSTS)
    print('    telem + params wakeup, instructions per update: median %d  p95 %d  p99 %d  max %d  (%d updates)' % (c[len(c)//2], c[int(len(c)*.95)], c[int(len(c)*.99)], c[-1], len(c)))
    worst = sorted(range(len(COSTS)), key=lambda i: -COSTS[i])[:5]
    print('    worst at t =', [round((i + 1) * 0.05, 2) for i in worst])
dbg = P.debug()
print('   ', dbg)
print('    page filled after %s s' % (round(filled_at[0], 1) if filled_at[0] else 'never'))
check('the bridge frames reach params.lua (bridge counter %d)' % T.bridgeN, T.bridgeN > 100)
check('params.lua talks MAVLink', 'MAVLINK' in dbg)
check('GCS heartbeats sent to wake the bridge (%d)' % getattr(ap, 'hellos', 0), getattr(ap, 'hellos', 0) >= 10)
nonq = [n for i, n in enumerate(names) if L.eval('function(L, i) return L[i][10] end')(LIST, i + 1) != 'q']
flight = [n for i, n in enumerate(names) if L.eval('function(L, i) return L[i][1] end')(LIST, i + 1) == 'FLIGHT']
fv = L.eval('function(P, n) return P.valueOf(n) end')
check('open tab (FLIGHT) filled, then idle: %d/%d (%d answers)' % (sum(1 for n in flight if fv(P, n) is not None), len(flight), P.stats.rx),
      all(fv(P, n) is not None for n in flight) and 'idle' in dbg)
check('passthrough text still arrives (status text: %s)' % (T.s.msgs[len(T.s.msgs)].text if len(T.s.msgs) > 0 else None),
      len(T.s.msgs) > 0)
# the mission editor's Send over the bridge (standard upload), then read back
P.missionOn = True
send = [{'cmd': 22, 'frame': 3, 'lat': -35.36, 'lon': 149.16, 'alt': 40.0, 'p1': 0.0, 'p2': 0.0, 'p3': 0.0},
        {'cmd': 16, 'frame': 3, 'lat': -35.352, 'lon': 149.168, 'alt': 90.0, 'p1': 0.0, 'p2': 0.0, 'p3': 0.0},
        {'cmd': 21, 'frame': 3, 'lat': -35.361, 'lon': 149.161, 'alt': 0.0, 'p1': 0.0, 'p2': 0.0, 'p3': 0.0}]
P.missionSend(L.table_from([L.table_from(d) for d in send]))
for _ in range(int(40 / 0.05)):
    state['t'] += 0.05
    ap.tick(state['t'])
    passthrough(state['t'])
    for c, f in ap.frames():
        deliver(c, f)
    T.wakeup(T.LINK_CRSF)
    T.s.fc = 'ArduPilot'
    T.s.armed = False
    P.missionWakeup(T.s)
    if P.sendState.state in ('done', 'failed'): break
check('mission Send over the bridge: "%s"' % P.sendState.msg, P.sendState.state == 'done')
check('the aircraft holds home + takeoff, waypoint, land', [x[0] for x in ap.mission] == [16, 22, 16, 21])
print('%s: %d failed' % (target, len(fails)))
sys.exit(1 if fails else 0)
