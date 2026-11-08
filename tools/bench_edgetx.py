#!/usr/bin/env python3
"""Lua cost of an EdgeTX telemetry widget: OmniDeck against Yaapu, same input.

    python tools/bench_edgetx.py omnideck|yaapu [--seconds 60] [--crsf] [--texts]

Both widgets run in Lua 5.4 (lupa) against the same stubbed EdgeTX API on a 480 x 272
screen (TX16S), from a fake SD card (OmniDeck built with tools/build_edgetx.py, Yaapu from
~/yaapu-src/OTX_ETX/c480x272/SD/WIDGETS/yaapu), full screen. They are fed the same ArduPilot
passthrough: S.Port (sportTelemetryPop) or, with --crsf, CRSF (crossfireTelemetryPop, 0x80
frames with up to 9 values in one 0xF2 array frame); a full set every 0.25 s.

refresh() is called every 50 ms, as EdgeTX does for a widget on show; every Lua instruction
inside it is counted (EdgeTX's per-call limit is 20,000), and getUsage() reports that count
live, as EdgeTX's hook does. Drawing calls, bit32 and the other radio functions are C on
the radio and cost one call here too (they are Python functions, not Lua).

Reported: worst and median instructions per refresh() and Lua instructions per second.
"""
import os
import shutil
import statistics
import sys
import tempfile

from lupa import lua54

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from simtelem import packets, project   # noqa: E402
import build_edgetx                       # noqa: E402

args = sys.argv[1:]
WHO = args[0] if args else 'omnideck'
SECONDS = float(args[args.index('--seconds') + 1]) if '--seconds' in args else 60.0
CRSF = '--crsf' in args
# --elrs: ArduPilot over ELRS/Crossfire - no 0x0800 in passthrough, the position only as the
# native CRSF "GPS" sensor (getValue returns { lat=, lon= }), as AP_CRSF_Telem sends it
ELRS = '--elrs' in args
if ELRS: CRSF = True
W, H = 480, 272

SD = tempfile.mkdtemp(prefix='bench_etx_')
if WHO == 'omnideck':
    build_edgetx.build(SD)
    MAIN = '/WIDGETS/OmniDeck/main.lua'
    # OmniDeck Setup: link CRSF (Auto finds it too; set so both start alike); --panel N: the
    # main page's top-right panel (0 minimap, 1 radar, 2 OmniDeck logo, 3 Stratos logo)
    cfg = ('linkMode=1\n' if CRSF else '') + ('panel=%s\n' % args[args.index('--panel') + 1] if '--panel' in args else '')
    # --page 2: start on the map page (the trail is drawn there, not on the main page)
    cfg += ('startPage=%s\n' % args[args.index('--page') + 1]) if '--page' in args else ''
    if cfg:
        open(os.path.join(SD, 'WIDGETS', 'OmniDeck', 'Bench.cfg'), 'w').write(cfg)
else:
    shutil.copytree(os.path.expanduser('~/yaapu-src/OTX_ETX/c480x272/SD/WIDGETS/yaapu'),
                    os.path.join(SD, 'WIDGETS', 'Yaapu'))
    MAIN = '/WIDGETS/Yaapu/main.lua'
    os.makedirs(os.path.join(SD, 'WIDGETS', 'Yaapu', 'cfg'), exist_ok=True)
    if CRSF:   # Yaapu menu: "enable CRSF support" = yes (option 2)
        open(os.path.join(SD, 'WIDGETS', 'Yaapu', 'cfg', 'bench.cfg'), 'w').write('CRSF:2\n')


def sd_path(p):
    return os.path.join(SD, *[x for x in str(p).split('/') if x])


L = lua54.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
sim_t = [0.0]
sport_q, crsf_q = [], []


def sport_pop():
    if not sport_q: return None
    return sport_q.pop(0)


def crsf_pop():
    if not crsf_q: return None
    cmd, data = crsf_q.pop(0)
    return cmd, L.table_from(data)


