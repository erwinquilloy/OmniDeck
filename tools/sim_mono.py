#!/usr/bin/env python3
"""OmniDeck Mono in a 128x64 black-and-white EdgeTX stand-in (Lua 5.2, as EdgeTX).

    python tools/sim_mono.py [outdir] [--sport] [--native]

Runs targets/mono as a telemetry screen: init(), then background() / run(event) with ArduPilot
passthrough over CRSF (default) or S.Port (--sport), or INAV-style native sensors (--native).
Draws each page into a 128x64 one-bit image (saved 4x size) and checks:
  - the pages draw and show the values fed in (mode, altitude, link, flight controller)
  - ENTER cycles the pages
  - Lua instructions per run() call (EdgeTX stops a script that runs too long) and memory
    (collectgarbage count; the radio's 32-bit Lua uses less than this 64-bit one, so the
    radio's own figure on the link page is the one that counts)
"""
import math, os, sys
from lupa import lua52
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from simtelem import packets, text_chunks

args = [a for a in sys.argv[1:] if not a.startswith('--')]
OUT = os.path.abspath(args[0]) if args else os.path.join(HERE, 'out_mono')
SPORT, NATIVE = '--sport' in sys.argv, '--native' in sys.argv
SD = os.path.normpath(os.path.join(HERE, '..', 'targets', 'mono'))
os.makedirs(OUT, exist_ok=True)
tag = ('native' if NATIVE else 'ap') + ('_sport' if SPORT else '_crsf') + ('_imp' if '--imperial' in sys.argv else '') + ('_pages' if '--pages' in sys.argv else '') + ('_notable' if '--notable' in sys.argv else '')

L = lua52.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
L.execute('collectgarbage()')
MEM_BASE = L.eval('(collectgarbage("count"))')   # this Lua's own libraries, before any script

# ------------------------------------------------------------------ screen: 128x64, one bit
W, H = 128, 64
fb = bytearray(W * H)
texts = []
# flag values: arbitrary but distinct, as the scripts only pass the names
FLAGS = dict(INVERS=0x01, RIGHT=0x02, SMLSIZE=0x04, FORCE=0x08, ERASE=0x10, SOLID=0, DOTTED=0x55, BOLD=0x20,
             MIDSIZE=0x40, DBLSIZE=0x80, BLINK=0x100)
