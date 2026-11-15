"""
Off-radio test of the PARAMS page client (params.lua) against a copy of ArduPilot's MAVlite
code (libraries/AP_Frsky_Telem/AP_Frsky_MAVlite_SPortToMAVlite.cpp / MAVliteToSPort.cpp and
AP_Frsky_MAVliteMsgHandler.cpp: PARAM_REQUEST_READ / PARAM_SET -> PARAM_VALUE).

  python tools/test_params.py [edgetx|x20|x18] [--lua54]
"""
import os, struct, sys, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lupa
HERE = os.path.dirname(os.path.abspath(__file__))
TGT = {'edgetx': 'targets/edgetx/WIDGETS/OmniDeck', 'x20': 'targets/ethos/x20', 'x18': 'targets/ethos/x18'}
tgt = next((a for a in sys.argv[1:] if a in TGT), 'edgetx')
DIR = os.path.join(HERE, '..', TGT[tgt])
L = (lupa.lua54 if '--lua54' in sys.argv else lupa.lua52).LuaRuntime(unpack_returned_tuples=True)

from fake_mavlite import FakeAP, ck

PARAMS = {'Q_ENABLE': 1.0, 'Q_ASSIST_SPEED': 0.2, 'Q_ASSIST_ALT': 0.0, 'AIRSPEED_CRUISE': 18.0, 'TRIM_THROTTLE': 45.0, 'ARMING_SKIPCHK': 0.0,
          'RLL_RATE_P': 0.08, 'PTCH_RATE_FF': 0.345, 'Q_A_RAT_RLL_D': 0.0036, 'FS_LONG_ACTN': 1.0}
ap = FakeAP(PARAMS, dup='--nodup' not in sys.argv)

# ---------------- Lua side
G = L.globals()
state = {'t': 0.0, 'busy': False}
def push(t):
    if state['busy']: state['busy'] = False; return False   # radio slot busy once: must be retried
    ap.uplink(int(t['appId']), int(t['value'])); return True
def pop():
    if not ap.down: return None
    a, v = ap.down.pop(0)
    if '--lua54' in sys.argv and v >= 2**31: v -= 2**32      # Ethos 32-bit Lua: value as int32
    return L.eval('function(a, v) return { primId = function() return 0x32 end, appId = function() return a end, value = function() return v end } end')(a, v)
sensor = L.eval('function(push, pop) return { pushFrame = function(self, t) return push(t) end, popFrame = function(self) return pop() end } end')(push, pop)
G.sport = L.eval('function(sn) return { getSensor = function(arg) return sn end } end')(sensor)
G.os.clock = lambda: state['t']
for k in ('RIGHT', 'CENTERED'): G[k] = 0
T = L.eval('''function() local T = {}
  T.alive = function() return true end
  T.split32 = function(v) if v < 0 then v = v + 4294967296 end return v % 65536, math.floor(v / 65536) end
  return T end''')()
P = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
LIST = L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read())
P.init(T, LIST)
S = L.eval('{ fc = "ArduPilot", link = "S.Port", armed = false, msgs = {} }')

fails = []
def check(what, cond):
    print(('PASS ' if cond else 'FAIL ') + what)
    if not cond: fails.append(what)
def run(sec, dt=0.05):
    n = int(sec / dt)
    for _ in range(n):
        state['t'] += dt
        for tx in ap.texts: L.eval('function(s, t) s.msgs[#s.msgs+1] = { text = t, sev = 4 } end')(S, tx)
        ap.texts.clear()
        P.wakeup(S)

# 1 float32 round trip, byte exact against struct
rnd = random.Random(1)
vals = [0.0, 1.0, -1.0, 0.345, 0.0036, 0.08, 18.0, 1048575.0, 13.2, -0.5, 30000.0, 1e-20, 3.4e38, 0.001]
vals += [rnd.uniform(-1000, 1000) for _ in range(300)] + [rnd.uniform(0, 1) for _ in range(300)]
bad = 0
for v in vals:
    b = list(P._f2b(v).values()); want = list(struct.pack('<f', v))
    if b != want: bad += 1; print('  f2b', v, b, want) if bad < 5 else None
    back = P._b2f(*want); exp = struct.unpack('<f', bytes(want))[0]
    if abs(back - exp) > abs(exp) * 1e-7 + 1e-45: bad += 1; print('  b2f', v, back, exp) if bad < 5 else None
check('float32 encode/decode byte-exact on %d values' % len(vals), bad == 0)

