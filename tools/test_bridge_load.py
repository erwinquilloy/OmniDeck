#!/usr/bin/env python3
"""Params page over the mLRS bridge with a full MAVLink stream: fill time and save time.

    python tools/test_bridge_load.py x18|x20 [--old] [--rate 2200] [--hz 10]

Marcin, X18 + mLRS 2.4 GHz 50 Hz 2026-11-14: saves got slow ("Saving..." for many seconds) after the
MAV2 stream rates were raised to the recommended 50 Hz set (~2.2 kB/s of MAVLink). The parameter
replies come mixed into that whole stream, and telem.lua took only 3 bridge frames (X18; X20 4) per
update, so the frames queued up in the radio and every reply came later and later.

This runs the real Ethos telem.lua + params.lua (Ethos reader model as in test_ethos_bridge.py) with
a pymavlink ArduPilot sending --rate B/s (full 50-58 byte bridge frames, like mLRS) and the widget
updated --hz times a second. --old forces the fixed cap (T.mavUsedAt ignored), as in 0.4.test.
"""
import os
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
args = [a for a in sys.argv[1:] if not a.startswith('--')]
target = args[0] if args else 'x18'
OLD = '--old' in sys.argv
def opt(name, default):
    if name in sys.argv: return float(sys.argv[sys.argv.index(name) + 1])
    return default
RATE = opt('--rate', 2200.0)
HZ = opt('--hz', 10.0)
DT = 1.0 / HZ
DIR = os.path.join(HERE, '..', 'targets', 'ethos', target)

sys.path.insert(0, HERE)
from fake_mavap import FakeAP
state = {'t': 0.0}
ap = FakeAP()
ap.p.update({'AIRSPEED_CRUISE': 18.0})

L = lupa.lua54.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
G.os.clock = lambda: state['t']
sensors = []
def pynew():
    sensors.append([]); return len(sensors) - 1
def pop(qi, lo, hi):
    q = sensors[qi]
    while q:
        cmd, data = q.pop(0)
        if lo is None or lo <= cmd <= (hi if hi is not None else lo):
            return cmd, L.table_from(data)
    return None
def deliver(cmd, data):
    for q in sensors: q.append((cmd, list(data)))
G.PYNEW, G.PYPOP = pynew, pop
G.PYPUSH = lambda c, d: (ap.from_radio(c, [d[i] for i in range(1, len(d) + 1)]) if c == 0xAA else None, True)[1]
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
if target == 'x18': P.readAhead = 1
names = [L.eval('function(L, i) return L[i][2] end')(LIST, i) for i in range(1, len(LIST) + 1)]
qrow = [L.eval('function(L, i) return L[i][10] end')(LIST, i) == 'q' for i in range(1, len(LIST) + 1)]
for n in names: ap.p.setdefault(n, 1.0)
ap.p['Q_ENABLE'] = 0.0
nonq = [n for n, q in zip(names, qrow) if not q]
# only the open tab is read: "fill" = the first tab (FLIGHT), as on opening the page
grpOf = lambda i: L.eval('function(L, i) return L[i][1] end')(LIST, i + 1)
nonq = [n for i, n in enumerate(names) if not qrow[i] and grpOf(i) == 'FLIGHT']

ap.loss = 0.0
ap.needs_hello = True
ap.bytes_per_tick = 4100 * DT        # 2.4 GHz 50 Hz downlink
import random
frnd = random.Random(1)
def stream():
    """the aircraft's stream to --rate B/s: attitude + VFR_HUD (fake_mavap) plus filler messages the
    radio has no use for (stand-ins for AHRS2, GPS_RAW_INT, SYS_STATUS ...)"""
    before = len(ap.out)
    ap.tick(state['t'])
    want = RATE * DT - (len(ap.out) - before)
    while want > 0:
        m = ap.mv.named_value_float_encode(int(state['t'] * 1000), b'FILL', 1.0)
        ap.out += m.pack(ap.mv); want -= 30
def frames():
    fr = []
    if ap.frames_in == 0:
        ap.out = b''
        return fr
    budget = ap.bytes_per_tick
    while ap.out and budget > 0:
        n = min(len(ap.out), frnd.randint(50, 58))
        budget -= n
        fr.append([0, n] + list(ap.out[:n])); ap.out = ap.out[n:]
    return fr