for k, v in FLAGS.items(): G[k] = v
FONT = {
'0':'01110 10001 10011 10101 11001 10001 01110','1':'00100 01100 00100 00100 00100 00100 01110','2':'01110 10001 00001 00010 00100 01000 11111',
'3':'11110 00001 00001 01110 00001 00001 11110','4':'00010 00110 01010 10010 11111 00010 00010','5':'11111 10000 11110 00001 00001 10001 01110',
'6':'00110 01000 10000 11110 10001 10001 01110','7':'11111 00001 00010 00100 01000 01000 01000','8':'01110 10001 10001 01110 10001 10001 01110',
'9':'01110 10001 10001 01111 00001 00010 01100','A':'01110 10001 10001 11111 10001 10001 10001','B':'11110 10001 10001 11110 10001 10001 11110',
'C':'01110 10001 10000 10000 10000 10001 01110','D':'11100 10010 10001 10001 10001 10010 11100','E':'11111 10000 10000 11110 10000 10000 11111',
'F':'11111 10000 10000 11110 10000 10000 10000','G':'01110 10001 10000 10111 10001 10001 01111','H':'10001 10001 10001 11111 10001 10001 10001',
'I':'01110 00100 00100 00100 00100 00100 01110','J':'00111 00010 00010 00010 00010 10010 01100','K':'10001 10010 10100 11000 10100 10010 10001',
'L':'10000 10000 10000 10000 10000 10000 11111','M':'10001 11011 10101 10101 10001 10001 10001','N':'10001 10001 11001 10101 10011 10001 10001',
'O':'01110 10001 10001 10001 10001 10001 01110','P':'11110 10001 10001 11110 10000 10000 10000','Q':'01110 10001 10001 10001 10101 10010 01101',
'R':'11110 10001 10001 11110 10100 10010 10001','S':'01111 10000 10000 01110 00001 00001 11110','T':'11111 00100 00100 00100 00100 00100 00100',
'U':'10001 10001 10001 10001 10001 10001 01110','V':'10001 10001 10001 10001 10001 01010 00100','W':'10001 10001 10001 10101 10101 10101 01010',
'X':'10001 10001 01010 00100 01010 10001 10001','Y':'10001 10001 01010 00100 00100 00100 00100','Z':'11111 00001 00010 00100 01000 10000 11111',
' ':'00000 00000 00000 00000 00000 00000 00000','.':'00000 00000 00000 00000 00000 01100 01100',':':'00000 01100 01100 00000 01100 01100 00000',
'-':'00000 00000 00000 11111 00000 00000 00000','+':'00000 00100 00100 11111 00100 00100 00000','/':'00001 00010 00010 00100 01000 01000 10000',
'%':'11001 11010 00010 00100 01000 01011 10011','!':'00100 00100 00100 00100 00100 00000 00100','(':'00010 00100 01000 01000 01000 00100 00010',
')':'01000 00100 00010 00010 00010 00100 01000',"'":'00100 00100 00000 00000 00000 00000 00000','=':'00000 00000 11111 00000 11111 00000 00000',
'*':'00000 10101 01110 11111 01110 10101 00000','?':'01110 10001 00001 00010 00100 00000 00100',
}
FONT_S = {
'0':'0110 1001 1001 1001 1001 0110',
'1':'0100 1100 0100 0100 0100 1110',
'2':'0110 1001 0010 0100 1000 1111',
'3':'1110 0001 0110 0001 0001 1110',
'4':'1001 1001 1111 0001 0001 0001',
'5':'1111 1000 1110 0001 0001 1110',
'6':'0110 1000 1110 1001 1001 0110',
'7':'1111 0001 0010 0100 0100 0100',
'8':'0110 1001 0110 1001 1001 0110',
'9':'0110 1001 1001 0111 0001 0110',
'.':'0000 0000 0000 0000 0000 0100',
':':'0000 0100 0000 0000 0100 0000',
'W':'1001 1001 1001 1111 1111 1001',
'H':'1001 1001 1111 1001 1001 1001',
'/':'0001 0010 0010 0100 0100 1000',
'K':'1001 1010 1100 1010 1001 1001',
'M':'1001 1111 1111 1001 1001 1001',
'T':'1111 0100 0100 0100 0100 0100',
'G':'0111 1000 1011 1001 1001 0111',
'S':'0111 1000 0110 0001 0001 1110',
'<':'0010 0100 1000 0100 0010 0000',
'>':'0100 0010 0001 0010 0100 0000',
'-':'0000 0000 1111 0000 0000 0000',
' ':'0000 0000 0000 0000 0000 0000',
'N':'1001 1101 1101 1011 1011 1001',
'?':'0110 1001 0010 0100 0000 0100',
}
def setpx(x, y, v):
    if 0 <= x < W and 0 <= y < H: fb[y * W + x] = v
def lcd_clear(*a):
    for i in range(W * H): fb[i] = 0
    texts.clear()
def colour(flags):
    return 0 if (flags or 0) & FLAGS['ERASE'] else 1
def draw_line(x1, y1, x2, y2, pattern=0, flags=0):
    x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
    v = colour(flags)
    dx, sx = abs(x2 - x1), 1 if x1 < x2 else -1
    dy, sy = -abs(y2 - y1), 1 if y1 < y2 else -1
    e = dx + dy
    while True:
        setpx(x1, y1, v)
        if x1 == x2 and y1 == y2: break
        e2 = 2 * e
        if e2 >= dy: e += dy; x1 += sx
        if e2 <= dx: e += dx; y1 += sy
def fill_rect(x, y, w, h, flags=0):
    v = colour(flags)
    for j in range(int(y), int(y) + int(h)):
        for i in range(int(x), int(x) + int(w)): setpx(i, j, v)