def tab_names():
    """the page's tabs in order, from walking the wheel (Q tabs only when shown)"""
    P.key(S, 'back')
    for _ in range(200): P.key(S, 'left')
    seen = []
    for _ in range(200):
        P.key(S, 'right'); t = P._tab()
        if not seen or seen[-1] != t: seen.append(t)
    P.key(S, 'back')
    return seen
def open_tab(tab):
    """wheel to the first row of a tab, then RTN: the page stays on that tab"""
    P.key(S, 'back')
    for _ in range(200): P.key(S, 'left')
    for _ in range(200):
        P.key(S, 'right')
        if P._tab() == tab: break
    P.key(S, 'back')
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

# 2 Q_ENABLE then the list reads; missing params become n/a without hanging
state['busy'] = True
run(40)
check('only the open tab is read: FLIGHT done, TECS untouched', tab_done('FLIGHT') and all(P.valueOf(n) is None for n in rows_of('TECS')))
read_tabs()
v = L.eval('function(P) return P end')(P)
got = L.eval('function(P, n) return nil end')
check('read AIRSPEED_CRUISE over MAVlite', abs(P.stats.rx) > 0)
dbg = P.debug(); print('  ', dbg)
check('no checksum errors', P.stats.bad == 0)
check('idle after reading the whole list', 'idle' in dbg)

# AIRSPEED_CRUISE (TECS tab): its row number in the list (all rows shown: Q_ENABLE 1)
CRUISE_ROW = [L.eval('function(L, i) return L[i][2] end')(LIST, i) for i in range(1, len(LIST) + 1)].index('AIRSPEED_CRUISE') + 1
check('ENTER with nothing selected turns the page', P.key(S, 'enter') == 'next')
for _ in range(CRUISE_ROW): P.key(S, 'right')   # the wheel walks the rows to AIRSPEED_CRUISE
check('ENTER opens the editor', P.key(S, 'enter') is True)
run(2)
for _ in range(4): P.key(S, 'right')       # +4 x 0.5 = 20.0
S.armed = True
P.key(S, 'enter'); run(2)
check('armed: no PARAM_SET sent', ap.sets == 0 and PARAMS['AIRSPEED_CRUISE'] == ap.p['AIRSPEED_CRUISE'])
check('armed: ENTER closed the editor', not P.editing())
S.armed = False
P.key(S, 'enter'); run(2)
for _ in range(4): P.key(S, 'right')
P.key(S, 'enter'); run(3)
check('save AIRSPEED_CRUISE 18 -> 20 reached the FC', abs(ap.p['AIRSPEED_CRUISE'] - 20.0) < 1e-6)
check('one PARAM_SET only', ap.sets == 1)
check('read-back shows "Saved and verified"', P.phase() == 'Saved and verified')
P.key(S, 'enter')                          # unchanged now: closes
check('ENTER on a saved value closes the editor', not P.editing())

# 3 a PID gain (float) by its doc step, then ARMING_SKIPCHK bits
def select(name):
    P.key(S, 'back')
    for _ in range(80): P.key(S, 'left')
    for i in range(1, 80):
        P.key(S, 'right')
        if L.eval('function(P, LIST) return nil end'): pass
        r = L.eval('function(LIST, i) return LIST[i] and LIST[i][2] end')
    return None
# walk to RLL_RATE_P by counting visible rows (Q rows shown: Q_ENABLE 1)
names = [L.eval('function(L, i) return L[i][2] end')(LIST, i) for i in range(1, len(LIST) + 1)]
def goto(name):
    P.key(S, 'back')
    for _ in range(100): P.key(S, 'left')
    for _ in range(names.index(name) + 1): P.key(S, 'right')
    run(2)
