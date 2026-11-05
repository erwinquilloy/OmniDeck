"""
Off-radio test harness for the OmniDeck Ethos widget.

Runs scripts/omnideck/main.lua in Lua 5.4 (lupa) against a stubbed Ethos API,
feeds ArduPilot passthrough packets encoded exactly like
AP_Frsky_SPort_Passthrough.cpp (as CRSF 0x80/0xF2 frames or S.Port frames),
checks the decoded state and renders each page to PNG.

  python tools/sim.py [outdir] [--sport] [--res 800x480]
"""
import math, os, sys
from lupa import lua54
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'scripts', 'omnideck')
args = [a for a in sys.argv[1:] if not a.startswith('--')]
OUT = os.path.abspath(args[0]) if args else os.path.join(HERE, 'out')
SPORT = '--sport' in sys.argv
NATIVE = '--native' in sys.argv
TILES = '--tiles' in sys.argv
INAV = '--inav' in sys.argv
# --slowmsp: every MSP reply reaches the radio 1.3 s late, past the client's 1 s timeout, so the
# repeated request is answered twice (TBS Crossfire, TX16S, 2026-11-05: 6 WPs showed as 1 and 4)
MSP_DELAY = 1.3 if '--slowmsp' in sys.argv else 0.0
if INAV: NATIVE = True
RES = '800x480'
for i, a in enumerate(sys.argv):
    if a == '--res':
        RES = sys.argv[i + 1]
W, H = map(int, RES.split('x'))
os.makedirs(OUT, exist_ok=True)

# ------------------------------------------------------------------ AP encoders
from simtelem import prep_number, latlng, dist_brg, project, packets, text_chunks, R

# ------------------------------------------------------------------ Ethos stubs
FONT_PX = {'FONT_XXS': 10, 'FONT_XS': 12, 'FONT_S': 15, 'FONT_STD': 18, 'FONT_L': 24, 'FONT_XL': 32}
if W <= 480:
    FONT_PX = {'FONT_XXS': 9, 'FONT_XS': 11, 'FONT_S': 13, 'FONT_STD': 15, 'FONT_L': 20, 'FONT_XL': 28}
fonts = {k: ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf' if k != 'FONT_XXS' else 'C:/Windows/Fonts/arial.ttf', v)
         for k, v in FONT_PX.items()}

class Canvas:
    def __init__(self):
        self.img = Image.new('RGB', (W, H), (255, 0, 255))
        self.d = ImageDraw.Draw(self.img)
        self.col = (255, 255, 255)
        self.font = fonts['FONT_STD']
        self.clip = (0, 0, W, H)
        self.ops = 0
    def _clipped(self, fn):
        # draw on a layer, paste through the clip mask
        layer = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        fn(ImageDraw.Draw(layer))
        x, y, w, h = self.clip
        mask = Image.new('L', (W, H), 0)
        ImageDraw.Draw(mask).rectangle([x, y, x + w - 1, y + h - 1], fill=255)
        alpha = Image.composite(layer.getchannel('A'), Image.new('L', (W, H), 0), mask)
        self.img.paste(layer.convert('RGB'), (0, 0), alpha)
        self.ops += 1

cv = Canvas()
L = lua54.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
sim_time = [0.0]
L.execute('os.clock = function() return _SIMT() end')
G._SIMT = lambda: sim_time[0]

def rgb(r, g, b): return (int(r) << 16) | (int(g) << 8) | int(b)
def unrgb(c):
    c = int(c); return ((c >> 16) & 255, (c >> 8) & 255, c & 255)

def font_of(f): return fonts.get(FONTS_BY_ID.get(int(f)), fonts['FONT_STD'])
FONTS_BY_ID = {}
consts = {'LEFT': 0, 'CENTERED': 1, 'RIGHT': 2, 'EVT_TOUCH': 100, 'EVT_KEY': 101, 'TOUCH_END': 2,
          'TOUCH_START': 1, 'TOUCH_MOVE': 3, 'KEY_ENTER_BREAK': 32, 'KEY_ROTARY_LEFT': 4100, 'KEY_ROTARY_RIGHT': 4101,
          'OPTION_LATITUDE': 1, 'OPTION_LONGITUDE': 2, 'CATEGORY_SYSTEM': 400, 'MAIN_VOLTAGE': 401,
          'CATEGORY_TELEMETRY_SENSOR': 500, 'CATEGORY_SYSTEM_EVENT': 600, 'TELEMETRY_ACTIVE': 601}
for i, k in enumerate(FONT_PX): consts[k] = 200 + i; FONTS_BY_ID[200 + i] = k
for i, k in enumerate(['UNIT_KILOMETER_PER_HOUR', 'UNIT_KNOT', 'UNIT_MILE_PER_HOUR', 'UNIT_FOOT_PER_SECOND',
                       'UNIT_CENTIMETER_PER_SECOND', 'UNIT_METER_PER_MINUTE', 'UNIT_FOOT_PER_MINUTE', 'UNIT_FOOT',
                       'UNIT_CENTIMETER', 'UNIT_KILOMETER', 'UNIT_RADIAN']):
    consts[k] = 300 + i
for k, v in consts.items(): G[k] = v

def set_color(c): cv.col = unrgb(c)
def set_font(f): cv.font = font_of(f)
def text_size(t):
    b = cv.font.getbbox(str(t))
    return b[2] - b[0], cv.font.size + 2
drawn = []        # (text or 'rect', colour, x), cleared by the checks that read it
def draw_text(x, y, t, flags=0):
    t = str(t); tw, _ = text_size(t)
    drawn.append((t, cv.col, x))
    flags = int(flags or 0)
    if flags == 1: x = x - tw / 2
    elif flags == 2: x = x - tw
    col, font = cv.col, cv.font
    cv._clipped(lambda d: d.text((x, y), t, fill=col + (255,), font=font))
fills = []        # (colour, x, width) of filled rectangles
def frect(x, y, w, h):
    col = cv.col
    drawn.append(('rect', col, x))
    if w > 0: fills.append((col, x, w))
    if w <= 0 or h <= 0: return
    cv._clipped(lambda d: d.rectangle([x, y, x + w - 1, y + h - 1], fill=col + (255,)))
def rect(x, y, w, h):
    col = cv.col
    cv._clipped(lambda d: d.rectangle([x, y, x + w - 1, y + h - 1], outline=col + (255,)))
def line(x1, y1, x2, y2):
    col = cv.col
    cv._clipped(lambda d: d.line([x1, y1, x2, y2], fill=col + (255,)))
tris = []         # (colour, (x1, y1, x2, y2, x3, y3))
def tri(x1, y1, x2, y2, x3, y3):
    col = cv.col
    tris.append((col, (x1, y1, x2, y2, x3, y3)))
    cv._clipped(lambda d: d.polygon([(x1, y1), (x2, y2), (x3, y3)], fill=col + (255,)))
def circle(x, y, r):
    col = cv.col
    cv._clipped(lambda d: d.ellipse([x - r, y - r, x + r, y + r], outline=col + (255,)))
def fcircle(x, y, r):
    col = cv.col
    cv._clipped(lambda d: d.ellipse([x - r, y - r, x + r, y + r], fill=col + (255,)))
def clipping(x, y, w, h): cv.clip = (x, y, w, h)

SD = os.path.join(OUT, 'sd')
bitmaps = {}
def sd_path(p): return os.path.join(SD, *[x for x in str(p).split('/') if x])
def load_bitmap(p):
    fp = sd_path(p)
    if not os.path.isfile(fp): raise Exception('no file ' + str(p))
    img = Image.open(fp).convert('RGB')
    bitmaps[id(img)] = img
    stats['loads'] += 1
    return L.table_from({'_id': id(img), 'width': lambda self=None: img.width, 'height': lambda self=None: img.height})
def draw_bitmap(x, y, bmp):
    img = bitmaps[bmp['_id']]
    def f(d, img=img, x=x, y=y):
        d._image.paste(img.convert('RGBA'), (int(x), int(y)))
    cv._clipped(f)
    stats['draws'] += 1
stats = {'loads': 0, 'draws': 0}
def list_files(p):
    fp = sd_path(p)
    if not os.path.isdir(fp): return L.table_from([])
    return L.table_from(sorted(os.listdir(fp)))
# Ethos reads pixel coordinates with luaL_checkinteger: 3.0 is fine, 3.5 / NaN / inf raise
# "number has no integer representation" and the rest of paint() is skipped.
def strict(name, fn):
    def f(*a):
        for v in a:
            if isinstance(v, float) and not (math.isfinite(v) and v == int(v)):
                raise Exception('%s: number has no integer representation (%r)' % (name, v))
        return fn(*a)
    return f
frect, rect, line, tri, circle, fcircle, clipping, draw_bitmap = [strict(n, fn) for n, fn in (
    ('drawFilledRectangle', frect), ('drawRectangle', rect), ('drawLine', line), ('drawFilledTriangle', tri),
    ('drawCircle', circle), ('drawFilledCircle', fcircle), ('setClipping', clipping), ('drawBitmap', draw_bitmap))]
lcd = L.table_from({'loadBitmap': load_bitmap, 'drawBitmap': draw_bitmap,
    'RGB': rgb, 'color': set_color, 'font': set_font, 'getTextSize': text_size, 'drawText': draw_text,
    'drawFilledRectangle': frect, 'drawRectangle': rect, 'drawLine': line, 'drawFilledTriangle': tri,
    'drawCircle': circle, 'drawFilledCircle': fcircle, 'setClipping': clipping,
    'getWindowSize': lambda: (W, H), 'invalidate': lambda: None, 'isVisible': lambda: True,
})
G.lcd = lcd

# telemetry queues
crsf_q, sport_q = [], []
msp_reply_q = []          # chunks waiting for the radio (CRSF: data lists, S.Port: (appId, value))
msp_log = {'req': [], 'crc_bad': 0, 'dropped': 0}
INAV_WPS = []
def inav_reply(cmd, payload):
    if cmd == 2: return [ord(c) for c in 'INAV']
    if cmd == 20: return [0, 120, 1, len(INAV_WPS)]
    if cmd == 118:
        i = payload[0]
        if not 1 <= i <= len(INAV_WPS): return None
        a, la, lo, alt, p1, fl = INAV_WPS[i - 1]
        b = [i, a]
        for v in (int(round(la * 1e7)), int(round(lo * 1e7)), int(alt * 100)):
            b += list((v & 0xFFFFFFFF).to_bytes(4, 'little'))
        for v in (p1, 0, 0): b += list((v & 0xFFFF).to_bytes(2, 'little'))
        return b + [fl]
    if cmd == 121: return [3, 5, 1, 2, 0, 0, 0]
    return None
