"""Both radio tools against a fake mLRS TX module + ArduPilot (pymavlink): request -> PARAM_VALUE shown."""
import os, random, sys
from lupa import lua52, lua54
from pymavlink.dialects.v20 import ardupilotmega as mav
HERE = os.path.dirname(os.path.abspath(__file__))
fails = 0
def check(name, ok):
    global fails
    print(('PASS ' if ok else 'FAIL ') + name); fails += 0 if ok else 1

class FakeModule:
    """Envelopes in -> MAVLink to the 'aircraft'; aircraft MAVLink out -> envelopes (<= 58 bytes)."""
    def __init__(self):
        self.ap = mav.MAVLink(None, srcSystem=1, srcComponent=1)
        self.rx = mav.MAVLink(None); self.rx.robust_parsing = True
        self.out = b''; self.reqs = []; random.seed(2)
    def from_radio(self, cmd, data):
        assert cmd == 0xAA and data[0] == 0 and data[1] == len(data) - 2, (cmd, data[:3])
        for m in self.rx.parse_buffer(bytes(data[2:])) or []:
            if m.get_type() == 'PARAM_REQUEST_READ':
                self.reqs.append(m)
                self.out += self.ap.param_value_encode(m.param_id.encode(), 18.0, 9, 1000, 120).pack(self.ap)
    def tick(self, t):
        if int(t * 10) % 10 == 0: self.out += self.ap.heartbeat_encode(1, 3, 0, 0, 4).pack(self.ap)
        self.out += self.ap.attitude_encode(int(t * 1000), 0.1, 0.2, 0.3, 0, 0, 0).pack(self.ap)
    def frames(self):
        fr = []
        while self.out:
            n = min(len(self.out), random.randint(20, 58))
            fr.append([0, n] + list(self.out[:n])); self.out = self.out[n:]
        return fr

for target, RT in (('edgetx', lua52), ('ethos', lua54)):
    L = RT.LuaRuntime(unpack_returned_tuples=True); G = L.globals()
    fm = FakeModule(); q = []; t = [0.0]
    path = os.path.join(HERE, 'out', *(('EdgeTX', 'SCRIPTS', 'TOOLS', 'mLRS cbridge test.lua') if target == 'edgetx' else ('Ethos', 'scripts', 'mlrstest', 'main.lua')))
    texts = []
    if target == 'edgetx':
        G.getTime = lambda: int(t[0] * 100)
        G.crossfireTelemetryPush = lambda c, d: fm.from_radio(c, list(d.values()))
        def pop():
            if not q: return None
            return (0xAA, L.table_from(q.pop(0)))
        G.crossfireTelemetryPop = pop
        L.execute('lcd = { clear = function() end, drawText = function(x, y, s) PYTXT(s) end } BOLD = 1 LCD_H = 272 EVT_VIRTUAL_EXIT = 99')
        G.PYTXT = lambda s: texts.append(s)
        tool = L.execute(open(path, encoding='utf-8').read())
        step = lambda: tool.run(0)
    else:
        L.execute('os.clock = PYCLOCK') if False else None
        G.PYCLOCK = lambda: t[0]
        L.execute('os.clock = PYCLOCK')
        sensor = L.eval('{}')
        G.PYPUSH = lambda c, d: fm.from_radio(c, list(d.values()))
        def popf(*a):
            if not q: return None
            return (0xAA, L.table_from(q.pop(0)))
        G.PYPOP = popf
        L.execute('''_S = { pushFrame = function(self, c, d) PYPUSH(c, d) end, popFrame = function(self, a, b) return PYPOP(a, b) end }
            crsf = { getSensor = function() return _S end }
            lcd = { invalidate = function() end, font = function() end, color = function() end, RGB = function() return 0 end, drawText = function(x, y, s) PYTXT(s) end, getWindowSize = function() return 800, 480 end, drawFilledRectangle = function() end, getTextSize = function() return 10, 20 end }
            FONT_S = 1
            FONT_STD = 0
            system = { registerWidget = function(t) TOOL = t end }''')
        G.PYTXT = lambda s: texts.append(s)
        L.execute(open(path, encoding='utf-8').read()).init()
        tool = G.TOOL; W = tool.create()
        def step(): tool.wakeup(W); tool.paint(W)
    for _ in range(100):           # 10 s at 10 Hz
        t[0] += 0.1
        fm.tick(t[0]); q.extend(fm.frames())
        texts.clear(); step()
    shown = ' | '.join(texts)
    check('%s: requests reached the aircraft as PARAM_REQUEST_READ AIRSPEED_CRUISE (%d)' % (target, len(fm.reqs)),
          len(fm.reqs) >= 2 and all(r.param_id == 'AIRSPEED_CRUISE' and r.target_system == 1 for r in fm.reqs))
    check('%s: screen shows the reply' % target, 'AIRSPEED_CRUISE = 18.000' in shown)
    check('%s: autopilot 1/1, no crc errors' % target, 'autopilot 1/1' in shown and 'crc bad 0' in shown)
    print('   ', shown)
print('%d failed' % fails); sys.exit(1 if fails else 0)