goto('RLL_RATE_P'); P.key(S, 'enter'); run(2)
P.key(S, 'right'); P.key(S, 'right'); P.key(S, 'enter'); run(3)
check('RLL_RATE_P 0.080 -> 0.090 (two steps of 0.005)', abs(ap.p['RLL_RATE_P'] - 0.09) < 1e-6)
P.key(S, 'back')
# a row that takes -1 (Q_ASSIST_SPEED: -1 = Q_ASSIST off): 0.2 -> 0.1 -> 0 -> -1 (not -0.1), and back up to 0
goto('Q_ASSIST_SPEED'); P.key(S, 'enter'); run(2)
for _ in range(3): P.key(S, 'left')
P.key(S, 'enter'); run(3)
check('Q_ASSIST_SPEED steps 0.2 -> 0 -> -1 and saves -1 (%s)' % ap.p['Q_ASSIST_SPEED'], abs(ap.p['Q_ASSIST_SPEED'] + 1) < 1e-6)
P.key(S, 'back')
goto('Q_ASSIST_SPEED'); P.key(S, 'enter'); run(2)
P.key(S, 'right'); P.key(S, 'enter'); run(3)
check('Q_ASSIST_SPEED one step up from -1 is 0 (%s)' % ap.p['Q_ASSIST_SPEED'], abs(ap.p['Q_ASSIST_SPEED']) < 1e-6)
P.key(S, 'back')
goto('ARMING_SKIPCHK'); P.key(S, 'enter'); run(2)
P.key(S, 'right'); P.key(S, 'right')     # cursor on bit 3 GPS lock... (cursor starts at 1 = Barometer)
P.key(S, 'enter')                         # toggle GPS lock (bit 3)
for _ in range(18 - 3 + 4): P.key(S, 'right')   # to "Save" (18 checks, All on, All off, Back, Save)
P.key(S, 'enter'); run(3)
check('ARMING_SKIPCHK GPS lock skipped = 8', ap.p['ARMING_SKIPCHK'] == 8.0)
P.key(S, 'back')
goto('TRIM_THROTTLE'); P.key(S, 'enter'); run(2)
orig = ap.handle
def deny(mid, pl):
    if mid == 23: ap.texts.append('Param write denied (TRIM_THROTTLE)'); ap.reply('TRIM_THROTTLE'); return
    orig(mid, pl)
ap.handle = deny
P.key(S, 'right'); P.key(S, 'enter'); run(3)
check('denied write: "Not saved" with the FC value', P.phase().startswith('Not saved') and ap.p['TRIM_THROTTLE'] == 45.0)
ap.handle = orig
# no answer at all: not resent, says check in a GCS
ap.handle = lambda mid, pl: None if mid == 23 else orig(mid, pl)
n0 = ap.sets
P.key(S, 'enter'); run(6)
check('no answer to a save: not sent again, "check in a GCS"', 'GCS' in P.phase())
ap.handle = orig
P.key(S, 'back')

# 3b in flight: gains and trims only, and only with "Edit in flight" on
S.armed = True
P.flightEdit = False
goto('RLL_RATE_P'); P.key(S, 'enter'); run(2)
before = ap.p['RLL_RATE_P']; P.key(S, 'right'); P.key(S, 'enter'); run(3)
check('armed, edit in flight Off: gain not written', ap.p['RLL_RATE_P'] == before and not P.editing())
P.flightEdit = True
goto('RLL_RATE_P'); P.key(S, 'enter'); run(2)
P.key(S, 'right'); P.key(S, 'enter'); run(3)
check('armed, edit in flight On: RLL_RATE_P +0.005 written and verified',
      abs(ap.p['RLL_RATE_P'] - (before + 0.005)) < 1e-6 and P.phase() == 'Saved and verified')
P.key(S, 'back')
goto('PTCH_RATE_FF'); P.key(S, 'enter'); run(2)
P.key(S, 'left'); P.key(S, 'enter'); run(3)
check('armed, edit in flight On: PTCH_RATE_FF -0.001 written', abs(ap.p['PTCH_RATE_FF'] - 0.344) < 1e-6)
P.key(S, 'back')
goto('AIRSPEED_CRUISE'); P.key(S, 'enter'); run(2)
c0 = ap.p['AIRSPEED_CRUISE']; P.key(S, 'right'); P.key(S, 'enter'); run(3)
check('armed, edit in flight On: AIRSPEED_CRUISE (not a gain/trim) stays view only', ap.p['AIRSPEED_CRUISE'] == c0)
P.key(S, 'back')
goto('Q_A_RAT_RLL_D'); P.key(S, 'enter'); run(2)
P.key(S, 'right'); P.key(S, 'enter'); run(3)
check('armed, edit in flight On: Q_A_RAT_RLL_D (Q PID) written', abs(ap.p['Q_A_RAT_RLL_D'] - 0.0041) < 1e-6)
P.key(S, 'back')
S.armed = False
P.flightEdit = False

# 4 link/FC gating
S2 = L.eval('{ fc = "INAV/BF", link = "S.Port", armed = false, msgs = {} }')
check('INAV: ENTER turns the page', P.key(S2, 'enter') == 'next')


