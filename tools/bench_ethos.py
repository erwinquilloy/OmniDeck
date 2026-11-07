#!/usr/bin/env python3
"""Lua cost of an Ethos telemetry widget: OmniDeck against Yaapu, same input.

    python tools/bench_ethos.py omnideck|yaapu [--res 800x480] [--seconds 60] [--page main|map] [--crsf]

Both widgets run in Lua 5.4 (lupa) against the same stubbed Ethos API, fed the same
ArduPilot passthrough over S.Port, or with --crsf over CRSF (0x80 frames, up to 9 values
in one 0xF2 array frame, as ArduPilot packs them) (tools/simtelem.py: a full set of values
every 0.25 s, flying a circle). Yaapu's "CRSF" setting is switched on for --crsf. wakeup() is called every 50 ms, paint() whenever the widget asked for a
redraw (lcd.invalidate), as Ethos does. Every Lua instruction inside paint() and wakeup()
is counted, the work Ethos's per-call limit counts; drawing calls are C on the radio and
do nothing here.

Reported: worst and median instructions per paint() and per wakeup(), paints per second,
and Lua instructions per second in all (the widget's CPU load).

omnideck: targets/ethos (the loader picks x20/ or x18/ by --res).
yaapu:    ~/yaapu-src/ETHOS/c<res>/SD/scripts/yaaputelemetry (+ common audio not needed).
"""
import os
import statistics
import sys

from lupa import lua54

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from simtelem import packets, project   # noqa: E402

args = sys.argv[1:]
WHO = args[0] if args else 'omnideck'
RES = args[args.index('--res') + 1] if '--res' in args else '800x480'
SECONDS = float(args[args.index('--seconds') + 1]) if '--seconds' in args else 60.0
PAGE = args[args.index('--page') + 1] if '--page' in args else 'main'
CRSF = '--crsf' in args
W, H = map(int, RES.split('x'))

if WHO == 'omnideck':
    ROOT = os.path.normpath(os.path.join(HERE, '..', 'targets', 'ethos'))
else:
    ROOT = os.path.expanduser('~/yaapu-src/ETHOS/c%s/SD/scripts/yaaputelemetry' % RES)
assert os.path.isfile(os.path.join(ROOT, 'main.lua')), ROOT

L = lua54.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
sim_t = [0.0]
G.py_time = lambda: sim_t[0]
sport_q = []
def pop_sport():
    if not sport_q: return None
    return tuple(sport_q.pop(0))
G.py_pop_sport = pop_sport
crsf_q = []
def pop_crsf():
    if not crsf_q: return None
    return L.table_from(crsf_q.pop(0))
G.py_pop_crsf = pop_crsf
G.YAAPU_CRSF = CRSF and WHO == 'yaapu'
G.SCR_W, G.SCR_H = W, H
G.py_rgb = lambda r=0, g=0, b=0, a=None: int(r or 0) * 65536 + int(g or 0) * 256 + int(b or 0)
G.py_size = lambda t=None, *a: (len(str(t if t is not None else '')) * 8, 16)
G.py_zero = lambda *a: 0
CAP = {'on': False, 'texts': []}
def _text(*a):
    if CAP['on'] and len(a) > 2: CAP['texts'].append(str(a[2]))
    return 0
G.py_text = _text