def rect(x, y, w, h, flags=0):
    x, y, w, h = int(x), int(y), int(w), int(h)
    draw_line(x, y, x + w - 1, y, 0, flags); draw_line(x, y + h - 1, x + w - 1, y + h - 1, 0, flags)
    draw_line(x, y, x, y + h - 1, 0, flags); draw_line(x + w - 1, y, x + w - 1, y + h - 1, 0, flags)
def draw_text(x, y, t, flags=0):
    t = str(t); flags = int(flags or 0)
    x, y = int(x), int(y)
    small = flags & FLAGS['SMLSIZE']
    font, pitch, gw, gh = (FONT_S, 5, 4, 6) if small else (FONT, 6, 5, 7)
    width = len(t) * pitch
    if flags & FLAGS['RIGHT']: x = x - width + 1
    inv = flags & FLAGS['INVERS']
    texts.append((t, x, y))
    if inv: fill_rect(x - 1, y - 1, width + 1, gh + 2)
    for k, ch in enumerate(t.upper()):
        rows = font.get(ch, font['?']).split()
        for r in range(gh):
            for c in range(gw):
                if rows[r][c] == '1': setpx(x + k * pitch + c, y + r, 0 if inv else 1)
    return x + width
G.lcd = L.table_from({'clear': lcd_clear, 'drawLine': draw_line, 'drawFilledRectangle': fill_rect,
                      'drawRectangle': rect, 'drawText': draw_text, 'drawPoint': lambda x, y, *a: setpx(int(x), int(y), 1)})
G.LCD_W, G.LCD_H = W, H
def save(name):
    im = Image.new('L', (W, H), 255)
    im.putdata([0 if p else 220 for p in fb])
    im.resize((W * 4, H * 4), Image.NEAREST).save(os.path.join(OUT, name))

# ------------------------------------------------------------------ radio
# EdgeTX-style io on a scratch copy of the card: reads fall back to the package, writes stay in
# OUT/sd (EdgeTX cannot make folders, so only the ones the package ships exist)
SIMSD = os.path.join(OUT, 'sd')
import shutil
shutil.rmtree(SIMSD, ignore_errors=True)
os.makedirs(os.path.join(SIMSD, 'SCRIPTS', 'OMNID', 'logs'))
IMPERIAL = '--imperial' in sys.argv
ALLPAGES = '--pages' in sys.argv
if IMPERIAL or ALLPAGES:
    with open(os.path.join(SIMSD, 'SCRIPTS', 'OMNID', 'Sim_Plane.cfg'), 'w') as f:
        f.write('altUnit=1\nspdUnit=3\neffUnit=3\nlowVolt=380\ncells=4\n' if IMPERIAL else 'statsPage=1\ncheckPage=1\n')
def sd_path(p, base):
    return os.path.join(base, *[x for x in str(p).split('/') if x])
handles = {}
def io_open(p, mode='r'):
    mode = str(mode)
    w = os.path.join(SIMSD, *[x for x in str(p).split('/') if x])
    if 'w' in mode or 'a' in mode:
        if not os.path.isdir(os.path.dirname(w)): return None
        fh = open(w, mode.replace('b', '') + 'b')
    else:
        src = w if os.path.isfile(w) else sd_path(p, SD)
        if not os.path.isfile(src): return None
        fh = open(src, 'rb')
    k = len(handles) + 1
    handles[k] = fh
    return k
def io_read(k, n=1024):
    d = handles[k].read(int(n))
    return d.decode('latin-1') if d else ''
def io_write(k, *parts):
    for s in parts: handles[k].write(str(s).encode('latin-1'))
def io_close(k): handles.pop(k).close()
G.io = L.table_from({'open': io_open, 'read': io_read, 'write': io_write, 'close': io_close})
# dir(): as EdgeTX, an iterator over a folder's names; two voice packs on the scratch card
for pk in ('Guy', 'Aria'):
    os.makedirs(os.path.join(SIMSD, 'SCRIPTS', 'OMNID', 'audio', pk), exist_ok=True)