# ---- radio functions in Python: C calls on the radio, one call each here
def extract(n, field, width=1): return (int(n) >> int(field)) & ((1 << int(width)) - 1)
def band(*a):
    r = 0xFFFFFFFF
    for x in a: r &= int(x) & 0xFFFFFFFF
    return r
def bor(*a):
    r = 0
    for x in a: r |= int(x) & 0xFFFFFFFF
    return r
G.bit32 = L.table_from({'extract': extract, 'band': band, 'bor': bor,
                        'bnot': lambda x: (~int(x)) & 0xFFFFFFFF,
                        'lshift': lambda x, n: (int(x) << int(n)) & 0xFFFFFFFF,
                        'rshift': lambda x, n: (int(x) & 0xFFFFFFFF) >> int(n),
                        'bxor': lambda a, b: (int(a) ^ int(b)) & 0xFFFFFFFF})
G.getTime = lambda: int(sim_t[0] * 100)
G.sportTelemetryPop = sport_pop
G.crossfireTelemetryPop = crsf_pop
G.sportTelemetryPush = lambda *a: True
G.crossfireTelemetryPush = lambda *a: True
G.LCD_W, G.LCD_H = W, H
ETXV = (args[args.index('--etxver') + 1] if '--etxver' in args else '2.10.5')   # --etxver 2.12.0
G.ETXVER_S = ETXV
G.ETXVER_MAJ, G.ETXVER_MIN, G.ETXVER_REV = (int(v) for v in ETXV.split('.'))


def lua_open(path, mode='r'):
    p = sd_path(path)
    if 'r' in mode and not os.path.exists(p): return None
    if 'w' in mode or 'a' in mode: os.makedirs(os.path.dirname(p), exist_ok=True)
    return open(p, mode.replace('b', '') + 'b' if 'b' in mode else mode.replace('b', ''), encoding=None if 'b' in mode else 'latin-1')


G.py_open = lua_open
G.py_rgb = lambda r, g=None, b=None: (r or 0) if g is None else int(r) * 65536 + int(g) * 256 + int(b)
G.py_size = lambda t, f=0: (len(str(t)) * 8, 16)
G.py_zero = lambda *a: 0
G.py_fread = lambda f, n=None: (f.read(int(n)) if n else f.read()) or ''
G.py_fwrite = lambda f, t: f.write(str(t))
G.py_fclose = lambda f: f.close()
G.py_exists = lambda p: os.path.exists(sd_path(p))
G.py_src = lambda p: open(sd_path(p), encoding='latin-1').read() if os.path.exists(sd_path(p)) else None
G.py_dir = lambda p: L.table_from(os.listdir(sd_path(p)) if os.path.isdir(sd_path(p)) else [])