rx_req = {'buf': None}
reply_seq = [0]
drop_once = {'done': False}
def fc_receive(chunk, transport):
    st = chunk[0]
    if st & 0x10:
        rx_req['buf'] = list(chunk[1:])
    elif rx_req['buf'] is not None:
        rx_req['buf'] += list(chunk[1:])
    b = rx_req['buf']
    if b is None or len(b) < 2: return
    size, cmd = b[0], b[1]
    need = 2 + size + (1 if transport == 'sport' else 0)
    if len(b) < need: return
    payload = b[2:2 + size]
    if transport == 'sport':
        crc = 0
        for x in b[:2 + size]: crc ^= x
        if crc != b[2 + size]: msp_log['crc_bad'] += 1
    rx_req['buf'] = None
    msp_log['req'].append(cmd)
    out = inav_reply(cmd, payload)
    if out is None: return
    if cmd == 118 and payload[0] == 2 and not drop_once['done']:
        drop_once['done'] = True; msp_log['dropped'] += 1; return     # lose one reply: client must retry
    body = [len(out), cmd] + out
    if transport == 'sport':
        crc = 0
        for x in body: crc ^= x
        body.append(crc)
    per = 5 if transport == 'sport' else 57
    first = True
    for i in range(0, len(body), per):
        c = [0x20 | (0x10 if first else 0) | reply_seq[0]] + body[i:i + per]
        reply_seq[0] = (reply_seq[0] + 1) & 0x0F
        first = False
        if transport == 'sport':
            c += [0] * (6 - len(c))
            item = (c[0] | (c[1] << 8), c[2] | (c[3] << 8) | (c[4] << 16) | (c[5] << 24))
            msp_reply_q.append((sim_time[0] + MSP_DELAY, item))
            if i == 0: msp_reply_q.append((sim_time[0] + MSP_DELAY, item))      # receivers can repeat a frame
        else:
            msp_reply_q.append((sim_time[0] + MSP_DELAY, [0xEA, 0xC8] + c))
def crsf_push(cmd, data):
    data = [data[i] for i in range(1, len(data) + 1)]
    if cmd == 0x7A and data[:2] == [0xC8, 0xEA]: fc_receive(data[2:], 'crsf')
    return True
def sport_push(t):
    a, v = int(t['appId']), int(t['value'])
    fc_receive([a & 0xFF, a >> 8, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF], 'sport')
    return True
def pop_msp_crsf():
    if SPORT or not msp_reply_q or msp_reply_q[0][0] > sim_time[0]: return None
    return L.table_from(msp_reply_q.pop(0)[1])
def pop_msp_sport():
    if not SPORT or not msp_reply_q or msp_reply_q[0][0] > sim_time[0]: return None
    return L.table_from(list(msp_reply_q.pop(0)[1]))
G._CRSFPUSH, G._SPORTPUSH, G._POPMSPCRSF, G._POPMSPSPORT = crsf_push, sport_push, pop_msp_crsf, pop_msp_sport
L.execute('''
function _mkcrsf(q)
  return { getSensor = function() return {
      pushFrame = function(self, cmd, data) return _CRSFPUSH(cmd, data) end,
      popFrame = function(self, lo, hi)
        if lo == 0x7B then
          local f = _POPMSPCRSF(); if f == nil then return nil end
          local t = {} for i = 1, #f do t[i] = f[i] end
          return 0x7B, t
        end
        local f = _POPCRSF(); if f == nil then return nil end
        local t = {} for i = 1, #f do t[i] = f[i] end
        return 0x80, t end } end }
end
function _mksport()
  return { getSensor = function(arg)
      if arg and arg.module == 1 then return nil end
      if arg and arg.primId == 0x32 then
        return { pushFrame = function(self, t) return _SPORTPUSH(t) end,
          popFrame = function(self)
            local f = _POPMSPSPORT(); if f == nil then return nil end
            return { primId = function() return 0x32 end, appId = function() return f[1] end, value = function() return f[2] end }
          end }
      end
      return { popFrame = function(self)
        local f = _POPSPORT(); if f == nil then return nil end
        return { primId = function() return 0x10 end, appId = function() return f[1] end, value = function() return f[2] end }
      end } end }
end
''')
def pop_crsf():
    if not crsf_q: return None
    return L.table_from(crsf_q.pop(0))
def pop_sport():
    if not sport_q: return None
    return L.table_from(sport_q.pop(0))
G._POPCRSF, G._POPSPORT = pop_crsf, pop_sport
G.crsf = L.eval('_mkcrsf')(None)
G.sport = L.eval('_mksport')()
native_vals = {}
SPORT_APPIDS = {0x0100: 'Altitude', 0x0830: 'GPS speed', 0x0840: 'Yaw', 0x0480: 'GPS satellites',
                0x0210: 'Rx Batt', 0xF101: 'RSSI', 0x0A00: 'Airspeed'}
LINK_SENSORS = ('Rx Quality', 'Rx RSSI1', 'Flight mode')    # CRSF; these exist whatever the flight stack is
TX_VOLTS = [8.1]
# OD_R9=1 (with --native --sport): INAV over an R9 on Ethos. Ethos hasn't discovered INAV's mode,
# roll, pitch and satellites sensors until the widget creates them (model.createSensor), and
# the model still has a CRSF link sensor from an earlier TBS session, reading 0.
R9 = bool(os.environ.get('OD_R9')) and NATIVE and SPORT
R9_CREATED = set()
R9_NEEDS = {0x0470, 0x0440, 0x0430, 0x0480}
class SimSensor:
    pass
def create_sensor(opts):
    rec = {}
    def setter(field):
        def f(self_, v=None):
            rec[field] = v
            if field == 'appId': R9_CREATED.add(int(v))
        return f
    return L.table_from({k: setter(k) for k in ('name', 'unit', 'decimals', 'protocolDecimals', 'physId', 'band',
                                                  'minimum', 'maximum', 'appId', 'subId')})
# RF modules: internal off, external on (switched off in the module-off test)
MODULE_ON = {0: False, 1: True}
def get_module(i):
    i = int(i)
    return L.table_from({'enable': lambda self=None: MODULE_ON.get(i, False)})
SIM_MODEL = 'R9 INAV' if R9 else 'Talon Pro'
G.model = L.table_from({'getModule': get_module, 'name': lambda *a: SIM_MODEL})
if R9:
    G.model = L.table_from({'getModule': get_module, 'createSensor': create_sensor, 'name': lambda *a: SIM_MODEL})
    G.SENSOR_TYPE_DIY, G.UNIT_DEGREE, G.UNIT_RAW = 1, 20, 0
# the model's discovered sensors, in the order Ethos lists them (Model > Telemetry)
NAMEBUG = bool(os.environ.get('OD_NAMEBUG'))    # by name, getSource hands back the GPS (X18 + TBS)
def telem_members():
    if SPORT: return ['GPS'] if 'GPS1' in native_vals else []
    names = [k for k in native_vals if not k.startswith('GPS') or k in ('GPS alt', 'GPS speed', 'GPS satellites', 'GPS Satellites')]
    if not NATIVE: names = [k for k in names if k in LINK_SENSORS]
    if 'GPS1' in native_vals: names.insert(0, 'GPS')
    return names
def mksrc(key):
    return L.eval("""function(k, unit) return { value = function(self) return _NV(k) end, unit = function(self) return unit end,
        name = function(self) return k end, stringValue = function(self) return tostring(_NV(k)) end } end""")(key, native_units.get(key))
def get_source(q):
    if not isinstance(q, str) and 'category' in q and int(q['category']) == 500 and 'member' in q:   # telemetry sensor by member
        names = telem_members(); m = int(q['member'])
        if m >= len(names): return None
        nm = names[m]
        if nm == 'GPS':
            opt = q['options'] if 'options' in q else None
            if opt is None: return L.eval('function() return { value = function() return _NV("GPS1") + _NV("GPS2") end, unit = function() return nil end, name = function() return "GPS" end } end')()
            nm = 'GPS' + str(opt)
        if nm not in native_vals: return None
        return mksrc(nm) if nm[:3] != 'GPS' or nm[3:] not in ('1', '2') else L.eval(
            'function(k) return { value = function() return _NV(k) end, unit = function() return nil end, name = function() return "GPS" end } end')(nm)
    if NAMEBUG and NATIVE and isinstance(q, str) and 'GPS1' in native_vals:
        return L.eval('function() return { value = function() return _NV("GPS1") + _NV("GPS2") end, unit = function() return nil end, name = function() return "GPS" end } end')()
    if not isinstance(q, str) and 'category' in q and int(q['category']) == 600:   # Ethos's telemetry-active flag
        return L.eval('function() return { state = function() return _TLMON() end, value = function() return _TLMON() and 1 or 0 end, name = function() return "Telemetry active" end } end')()
    if not isinstance(q, str) and 'category' in q and int(q['category']) == 400:   # the radio's own battery
        return L.eval('function() return { value = function() return _TXV() end, unit = function() return nil end, name = function() return "Main voltage" end } end')()
    if not NATIVE:
        if isinstance(q, str):
            if SPORT or q not in LINK_SENSORS: return None
        elif not (SPORT and 'appId' in q and int(q['appId']) == 0xF101):
            return None
    if not isinstance(q, str) and 'crsfId' in q:      # CRSF link statistics only exist on CRSF
        if int(q['crsfId']) != 0x14: return None
        if R9: return L.eval('function() return { value = function() return 0 end, unit = function() return nil end, name = function() return "Rx Quality" end } end')()
        return None if SPORT else L.eval('function() return { value = function() return 96 end, unit = function() return nil end, name = function() return "Rx Quality" end } end')()
    if SPORT and isinstance(q, str): return None
    if SPORT and not isinstance(q, str) and 'appId' in q:
        aid = int(q['appId'])
        if R9 and aid in R9_NEEDS and aid not in R9_CREATED: return None
        if R9 and aid == 0x0440: return L.eval('function() return { value = function() return _NV("Roll") end, unit = function() return 20 end, name = function() return "Roll" end } end')()
        if R9 and aid == 0x0430: return L.eval('function() return { value = function() return _NV("Pitch") end, unit = function() return 20 end, name = function() return "Pitch" end } end')()
        if aid == 0x0470:   # INAV mode digits: E=4 armed, D=1 angle
            return L.eval('function() return { value = function() return _NV("SportMode") end, unit = function() return nil end, name = function() return "Tmp1" end } end')()
        key = SPORT_APPIDS.get(aid)
        if key is None: return None
    elif isinstance(q, str): key = q
    else:
        nm = q['name'] if 'name' in q else None
        key = nm + str(q['options']) if nm == 'GPS' else None
    if key not in native_vals: return None
    return L.eval("""function(k, unit) return { value = function(self) return _NV(k) end, unit = function(self) return unit end,
        name = function(self) return k end, physId = function(self) return 0x1B end, band = function(self) return 0 end } end""")(key, native_units.get(key))