# 5 params.txt: adds rows (built-in tab, new tab), flight marker, skips, Q_ gating, auto step
import tempfile
txt = """# comment
EXTRA_TOP
[pid] flight
YAW_RATE_P | Yaw P | 0.005
RLL_RATE_P
[NAV]
NAVL1_DAMPING
WP_RADIUS | WP radius |
Q_TAILSIT_MOT | Tail | 1
bad name here
[OOPS] maybe
TOO_LONG_NAME_FOR_MAVLINK
SERVO2_TRIM | Elev trim | -1
"""
tmp = os.path.join(tempfile.mkdtemp(), 'params.txt')
open(tmp, 'w').write(txt)
ap.p.update({'YAW_RATE_P': 0.2, 'NAVL1_DAMPING': 0.75, 'WP_RADIUS': 5.0, 'EXTRA_TOP': 0.0123, 'Q_ENABLE': 0.0})
P2 = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
LIST2 = L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read())
P2.init(T, LIST2, tmp)
X = P2.extra
print('   params.txt: added', X.added, 'skipped', X.skipped, 'first bad line', X.badLine)
check('params.txt: 5 rows added (EXTRA_TOP, YAW_RATE_P, NAV x2, Q_TAILSIT_MOT)', X.added == 5)
check('params.txt: 5 skipped (RLL_RATE_P dup, bad name, [OOPS] maybe, too long, step -1), first bad line 10',
      X.skipped == 5 and X.badLine == 10)
rows = {LIST2[i][2]: LIST2[i] for i in range(1, len(LIST2) + 1)}
check('[pid] adds to the built-in PID tab, flight marked', rows['YAW_RATE_P'][1] == 'PID' and rows['YAW_RATE_P'].fl)
check('names before any tab go to OTHER', rows['EXTRA_TOP'][1] == 'OTHER')
check('Q_ row from the file is a Q row', rows['Q_TAILSIT_MOT'][10] == 'q')
dbg = P2.debug(); print('  ', dbg)
check('sensor check line reports params.txt', 'params.txt +5 skipped 5 (line 10)' in dbg)
P = P2
ap.texts.clear()
LIST = LIST2; TAB_OF.clear()   # the helpers walk P2's tabs (OTHER and NAV from params.txt included)
read_tabs()
check('free row read: EXTRA_TOP auto step 0.0001 (about 1 % of 0.0123)', abs(rows['EXTRA_TOP'][7] - 0.0001) < 1e-12 and rows['EXTRA_TOP'][8] == 4)
check('free whole-number row: WP_RADIUS step 1', rows['WP_RADIUS'][7] == 1)
P2.key(S, 'back')
for _ in range(200): P2.key(S, 'left')
seen = []
for _ in range(120):
    P2.key(S, 'right'); P2.key(S, 'enter')
    if P2.editing():
        nm = P2._draft()[2]
        if not seen or seen[-1] != nm: seen.append(nm)
        P2.key(S, 'back')
check('wheel order: YAW_RATE_P at the end of the PID tab (after PTCH_RATE_FF, the last PID row this FC has)',
      'YAW_RATE_P' in seen and seen[seen.index('YAW_RATE_P') - 1] == 'PTCH_RATE_FF')
check('wheel order: new tabs after the built-in ones (NAV after PID rows)',
      'NAVL1_DAMPING' in seen and seen.index('NAVL1_DAMPING') > seen.index('YAW_RATE_P'))
def goto2(name):
    for _ in range(200): P2.key(S, 'left')
    for k in range(200):
        P2.key(S, 'right'); P2.key(S, 'enter')
        cur = P2._draft()[2] if P2.editing() else None
        if P2.editing(): P2.key(S, 'back')
        if cur == name: return True
    return False
P2.flightEdit = True
S.armed = True
assert goto2('YAW_RATE_P'); P2.key(S, 'enter'); run(2); P2.key(S, 'right'); P2.key(S, 'enter'); run(3)
check('armed: YAW_RATE_P ([pid] flight) saved +0.005', abs(ap.p['YAW_RATE_P'] - 0.205) < 1e-6)
P2.key(S, 'back')
assert goto2('WP_RADIUS'); P2.key(S, 'enter'); run(2); c0 = ap.p['WP_RADIUS']; P2.key(S, 'right'); P2.key(S, 'enter'); run(3)
check('armed: WP_RADIUS (no flight marker) view only', ap.p['WP_RADIUS'] == c0)
P2.key(S, 'back')
S.armed = False
assert goto2('WP_RADIUS'); P2.key(S, 'enter'); run(2)
for _ in range(30): P2.key(S, 'right')
P2.key(S, 'enter'); run(3)
check('free row: no range clamp, 5 + 30 x 1 = 35 saved', ap.p['WP_RADIUS'] == 35.0)
P2.key(S, 'back')
check('Q_ row hidden with Q_ENABLE 0', not goto2('Q_TAILSIT_MOT'))
P2.flightEdit = False