def sim_dir(p):
    d = os.path.join(SIMSD, *[x for x in str(p).split('/') if x])
    names = sorted(os.listdir(d), reverse=True) if os.path.isdir(d) else []
    return L.eval('function(t) local i = 0 return function() i = i + 1 return t[i] end end')(L.table_from(names))
G.dir = sim_dir
G.getDateTime = lambda: L.table_from({'year': 2026, 'mon': 11, 'day': 13, 'hour': 9, 'min': 30, 'sec': 5})
t_ms = [0]
G.getTime = lambda: t_ms[0] // 10
G.getVersion = lambda: ('2.12.2', 'tx12mk2', 2, 12, 2, 'EdgeTX')
G.playFile = lambda *a: None
G.playNumber = lambda *a: None
G.playTone = lambda *a: None
G.EVT_VIRTUAL_ENTER, G.EVT_VIRTUAL_NEXT, G.EVT_VIRTUAL_PREV, G.EVT_VIRTUAL_EXIT = 0x2001, 0x2002, 0x2003, 0x2004
def load_script(path, mode='bt', env=None):
    p = os.path.join(SD, *[x for x in str(path).split('/') if x])
    if not os.path.isfile(p): return None
    src = open(p, encoding='utf-8').read()
    f = L.eval('function(src, name) local f, e = load(src, "@" .. name, "t") if not f then error(e) end return f end')
    return f(src, str(path))
G.loadScript = load_script
# G.dir: set with the scratch card below

crsf_q, sport_q = [], []
def crsf_pop():
    if not crsf_q: return None
    cmd, data = crsf_q.pop(0)
    return cmd, L.table_from(data)
def sport_pop():
    if not sport_q: return None
    return tuple(sport_q.pop(0))
G.crossfireTelemetryPop = crsf_pop
G.crossfireTelemetryPush = lambda *a: True
G.sportTelemetryPop = sport_pop
G.sportTelemetryPush = lambda *a: True
G.getRSSI = lambda: 90
native = {}
def get_value(name):
    v = native.get(str(name))
    if isinstance(v, dict): return L.table_from(v)
    return v
G.getValue = get_value
G.getFieldInfo = lambda name: L.table_from({'name': str(name)}) if str(name) in native else None
G.model = L.table_from({'getSensor': lambda i: None,
                        'getModule': lambda i: L.table_from({'Type': 5 if int(i) == 1 else 0, 'protocol': 0, 'subType': 0}),
                        'getInfo': lambda *a: L.table_from({'name': 'Sim Plane'})})

# instruction counting, as EdgeTX's hook does
L.execute('''
_N = 0
local pack, unpack = table.pack, table.unpack
function _CALL(f, ...)
  _N = 0
  debug.sethook(function() _N = _N + 100 end, "", 100)
  local r = pack(pcall(f, ...))
  debug.sethook()
  if not r[1] then error(r[2], 0) end
  return unpack(r, 2, r.n)
end''')
CALL = G._CALL
if '--notable' in sys.argv:   # as EdgeTX on the TX12 MK2: no table library
    L.execute('table = nil')

# ------------------------------------------------------------------ vehicle
HOME = (43.49323, 142.88785)
st = dict(lat=HOME[0], lon=HOME[1], hlat=HOME[0], hlon=HOME[1], mode=5, armed=True, thr=55, sats=14, hdop=0.8,
          altmsl=160, volt=15.8, curr=12.3, mah=640, alt=120, vs=1.2, **{'as': 17.0}, gs=18.5, yaw=30, roll=18, pitch=4,
          wdir=270, wspd=4.2, wpn=0, wpd=0, wpb=0)