native_units = {}
G._NV = lambda k: native_vals.get(k)
G._TXV = lambda: TX_VOLTS[0]
TLM_ON = [True]
G._TLMON = lambda: TLM_ON[0]
G.system = L.table_from({'getSource': get_source, 'registerWidget': None, 'playFile': lambda f: played.append(os.path.basename(f)[:-4]), 'listFiles': list_files})
# SD-card paths ("/scripts/...", "/bitmaps/...") open inside the fake card
G._SDROOT = SD.replace(chr(92), '/')
L.execute('local o = io.open; io.open = function(p, m) if p:sub(1, 1) == "/" then p = _SDROOT .. p end return o(p, m) end')
# Ethos widget storage is positional: keys are ignored, values come back in write order.
# A nil write is assumed to store nothing (the worst case: every later value shifts).
slots, wr_log, rd = [], [], [0]
def st_write(k, v):
    wr_log.append((str(k), v))
    if v is not None: slots.append(v)
def st_read(k):
    i = rd[0]; rd[0] += 1
    return slots[i] if i < len(slots) else None
store = {}
played = []
os.makedirs(os.path.join(SD, 'scripts', 'omnideck', 'audio', 'Aria'), exist_ok=True)
G.storage = L.table_from({'read': st_read, 'write': st_write})
def do_write():
    del slots[:]; del wr_log[:]
    wt['write'](widget)
def do_read(w=None):
    rd[0] = 0
    wt['read'](w if w is not None else widget)
def saved(key): return dict(wr_log).get(key)
registered = {}
def register(t): registered['w'] = t
G.system.registerWidget = register