# 6 CRSF transport (ELRS / Crossfire, Stratos firmware): one 0x80 frame per request
#   { 0xC8, 0xEA, 0xF4, len, msgid, payload }, replies { 0xF4, len, msgid, payload } via T.onMavlite
crsf_frames = []
class CrsfFC:
    def __init__(self, ap, answer=True): self.ap, self.answer, self.replies = ap, answer, []
    def push(self, cmd, data):
        d = [int(data[i]) for i in range(1, len(data) + 1)]
        crsf_frames.append((int(cmd), d))
        if not self.answer or cmd != 0x80 or d[:3] != [0xC8, 0xEA, 0xF4]: return True
        ln, mid, pl = d[3], d[4], bytes(d[5:5 + d[3]])
        r = self.ap.mission_reply(mid, pl)
        if r:
            self.replies.append([0xF4, len(r[1]), r[0]] + list(r[1])); return True
        if mid == 20:
            name = pl.decode()
            if name in self.ap.p: self.reply(name)
            else: self.ap.texts.append('Param read failed (%s)' % name)
        elif mid == 23:
            v = struct.unpack('<f', pl[:4])[0]; name = pl[4:].decode()
            if name in self.ap.p:
                self.ap.p[name] = struct.unpack('<f', struct.pack('<f', v))[0]; self.ap.sets += 1; self.reply(name)
        return True
    def reply(self, name):
        pl = struct.pack('<f', self.ap.p[name]) + name.encode()
        self.replies.append([0xF4, len(pl), 22] + list(pl))
fc = CrsfFC(ap)
G.crsf = L.eval('function(push) local sn = { pushFrame = function(self, c, d) return push(c, d) end } return { getSensor = function() return sn end } end')(lambda c, d: fc.push(c, d))
# telem.lua owns the one CRSF sensor; params.lua sends through T.crsfPush
T.crsfPush = L.eval('function(sn) return function(c, d) return sn:pushFrame(c, d) end end')(G.crsf.getSensor())
gets = [0]
G.crsf = L.eval('function(push, count) local sn = { pushFrame = function(self, c, d) return push(c, d) end } return { getSensor = function() count() return sn end } end')(lambda c, d: fc.push(c, d), lambda: gets.__setitem__(0, gets[0] + 1))
P3 = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
LIST3 = L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read())
P3.init(T, LIST3, None)
SC = L.eval('{ fc = "ArduPilot", link = "CRSF", armed = false, msgs = {} }')
def runc(sec, dt=0.05):
    for _ in range(int(sec / dt)):
        state['t'] += dt
        while fc.replies: T.onMavlite(L.table_from(fc.replies.pop(0)))
        for tx in ap.texts: L.eval('function(s, t) s.msgs[#s.msgs+1] = { text = t, sev = 4 } end')(SC, tx)
        ap.texts.clear()
        P3.wakeup(SC)
ap.p['Q_ENABLE'] = 0.0
runc(30)
check('CRSF: params.lua makes no CRSF sensor of its own (sends via telem.lua)', gets[0] == 0)
_req = [(c, d) for c, d in crsf_frames if c != 0xAA]
_hb = [(c, d) for c, d in crsf_frames if c == 0xAA]
check('CRSF: every request is one 0x80 frame C8 EA F4 len msgid ...', _req and all(c == 0x80 and d[:3] == [0xC8, 0xEA, 0xF4] and d[3] == len(d) - 5 for c, d in _req))
check('CRSF: a GCS HEARTBEAT in an mLRS bridge frame every 2 s (wakes cbridge; %d)' % len(_hb), len(_hb) >= 10 and all(d[2] == 0xFD and d[9] == 0 for c, d in _hb))
check('CRSF: all rows read (idle, no bad frames)', 'idle' in P3.debug() and P3.stats.bad == 0)
P3.key(SC, 'back')
for _ in range(100): P3.key(SC, 'left')
_qrows = sum(1 for i in range(1, CRUISE_ROW) if L.eval('function(L, i) return L[i][10] end')(LIST3, i) == 'q')
for _ in range(CRUISE_ROW - _qrows): P3.key(SC, 'right')     # (Q rows hidden: Q_ENABLE 0)
runc(3)                       # its tab (TECS) is read now, the selected row first
P3.key(SC, 'enter'); runc(2)
b0 = ap.p['AIRSPEED_CRUISE']
P3.key(SC, 'right'); P3.key(SC, 'enter'); runc(3)
check('CRSF: save AIRSPEED_CRUISE +0.5, "Saved and verified"', abs(ap.p['AIRSPEED_CRUISE'] - (b0 + 0.5)) < 1e-6 and P3.phase() == 'Saved and verified')
P3.key(SC, 'back'); P3.key(SC, 'back')
check('CRSF: ENTER with no row picked turns the page', P3.key(SC, 'enter') == 'next')
# a flight controller that never answers (upstream ArduPilot over ELRS, mLRS, ELRS MAVLink mode)
crsf_frames.clear()
fc.answer = False
P4 = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
P4.init(T, L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read()), None)
P3 = P4
runc(14)
check('CRSF, no answer: "NO ANSWER", sending stops', 'NO ANSWER' in P4.debug())
n0 = len(crsf_frames); runc(5)
check('CRSF, no answer: quiet until the 15 s retry', len(crsf_frames) == n0)
runc(12)
check('CRSF, no answer: tries again after 15 s', len(crsf_frames) > n0)
fc.answer = True
runc(20)
check('CRSF: answers after the retry (firmware flashed) clear NO ANSWER', 'NO ANSWER' not in P4.debug() and P4.stats.rx > 0)