L.execute(r'''
local unpack = table.unpack
-- counting: every instruction inside refresh(); getUsage() reads it live (percent of 20,000)
COUNT, COUNTING = 0, false
getUsage = function() return math.floor(COUNT / 200) end
function measured(fn, ...)
  COUNT = 0
  debug.sethook(function() COUNT = COUNT + 1 end, "", 1)
  local r = table.pack(pcall(fn, ...))
  debug.sethook()
  if not r[1] then error(r[2], 0) end
  return COUNT
end

local stubMT = {}
local function stub() return setmetatable({}, stubMT) end
stubMT.__index = function() return function() return stub() end end
STUB = stub

lcd = setmetatable({ RGB = py_rgb, sizeText = py_size, getLastPos = py_zero, getLastRightPos = py_zero,
                     getLastLeftPos = py_zero },
                   { __index = function(t, k) t[k] = py_zero return py_zero end })

Bitmap = { open = function() return {} end, getSize = function() return 64, 64 end, resize = function(b) return b end }
getVersion = function() return ETXVER_S, "tx16s", ETXVER_MAJ, ETXVER_MIN, ETXVER_REV, "EdgeTX" end
getGeneralSettings = function() return { imperial = 0, battMin = 6.6, battMax = 8.4, language = "en", voice = "en",
                                          gtimer = 0 } end
getDateTime = function() return { year = 2026, mon = 11, day = 7, hour = 12, min = 0, sec = 0 } end
getRSSI = function() return 99, 40, 30 end
getValue = function(n) if py_val then local v = py_val(n) if v ~= nil then return v end end return 0 end
getFieldInfo = function(n) return { id = 1, name = tostring(n), desc = tostring(n), unit = 0 } end
getSourceValue = function() return 0 end
getSwitchValue = function() return false end
getOutputValue = function() return 0 end
getFlightMode = function() return 0, "FM0" end
setTelemetryValue = function() return true end
getStickMode = function() return 1 end
playFile = function() end playNumber = function() end playHaptic = function() end playTone = function() end
popupConfirmation = function() end
killEvents = function() end
model = setmetatable({
  getInfo = function() return { name = "Bench", bitmap = "" } end,
  getTimer = function() return { value = 0, start = 0, countdownBeep = 0, minuteBeep = false, persistent = 0 } end,
  setTimer = function() end, resetTimer = function() end,
  getSensor = function() return nil end,
}, { __index = function() return function() return stub() end end })

-- files on the fake SD card (EdgeTX's io: io.open, io.read(f, n), io.write(f, s), io.close(f))
io = {
  open = function(p, m) return py_open(p, m or "r") end,
  read = function(f, n) return py_fread(f, n) end,
  write = function(f, ...) for _, s in ipairs({...}) do py_fwrite(f, s) end end,
  close = function(f) py_fclose(f) end,
}
fstat = function(p) if py_exists(p) then return { size = 1, time = { year = 2026, mon = 1, day = 1, hour = 0, min = 0, sec = 0 } } end return nil end
dir = function(p) local t, i = py_dir(p), 0 return function() i = i + 1 return t[i] end end
loadScript = function(path, mode, env)
  local src = py_src(path)
  if src == nil then return nil, "not found: " .. tostring(path) end
  return load(src, "@" .. path, "t", env or _G)
end
''')

# string.format as EdgeTX's Lua 5.2: %d of a fractional number truncates (Lua 5.4 refuses it).
# A Python function (one call, as the C original on the radio), retried with whole numbers.
_fmt = L.eval('string.format')
def lua52_format(f, *a):
    try:
        return _fmt(f, *a)
    except Exception:
        return _fmt(f, *[int(x) if isinstance(x, float) and x == x and abs(x) != float('inf') else x for x in a])
G.py_format = lua52_format
L.execute('string.format = py_format')
# what the widget draws, for --texts: captured from the start (OmniDeck's adapter keeps its own
# reference to lcd.drawText), switched on only for the one checked refresh
CAPT = {'on': False, 'texts': [], 'nums': []}
def _cap_text(*a):
    if CAPT['on'] and len(a) > 2: CAPT['texts'].append(str(a[2]))
def _cap_num(*a):
    if CAPT['on'] and len(a) > 2: CAPT['nums'].append(str(a[2]))
G.py_text, G.py_num = _cap_text, _cap_num
L.execute('lcd.drawText = py_text; lcd.drawNumber = py_num')

# EdgeTX constants: the ones both widgets use; any other upper-case global reads as 0 (a flag),
# as an EdgeTX flag would be some number
L.execute('''
for k, v in pairs({ SMLSIZE = 0x200, MIDSIZE = 0x300, DBLSIZE = 0x400, XXLSIZE = 0x500, TINSIZE = 0x600, STDSIZE = 0,
  BOLD = 0x10, CENTER = 0x80, RIGHT = 0x40, LEFT = 0, CUSTOM_COLOR = 0x8000, SOLID = 0, DOTTED = 1, BLINK = 0x1000,
  INVERS = 0x2000, SHADOWED = 0x4000, VALUE = 1, BOOL = 2, COLOR = 3, STRING = 4, SOURCE = 5, TIMER = 6,
  EVT_VIRTUAL_ENTER = 0x2001, EVT_VIRTUAL_NEXT = 0x2002, EVT_VIRTUAL_PREV = 0x2003, EVT_TOUCH_TAP = 0x3001,
  EVT_TOUCH_BREAK = 0x3002, EVT_TOUCH_FIRST = 0x3000, EVT_ENTER_BREAK = 0x2001, EVT_EXIT_BREAK = 0x2004 }) do _G[k] = v end
''')
if WHO == 'yaapu':
    L.execute('setmetatable(_G, { __index = function(t, k) if type(k) == "string" and k:match("^[A-Z][A-Z0-9_]*$") then return 0 end end })')