feed_n = [0]
def feed(pkts):
    # a live link always moves a little: RSSI wobbles by 1 dB, as on a real radio
    feed_n[0] += 1
    TLM_ON[0] = True                  # frames arriving: Ethos says telemetry is active
    wob = feed_n[0] % 2
    native_vals.update({'Rx Quality': 96, 'Rx RSSI1': -72 - wob, 'RSSI': 88 - wob})
    if not NATIVE and not SPORT:
        native_vals['Flight mode'] = 'FBWA' + ('' if st['armed'] else '*')   # ArduPilot's own CRSF mode text
    if NATIVE:
        native_vals.update({'GPS1': st['lat'], 'GPS2': st['lon'], 'Altitude': st['alt'], 'VSpeed': st['vs'],
            'GPS speed': st['gs'] * 3.6, 'Yaw': st['yaw'], 'GPS satellites': st['sats'], 'Roll': st['roll'],
            'Pitch': -st['pitch'], 'Rx Batt': st['volt'], 'Rx Current': st['curr'], 'Rx Cons': st['mah'],
            'Flight mode': st.get('fm') or ('ANGL' if st['armed'] else 'OK'), 'SportMode': st.get('sm') or (14 if st['armed'] else 1)})
        native_units['GPS speed'] = consts['UNIT_KILOMETER_PER_HOUR']
        if st.get('pitot'):
            native_vals['Airspeed'] = st['as'] * 3.6
            native_units['Airspeed'] = consts['UNIT_KILOMETER_PER_HOUR']
        if SPORT:
            # INAV/BF over S.Port send their position as raw FrSky GPS frames, app ID 0x0800,
            # the same ID as ArduPilot passthrough: the radio's S.Port reader sees them too
            sport_q.append([0x0800, latlng(st['lat'], False)])
            sport_q.append([0x0800, latlng(st['lon'], True)])
        return
    if SPORT:
        for a, v in pkts: sport_q.append([a, v])
    else:
        # ArduPilot packs up to 9 packets into one 0xF2 frame
        for i in range(0, len(pkts), 6):
            grp = pkts[i:i + 6]
            data = [0xF2, len(grp)]
            for a, v in grp:
                data += [a & 0xFF, a >> 8, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
            crsf_q.append(data)

# ------------------------------------------------------------------ run
# Ethos's file:read() rejects "a" / "*a" ("bad argument #1 to 'read' (invalid format)",
# X18 tester 2026-11-03): the sim's files do the same
L.execute(r"""
local rawopen = io.open
io.open = function(p, m)
  local f, e = rawopen(p, m)
  if not f then return f, e end
  return setmetatable({}, { __index = function(_, k)
    if k == "read" then
      return function(_, fmt, ...)
        if fmt == "a" or fmt == "*a" then error("bad argument #1 to 'read' (invalid format)", 2) end
        return f:read(fmt, ...)
      end
    end
    local v = f[k]
    if type(v) == "function" then return function(_, ...) return v(f, ...) end end
    return v
  end })
end
""")
os.chdir(SRC)
mod = L.execute(open('main.lua', encoding='utf8').read())
mod['init']()
wt = registered['w']
widget = wt['create']()
do_read()
if NATIVE: widget.batCap = 5000           # INAV and Betaflight send no capacity

HOME = (43.49323, 142.88785)
st = dict(lat=HOME[0], lon=HOME[1], hlat=HOME[0], hlon=HOME[1], mode=5, armed=True, thr=55, sats=14, hdop=0.8,
          altmsl=160, volt=15.8, curr=12.3, mah=0, alt=0, vs=0, **{'as': 17.0}, gs=18.5, yaw=0, roll=0, pitch=0,
          wdir=270, wspd=4.2, wpn=0, wpd=0, wpb=0)

PAINT = [False]
def step(dt=0.2):
    global cv
    sim_time[0] += dt
    feed(packets(st))
    for _ in range(4):
        wt['wakeup'](widget)
        if PAINT[0]:
            cv = Canvas(); wt['paint'](widget)   # the radio paints between wakeups

# ------------------------------------------------------------------ fake SD: tiles + mission
WPS = [project(HOME[0], HOME[1], 700, 40), project(HOME[0], HOME[1], 1900, 55), project(HOME[0], HOME[1], 1600, 95)]
def merc_px(lat, lon, z):
    size = (2 ** z) * 100
    sl = math.sin(math.radians(lat))
    return (lon + 180) / 360 * size, (0.5 - math.log((1 + sl) / (1 - sl)) / (4 * math.pi)) * size
if TILES:
    import shutil, random
    shutil.rmtree(SD, ignore_errors=True)
    fnt = ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 11)
    n = 0
    for z in range(14, 18):
        la0, lo0 = project(HOME[0], HOME[1], 4000, 225)
        la1, lo1 = project(HOME[0], HOME[1], 4000, 45)
        xa, ya = merc_px(la1, lo0, z); xb, yb = merc_px(la0, lo1, z)
        hx, hy = merc_px(HOME[0], HOME[1], z)
        wpx = [merc_px(a, b, z) for a, b in WPS]
        for tx in range(int(xa // 100), int(xb // 100) + 1):
            for ty in range(int(ya // 100), int(yb // 100) + 1):
                rnd = random.Random(z * 1000003 + tx * 7919 + ty)
                img = Image.new('RGB', (100, 100), (60 + rnd.randint(0, 25), 85 + rnd.randint(0, 25), 50 + rnd.randint(0, 20)))
                d = ImageDraw.Draw(img)
                d.rectangle([0, 0, 99, 99], outline=(30, 45, 25))
                d.text((3, 2), '%d/%d/%d' % (z, tx, ty), fill=(200, 220, 190), font=fnt)
                # crosses exactly where home and the waypoints are, to check alignment
                for (px, py), col in [((hx, hy), (255, 0, 0))] + [(p, (255, 255, 0)) for p in wpx]:
                    lx, ly = px - tx * 100, py - ty * 100
                    if -12 < lx < 112 and -12 < ly < 112:
                        d.line([lx - 10, ly, lx + 10, ly], fill=col, width=2); d.line([lx, ly - 10, lx, ly + 10], fill=col, width=2)
                path = os.path.join(SD, 'bitmaps', 'ethosmaps', 'maps', 'GOOGLE', 'Satellite', str(z), str(tx))
                os.makedirs(path, exist_ok=True)
                img.save(os.path.join(path, '%d.jpg' % ty), quality=85)
                n += 1
    md = os.path.join(SD, 'scripts', 'omnideck', 'missions'); os.makedirs(md, exist_ok=True)
    with open(os.path.join(md, 'test.waypoints'), 'w') as f:
        T_ = chr(9); NL = chr(10)
        f.write('QGC WPL 110' + NL)
        f.write(T_.join(['0', '1', '0', '16', '0', '0', '0', '0', '%.7f' % HOME[0], '%.7f' % HOME[1], '160', '1']) + NL)
        for i, (a, b) in enumerate(WPS):
            f.write(T_.join([str(i + 1), '0', '3', '16', '0', '0', '0', '0', '%.7f' % a, '%.7f' % b, '120', '1']) + NL)
        la, lo = project(HOME[0], HOME[1], 150, 200)
        f.write(T_.join(['4', '0', '3', '21', '0', '0', '0', '0', '%.7f' % la, '%.7f' % lo, '0', '1']) + NL)
    print('fake SD: %d tiles' % n)

if INAV:
    INAV_WPS = [(1, *project(HOME[0], HOME[1], 600, 30), 80, 0, 0), (1, *project(HOME[0], HOME[1], 1500, 50), 100, 0, 0),
                (3, *project(HOME[0], HOME[1], 1800, 80), 100, 30, 0), (1, *project(HOME[0], HOME[1], 900, 120), 90, 0, 0),
                (8, *project(HOME[0], HOME[1], 100, 200), 0, 0, 0xA5)]
st['armed'] = False
for _ in range(10): step(0.5)
st['armed'] = True
# fly a path: out to the NE, a wide turn, then back towards home
lat, lon = HOME
yaw = 45.0
for i in range(900):
    t = i * 0.5
    if 300 < i < 520: yaw = (yaw + 1.1) % 360
    lat, lon = project(lat, lon, 18.5 * 0.5, yaw)
    wi = min(2, i // 300)
    wd, wb = dist_brg(lat, lon, WPS[wi][0], WPS[wi][1])
    st.update(wpn=wi + 1, wpd=round(wd), wpb=wb)
    st.update(lat=lat, lon=lon, yaw=yaw, alt=min(120, i * 0.8), roll=25 if 300 < i < 520 else 0,
              pitch=4, vs=1.6 if i < 150 else 0, mah=i * 3.2, thr=55)
    step(0.5)

st.update(roll=28, pitch=6.4, vs=2.3)
# start-up: the ready clip plays first and once (as Yaapu's does), not tied to telemetry
for _ in range(6):
    sim_time[0] += 0.2
    wt['wakeup'](widget)
assert played[:1] == ['omniready'] and played.count('omniready') == 1, 'ready clip first, once: %s' % played
for _ in range(3): step(0.2)
for chunk in ([] if NATIVE else text_chunks("Mission: 3 WP", 6) + text_chunks("Low battery! Check RTL", 4)):
    sport_q.append([0x5000, chunk]) if SPORT else crsf_q.append([0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24])
step(0.2)

getS = L.execute('''
return function()
  local p = package.loaded
  for i = 1, 200 do
    local n, v = debug.getupvalue(_W.wakeup, i)
    if n == nil then break end
    if n == "T" then return v.s end
  end
end''')
G._W = wt
S = getS()
if R9:
    assert R9_CREATED == R9_NEEDS, 'R9: the missing INAV sensors are created %s' % sorted(hex(a) for a in R9_CREATED)
    print('R9: created', sorted(hex(a) for a in R9_CREATED))
d, brg = dist_brg(st['lat'], st['lon'], HOME[0], HOME[1])
print('state: fc=%s link=%s mode=%s armed=%s' % (S.fc, S.link, S.mode, S.armed))
print('  lat %.6f lon %.6f (truth %.6f %.6f)' % (S.lat, S.lon, st['lat'], st['lon']))
print('  home %.6f %.6f (truth %.6f %.6f) err %.1f m' % (S.homeLat, S.homeLon, HOME[0], HOME[1],
      dist_brg(S.homeLat, S.homeLon, HOME[0], HOME[1])[0]))
print('  homeDist %s (truth %.0f) homeBrg %s (truth %.0f)' % (S.homeDist, d, S.homeBrg, brg))
print('  alt %s vspd %s gspd %s aspd %s yaw %.1f (truth %.1f) roll %.1f pitch %.1f' % (S.alt, S.vspd, S.gspd, S.aspd, S.yaw, st['yaw'], S.roll, S.pitch))
print('  volt %s curr %s mah %s cap %s thr %s sats %s fix %s hdop %s altMSL %s' % (S.volt, S.curr, S.mah, S.cap, S.thr, S.sats, S.fix, S.hdop, S.altMSL))
print('  wind %s@%s  wp %s %s m brg %s' % (S.windSpd, S.windDir, S.wpNum, S.wpDist, S.wpBrg))
msgs = [(S.msgs[i].text, S.msgs[i].sev) for i in range(1, len(S.msgs) + 1)]
print('  msgs', msgs)
print('  zoom level', widget.level)

def render(name, page, **kw):
    global cv
    for k, v in kw.items(): widget[k] = v
    widget.page = page
    cv = Canvas()
    wt['paint'](widget)
    path = os.path.join(OUT, name)
    cv.img.save(path)
    print('wrote', path, 'ops', cv.ops)

tag = ('native' if NATIVE else ('sport' if SPORT else 'crsf')) + '_' + RES
if INAV:
    getU = L.execute('''return function(W, name) for i = 1, 300 do local n, v = debug.getupvalue(W.wakeup, i)
        if n == nil then break end if n == name then return v end end end''')
    MSPC = getU(wt, 'MSPC'); MIm = getU(wt, 'MI')
    print('  msp state', MSPC.state(), 'variant', MSPC.variant(), 'count', MSPC.count(), 'active', MSPC.active())
    print('  requests', msp_log['req'][:12], '... total', len(msp_log['req']), 'crc_bad', msp_log['crc_bad'], 'dropped', msp_log['dropped'])
    wl = MSPC.waypoints()
    assert len(wl) == len(INAV_WPS), len(wl)
    for k in range(1, len(wl) + 1):
        w_ = wl[k]; t = INAV_WPS[k - 1]
        e = dist_brg(w_.lat, w_.lon, t[1], t[2])[0]
        assert e < 0.05 and w_.action == t[0] and abs(w_.alt - t[3]) < 0.01 and w_.p1 == t[4], (k, e)
    cur, kind = MIm.current()
    print('  mission source', kind, 'points', len(cur), 'labels', [cur[k].label for k in range(1, len(cur) + 1)])
    assert kind == 'inav' and MSPC.active() == 2
    tag = 'inav_' + ('sport' if SPORT else 'crsf') + '_' + RES
    render('map_%s.png' % tag, 2)
    # a mission uploaded after the download (TX16S + Crossfire, 2026-11-05: 2 of 5 WPs shown):
    # armed, nothing is re-checked; disarmed, the count is re-checked every 10 s and the
    # changed mission downloaded again
    five = list(INAV_WPS)
    INAV_WPS[:] = five[:2] + [(8, *project(HOME[0], HOME[1], 300, 250), 0, 0, 0xA5)]
    for _ in range(30): step(0.5)            # 15 s armed
    assert len(MSPC.waypoints()) == 5, 'armed: the mission is not re-checked (%d)' % len(MSPC.waypoints())
    st['armed'] = False
    for _ in range(60): step(0.5)            # 30 s disarmed (a re-check every 10 s, then the download)
    cur, kind = MIm.current()
    assert len(MSPC.waypoints()) == 3 and kind == 'inav' and len(cur) == 3, \
        'disarmed: changed mission downloaded again (%d)' % len(MSPC.waypoints())
    INAV_WPS[:] = five
    for _ in range(60): step(0.5)
    assert len(MSPC.waypoints()) == 5, 'back to 5 WPs (%d)' % len(MSPC.waypoints())
    print('  ' + str(MSPC.debug()))
    assert 'FC count 5' in str(MSPC.debug()) and 'got 5' in str(MSPC.debug()) and 'last flag A5' in str(MSPC.debug())
    print('INAV checks OK')
    sys.exit(0)
if TILES:
    getMI = L.execute('''return function(W) for i = 1, 200 do local n, v = debug.getupvalue(W.wakeup, i)
        if n == nil then break end if n == "MI" then return v end end end''')
    MIm = getMI(wt)
    cur, kind = MIm.current(); print("  mission source", kind)
    for k in range(1, (len(cur) if cur is not None else 0) + 1):   # ArduPilot learns WPs; INAV/BF sensors don't send them
        e = cur[k]; t = WPS[int(e.num) - 1]
        print('  learned WP%d err %.1f m' % (e.num, dist_brg(e.lat, e.lon, t[0], t[1])[0]))
    PAINT[0] = True
    widget.tileSet = 'GOOGLE Satellite'
    do_write(); do_read()
    stats['loads'] = 0
    for _ in range(40): step(0.2)      # let the queue fill the view
    tag = ('tiles_native_' if NATIVE else 'tiles_') + RES
    print('  tile zoom', widget.tz, 'loads', stats['loads'])
    render('map_learned_%s.png' % tag, 2)
    widget.missionFile = 'test.waypoints'
    do_write(); do_read()
    for _ in range(40): step(0.2)
    render('main_%s.png' % tag, 1)
    for _ in range(40): step(0.2)
    render('map_%s.png' % tag, 2)
    for _ in range(3): wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_RIGHT'], 0, 0)
    for _ in range(40): step(0.2)
    render('map_zoomed_%s.png' % tag, 2)
    print('  manual zoom ->', widget.tz, 'view', widget.zoomMode)
    sys.exit(0)
render('main_%s.png' % tag, 1)
render('map_north_%s.png' % tag, 2)
render('map_heading_%s.png' % tag, 2, orient=1)
MSGS = [("ArduPlane V4.7.1 (ArduCustom)", 6), ("EKF3 IMU0 is using GPS", 6), ("Throttle armed", 5),
        ("Mode FBWA", 6), ("Takeoff complete", 6), ("Mode AUTO", 6), ("Mission: 1 Takeoff", 6),
        ("Mission: 2 WP", 6), ("Reached waypoint #2 dist 18m", 6), ("Mission: 3 WP", 6),
        ("Low battery! Check RTL", 4), ("Battery 1 is low 14.0V used 4100 mAh", 2), ("Mode RTL", 6)]
if not NATIVE:
    for text, sev in MSGS:
        for chunk in text_chunks(text, sev):
            sport_q.append([0x5000, chunk]) if SPORT else crsf_q.append([0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24])
        step(7)
# more history so the list overflows the screen
if not NATIVE:
    for k in range(25):
        for chunk in text_chunks("PreArm check %d OK" % k if k % 5 else "GPS glitch %d" % k, 6 if k % 5 else 3):
            sport_q.append([0x5000, chunk]) if SPORT else crsf_q.append([0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24])
        step(1)
render('msgs_%s.png' % tag, 3, orient=0)
if not NATIVE:
    E, TE = consts['EVT_KEY'], consts['EVT_TOUCH']
    mx = widget.msgMax
    assert mx > 0, 'list should overflow'
    for _ in range(5): wt['event'](widget, E, consts['KEY_ROTARY_LEFT'], 0, 0)
    render('msgs_scrolled_%s.png' % tag, 3)
    assert widget.msgScroll == 5, widget.msgScroll
    first_new = widget.msgScroll
    # a new message while scrolled back must not move the view
    for chunk in text_chunks("Mode LOITER", 6):
        sport_q.append([0x5000, chunk]) if SPORT else crsf_q.append([0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24])
    step(1); render('_t.png', 3)
    assert widget.msgScroll == 6, widget.msgScroll
    # drag up by 3 rows -> 3 newer
    rh = widget.msgRowH
    wt['event'](widget, TE, consts['TOUCH_START'], 300, 300)
    wt['event'](widget, TE, consts['TOUCH_MOVE'], 300, 300 - 3 * rh)
    wt['event'](widget, TE, consts['TOUCH_END'], 300, 300 - 3 * rh)
    assert widget.msgScroll == 3 and widget.page == 3, (widget.msgScroll, widget.page)
    render('_t.png', 3)
    b = widget.msgLatestBtn
    wt['event'](widget, TE, consts['TOUCH_START'], b.x + 4, b.y + 4)
    wt['event'](widget, TE, consts['TOUCH_END'], b.x + 4, b.y + 4)
    assert widget.msgScroll == 0 and widget.page == 3, 'latest button'
    for _ in range(500): wt['event'](widget, E, consts['KEY_ROTARY_LEFT'], 0, 0)
    assert widget.msgScroll == mx + 1 or widget.msgScroll == widget.msgMax, 'clamped'
    os.remove(os.path.join(OUT, '_t.png'))
    print('scroll checks OK, max scroll', widget.msgMax)
    widget.msgScroll = 0

# ------------------------------------------------------------------ input + zoom checks
render('_tmp.png', 2)
b = widget.btns
lvl0 = widget.level
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], b.plus.x + 5, b.plus.y + 5)
assert widget.level == lvl0 - 1, 'plus button'
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], b.minus.x + 5, b.minus.y + 5)
assert widget.level == lvl0, 'minus button'
assert widget.zoomMode == 0 and b.auto.label == 'PLANE', 'aircraft-centred by default'
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], b.auto.x + 5, b.auto.y + 5)
assert widget.zoomMode == 1, 'view button -> home-centred'
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], b.auto.x + 5, b.auto.y + 5)
assert widget.zoomMode == 0, 'view button -> aircraft-centred'
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_RIGHT'], 0, 0)
assert widget.level == lvl0 - 1, 'rotary'
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_START'], 200, 200)
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], 200, 200)
assert widget.page == 3, 'tap changes page'
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 5, 'enter goes on to the sensor check (no flight yet)'
cv = Canvas(); drawn.clear(); wt['paint'](widget); cv.img.save(os.path.join(OUT, 'check_%s.png' % tag))
assert any('SENSOR CHECK' in t for t, c, x in drawn), 'sensor check page draws'
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 1, 'enter wraps to page 1'
os.remove(os.path.join(OUT, '_tmp.png'))
MAPmod = L.execute(open('map.lua', encoding='utf8').read())
print('input checks OK')