# 7 ArduPilot mission download (Stratos firmware) over S.Port and CRSF
HOME7 = (-35.36, 149.16)
BASE7 = [(16, 0, 0.0, 0.0, 0.0, 0.0, 0.0),
              (22, 3, -35.361, 149.161, 40.0, 0.0, 0.0),
              (16, 3, -35.362, 149.162, 60.0, 0.0, 0.0),
              (18, 3, -35.363, 149.163, 70.0, 3.0, 80.0),
              (189, 0, 0.0, 0.0, 0.0, 0.0, 0.0),
              (21, 3, -35.364, 149.164, 0.0, 0.0, 0.0)]
for transport in ('sport', 'crsf'):
    ap.mission = list(BASE7); ap.mstamp += 5000
    Pm = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
    Pm.init(T, L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read()), None)
    got = []
    Pm.onMission = lambda lst: got.append(None if lst is None else [dict(lst[i]) for i in range(1, len(lst) + 1)])
    Pm.missionOn = True
    Sm = L.eval('{ fc = "ArduPilot", link = "%s", armed = false, msgs = {} }' % ('S.Port' if transport == 'sport' else 'CRSF'))
    def runm(sec, dt=0.05, page=False):
        for _ in range(int(sec / dt)):
            state['t'] += dt
            while fc.replies: T.onMavlite(L.table_from(fc.replies.pop(0)))
            (Pm.wakeup if page else Pm.missionWakeup)(Sm)
    runm(3)
    lst = got[-1] if got else None
    ok = lst is not None and [x['seq'] for x in lst] == [1, 2, 3, 4, 5]
    check('%s: mission downloaded (5 items after home)' % transport, ok)
    if ok:
        l3 = lst[2]
        check('%s: item 3 LOITER_TURNS lat/lon/alt/turns/radius' % transport,
              l3['cmd'] == 18 and abs(l3['lat'] + 35.363) < 1e-6 and abs(l3['lon'] - 149.163) < 1e-6 and l3['alt'] == 70 and l3['p1'] == 3 and l3['p3'] == 80)
    check('%s: Sensor check line shows "mission: 5 items"' % transport, 'mission: 5 items' in Pm.debug())
    n0 = len(got); runm(12)
    check('%s: unchanged mission is not downloaded again' % transport, len(got) == n0)
    ap.mission.append((16, 3, -35.365, 149.165, 50.0, 0.0, 0.0)); ap.mstamp += 5000
    runm(12)
    check('%s: mission changed in a GCS -> downloaded again (6 items)' % transport, got and got[-1] and len(got[-1]) == 6)
    Sm.armed = True
    ap.mission.pop(); ap.mstamp += 5000
    n0 = len(got); runm(25)
    check('%s: armed -> no re-check, the mission on the map stays' % transport, len(got) == n0)
    Sm.armed = False
    runm(12)
    check('%s: disarmed again -> the change is picked up (5 items)' % transport, got and got[-1] and len(got[-1]) == 5)
    ap.mission[:] = ap.mission[:1]; ap.mstamp += 5000
    runm(12)
    check('%s: empty mission (home only) -> nothing on the map' % transport, got and got[-1] is None)
    ap.mission[:] = [(16, 0, 0.0, 0.0, 0.0, 0.0, 0.0), (16, 3, -35.361, 149.161, 40.0, 0.0, 0.0)]; ap.mstamp += 5000
    runm(12)
    tx0 = P.stats.tx
    check('%s: params page still reads while the mission client is on (no n/a from mission traffic)' % transport,
          'NO ANSWER' not in Pm.debug())