TEXTQ = []
def feed():
    if NATIVE:
        native.update({'GPS': {'lat': st['lat'] + 0.004, 'lon': st['lon'] + 0.003}, 'Alt': st['alt'], 'VSpd': st['vs'],
                       'GSpd': st['gs'] * 3.6, 'Hdg': st['yaw'], 'Sats': st['sats'], 'Roll': st['roll'], 'Ptch': -st['pitch'],
                       'RxBt': st['volt'], 'Curr': st['curr'], 'Capa': st['mah'], 'FM': 'ANGL', 'RQly': 96, '1RSS': -72})
        return
    native.update({'RQly': 96, '1RSS': -72} if not SPORT else {'RSSI': 88})
    pk = packets(st)
    if TEXTQ:   # status texts, one message per feed ride along as 0x5000 chunks
        pk += [(0x5000, c) for c in TEXTQ.pop(0)]
    if SPORT:
        for a, v in pk: sport_q.append([0x1B, 0x10, a, v])
    else:
        for i in range(0, len(pk), 6):
            grp = pk[i:i + 6]
            data = [0xF2, len(grp)]
            for a, v in grp:
                data += [a & 0xFF, a >> 8, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
            crsf_q.append((0x80, data))

# ------------------------------------------------------------------ run
script = load_script('/SCRIPTS/TELEMETRY/omnid.lua')()
worst = {'init': 0, 'run': 0, 'background': 0}
CALL(script['init']); worst['init'] = G._N
mem_init = L.eval('(collectgarbage("count"))')

def run(evt=0, frames=1):
    for _ in range(frames):
        t_ms[0] += 50
        if t_ms[0] % 250 == 0: feed()
        CALL(script['run'], evt); evt = 0
        worst['run'] = max(worst['run'], G._N)
def bg(n):
    for _ in range(n):
        t_ms[0] += 50
        if t_ms[0] % 250 == 0: feed()
        CALL(script['background']); worst['background'] = max(worst['background'], G._N)

bg(40)
run(frames=40)
words = ' '.join(t for t, x, y in texts)
save('main_%s.png' % tag)
s = G.OD_ENV  # adapter environment (not used directly)
if NATIVE:
    assert 'ANGL' in words, words
else:
    assert 'FBWA' in words and ('ALT 394FT' if IMPERIAL else 'ALT 120M') in words and 'ARM 3D14' in words, words
    assert '15.8V' in words and 'A' in words and 'GS ' in words and '030' in words, words
    assert any(w.endswith('MAH/MI' if IMPERIAL else 'WH/KM') and not w.startswith('--') for w in words.split()), words
print('main page OK:', words[:120])
# roll the other way and pitch down
st.update(roll=-35, pitch=-8)
run(frames=20); save('main_roll_%s.png' % tag)
# fly 1.5 km north-east of home: the home icon and the distance appear
st.update(roll=10, pitch=3, lat=HOME[0] + 0.0095, lon=HOME[1] + 0.013, yaw=200)
run(frames=40); save('main_away_%s.png' % tag)
words = ' '.join(t for t, x, y in texts)
assert 'H' in words.split() and ('0.9MI' if IMPERIAL else '1.5K') in words, words
# a short flight east of home, towards waypoint 3, with status texts
from simtelem import text_chunks
for m, sev in [('ArduPlane V4.7.2 (fb773567)', 6), ('PreArm: Throttle below failsafe', 2), ('Mission: 3 WP', 6),
               ('Takeoff complete at 120 m', 6)]:
    TEXTQ.append(text_chunks(m, sev))
st.update(wpn=3, wpd=800, wpb=90, roll=0, pitch=2, yaw=90)
for k in range(30):
    st.update(lat=HOME[0] + 0.0004 * k, lon=HOME[1] + 0.0002 * k * k / 10)
    run(frames=10)
run(G.EVT_VIRTUAL_ENTER, frames=5)
words = ' '.join(t for t, x, y in texts)
save('map_%s.png' % tag)
if not NATIVE:
    assert 'WP3' in words and 'H' in words.split(), words
print('map page OK:', words[:100])
if not NATIVE:   # messages: ArduPilot only
    run(G.EVT_VIRTUAL_ENTER, frames=5)
    words = ' '.join(t for t, x, y in texts)
    save('msg_%s.png' % tag)
    assert 'MESSAGES' in words and any('Takeoff' in t for t, x, y in texts), words
    assert any(t.startswith('! PreArm') for t, x, y in texts), words
    print('messages page OK:', words[:140])
    run(G.EVT_VIRTUAL_PREV, frames=1); save('msg_scrolled_%s.png' % tag)
    assert any('ArduPlane' in t for t, x, y in texts), 'wheel scrolls back to the first message'
if ALLPAGES:     # flight stats in the cycle, live
    run(G.EVT_VIRTUAL_ENTER, frames=5)
    words = ' '.join(t for t, x, y in texts)
    save('stats_%s.png' % tag)
    assert 'FLIGHT STATS' in words, words
    print('stats page OK:', words[:120])
run(G.EVT_VIRTUAL_ENTER, frames=5)
words = ' '.join(t for t, x, y in texts)
assert 'LINK CHECK' in words, words
if not NATIVE:
    assert 'ARDUPILOT' in words and 'YES' in words, words
save('link_%s.png' % tag)
print('link page OK:', words[:140])
if ALLPAGES:     # sensor check, page after the link page
    run(G.EVT_VIRTUAL_ENTER, frames=5)
    words = ' '.join(t for t, x, y in texts)
    save('sensors_%s.png' % tag)
    assert 'SENSORS' in words, words
    print('sensor page OK:', words[:160])
run(G.EVT_VIRTUAL_ENTER)
assert any(t.startswith('ALT') for t, x, y in texts), 'ENTER back to the main page'
# disarm: the summary opens by itself and the flight log is written (the native-sensor feed
# has no arm state to clear, so that run stops here)
if NATIVE:
    st.update(armed=True)
st.update(armed=False)
run(frames=60)
words = ' '.join(t for t, x, y in texts)
save('summary_%s.png' % tag)
if not NATIVE:
  assert 'FLIGHT SUMMARY' in words and 'DIST FLOWN' in words and 'MAX AS/GS' in words, words
  logs = os.listdir(os.path.join(SIMSD, 'SCRIPTS', 'OMNID', 'logs'))
  assert logs and logs[0].startswith('Sim Plane-2026-11-13'), logs
  print('summary page OK:', words[:120])
  print('log:', logs[0]); print(open(os.path.join(SIMSD, 'SCRIPTS', 'OMNID', 'logs', logs[0])).read()[:700])
  run(G.EVT_VIRTUAL_ENTER)
  assert any(t.startswith('ALT') for t, x, y in texts), 'ENTER leaves the summary for the start page'
L.execute('collectgarbage()'); mem_now = L.eval('(collectgarbage("count"))')
print('page cycle OK')
print('instructions per call: init %d, run max %d, background max %d' % (worst['init'], worst['run'], worst['background']))
print('Lua memory (64-bit sim, above the bare runtime %.1f KB): %.1f KB after init, %.1f KB after the page cycle' % (MEM_BASE, mem_init - MEM_BASE, mem_now - MEM_BASE))
print('Mono checks OK', tag)

# SYS > Tools > OmniDeck Setup, on the same screen stubs
G.loadScript = load_script
tool = load_script('/SCRIPTS/TOOLS/OmniDeck Setup.lua')()
tool['init']()
tool['run'](0); save('setup_%s.png' % tag)
for e in (G.EVT_VIRTUAL_NEXT, G.EVT_VIRTUAL_NEXT, G.EVT_VIRTUAL_ENTER, G.EVT_VIRTUAL_NEXT):
    tool['run'](e)
save('setup_edit_%s.png' % tag)
words = ' '.join(t for t, x, y in texts)
assert 'OMNIDECK SETUP' in words and ('SPEED KM/H' if IMPERIAL else 'SPEED M/S') in words, words
cfgf = os.path.join(SIMSD, 'SCRIPTS', 'OMNID', 'Sim_Plane.cfg')
assert ('spdUnit=0' if IMPERIAL else 'spdUnit=1') in open(cfgf).read()
print('setup tool OK:', words[:120])