# ------------------------------------------------------------------ flight summary
getV = L.execute('''return function(W, name) for i = 1, 300 do local n, v = debug.getupvalue(W.wakeup, i)
    if n == nil then break end if n == name then return v end end end''')
FS = getV(wt, 'FS')
wt_alive = getV(wt, 'T').alive
assert FS.last() is None, 'no summary before the first disarm'
widget.page = 2
peak_mah = S.mah

st['armed'] = False                       # one bad frame must not end the flight
step(0.2); step(0.2)
st['armed'] = True
for _ in range(8): step(0.2)
assert widget.page == 2 and FS.last() is None, 'disarm flicker ended the flight'

st['armed'] = False
for _ in range(10): step(0.2)
assert widget.page == 4, 'disarm opens the summary, page %s' % widget.page
f = FS.last()
print('summary: time %.0f dist %.0f home %s alt %s gspd %s as %s used %s volt %s curr %s lq %s rssi %s lost %s' % (
    f.time, f.dist, f.maxHome, f.maxAlt, f.maxGspd, f.maxAspd, f.used, f.minVolt, f.maxCurr, f.minLq, f.minRssi, f.lost))
if SPORT:
    assert S.rssi in (87, 88) and S.lq is None, 'S.Port has RSSI, no LQ (%s %s)' % (S.rssi, S.lq)
elif not INAV:
    assert S.lq == 96 and S.rssi in (-72, -73), 'CRSF has LQ and RSSI (%s %s)' % (S.lq, S.rssi)
assert f.time > 100 and f.dist > 3000 and abs(f.maxAlt - 120) < 1 and f.lost == 0, 'summary values'
render('summary_%s.png' % tag, 4)
first_time = f.time

wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_LEFT'], 0, 0)
assert widget.page == 4, 'rotary stays on the summary'
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 5, 'enter leaves the summary (on to the sensor check)'
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 1, 'then back to page 1'
widget.page = 3
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 4, 'summary joins the cycle'

st['armed'] = True                        # arming closes it, back to the main page
for _ in range(5): step(0.2)
assert widget.page == 1, 're-arm closes the summary to main, page %s' % widget.page
for _ in range(15): step(0.2)             # 3 s on the bench: too short to count
st['armed'] = False
for _ in range(10): step(0.2)
assert widget.page == 1 and FS.last().time == first_time, 'short arm shows nothing'

st['armed'] = True                        # link lost mid-flight, then found disarmed
for _ in range(100): step(0.2)
# aircraft off: no frames, and the radio's sensors keep their last values except link quality/RSSI
TLM_ON[0] = False   # Ethos keeps LQ/RSSI as they were (X18 tester); only its flag drops
for _ in range(50):                       # 10 s with no frames; wakeups keep running
    sim_time[0] += 0.2
    for _ in range(4): wt['wakeup'](widget)