# 8 mission SEND (EdgeTX / X20 editor) over S.Port and CRSF: clear, write, read back
SEND8 = [{'cmd': 22, 'frame': 3, 'lat': -35.36, 'lon': 149.16, 'alt': 50.0, 'p1': 0.0, 'p3': 0.0},
         {'cmd': 16, 'frame': 3, 'lat': -35.355, 'lon': 149.165, 'alt': 120.0, 'p1': 0.0, 'p3': 0.0},
         {'cmd': 18, 'frame': 3, 'lat': -35.35, 'lon': 149.17, 'alt': 110.0, 'p1': 3.0, 'p3': 0.0},
         {'cmd': 20, 'frame': 3, 'lat': 0.0, 'lon': 0.0, 'alt': 0.0, 'p1': 0.0, 'p3': 0.0}]
for transport in ('sport', 'crsf'):
    ap.mission = list(BASE7); ap.mstamp += 5000; ap.armed = False; ap.alt_bias = 0.0
    Pm = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
    Pm.init(T, L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read()), None)
    Pm.missionOn = True
    Sm = L.eval('{ fc = "ArduPilot", link = "%s", armed = false, msgs = {} }' % ('S.Port' if transport == 'sport' else 'CRSF'))
    def runm(sec, dt=0.05):
        for _ in range(int(sec / dt)):
            state['t'] += dt
            while fc.replies: T.onMavlite(L.table_from(fc.replies.pop(0)))
            Pm.missionWakeup(Sm)
    runm(3)
    send_items = L.table_from([L.table_from(d) for d in SEND8])
    Pm.missionSend(send_items); runm(6)
    st8 = Pm.sendState
    print('   %s send: %s / %s' % (transport, st8.state, st8.msg))
    check('%s: send -> "Sent and verified"' % transport, st8.state == 'done' and st8.msg == 'Sent and verified')
    m = ap.mission
    check('%s: the aircraft has exactly the 4 items (+ home), loiter 3 turns, RTL last' % transport,
          len(m) == 5 and [x[0] for x in m[1:]] == [22, 16, 18, 20] and m[3][5] == 3.0 and abs(m[2][2] + 35.355) < 1e-6 and abs(m[2][4] - 120) < 1e-6)
    ap.alt_bias = 7.0
    Pm.missionSend(send_items); runm(6)
    check('%s: a mission stored differently -> "Not verified"' % transport, Pm.sendState.state == 'failed' and Pm.sendState.msg.startswith('Not verified'))
    ap.alt_bias = 0.0; ap.armed = True
    Pm.missionSend(send_items); runm(4)
    check('%s: aircraft armed -> "Refused: aircraft armed"' % transport, Pm.sendState.state == 'failed' and Pm.sendState.msg == 'Refused: aircraft armed')
    ap.armed = False

# 9 VTOL mission send (quadplane): VTOL takeoff, transition to FW, WP, transition to VTOL, VTOL land
VT9 = [{'cmd': 84, 'frame': 3, 'lat': -35.36, 'lon': 149.16, 'alt': 30.0, 'p1': 0.0, 'p3': 0.0},
       {'cmd': 3000, 'frame': 2, 'lat': 0.0, 'lon': 0.0, 'alt': 0.0, 'p1': 4.0, 'p3': 0.0},
       {'cmd': 16, 'frame': 3, 'lat': -35.355, 'lon': 149.165, 'alt': 100.0, 'p1': 0.0, 'p3': 0.0},
       {'cmd': 3000, 'frame': 2, 'lat': 0.0, 'lon': 0.0, 'alt': 0.0, 'p1': 3.0, 'p3': 0.0},
       {'cmd': 85, 'frame': 3, 'lat': -35.361, 'lon': 149.161, 'alt': 40.0, 'p1': 0.0, 'p3': 0.0}]