measured = G.measured
res = G.loadScript(MAIN, 'bt')
chunk = res[0] if isinstance(res, tuple) else res
assert chunk is not None, res
wdef = chunk()
opts = {}
for i in range(1, len(wdef.options or []) + 1):
    o = wdef.options[i]
    opts[o[1]] = o[3]
options = L.table_from(opts)
zone = L.table_from({'x': 0, 'y': 0, 'w': W, 'h': H})
holder = {}
def make(): holder['w'] = wdef.create(zone, options)
G.py_make = make
# (--elrs: link quality 100, as a live ELRS link reports; the GPS gate skips LQ 0)
if ELRS: G.py_val = lambda n: L.table_from({'lat': st['lat'], 'lon': st['lon']}) if n == 'GPS' else (100 if n == 'RQly' else None)
L.execute('py_make()')
widget = holder['w']
refresh = wdef.refresh
touch = None

st = dict(lat=43.49323, lon=142.88785, hlat=43.49323, hlon=142.88785, mode=5, armed=True, thr=55, sats=14,
          hdop=0.8, altmsl=160, volt=15.8, curr=12.3, mah=0, alt=120, vs=0, **{'as': 17.0}, gs=18.5,
          yaw=0, roll=20, pitch=5, wdir=270, wspd=4.2, wpn=0, wpd=0, wpb=0)
calls = []
# --prof parts|func|line (OmniDeck): where the refresh goes, sampled every 20 instructions.
#   parts: the screen part being drawn (the innermost safe(part, fn) on the stack), or
#          "update <fn>" for the work in UI.wakeup, "other" for the rest
#   func:  the function running (adapter work in etx.lua shows as its own functions)
#   line:  the line of OmniDeck code running, adapter work charged to the line that called it
PROF = args[args.index('--prof') + 1] if '--prof' in args else None
if PROF:
    G.PROFMODE = PROF
    L.execute('''
      PROFT = {}
      function measured(fn, ...)
        COUNT = 0
        debug.sethook(function()
          COUNT = COUNT + 20
          local k
          if PROFMODE == "parts" then
            for lv = 2, 40 do
              local i = debug.getinfo(lv, "Sn")
              if not i then break end
              if i.name == "safe" then
                local nm, v = debug.getlocal(lv, 1)
                if nm == "part" then k = "draw " .. tostring(v) break end
              end
              if i.name == "wakeup" and string.find(i.short_src or "", "ui.lua", 1, true) then
                local c = debug.getinfo(lv - 1, "Sn")
                k = "update " .. ((c and c.name) or "?") break
              end
            end
            k = k or "other"
          elseif PROFMODE == "line" then
            for lv = 2, 40 do
              local i = debug.getinfo(lv, "Sl")
              if not i then break end
              local f = string.match(i.short_src or "?", "[^/]*$")
              if f ~= "etx.lua" and f ~= "[C]" then k = f .. ":" .. (i.currentline or 0) break end
            end
            k = k or "etx.lua"
          else
            local i = debug.getinfo(2, "Sn")
            k = i and (string.match(i.short_src or "?", "[^/]*$") .. ":" .. (i.linedefined or 0) .. " " .. (i.name or "?")) or "?"
          end
          PROFT[k] = (PROFT[k] or 0) + 1
        end, "", 20)
        local ok, err = pcall(fn, ...)
        debug.sethook()
        if not ok then error(err, 0) end
        return COUNT
      end''')
    measured = G.measured