assert not wt_alive(), 'telemetry lost must show as lost'
sim_time[0] = math.floor(sim_time[0]) + 1.1          # the 'on' half of the 2 Hz flash
widget.page = 2
cv = Canvas(); wt['paint'](widget)
assert cv.img.getpixel((2, H // 2)) == (255, 70, 70), 'red edge while lost %s' % (cv.img.getpixel((2, H // 2)),)
assert 'NO TELEMETRY' in [t for t, c, x in drawn], 'top bar says NO TELEMETRY'
assert S.lat is not None and '%.6f' % S.lat in [t for t, c, x in drawn] and '%.6f' % S.lon in [t for t, c, x in drawn], 'last coordinates stay on screen while lost'
cv.img.save(os.path.join(OUT, 'lost_%s.png' % tag))
assert widget.page == 2, 'link loss must not end the flight'
assert NATIVE or S.aspd is not None, 'a lost link must not blank the speed tape'
st['armed'] = False
for _ in range(10): step(0.2)
assert widget.page == 4, 'disarm after link loss'
f = FS.last()
print('after link loss: time %.1f lost %.1f' % (f.time, f.lost))
assert 8 < f.lost < 16 and 18 < f.time < 22, 'link loss accounting'   # from Ethos's flag: up to 3 s earlier than the frame timeout
# the radio's module switched off: nothing arrives and every sensor, link quality included,
# keeps its last value. The module setting says the link is off.
for _ in range(10): step(0.2)
assert wt_alive(), 'link back'
MODULE_ON[1] = False
for _ in range(50):
    sim_time[0] += 0.2
    for _ in range(4): wt['wakeup'](widget)
assert not wt_alive(), 'module off (frozen sensors) shows as lost'
MODULE_ON[1] = True
for _ in range(10): step(0.2)
assert wt_alive(), 'link back after the module is on again'
# the widget re-created while another Ethos screen was up: an unseen summary still opens
FS.last().shown = False
other = wt['create'](); do_read(other); other.sumAuto = 1; other.page = 2
sim_time[0] += 0.2
wt['wakeup'](other)
assert other.page == 4, 'unseen summary opens in a re-created widget, page %s' % other.page
cv = Canvas(); wt['paint'](other)
assert FS.last().shown, 'drawing the summary marks it seen'
other.page = 1; wt['wakeup'](other)
assert other.page == 1, 'a seen summary does not come back'
widget.page = 1
st['armed'] = True
for _ in range(100): step(0.2)
widget.sumAuto = 0
st['armed'] = False
for _ in range(10): step(0.2)
assert widget.page == 1, 'setting off keeps the page'
widget.sumAuto = 1
# flight time: ArduPilot counts only while its flying flag is set (Yaapu); INAV/BF from arming
st['flying'] = False
st['armed'] = True
for _ in range(60): step(0.2)            # 12 s armed on the ground
g = FS.live()
assert NATIVE or (g.fly == 0 and g.flyFrom is None), 'AP: no flight time while armed on the ground'
st['flying'] = True
for _ in range(100): step(0.2)           # 20 s flying
st['flying'] = False
for _ in range(25): step(0.2)            # 5 s landed, still armed
st['armed'] = False
for _ in range(10): step(0.2)
f = FS.last()
print('flight time: %.1f s (%s)' % (f.time, 'armed' if NATIVE else 'flying'))
if NATIVE:
    assert 35 < f.time < 39, 'INAV/BF: time from arming %.1f' % f.time
else:
    assert 19 < f.time < 21, 'AP: only the flying part counts %.1f' % f.time
del st['flying']
print('summary checks OK')

# ------------------------------------------------------------------ main page tiles
GS_COL, OK_COL, WARN_COL, BAD_COL = (90, 235, 140), (35, 140, 60), (190, 130, 10), (190, 40, 40)
def main_drawn():
    global cv
    widget.page = 1
    cv = Canvas(); drawn.clear(); fills.clear(); tris.clear(); wt['paint'](widget)
    return list(drawn)
def fill(col):
    w = [fw for c, x, fw in fills if c == col and x > W * 0.56]
    assert len(w) <= 1, 'battery fill is one bar, got %s' % w
    return w[0] if w else 0

keep = dict(mah=st['mah'], curr=st['curr'], armed=st['armed'])
st['armed'] = False                       # battery call-outs only run armed; don't disturb those checks
if NATIVE: widget.batCap = 5000
step(0.2); step(0.2)
assert S.cap == 5000, 'capacity %s' % S.cap
# the fake S.Port sensors have no current or mAh, so there the gauge can only show --
full = None
for mah, left, col in ((0, 1, OK_COL), (500, 0.9, OK_COL), (2500, 0.5, OK_COL), (3750, 0.25, WARN_COL), (4400, 0.12, BAD_COL), (6000, 0, OK_COL)):
    st['mah'] = mah
    step(0.2); step(0.2)
    ops = main_drawn()
    if full is None: full = fill(col)
    assert abs(fill(col) - full * left) <= 1, '%d mAh: fill %s of %s' % (mah, fill(col), full)
    volts = [(t, x) for t, c, x in ops if t.endswith('V') and t not in ('TX %.1fV' % TX_VOLTS[0], SIM_MODEL)]
    assert volts and all(t == '15.8V' and x > W * 0.56 for t, x in volts), 'voltage on the gauge only %s' % volts
st['mah'], st['curr'] = 0, 0              # no current sensor: never a full-looking gauge
step(0.2); step(0.2)
ops = main_drawn()
assert fill(OK_COL) == 0 and '15.8V' in [t for t, c, x in ops], 'no current sensor shows voltage in the gauge'
st['mah'], st['curr'] = 2500, keep['curr']
if NATIVE:
    widget.batCap = 0
    step(0.2); step(0.2)
    ops = main_drawn()
    assert S.cap is None and fill(OK_COL) == 0 and '15.8V' in [t for t, c, x in ops], 'native without a capacity shows voltage'
    widget.batCap = 5000
    step(0.2); step(0.2)

ops = main_drawn()
txt = [t for t, c, x in ops]
assert 'ALT' not in txt and not any(t.startswith('GSPD') for t in txt), 'ALT and GSPD tiles are gone'
assert any(t.startswith('ALT ') for t in txt), 'altitude tape stays'
f = FS.live()
def dist_txt(m): return '%dm' % int(m + 0.5) if m < 999.5 else '%.2fkm' % (m / 1000)
assert dist_txt(999.4) == '999m' and dist_txt(999.6) == '1.00km' and dist_txt(3293.79) == '3.29km'
NOTES = H >= 320            # the small notes are left out only on the narrowest screens
assert 'HOME' in txt and (not NOTES or 'TOTAL ' + dist_txt(f.dist) in txt), 'total distance in the home block %s' % txt
assert 'TOTAL DIST' not in txt, 'TOTAL DIST block gave its place to FLIGHT TIME %s' % txt
import re
assert 'FLIGHT TIME' in txt and any(re.fullmatch(r'\d\d:\d\d', t) for t in txt), 'flight time block %s' % txt
assert 'MAX GS km/h' in txt and '%.1f' % (f.maxGspd * 3.6) in txt, 'max GS %s' % txt
assert 'MAX AS km/h' in txt, 'max AS block %s' % txt
assert f.maxCurr is None or not NOTES or 'MAX %.1fA' % f.maxCurr in txt, 'max current in the current block %s' % txt
assert cv.img.getpixel((3, H // 3)) != (20, 20, 20), 'horizon shows through the speed tape'
if NATIVE:
    assert f.maxAspd is None and not any(c == GS_COL for t, c, x in ops), 'no second box when the tape already shows ground speed'
else:
    assert '%.1f' % (f.maxAspd * 3.6) in txt, 'max AS %s' % txt
    gs = [t for t, c, x in ops if c == GS_COL]
    assert gs == [str(round(S.gspd * 3.6)), 'GS'] and float(gs[0]) != round(S.aspd * 3.6), 'GS box %s' % gs
    st['nogs'] = True
    for _ in range(30): step(0.2)
    ops = main_drawn()
    assert S.gspd is None and S.aspd is not None and not any(c == GS_COL for t, c, x in ops), 'stale GS must go'
    st['nogs'] = False
    step(0.2); step(0.2)
    assert S.gspd is not None, 'GS comes back'

if f.effSpd is None:
    assert not NOTES or '-- Wh/km' in txt, 'no efficiency without current %s' % txt
else:
    wh = f.effAmps * f.effVolts / (f.effSpd * 3.6)
    assert 2 < wh < 4, 'efficiency %.2f Wh/km' % wh
    amps = f.effAmps * 1000 / (f.effSpd * 3.6)
    for unit, text in ((0, '%.2f Wh/km' % wh), (1, '%.2f mAh/km' % amps), (2, '%.2f Wh/mi' % (wh * 1.609344)), (3, '%.2f mAh/mi' % (amps * 1.609344))):
        widget.effUnit = unit
        assert not NOTES or text in [t for t, c, x in main_drawn()], 'efficiency unit %d: want %s' % (unit, text)
    widget.effUnit = 2
    do_write()
    assert saved('effUnit') == 2, 'efficiency unit saved'
    widget.effUnit = 0

# flight summary follows the efficiency unit, as a whole-flight average
def page_text(page):
    global cv
    widget.page = page
    cv = Canvas(); drawn.clear(); wt['paint'](widget)
    return [t for t, c, x in drawn]
lf = FS.last()
if lf.used and lf.dist > 100:
    mah_km = lf.used / (lf.dist / 1000)
    volts = lf.voltSum / lf.voltN
    assert 2 < mah_km / 1000 * volts < 200, 'average %.1f Wh/km' % (mah_km / 1000 * volts)
    for unit, label, value in ((0, 'Wh/km', '%.2f' % (mah_km / 1000 * volts)), (1, 'mAh/km', '%.2f' % mah_km),
                               (2, 'Wh/mi', '%.2f' % (mah_km / 1000 * volts * 1.609344)), (3, 'mAh/mi', '%.2f' % (mah_km * 1.609344))):
        widget.effUnit = unit
        t = page_text(4)
        assert label in t and value in t, 'summary unit %d: want %s %s in %s' % (unit, value, label, t)
    widget.effUnit = 0
    t = page_text(4)
    for want in (dist_txt(lf.dist), dist_txt(lf.maxHome), dist_txt(lf.maxAlt), '%.1f' % (lf.maxGspd * 3.6), '%.1f' % (lf.maxAspd * 3.6)):
        assert want in t, 'summary format: want %s in %s' % (want, t)
    widget.altUnit = 1
    t = page_text(4)
    assert '%dft' % int(lf.maxAlt * 3.28084 + 0.5) in t and '%.2fmi' % (lf.dist * 3.28084 / 5280) in t, 'summary in feet %s' % t
    widget.altUnit = 0
else:
    t = page_text(4)
    assert 'Wh/km' in t and 'mAh/km' not in t, 'summary label %s' % t

# ready to arm
def chips():
    t = page_text(1)
    return [x for x in t if x not in ('READY', 'NOT READY') and ('ARM' in x and x not in ('ARMED', 'DISARMED') or x.startswith('READY') or x.startswith('NOT READY') or x.startswith('WAITING'))]
if NATIVE and not SPORT:
    for raw, want in (('OK', 'READY TO ARM'), ('WAIT', 'WAITING FOR GPS'), ('!ERR', 'NOT READY TO ARM'), ('ACRO*', 'READY TO ARM'),
                      ('ACRO!', 'NOT READY TO ARM'), ('ACRO?', 'READY, NO GPS RESCUE'), ('ANGL*', 'READY TO ARM'),
                      ('RTL*', None), ('FBWA*', None)):   # ArduPilot's own CRSF text: "*" only means disarmed
        st['fm'] = raw
        step(0.2)
        assert chips() == ([want] if want else []), '%s -> %s' % (raw, chips())
        if raw == '!ERR': render('main_notready_%s.png' % tag, 1)
        if raw == 'OK': render('main_ready_%s.png' % tag, 1)
    st['fm'] = 'ANGL'
    step(0.2)
    assert S.armed is True and chips() == [], 'armed shows no arming status %s' % chips()
    st.pop('fm')
elif NATIVE:
    for digits, want in ((1, 'READY TO ARM'), (2, 'NOT READY TO ARM')):
        st['sm'] = digits
        step(0.2)
        assert chips() == [want], '%d -> %s' % (digits, chips())
    st.pop('sm')
else:
    st['armed'] = True
    step(0.2); step(0.2)
    assert chips() == [], 'armed shows no arming status %s' % chips()
    st['armed'] = False
    step(0.2); step(0.2)
    assert chips() == ['CHECKING ARMING'], 'wait after disarm %s' % chips()
    for _ in range(41): step(1)
    assert chips() == ['READY TO ARM'], 'no PreArm for 40 s %s' % chips()
    render('main_ready_%s.png' % tag, 1)
    for chunk in text_chunks("PreArm: Need 3D Fix", 2):
        sport_q.append([0x5000, chunk]) if SPORT else crsf_q.append([0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24])
    step(1)
    assert chips() == ['NOT READY TO ARM'], 'PreArm message %s' % chips()
    render('main_notready_%s.png' % tag, 1)
    for _ in range(35): step(1)
    assert chips() == ['NOT READY TO ARM'], 'still inside the repeat period %s' % chips()
    for _ in range(6): step(1)
    assert chips() == ['READY TO ARM'], 'PreArm stopped %s' % chips()
    if not SPORT:
        # ArduPilot's CRSF status frame (0xF1): read whole; after it the 0x5000 copy is ignored
        n0 = S.msgTotal
        crsf_q.append([0xF1, 2] + list(b'PreArm: Compass not calibrated') + [0])
        step(1)
        assert chips() == ['NOT READY TO ARM'], 'PreArm in a CRSF status frame %s' % chips()
        assert S.msgs[len(S.msgs)].text == 'PreArm: Compass not calibrated' and S.msgs[len(S.msgs)].sev == 2
        for chunk in text_chunks('PreArm: Compass not calibrated', 2):
            crsf_q.append([0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24])
        step(1)
        assert S.msgTotal == n0 + 1, 'no second copy from passthrough (%d new)' % (S.msgTotal - n0)
        # the same message again (TX16S + TBS showed 4 lines of each): one line with a count
        for _ in range(3): crsf_q.append([0xF1, 2] + list(b'PreArm: Compass not calibrated') + [0])
        step(1)
        last = S.msgs[len(S.msgs)]
        assert S.msgTotal == n0 + 1 and last.text == 'PreArm: Compass not calibrated (x4)', \
            'repeats fold into one line: %d new, %s' % (S.msgTotal - n0, last.text)
        for _ in range(42): step(1)
        assert chips() == ['READY TO ARM'], 'ready again %s' % chips()
    # no PreArm heard, but the GPS has no 3D fix: not ready straight away (bench report 2026-11-02)
    st['fix'] = 1
    step(0.2); step(0.2)
    assert chips() == ['NOT READY: NO GPS FIX'], 'no fix %s' % chips()
    render('main_nofix_%s.png' % tag, 1)
    st['fix'] = 0                          # no GPS fitted: ArduPilot doesn't need one
    step(0.2); step(0.2)
    assert chips() == ['READY TO ARM'], 'no GPS fitted %s' % chips()
    st['fix'] = 3
    step(0.2); step(0.2)
    assert chips() == ['READY TO ARM'], 'fix back %s' % chips()

# INAV with a pitot: airspeed on the tape and ground speed in the green box, as on ArduPilot
if NATIVE:
    st['pitot'] = True
    for _ in range(40): step(0.2)         # a new sensor: list re-read every 5 s, missing ones retried every 2 s
    ops = main_drawn()
    txt = [t for t, c, x in ops]
    assert abs(S.aspd - st['as']) < 0.1 and any(t.startswith('AS ') for t in txt), 'native airspeed %s' % S.aspd
    assert any(c == GS_COL for t, c, x in ops), 'ground speed box with a pitot'
    render('main_pitot_%s.png' % tag, 1)
    st['pitot'] = False
    native_vals.pop('Airspeed', None)
    S.aspd = None

# nothing on the main page or the map spills out of its box at this size
widget.page = 2
cv = Canvas(); wt['paint'](widget)
auto = widget.btns.auto
cv.font = font_of(consts['FONT_STD'])
assert text_size('AUTO')[0] + 4 <= auto.w, 'AUTO fits its button (%d px in %d)' % (text_size('AUTO')[0], auto.w)
widget.page = 1

# no GPS fix: ArduPilot sends 0,0, which is no position; the map centres on the last good one
if not NATIVE and not TILES:
    posf = os.path.join(SD, 'scripts', 'omnideck', 'lastpos.txt')
    assert os.path.isfile(posf), 'last position saved'
    la, lo = map(float, open(posf).read().split(','))
    assert abs(la - st['lat']) < 0.05 and abs(lo - st['lon']) < 0.05, 'saved position near the aircraft'
    keep_pos = (st['lat'], st['lon'], st.get('fix', 3))
    st['lat'], st['lon'], st['fix'] = 0.0, 0.0, 1
    for _ in range(6): step(0.2)
    assert S.lat is None and S.lon is None, '0,0 is no position (%s, %s)' % (S.lat, S.lon)
    widget.page = 2
    cv = Canvas(); drawn.clear(); wt['paint'](widget)
    assert 'NO GPS' in [t for t, c, x in drawn], 'map says NO GPS'
    txt = [t for t, c, x in drawn]
    assert 'LAST' in txt and '%.6f' % la in txt and '%.6f' % lo in txt, 'last position on the map page %s' % txt[-8:]
    cv.img.save(os.path.join(OUT, 'map_nofix_%s.png' % tag))
    st['lat'], st['lon'], st['fix'] = keep_pos
    for _ in range(6): step(0.2)
    assert S.lat is not None
    widget.page = 2
    cv = Canvas(); drawn.clear(); wt['paint'](widget)
    txt = [t for t, c, x in drawn]
    assert 'Lat ' in txt and '%.6f' % S.lat in txt and '%.6f' % S.lon in txt and 'LAST' not in txt, 'coordinates on the map page'
    cv.img.save(os.path.join(OUT, 'map_coords_%s.png' % tag))
    widget.page = 1
    print('no-fix map centre OK')

# mLRS 1.4.x packs 0x800 with the coordinate negated first: decode it to the real position
Tm = getV(wt, 'T')
def mlrs_latlng(deg, is_lon):  # (ArduPilot runs only: passthrough packets would switch an INAV run over)
    L = abs(int(round(deg * 1e7)))
    raw = ((2 ** 32 - L) // 50) * 3
    v = raw | ((1 << 30) if deg < 0 else 0) | ((1 << 31) if is_lon else 0)
    return v & 0xFFFFFFFF
if NATIVE and SPORT:
    assert S.fc == 'INAV/BF', 'INAV GPS frames (0x0800) must not switch the run to ArduPilot: %s' % S.fc
for la, lo in (() if NATIVE else ((14.1749166, 121.2435277), (-33.86, 151.21), (51.48, -0.12), (40.7, -74.0))):
    Tm.decodePassthrough(0x0800, mlrs_latlng(la, False))
    Tm.decodePassthrough(0x0800, mlrs_latlng(lo, True))
    assert abs(S.lat - la) < 1e-5 and abs(S.lon - lo) < 1e-5, 'mLRS position %s %s -> %s %s' % (la, lo, S.lat, S.lon)
for _ in range(6): step(0.2)          # back to the simulated aircraft
print('mLRS coordinates OK')

# home-centred view: armed -> closest step; flying out only zooms out, keeping the aircraft
# inside the map; flying back does not zoom in again
if not TILES:
    MAPr = getV(wt, 'MAP')
    # aircraft-centred and zoomed in so home is off the map: a small home icon on the edge
    widget.zoomMode = 0; widget.page = 2; widget.level = 1
    st['lat'], st['lon'] = project(HOME[0], HOME[1], 600, 30)     # well away from home
    for _ in range(10): step(0.2)
    cv = Canvas(); tris.clear(); wt['paint'](widget)
    rx, ry, rw_, rh_ = 0, round(H * 0.09), W, H - round(H * 0.09)
    homes = [p for c, p in tris if c == (80, 200, 255)]
    assert homes, 'home marker drawn'
    hx, hy = homes[-1][2], homes[-1][3]          # the roof's apex
    assert hx < 25 or hx > W - 25 or hy < ry + 30 or hy > H - 45, 'home icon on the edge (%s, %s)' % (hx, hy)
    cv.img.save(os.path.join(OUT, 'map_homeedge_%s.png' % tag))
    widget.zoomMode = 1; widget.page = 2
    st['armed'] = False; st['lat'], st['lon'] = HOME
    for _ in range(15): step(0.2)
    st['armed'] = True
    for _ in range(5): step(0.2)
    assert widget.level == 1, 'closest step at arming (%s)' % widget.level
    levels = []
    for k in range(80):                                   # straight out to about 1.2 km
        st['lat'], st['lon'] = project(HOME[0], HOME[1], 15 * k, 60)
        step(0.25)
        levels.append(widget.level)
        if S.homeDist:
            assert S.homeDist <= MAPr.EDGE * MAPr.LEVELS[widget.level] + 30, 'aircraft kept on the map (%.0f m at %s)' % (S.homeDist, MAPr.LEVELS[widget.level])
    assert levels == sorted(levels) and levels[-1] > 1, 'flying out only zooms out %s' % levels[::10]
    render('map_homeview_%s.png' % tag, 2)
    out = widget.level
    back = []
    for k in range(80, -1, -2):                           # back home, a little slower
        st['lat'], st['lon'] = project(HOME[0], HOME[1], 15 * k, 60)
        step(0.5)
        back.append(widget.level)
        if S.homeDist:
            assert S.homeDist <= MAPr.EDGE * MAPr.LEVELS[widget.level] + 30, 'still on the map on the way back'
    assert back == sorted(back, reverse=True) and back[-1] < out, 'flying back zooms in again %s' % back[::5]
    for _ in range(20): step(0.5)                         # parked at home: back to the closest steps
    assert widget.level <= 2, 'zoomed in at home (%s)' % widget.level
    st['armed'] = False
    for _ in range(15): step(0.2)
    widget.zoomMode = 0; widget.page = 1; widget.level = 4
    print('home-centred view OK')

# tile folders are found whatever their capitals ("Google/hybrid" as well as "GOOGLE/Hybrid")
if not TILES:
    TLm = getV(wt, 'TL')
    odd = os.path.join(SD, 'bitmaps', 'ethosmaps', 'maps', 'Google', 'hybrid', '15')
    os.makedirs(odd, exist_ok=True)
    sets = TLm.scan()
    found = [sets[i] for i in range(1, len(sets) + 1) if sets[i].label == 'GOOGLE Hybrid']
    assert found and found[0].dirP == 'Google' and found[0].dirT == 'hybrid' and found[0].minZ == 15, 'odd capitals'
    import shutil; shutil.rmtree(os.path.join(SD, 'bitmaps', 'ethosmaps', 'maps', 'Google'))
    print('tile folders: capitals ignored OK')

# home arrow in the HOME block: points to home relative to the nose
def arrow_deg():
    main_drawn()
    tiles_y = round(H * 0.09) + min(W - round(W * 0.56) - 3, round((H - round(H * 0.09) - round(H * 0.075)) * 0.46))
    pts = [p for c, p in tris if c == (80, 200, 255) and min(p[1], p[3], p[5]) > tiles_y and p[0] > W * 0.56]
    if not pts: return None
    assert len(pts) == 2 and pts[0][:2] == pts[1][:2], 'arrow is two triangles sharing the tip %s' % pts
    tx, ty = pts[0][0], pts[0][1]
    cx = sum(p[i] for p in pts for i in (2, 4)) / 4      # the tail points sit around the centre line
    cy = sum(p[i] for p in pts for i in (3, 5)) / 4
    return math.degrees(math.atan2(tx - cx, cy - ty)) % 360
lat0 = st['lat']
st['lat'] = lat0 + 0.006                  # ~670 m north of where it stands, so home is not underfoot
st['armed'] = False
step(0.2); step(0.2)
assert arrow_deg() is not None or S.homeDist is None or S.homeDist == 0, 'arrow away from home'
for yaw in (0, 90, 200, 315):
    st['yaw'] = yaw
    step(0.2); step(0.2)
    got = arrow_deg()
    want = (S.homeBrg - S.yaw) % 360
    assert got is not None and abs((got - want + 180) % 360 - 180) < 8, 'yaw %d: arrow %s, want %.0f' % (yaw, got, want)
st['lat'] = lat0
st['yaw'] = 0
step(0.2); step(0.2)
if S.homeDist is not None and S.homeDist < 1:
    assert arrow_deg() is None, 'no arrow when at home'
print('home arrow OK')
render('main_arrow_%s.png' % tag, 1)
tris.clear()

# transmitter battery in the top bar, between the mode and the link figures
t = page_text(1)
assert 'TX 8.1V' in t, 'TX battery %s' % t
assert SIM_MODEL in t, 'model name in the top bar %s' % t
TX_VOLTS[0] = 7.46
t = page_text(1)
assert 'TX 7.5V' in t, 'TX battery follows the radio %s' % t
TX_VOLTS[0] = 8.1
for pg in (2, 3, 4):
    assert 'TX 8.1V' in page_text(pg), 'TX battery on page %d' % pg
print('TX battery + model name OK')

store_form = {}
L.execute('''form = { addLine = function(n) return n end, addChoiceField = function() end, addSourceField = function() end,
  addNumberField = function(line, r, lo, hi, get, set) _NF[line] = { lo, hi, get, set } end }''')
G._NF = L.table_from({})
wt['configure'](widget)
nf = G._NF['Battery mAh (INAV/BF only)']
assert nf is not None, 'capacity field'
nf[4](3300)
assert widget.batCap == 3300 and nf[3]() == 3300
do_write()
assert saved('batCap') == 3300, 'capacity saved'

# settings survive a radio restart: write, then read into a brand-new widget (positional storage)
keep_w = {k: widget[k] for k in ('linkMode', 'orient', 'zoomMode', 'spdUnit', 'altUnit', 'trail', 'startPage',
                                 'level', 'tileSet', 'missionFile', 'inavWp', 'sumAuto', 'voice', 'batCap', 'effUnit', 'beep')}
for k, v in (('orient', 1), ('spdUnit', 2), ('altUnit', 1), ('trail', 0), ('startPage', 2), ('level', 6),
             ('sumAuto', 0), ('voice', 'Michelle'), ('batCap', 2200), ('effUnit', 3), ('beep', 2), ('inavWp', 0)):
    widget[k] = v
widget.zoomSource = None
do_write()
fresh = wt['create']()
do_read(fresh)
for k, v in (('orient', 1), ('spdUnit', 2), ('altUnit', 1), ('trail', 0), ('startPage', 2), ('level', 6),
             ('sumAuto', 0), ('voice', 'Michelle'), ('batCap', 2200), ('effUnit', 3), ('beep', 2), ('inavWp', 0)):
    assert fresh[k] == v, 'after restart %s = %s, want %s' % (k, fresh[k], v)
assert fresh.page == 2 and fresh.zoomSource is None
# an older layout's data (no schema first) gives defaults, not shifted values
del slots[:]; slots.extend([1, 1, 0, 5, 2])
older = wt['create'](); do_read(older)
assert older.orient == 0 and older.spdUnit == 0 and older.batCap == 0, 'old layout -> defaults'
for k, v in keep_w.items(): widget[k] = v
do_write()
print('settings survive a restart OK')
widget.batCap = 5000 if NATIVE else 0
st.update(keep)
step(0.2); step(0.2)
widget.page = 1
print('main page tiles OK')

# ------------------------------------------------------------------ voice call-outs
assert widget.voice == 'Aria', 'first pack found is the default, got %s' % widget.voice
def hear(n=10):
    del played[:]
    for _ in range(n): step(0.2)
    return list(played)
widget.sumAuto = 1
AUm = getV(wt, 'AU')
AUm.setBeep(0)                            # beeps have their own checks below
hear(20)                                  # let any ready-to-arm change settle first
assert hear() == [], 'quiet while nothing changes, got %s' % played
st['armed'] = True
assert 'armed' in hear(), 'armed'
if not NATIVE:
    def text(t, sev=6):
        # over CRSF ArduPilot sends each message twice: passthrough 0x5000 chunks and a 0xF1 frame
        for chunk in text_chunks(t, sev):
            sport_q.append([0x5000, chunk]) if SPORT else crsf_q.append([0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24])
        if not SPORT:
            crsf_q.append([0xF1, sev] + list(t.encode()[:49]) + [0])
    st['mode'] = 11
    assert hear() == ['rtl'], 'mode %s' % played
    st['mode'] = 26
    assert hear() == ['coursehold'], 'fork mode %s' % played
    st['mode'] = 5
    assert hear() == ['flybywirea'], 'FBWA %s' % played
    st['mode'] = 11; step(0.2); st['mode'] = 5     # switch sweeping through a mode
    assert hear() == [], 'brief mode is not read out, got %s' % played
    text('Takeoff complete - FBWB')
    assert hear() == ['3843641'], 'status text %s' % played
    text('PreArm: GPS 1: Bad fix')
    assert hear() == [], 'unlisted text stays silent, got %s' % played
    st['mah'] = 3800                               # 24 % of 5000
    assert hear() == ['bat25'], 'battery %s' % played
    st['mah'] = 3900
    assert hear() == [], 'no repeat inside a step, got %s' % played
    del played[:]
    TLM_ON[0] = False   # Ethos keeps LQ/RSSI as they were (X18 tester); only its flag drops
    for _ in range(50):                            # link lost while armed
        sim_time[0] += 0.2
        for _ in range(4): wt['wakeup'](widget)
    assert played == ['telemlost'], 'link lost %s' % played
    assert hear() == ['telemok'], 'link back %s' % played
    st['armed'] = False; st['mode'] = 11; st['thr'] = 0
    h = hear()
    assert h[0] == 'disarmed' and 'rtl' in h, 'urgent first %s' % h
if NATIVE and not SPORT:
    # every CRSF string in INAV's and Betaflight's telemetry/crsf.c
    st.pop('fm', None); st['armed'] = True
    hear()
    MODES = {'MANU': 'manual', 'RTH': 'rtl', 'LOTR': 'loiter', 'HOLD': 'poshold', 'CRUZ': 'cruise',
             'CRSH': 'coursehold', 'WP': 'waypoint', 'AH': 'althold', 'ANGL': 'angle', 'HOR': 'horizon',
             'ANGH': 'anglehold', 'TURT': 'turtle', 'GEO': 'geozone', 'LAND': 'land', 'ACRO': 'acro',
             'WRTH': 'rtl', 'PASS': 'passthrough', 'POSH': 'poshold', 'PHFL': 'posholdfail',
             'ALTH': 'althold', 'CHIR': 'chirp', 'AIR': 'airmode'}
    clips = {l.split('|')[0] for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'phrases.psv'), encoding='utf8') if '|' in l and l[0] != '#'}
    for m, clip in MODES.items():
        st['fm'] = m
        assert hear() == [clip], '%s -> %s' % (m, played)
        assert clip in clips, 'no phrase for ' + clip
        assert S.armed is True, m + ' reads as armed'
    st['fm'] = 'HRST'
    assert hear() == [], 'HRST silent, got %s' % played
    st['fm'] = '!FS!'
    assert hear() == ['failsafe'] and S.armed is True and S.mode == 'FAILSAFE', 'failsafe %s' % played
    st['fm'] = 'ACRO'
    hear()
    for raw, name in (('ACRO*', 'ACRO'), ('ACRO!', 'ACRO'), ('ACRO?', 'ACRO'), ('RTL*', 'RTL'), ('OK', 'OK'), ('WAIT', 'WAIT'), ('!ERR', '!ERR')):
        st['fm'] = raw
        hear()
        assert S.armed is False and S.mode == name, '%s -> %s %s' % (raw, S.armed, S.mode)
    st['fm'] = 'ANGL'
    h = hear()
    assert S.armed is True and h[:2] == ['armed', 'angle'], 'armed then mode %s' % h
    st['fm'] = 'ACRO!'
    assert hear()[0] == 'disarmed', 'BF disarm mark %s' % played
    print('CRSF mode strings OK:', len(MODES))
if NATIVE and SPORT:
    st['armed'] = True
    for digits, clip in ((1014, 'rtl'), (2014, 'waypoint'), (8014, 'coursehold'), (8214, 'cruise'),
                         (414, 'poshold'), (214, 'althold'), (44, 'manual'), (24, 'horizon'), (14, 'angle'), (4, 'acro')):
        st['sm'] = digits
        assert hear() == [clip], '%d -> %s' % (digits, played)
    st['sm'] = 1
    assert hear() == ['disarmed'], 'S.Port disarm %s' % played
    print('S.Port mode digits OK')
# message beep: one tone per burst, by the worst severity; ready to arm spoken on change
if not NATIVE:
    hear(15)                              # let the earlier PreArm call-out play out
    AUm.setBeep(1)
    text('Mission: 1 WP', 6)
    assert hear() == ['info'], 'info beep %s' % played
    for _ in range(12): step(0.2)
    text('Low battery', 4); text('EKF variance', 2); text('Another info', 6)
    h = hear()
    assert 'crit' in h and h.count('info') == 0, 'worst of a burst beeps, info does not %s' % h
    for _ in range(12): step(0.2)
    AUm.setBeep(2)
    text('Mission: 2 WP', 6)
    assert hear() == [], 'warnings only: info stays quiet %s' % played
    for _ in range(12): step(0.2)
    text('Fence breach', 4)
    assert hear() == ['warn'], 'warnings only: warning beeps %s' % played
    AUm.setBeep(0)
    st['armed'] = False
    hear(5)
    for _ in range(42): step(1)
    del played[:]
    for _ in range(12): step(0.2)
    text('PreArm: Need 3D Fix', 2)
    assert 'notready' in hear(15), 'not ready spoken %s' % played
    del played[:]
    for _ in range(45): step(1)
    assert S.armReady is True and 'readytoarm' in played, 'ready spoken %s' % played
    AUm.setVoice('off'); AUm.setBeep(1)
    for _ in range(12): step(0.2)
    text('Mission: 3 WP', 6)
    assert hear() == ['info'], 'beep plays with the voice off %s' % played
    AUm.setBeep(0); AUm.setVoice('Aria')
elif not SPORT:
    st['armed'] = False
    st['fm'] = '!ERR'
    assert 'notready' in hear(15), 'INAV arming prevented %s' % played
    st['fm'] = 'OK'
    assert 'readytoarm' in hear(15), 'INAV ready %s' % played
    st.pop('fm')
print('beep and ready-to-arm voice OK')
# low voltage and low altitude ("Terrain, pull up") alarms
AUm.setBeep(0); AUm.setVoice('Aria')
st.pop('sm', None); st.pop('fm', None)   # earlier mode tests leave a forced mode behind
st['armed'] = True; st['alt'] = 120
hear(15)
widget.lowVolt = 400                     # 4.00 V per cell; the 4S pack sits at 3.95
h = hear(30)                              # 6 s: past the 5 s hold
assert 'lowvoltage' in h, 'low voltage alarm %s' % h
assert 'lowvoltage' not in hear(50), 'not again within 30 s'
ops = main_drawn()
assert any(t == '%.1fV' % st['volt'] and c == (255, 190, 40) for t, c, x in ops), 'voltage amber on the gauge (low)'
widget.critVolt = 396                    # 3.96 V: the pack is critical now too
h = hear(30)
assert 'critvolt' in h and 'lowvoltage' not in h, 'critical takes over %s' % h
ops = main_drawn()
assert any(t == '%.1fV' % st['volt'] and c == (255, 70, 70) for t, c, x in ops), 'voltage red on the gauge (critical)'
assert hear(80).count('critvolt') == 1, 'critical repeats every 15 s (once in 16 s)'
widget.lowVolt = 0; widget.critVolt = 0
hear(10)
widget.lowAlt = 50                        # metres
st['alt'] = 30; h = hear(10)
assert 'pullup' not in h, 'below from the start (take-off) does not count %s' % h
st['alt'] = 120; hear(10)
st['alt'] = 30; h = hear(10)
assert 'pullup' in h, 'terrain pull up %s' % h
cv = Canvas(); drawn.clear(); widget.page = 1; wt['paint'](widget); cv.img.save(os.path.join(OUT, 'main_pullup_%s.png' % tag))
st['alt'] = 120; h = hear(20)
assert 'pullup' not in h, 'quiet again above %s' % h
widget.lowAlt = 0
print('alarms OK')
widget.voice = 'off'
vmod = getV(wt, 'AU'); vmod.setVoice('off')
st['armed'] = not st['armed']
assert hear() == [], 'voice off is silent, got %s' % played
print('voice checks OK')

# model switch: Ethos loads the widget once, so a new model must start with clean telemetry
# state (X18 tester: a BF plane showed "fc ArduPilot" left over from his ArduPilot R9 plane)
MODEL_NAME = ['Plane A']
G.model = L.table_from({'getModule': get_module, 'name': lambda *a: MODEL_NAME[0]})
def wake_only(dt=1.1):
    sim_time[0] += dt
    wt['wakeup'](widget)
wt['create']()
S_before = getS()
S_before.odMarker = 1
wt['create']()                    # another widget on the same model
assert getS().odMarker == 1, 'same model: state kept'
MODEL_NAME[0] = 'Plane B'
wt['create']()                    # selecting a model re-creates its widgets
S_after = getS()
assert S_after.odMarker is None, 'new model: state cleared'
S_before.odMarker2 = 2
assert getS().odMarker2 == 2, 'the state table is reset in place (the UI holds it)'
print('model switch OK')