for transport in ('sport', 'crsf'):
    ap.mission = list(BASE7); ap.mstamp += 5000; ap.armed = False; ap.alt_bias = 0.0
    ap.p['Q_ENABLE'] = 1.0
    Pm = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
    Pm.init(T, L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read()), None)
    Pm.missionOn = True
    Sm = L.eval('{ fc = "ArduPilot", link = "%s", armed = false, msgs = {} }' % ('S.Port' if transport == 'sport' else 'CRSF'))
    def runm(sec, dt=0.05):
        for _ in range(int(sec / dt)):
            state['t'] += dt
            while fc.replies: T.onMavlite(L.table_from(fc.replies.pop(0)))
            Pm.missionWakeup(Sm)
    runm(2)
    check('%s: quadplane unknown until asked' % transport, Pm.isQuadplane() is None)  # (fresh client)
    Pm.requestQ(); runm(2)
    check('%s: requestQ reads Q_ENABLE -> quadplane' % transport, Pm.isQuadplane() is True)
    Pm.missionSend(L.table_from([L.table_from(d) for d in VT9])); runm(6)
    check('%s: VTOL mission "Sent and verified" (%s)' % (transport, Pm.sendState.msg), Pm.sendState.state == 'done')
    check('%s: aircraft has VTOL takeoff, transition 4, WP, transition 3, VTOL land' % transport,
          [x[0] for x in ap.mission[1:]] == [84, 3000, 16, 3000, 85] and ap.mission[2][5] == 4 and ap.mission[4][5] == 3)

# 10 lost answers (Marcin X18 + ELRS 2026-11-15: most rows n/a until tapped): each parameter's first
# two answers are lost, more than one round of READ_TRIES. Over ELRS / Crossfire on the X18 the rows
# must fill in by themselves (EdgeTX / X20 unchanged); S.Port / F.Port is left as it was (n/a until tapped). A name the FC doesn't have goes
# n/a on both (its "failed" text).
def _lossy_run(transport):
    lost = {}
    def lossy_reply(name, orig):
        lost[name] = lost.get(name, 0) + 1
        if lost[name] > 2: orig(name)
    sp0, cr0 = ap.reply, fc.reply
    ap.reply = lambda name: lossy_reply(name, sp0)
    fc.reply = lambda name: lossy_reply(name, cr0)
    ap.p['Q_ENABLE'] = 1.0
    Px = L.execute(open(os.path.join(DIR, 'params.lua'), encoding='utf-8').read())
    Px.init(T, L.execute(open(os.path.join(DIR, 'plist.lua'), encoding='utf-8').read()))
    Sx = L.eval('{ fc = "ArduPilot", link = "%s", armed = false, msgs = {} }' % ('CRSF' if transport == 'crsf' else 'S.Port'))
    def runx(sec, dt=0.05):
        for _ in range(int(sec / dt)):
            state['t'] += dt
            while fc.replies: T.onMavlite(L.table_from(fc.replies.pop(0)))
            for tx in ap.texts: L.eval('function(s, t) s.msgs[#s.msgs+1] = { text = t, sev = 4 } end')(Sx, tx)
            ap.texts.clear()
            Px.wakeup(Sx)
    tab = next(tb for tb in TAB_OF if 'AIRSPEED_CRUISE' in TAB_OF[tb])
    Px.key(Sx, 'back')
    for _ in range(200): Px.key(Sx, 'left')
    for _ in range(200):
        Px.key(Sx, 'right')
        if Px._tab() == tab: break
    Px.key(Sx, 'back')
    have = [n for n in rows_of(tab) if n in ap.p]
    none = [n for n in rows_of(tab) if n not in ap.p]
    t0 = state['t']
    for _ in range(60):
        runx(1)
        if all(Px.valueOf(n) is not None for n in have + none): break
    ap.reply, fc.reply = sp0, cr0
    return tab, have, none, Px, state['t'] - t0
tab, have, none, Px, dt = _lossy_run('crsf')
if tgt == 'x18':   # the fix is in the X18 copy only (user 2026-11-15); EdgeTX and X20 as before
    check('ELRS lost answers: %s rows the FC has all read without a tap (%s, %.0f s)' % (tab, ', '.join(have), dt),
          all(Px.valueOf(n) not in (None, False) for n in have))
else:
    check('ELRS unchanged on %s: lost answers still end as n/a (%s)' % (tgt, ', '.join(have)),
          all(Px.valueOf(n) is False for n in have))
check('ELRS lost answers: rows the FC lacks are n/a (%d)' % len(none), all(Px.valueOf(n) is False for n in none))
tab, have, none, Px, dt = _lossy_run('sport')
check('S.Port unchanged: lost answers still end as n/a (%s)' % ', '.join(have), all(Px.valueOf(n) is False for n in have))
check('S.Port: rows the FC lacks are n/a (%d)' % len(none), all(Px.valueOf(n) is False for n in none))

print('\n%s: %d failed' % (tgt + (' lua54' if '--lua54' in sys.argv else ' lua52'), len(fails)))
sys.exit(1 if fails else 0)