L.execute(r'''
-- a placeholder for anything not stubbed: callable, indexable, and every method returns another
local stubMT = {}
local function stub() return setmetatable({}, stubMT) end
stubMT.__index = function(t, k) return function(...) return stub() end end
stubMT.__call = function() return stub() end
STUB = stub

local function now() return py_time() end
getTime = function() return math.floor(now() * 100) end
os.clock = now
os.time = function() return 1730000000 + math.floor(now()) end

lcd = setmetatable({
  RGB = py_rgb,
  getWindowSize = function() return SCR_W, SCR_H end,
  getTextSize = py_size,
  loadBitmap = function() return setmetatable({ width = function() return 64 end, height = function() return 64 end }, stubMT) end,
  loadMask = function() return stub() end,
  isVisible = function() return true end,
  invalidate = function() INVALIDATED = true end,
  drawText = py_text,
}, { __index = function(t, k) t[k] = py_zero return py_zero end })

local function source()
  return setmetatable({ value = function() return 0 end, name = function() return "src" end,
                        state = function() return true end, stringValue = function() return "" end,
                        unit = function() return 0 end }, stubMT)
end
system = setmetatable({
  getVersion = function() return { major = 1, minor = 6, revision = 3, board = "X20S", version = "1.6.3",
                                   lcdWidth = SCR_W, lcdHeight = SCR_H, simulation = false } end,
  getSource = function() return source() end,
  registerWidget = function(t) WIDGET = t end,
  registerSource = function() end,
  listFiles = function() return {} end,
  getMemoryUsage = function() return { luaRamAvailable = 400000, mainStackAvailable = 4000, ramAvailable = 400000 } end,
  playFile = function() end, playNumber = function() end, playHaptic = function() end,
  playTone = function() end, killEvents = function() end, resetBacklightTimeout = function() end,
  getLocale = function() return "en" end,
}, { __index = function(t, k) return function() return stub() end end })

model = setmetatable({
  name = function() return "Bench" end,
  getTimer = function() return setmetatable({ value = function() return 0 end }, stubMT) end,
  createTimer = function() return stub() end,
  getSensor = function() return nil end,
  createSensor = function() return stub() end,
}, { __index = function(t, k) return function() return stub() end end })

storage = { read = function(k) if k == "enableCRSF" and YAAPU_CRSF then return true end return nil end,
            write = function() end }
form = setmetatable({ getFieldSlots = function() return { [0] = 0, 0, 0, 0, 0 } end },
                    { __index = function(t, k) return function() return stub() end end })

-- S.Port passthrough: one reader object, frames from Python
local function frame(p, pr, a, v)
  return { physId = function() return p end, primId = function() return pr end,
           appId = function() return a end, value = function() return v end }
end
local sportSensor = {
  popFrame = function(self)
    local p, pr, a, v = py_pop_sport()
    if p == nil then return nil end
    return frame(p, pr, a, v)
  end,
  pushFrame = function() return true end,
}
sport = { getSensor = function() return sportSensor end }
local crsfSensor = {
  popFrame = function(self)
    local d = py_pop_crsf()
    if d == nil then return nil end
    local t = {} for i = 1, #d do t[i] = d[i] end
    return 0x80, t
  end,
  pushFrame = function() return true end,
}
crsf = { getSensor = function() return crsfSensor end, popFrame = function() return crsfSensor:popFrame() end }
serial = nil

-- Ethos constants both widgets use
for k, v in pairs({ FONT_XXS = 1, FONT_XS = 2, FONT_S = 3, FONT_STD = 4, FONT_L = 5, FONT_XL = 6, FONT_XXL = 7,
                    FONT_S_BOLD = 8, FONT_STD_BOLD = 9, FONT_L_BOLD = 10, FONT_XL_BOLD = 11, FONT_XXL_BOLD = 12,
                    LEFT = 0, CENTERED = 1, RIGHT = 2, TEXT_LEFT = 0, TEXT_CENTERED = 1, TEXT_RIGHT = 2,
                    SOLID = 0, DOTTED = 1, CATEGORY_ALWAYS_ON = 1, CATEGORY_NONE = 0, CATEGORY_SYSTEM = 2,
                    CATEGORY_TELEMETRY_SENSOR = 3, CATEGORY_ANALOG = 4, MAIN_VOLTAGE = 1,
                    EVT_KEY = 1, EVT_TOUCH = 2, TOUCH_START = 1, TOUCH_END = 2, TOUCH_MOVE = 3,
                    OPTION_LATITUDE = 1, OPTION_LONGITUDE = 2, UNIT_METER = 9, UNIT_KNOT = 4,
                    COLOR_WHITE = 0xFFFFFF, COLOR_BLACK = 0, COLOR_RED = 0xFF0000, COLOR_GREEN = 0x00FF00,
                    COLOR_YELLOW = 0xFFFF00, COLOR_BLUE = 0x0000FF, COLOR_GREY = 0x808080 }) do
  _G[k] = v
end

-- counting: every instruction inside the call (the hook itself is not counted)
COUNT = 0
function measured(fn, ...)
  COUNT = 0
  debug.sethook(function() COUNT = COUNT + 1 end, "", 1)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  if not ok then error(err, 0) end
  return COUNT
end
''')