# --split (OmniDeck): instructions spent in UI.wakeup (telemetry, voice, summary, alarms) and in
# UI.paint (drawing), out of each refresh
SPLIT = {'wake': [], 'paint': []}
if '--split' in args and WHO == 'omnideck':
    G.py_split = lambda k, n: SPLIT[k].append(n)
    L.execute('''
      local refresh = ...
      for i = 1, 200 do
        local n, v = debug.getupvalue(refresh, i)
        if n == nil then break end
        if n == "UI" then
          local w0, p0 = v.wakeup, v.paint
          v.wakeup = function(...) local c = COUNT local r = w0(...) py_split("wake", COUNT - c) return r end
          v.paint = function(...) local c = COUNT local r = p0(...) py_split("paint", COUNT - c) return r end
        end
      end''', wdef.refresh)
STEP, FEED = 0.05, 0.25
last_feed = -1.0
while sim_t[0] < SECONDS:
    sim_t[0] += STEP
    if sim_t[0] - last_feed >= FEED - 1e-9:
        last_feed = sim_t[0]
        st['yaw'] = (st['yaw'] + 1.5) % 360
        st['lat'], st['lon'] = project(st['lat'], st['lon'], st['gs'] * FEED, st['yaw'])
        st['mah'] += 1
        pk = packets(st)
        if ELRS: pk = [(a, v) for a, v in pk if a != 0x0800]
        if CRSF:
            for i in range(0, len(pk), 9):
                grp = pk[i:i + 9]
                data = [0xF2, len(grp)]
                for a, v in grp:
                    data += [a & 0xFF, a >> 8, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
                crsf_q.append((0x80, data))
        else:
            for a, v in pk:
                sport_q.append((0x1B, 0x10, a, v))
    calls.append(measured(refresh, widget, 0, touch))

if '--texts' in args:   # what one refresh drew: proof the widget shows flight data
    CAPT['on'] = True
    measured(refresh, widget, 0, touch)
    CAPT['on'] = False
    texts, nums = CAPT['texts'], CAPT['nums']
    print('texts:', ' | '.join(texts)[:700])
    print('numbers:', ' '.join(nums)[:300])
    print('frames still queued:', len(sport_q) + len(crsf_q))

steady = calls[int(len(calls) * 0.1):]
dur = SECONDS * 0.9
print('%s EdgeTX %s 480x272, %.0f s of flight (first 10 %% left out), %s passthrough' % (WHO, ETXV, SECONDS, 'CRSF' if CRSF else 'S.Port'))
print('  refresh: %5.1f per s   worst %7d   median %7d instructions   (%d %% of the 20,000 limit at worst)'
      % (len(steady) / dur, max(steady), statistics.median(steady), round(100 * max(steady) / 20000)))
print('  Lua instructions per second: %d' % (sum(steady) / dur))
print('  start-up (worst early refresh): %d' % max(calls[:int(len(calls) * 0.1)] or [0]))
if PROF:
    rows = sorted(((int(v), str(k)) for k, v in G.PROFT.items()), reverse=True)
    tot = sum(c for c, _ in rows) or 1
    print('profile (%s), share of all refresh work:' % PROF)
    for c, k in rows[:int(args[args.index('--top') + 1]) if '--top' in args else 25]:
        print('  %5.1f%%  %7d per refresh  %s' % (100 * c / tot, 20 * c / max(1, len(calls)), k))
if SPLIT['wake']:
    k = int(len(SPLIT['wake']) * 0.1)
    print('  of which: UI.wakeup median %d, UI.paint median %d (the rest: adapter tick, CRSF catch-up)'
          % (statistics.median(SPLIT['wake'][k:]), statistics.median(SPLIT['paint'][k:])))
shutil.rmtree(SD, ignore_errors=True)