S = T.s
def passthrough(t):
    v = 300
    deliver(0x80, [0xF0, 0x00, 0x50, v & 0xFF, (v >> 8) & 0xFF, 0, 0])
    if int(t * 10) % 50 == 0:
        deliver(0x80, [0xF1, 6] + list(b'mLRS bridge test') + [0])
def step():
    state['t'] += DT
    passthrough(state['t'])
    stream()
    for f in frames(): deliver(0xAA, f)
    if OLD: T.mavUsedAt = None
    if COUNT: COSTS.append(CNT(BOTH, T, P, S))
    elif MEM:
        a = MEMQ()
        T.wakeup(T.LINK_CRSF); S.fc = 'ArduPilot'; S.armed = False; P.wakeup(S)
        b = MEMQ(); MEMS.append((a, b))
    else:
        T.wakeup(T.LINK_CRSF)
        S.fc = 'ArduPilot'; S.armed = False
        P.wakeup(S)
COUNT = '--count' in sys.argv
MEM = '--mem' in sys.argv
MEMS = []
MEMQ = L.eval('function() return collectgarbage("count") end')
COSTS = []
CNT = L.execute('''return function(f, ...) local n = 0 debug.sethook(function() n = n + 1 end, "", 1) f(...) debug.sethook() return n end''')
BOTH = L.eval('''function(T, P, s) T.wakeup(T.LINK_CRSF) s.fc = "ArduPilot" s.armed = false P.wakeup(s) end''')
backlog = lambda: max(len(q) for q in sensors) if sensors else 0
val = L.eval('function(P, n) return P.valueOf(n) end')

# 1 fill
fill = None
maxq = 0
for _ in range(int(120 * HZ)):
    step(); maxq = max(maxq, backlog())
    if all(val(P, n) is not None for n in nonq): fill = state['t']; break
# 2 save AIRSPEED_CRUISE 18 -> 18.5 once everything is read
def goto(name):
    P.key(S, 'back')
    for _ in range(200): P.key(S, 'left')
    vis = [n for n, q in zip(names, qrow) if not q]
    order = []
    for g in dict.fromkeys(L.eval('function(L, i) return L[i][1] end')(LIST, i + 1) for i in range(len(names))):
        order += [n for i, n in enumerate(names) if not qrow[i] and L.eval('function(L, i) return L[i][1] end')(LIST, i + 1) == g]
    for _ in range(order.index(name) + 1): P.key(S, 'right')
def timed_save(name, steps):
    goto(name)
    for _ in range(int(20 * HZ)):         # the selected row's tab is read first: wait for its value
        step()
        if val(P, name) is not None: break
    P.key(S, 'enter'); step()
    for _ in range(steps): P.key(S, 'right')
    P.key(S, 'enter')
    t0 = state['t']
    for _ in range(int(30 * HZ)):
        step()
        ph = P.phase()
        if ph in ('Saved and verified',) or ph.startswith('No answer') or ph.startswith('Not saved'):
            break
    out = (state['t'] - t0, P.phase())
    P.key(S, 'back'); P.key(S, 'back')
    return out
save = timed_save('AIRSPEED_CRUISE', 1) if fill else (None, 'not filled')
print('%s %s  stream %d B/s  updates %d Hz:  fill %s s  (radio queue max %d frames, now %d)  save %s s "%s"  bridge frames %d' % (
    target, 'OLD cap' if OLD else 'new cap', RATE, HZ, round(fill, 1) if fill else 'never', maxq, backlog(),
    round(save[0], 1) if save[0] is not None else '-', save[1], T.bridgeN))
if MEM:
    peak = max(b for a, b in MEMS); grow = max(b - a for a, b in MEMS)
    print('    Lua heap KB (telem+params only): peak %.0f, most added in one update %.1f' % (peak, grow))
if COUNT:
    c = sorted(COSTS)
    print('    instructions per update (telem + params): median %d  p95 %d  max %d' % (c[len(c)//2], c[int(len(c)*.95)], c[-1]))
ok = fill is not None and save[1] == 'Saved and verified' and save[0] < 3.0 and backlog() < 20
sys.exit(0 if ok else 1)