os.chdir(ROOT)
if WHO == 'omnideck':
    mod = L.execute(open('main.lua', encoding='utf8').read())
    if mod is not None and hasattr(mod, '__getitem__') and mod['init']:
        mod['init']()
else:
    mod = L.execute('return dofile("main.lua")')
    if mod is not None and mod['init']:
        mod['init']()
wt = G.WIDGET
assert wt is not None, 'no widget registered'
measured = G.measured
widget = wt['create']()
if wt['read']:
    try:
        wt['read'](widget)
    except Exception as e:   # a widget that wants more of the storage API than stubbed
        print('read() skipped:', str(e)[:120])
if WHO == 'omnideck' and PAGE == 'map':
    widget.page = 2

st = dict(lat=43.49323, lon=142.88785, hlat=43.49323, hlon=142.88785, mode=5, armed=True, thr=55, sats=14,
          hdop=0.8, altmsl=160, volt=15.8, curr=12.3, mah=0, alt=120, vs=0, **{'as': 17.0}, gs=18.5,
          yaw=0, roll=20, pitch=5, wdir=270, wspd=4.2, wpn=0, wpd=0, wpb=0)

paints, wakes = [], []
STEP, FEED = 0.05, 0.25
last_feed = -1.0
t_end = SECONDS
while sim_t[0] < t_end:
    sim_t[0] += STEP
    if sim_t[0] - last_feed >= FEED - 1e-9:
        last_feed = sim_t[0]
        st['yaw'] = (st['yaw'] + 1.5) % 360
        st['lat'], st['lon'] = project(st['lat'], st['lon'], st['gs'] * FEED, st['yaw'])
        st['mah'] += 1
        pk = packets(st)
        if CRSF:
            for i in range(0, len(pk), 9):
                grp = pk[i:i + 9]
                data = [0xF2, len(grp)]
                for a, v in grp:
                    data += [a & 0xFF, a >> 8, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
                crsf_q.append(data)
        else:
            for a, v in pk:
                sport_q.append((0x1B, 0x10, a, v))
    wakes.append(measured(wt['wakeup'], widget))
    if G.INVALIDATED:
        G.INVALIDATED = False
        paints.append(measured(wt['paint'], widget))

if '--texts' in args:   # what the last paint drew: proof the widget shows flight data
    CAP['on'] = True
    measured(wt['paint'], widget)
    CAP['on'] = False
    print('texts in one paint:', ' | '.join(CAP['texts'])[:900])
    print('frames still queued:', len(sport_q) + len(crsf_q))
skip = int(len(wakes) * 0.1)          # the first seconds: start-up work, not the steady state
pw, ww = paints[int(len(paints) * 0.1):], wakes[skip:]
dur = SECONDS * 0.9
print('%s %s, %.0f s of flight (first 10 %% left out), %s passthrough' % (WHO, RES, SECONDS, 'CRSF' if CRSF else 'S.Port'))
print('  paint : %5.1f per s   worst %7d   median %7d instructions' % (len(pw) / dur, max(pw), statistics.median(pw)))
print('  wakeup: %5.1f per s   worst %7d   median %7d instructions' % (len(ww) / dur, max(ww), statistics.median(ww)))
print('  Lua instructions per second, paint + wakeup: %d' % ((sum(pw) + sum(ww)) / dur))
print('  start-up (first paint, worst early wakeup): %d / %d' % (paints[0] if paints else 0, max(wakes[:skip] or [0])))
