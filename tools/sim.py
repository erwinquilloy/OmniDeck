"""
Off-radio test harness for the OmniDeck Ethos widget.

Runs targets/ethos/main.lua (which loads x18/ or x20/ by screen width) in Lua 5.4 (lupa) against a stubbed Ethos API,
feeds ArduPilot passthrough packets encoded exactly like
AP_Frsky_SPort_Passthrough.cpp (as CRSF 0x80/0xF2 frames or S.Port frames),
checks the decoded state and renders each page to PNG.

  python tools/sim.py [outdir] [--sport] [--res 800x480]
"""
import math, os, sys
from lupa import lua54
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'targets', 'ethos')   # the loader picks x18/ or x20/ by screen width
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
          'KEY_RTN_BREAK': 33,
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
texts_xy = []     # (text, x, y) of every text drawn, cleared by the checks that read it
def draw_text(x, y, t, flags=0):
    t = str(t); tw, _ = text_size(t)
    drawn.append((t, cv.col, x))
    texts_xy.append((t, x, y))
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
    # Ethos (b14ckyy's ETHOS-API-QUIRKS, simulator 1.6.4-26.1.2): a missing file is no error and no nil,
    # but a handle of width 0 that draws nothing
    if not os.path.isfile(fp):
        stats['loads'] += 1
        return L.table_from({'_id': None, 'width': lambda self=None: 0, 'height': lambda self=None: 0})
    img = Image.open(fp).convert('RGB')
    bitmaps[id(img)] = img
    stats['loads'] += 1
    return L.table_from({'_id': id(img), 'width': lambda self=None: img.width, 'height': lambda self=None: img.height})
def draw_bitmap(x, y, bmp, w=None, h=None):
    if bmp['_id'] is None: return             # a missing file's handle draws nothing
    img = bitmaps[bmp['_id']]
    if w is not None and h is not None:   # Ethos scales the picture to w x h
        img = img.resize((int(w), int(h)))
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
# INAV 9 settings over MSPv2 (MSP2_COMMON_SETTING_INFO / _SETTING / _SET_SETTING, MSP_EEPROM_WRITE),
# as fc_msp.c answers them. type: 0 u8, 1 i8, 2 u16, 3 i16, 4 u32, 5 float; section 0x10 = control
# profile (a value per profile), 0x20 = mixer profile; look = lookup names (mode 0x40).
# OD_INAV_VER=8: an INAV before 9.0, whose telemetry MSP answers a v2 request with an error.
# OD_INAV_VER=9.0: INAV 9.0.x, whose MSP-over-telemetry replies leave out everything written with
# sbufWriteDataSafe (the setting's name, lookup names and value; fixed in 9.1.0). OD_INAV_BUG=1: that
# bug behind a 9.1 version number (the radio must show n/a, never a 0 made up from a short reply)
_iv = (os.environ.get('OD_INAV_VER', '9.1') + '.0').split('.')
INAV_VER = [int(_iv[0]), int(_iv[1]), 0]
INAV_SAFE_BUG = INAV_VER[:2] == [9, 0] or os.environ.get('OD_INAV_BUG') == '1'
INAV_PROF = {'ctl': 0, 'mix': 0}          # active control / mixer profile
INAV_ARMED = [False]
INAV_STORES = [0]
def _s(t, mn, mx, v, sec=0, look=None): return {'t': t, 'min': mn, 'max': mx, 'v': v, 'sec': sec, 'look': look}
INAV_SET = {
    'max_angle_inclination_rll': _s(3, 100, 900, 450), 'max_angle_inclination_pit': _s(3, 100, 900, 350),
    'fw_level_pitch_trim': _s(5, -10, 10, 1.5), 'roll_rate': _s(0, 4, 180, 18, 0x10 * 0), 'pitch_rate': _s(0, 4, 180, 9),
    'yaw_rate': _s(0, 1, 180, 6), 'fw_turn_assist_pitch_gain': _s(5, 0, 2, 1.0),
    'nav_fw_launch_thr': _s(2, 1000, 2000, 1700), 'nav_fw_launch_idle_thr': _s(2, 1000, 2000, 1000),
    'nav_fw_launch_accel': _s(2, 1350, 20000, 1863), 'nav_fw_launch_climb_angle': _s(0, 5, 45, 18),
    'nav_fw_launch_motor_delay': _s(2, 0, 5000, 500), 'nav_fw_launch_max_altitude': _s(2, 0, 60000, 0),
    'nav_fw_launch_max_angle': _s(0, 5, 180, 45),
    'nav_fw_cruise_thr': _s(2, 1000, 2000, 1400), 'nav_fw_min_thr': _s(2, 1000, 2000, 1200),
    'nav_fw_max_thr': _s(2, 1000, 2000, 1700), 'nav_fw_pitch2thr': _s(0, 0, 100, 10),
    'nav_fw_climb_angle': _s(0, 5, 80, 20), 'nav_fw_dive_angle': _s(0, 5, 80, 15), 'nav_fw_bank_angle': _s(0, 5, 80, 35),
    'nav_fw_cruise_speed': _s(2, 0, 65535, 1500), 'nav_fw_allow_manual_thr_increase': _s(0, 0, 1, 0, look=['OFF', 'ON']),
    'nav_rth_altitude': _s(2, 0, 65000, 5000), 'nav_rth_alt_mode': _s(0, 0, 4, 4, look=['CURRENT', 'EXTRA', 'FIXED', 'MAX', 'AT_LEAST']),
    'nav_rth_home_altitude': _s(2, 0, 65000, 0), 'nav_rth_climb_first': _s(0, 0, 2, 1, look=['OFF', 'ON', 'ON_FW_SPIRAL']),
    'nav_fw_loiter_radius': _s(4, 0, 30000, 7500),
    'nav_fw_land_approach_length': _s(4, 100, 100000, 35000), 'nav_fw_land_glide_alt': _s(2, 100, 5000, 200),
    'nav_fw_land_flare_alt': _s(2, 0, 10000, 150), 'nav_fw_land_glide_pitch': _s(1, -15, 45, 0),
    'nav_fw_land_flare_pitch': _s(1, -15, 45, 8),
    'nav_wp_radius': _s(2, 10, 10000, 100), 'nav_auto_speed': _s(2, 10, 2000, 500), 'nav_max_auto_speed': _s(2, 10, 2000, 1000),
    'nav_extra_arming_safety': _s(0, 0, 1, 1, look=['ON', 'ALLOW_BYPASS']),
    'tpa_rate': _s(0, 0, 200, [0, 20], 0x10), 'tpa_breakpoint': _s(2, 1000, 2000, [1500, 1500], 0x10),
    'fw_tpa_time_constant': _s(2, 0, 5000, [2000, 2000], 0x10),
    'nav_mc_hover_thr': _s(2, 1000, 2000, 1300), 'nav_land_maxalt_vspd': _s(2, 100, 2000, 200),
    'nav_land_minalt_vspd': _s(2, 50, 500, 50),
    'platform_type': _s(0, 0, 5, [1, 0], 0x20, look=['MULTIROTOR', 'AIRPLANE', 'HELICOPTER', 'TRICOPTER', 'ROVER', 'BOAT']),
}
for _ax, _fw, _mc in (('roll', (5, 7, 0, 50), (40, 30, 23)), ('pitch', (5, 7, 0, 50), (40, 30, 23)), ('yaw', (6, 10, None, 60), (85, 45, None))):
    for _k, _v in zip(('p', 'i', 'd', 'ff'), _fw):
        if _v is not None: INAV_SET['fw_%s_%s' % (_k, _ax)] = _s(2, 0, 255, [_v, _v + 100], 0x10)   # profile 2 differs
    for _k, _v in zip(('p', 'i', 'd'), _mc):
        if _v is not None: INAV_SET['mc_%s_%s' % (_k, _ax)] = _s(2, 0, 255, [_v + 100, _v], 0x10)   # hover tune = profile 2
def _sval(s):
    v = s['v']
    if isinstance(v, list): v = v[INAV_PROF['mix' if s['sec'] == 0x20 else 'ctl']]
    return v
def _enc(t, v):
    import struct
    return list(struct.pack({0: '<B', 1: '<b', 2: '<H', 3: '<h', 4: '<I', 5: '<f'}[t], v))
def _dec(t, b):
    import struct
    fmt = {0: '<B', 1: '<b', 2: '<H', 3: '<h', 4: '<I', 5: '<f'}[t]
    n = struct.calcsize(fmt)
    return struct.unpack(fmt, bytes(b[:n]))[0] if len(b) >= n else None
def _zname(p):
    if 0 not in p: return None, []
    i = p.index(0)
    return bytes(p[:i]).decode(), p[i + 1:]
msp_log['set'] = []
def inav_reply2(cmd, p):
    """(payload, error) for an MSPv2 request"""
    if cmd == 2: return [ord(c) for c in 'INAV'], False
    if cmd == 3: return INAV_VER, False
    if cmd == 0x2000:   # MSP2_INAV_STATUS: armingFlags u32 at bytes 10-13 (ARMED = bit 2), 8 box bytes, mixer profile
        return [0] * 9 + list((4 if INAV_ARMED[0] else 0).to_bytes(4, 'little')) + [0] * 8 + [INAV_PROF['mix']], False
    if cmd == 250:
        if INAV_ARMED[0]: return [2], True
        INAV_STORES[0] += 1
        return [], False
    if cmd in (0x1003, 0x1004, 0x1007):
        name, rest = _zname(p)
        s = INAV_SET.get(name)
        if s is None: return [2], True
        if cmd == 0x1003: return ([] if INAV_SAFE_BUG else _enc(s['t'], _sval(s))), False
        if cmd == 0x1004:
            v = _dec(s['t'], rest)
            if v is None or v < s['min'] or v > s['max']: return [2], True
            if isinstance(s['v'], list): s['v'][INAV_PROF['mix' if s['sec'] == 0x20 else 'ctl']] = v
            else: s['v'] = v
            msp_log['set'].append((name, v))
            return [], False
        out = ([] if INAV_SAFE_BUG else list(name.encode()) + [0]) + [0, 0, s['t'], s['sec'], 0x40 if s['look'] else 0]   # name\0, pgn, type, section, mode
        out += list((s['min'] & 0xFFFFFFFF).to_bytes(4, 'little')) + list((s['max'] & 0xFFFFFFFF).to_bytes(4, 'little'))
        out += [7, 0]
        out += [INAV_PROF['ctl'], 3] if s['sec'] == 0x10 else ([INAV_PROF['mix'], 2] if s['sec'] == 0x20 else [0, 0])
        if INAV_SAFE_BUG: return out, False
        for nm in (s['look'] or []): out += list(nm.encode()) + [0]
        return out + _enc(s['t'], _sval(s)), False
    return None, False
# OD_FC=BF45 / BF2025 / BF2026 / BFOLD: a Betaflight (tools/fake_bf.py) answers the MSP instead of the INAV fake
_BF = os.environ.get('OD_FC', '') if os.environ.get('OD_FC', '').startswith('BF') else ''
if _BF:
    from fake_bf import FakeBF
    _FBF = FakeBF(api={'BF45': 46, 'BF2025': 47, 'BF2026': 48, 'BFOLD': 45}[_BF])
    inav_reply2 = lambda cmd, p: _FBF.reply(cmd, p)
def fc_receive2(b, transport):
    """a complete MSPv2 request: flags, cmd lo, cmd hi, size lo, size hi, payload"""
    cmd, size = b[1] | (b[2] << 8), b[3] | (b[4] << 8)
    if len(b) < 5 + size: return False
    msp_log['req'].append(cmd)
    if INAV_VER[0] < 9: out, err, cmd = [0], True, 0      # INAV 7/8: TELEMETRY_MSP_VER_MISMATCH
    else: out, err = inav_reply2(cmd, b[5:5 + size])
    if out is None: return True
    body = [0, cmd & 0xFF, cmd >> 8, len(out) & 0xFF, len(out) >> 8] + out
    per = 5 if transport == 'sport' else 57
    for i in range(0, len(body), per):
        c = [0x40 | (0x10 if i == 0 else 0) | (0x80 if err else 0) | reply_seq[0]] + body[i:i + per]
        reply_seq[0] = (reply_seq[0] + 1) & 0x0F
        if transport == 'sport':
            c += [0] * (6 - len(c))
            item = (c[0] | (c[1] << 8), c[2] | (c[3] << 8) | (c[4] << 16) | (c[5] << 24))
            msp_reply_q.append((sim_time[0] + MSP_DELAY, item))
            if i == 0: msp_reply_q.append((sim_time[0] + MSP_DELAY, item))   # receivers can repeat a frame
        else:
            msp_reply_q.append((sim_time[0] + MSP_DELAY, [0xEA, 0xC8] + c))
    return True
rx_req = {'buf': None}
reply_seq = [0]
drop_once = {'done': False}
def fc_receive(chunk, transport):
    st = chunk[0]
    if st & 0x10:
        rx_req['buf'] = list(chunk[1:])
        rx_req['v2'] = (st >> 5) & 3 == 2
    elif rx_req['buf'] is not None:
        rx_req['buf'] += list(chunk[1:])
    b = rx_req['buf']
    if b is None or len(b) < 2: return
    if rx_req.get('v2'):
        if len(b) >= 5 and fc_receive2(b, transport): rx_req['buf'] = None
        return
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
# OD_MLRS_BRIDGE=1: mLRS (mspX) with Tx Ser Port = cbridge and the MSP-over-cbridge Tx firmware:
# the module drops CRSF MSP (0x7A) and passes raw MSP ($X< / $X>) in bridge frames: mLRS "mb"
# envelopes 0x81 / 0x82 (0x66, seq, size, up to 57 bytes) or 0xAA (chunk, size, up to 58), answered
# in the type the radio last sent (mb before any), as mLRS CommonTx/crsf_interface_tx.h does.
MLRS_BRIDGE = os.environ.get('OD_MLRS_BRIDGE') == '1'
INAV_SILENT = os.environ.get('OD_INAV_SILENT') == '1'   # stock mLRS: the radio's MSP never reaches INAV
bridge_q, bridge_rx = [], {'buf': [], 'mb': True, 'types': set()}
def _crc8x(c, b):
    c ^= b
    for _ in range(8): c = ((c << 1) ^ 0xD5) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c
def bridge_receive(raw_bytes):
    b = bridge_rx['buf']
    b += raw_bytes
    while True:
        while b and b[0] != 0x24: b.pop(0)
        if len(b) < 8: return
        if b[1] != 0x58 or b[2] != 0x3C: b.pop(0); continue
        size = b[6] | (b[7] << 8)
        if len(b) < 9 + size: return
        frame = b[3:8 + size]; crc = b[8 + size]
        del b[:9 + size]
        c = 0
        for x in frame: c = _crc8x(c, x)
        if c != crc: msp_log['crc_bad'] += 1; continue
        cmd = frame[1] | (frame[2] << 8)
        msp_log['req'].append(cmd)
        out, err = inav_reply2(cmd, frame[5:])
        if out is None: continue
        body = [0, cmd & 0xFF, cmd >> 8, len(out) & 0xFF, len(out) >> 8] + out
        c = 0
        for x in body: c = _crc8x(c, x)
        f = [0x24, 0x58, 0x21 if err else 0x3E] + body + [c]
        mb = bridge_rx['mb']
        for i in range(0, len(f), 57 if mb else 58):
            ch = f[i:i + (57 if mb else 58)]
            bridge_q.append((sim_time[0] + MSP_DELAY, (0x82, [0x66, 0, len(ch)] + ch) if mb else (0xAA, [0, len(ch)] + ch)))
def crsf_push(cmd, data):
    data = [data[i] for i in range(1, len(data) + 1)]
    if INAV_SILENT: return True
    if MLRS_BRIDGE:
        if cmd == 0x81 and len(data) >= 3 and data[0] == 0x66:
            bridge_rx['mb'] = True; bridge_rx['types'].add(cmd); bridge_receive(data[3:3 + data[2]])
        elif cmd == 0xAA and len(data) >= 2:
            bridge_rx['mb'] = False; bridge_rx['types'].add(cmd); bridge_receive(data[2:2 + data[1]])
        return True
    if cmd == 0x7A and data[:2] == [0xC8, 0xEA]: fc_receive(data[2:], 'crsf')
    return True
def pop_bridge():
    if not bridge_q or bridge_q[0][0] > sim_time[0]: return None
    c, d = bridge_q.pop(0)[1]
    return c, L.table_from(d)
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
G._POPBRIDGE = pop_bridge
L.execute('''
function _mkcrsf(q)
  return { getSensor = function() return {
      pushFrame = function(self, cmd, data) return _CRSFPUSH(cmd, data) end,
      popFrame = function(self, lo, hi)
        if lo == 0x82 or lo == 0xAA then   -- mLRS bridge (OD_MLRS_BRIDGE=1), else none
          local c, f = _POPBRIDGE(); if c == nil then return nil end
          local t = {} for i = 1, #f do t[i] = f[i] end
          return c, t
        end
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
                0x0210: 'Rx Batt', 0xF101: 'RSSI', 0xF010: 'VFR', 0x0A00: 'Airspeed'}
LINK_SENSORS = ('Rx Quality', 'Rx RSSI1', 'Flight mode')
# ArduPilot over CRSF also has the standard GPS and battery sensors (50 Hz test sets this)
AP_EXTRA = [False]    # CRSF; these exist whatever the flight stack is
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
STICK = [-1024]   # the radio's throttle stick, -1024..1024 (Ethos source "Throttle")
_stick_src = L.eval('function(get) return { value = function(self) return get() end, unit = function() return nil end, name = function() return "Throttle" end } end')(lambda: STICK[0])
def get_source(q):
    if isinstance(q, str) and q == 'Throttle': return _stick_src
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
            if SPORT or (q not in LINK_SENSORS and not (AP_EXTRA[0] and q in native_vals)): return None
        elif not (SPORT and 'appId' in q and int(q['appId']) in (0xF101, 0xF010)) \
                and not (not SPORT and 'name' in q and q['name'] == 'GPS' and 'GPS1' in native_vals):
            # (ArduPilot over CRSF: the native GPS frame does exist; a test sets GPS1/GPS2 for it)
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
G.system = L.table_from({'getSource': get_source, 'registerWidget': None, 'playFile': lambda f: played.append(os.path.basename(f)[:-4]), 'listFiles': list_files,
    # the radio's screen, as Ethos reports it (the loader in targets/ethos/main.lua reads lcdWidth)
    'getVersion': lambda: L.table_from({'lcdWidth': int(RES.split('x')[0]), 'lcdHeight': int(RES.split('x')[1]), 'board': 'X18' if int(RES.split('x')[0]) <= 480 else 'X20S'})})
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
# logs/ comes empty in the package (test43 flight logs, one file per flight)
LOGD = os.path.join(SD, 'scripts', 'omnideck', 'logs')
_sh_ = __import__('shutil'); _sh_.rmtree(LOGD, ignore_errors=True); os.makedirs(LOGD)
# the main page logos (X18-size screens, test41), as the install zip puts them on the card
import shutil as _sh
_LOGOS = os.path.join(SRC, 'logos')
if os.path.isdir(_LOGOS):
    _sh.copytree(_LOGOS, os.path.join(SD, 'scripts', 'omnideck', 'logos'), dirs_exist_ok=True)
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
    native_vals.update({'Rx Quality': 96, 'Rx RSSI1': -72 - wob, 'RSSI': 88 - wob, 'VFR': 98})
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
# OD_PANEL=n: the main page's top-right panel setting (test42: 0 minimap, 1 home arrow, 2 radar,
# 3 OmniDeck logo, 4 logo file)
if os.environ.get('OD_PANEL'): widget.topPanel = int(os.environ['OD_PANEL'])
if os.environ.get('OD_LOGO'): widget.logoFile = os.environ['OD_LOGO']   # e.g. stratos_title.png

HOME = (43.49323, 142.88785)
if os.environ.get('OD_HOME'): HOME = tuple(float(v) for v in os.environ['OD_HOME'].split(','))
st = dict(lat=HOME[0], lon=HOME[1], hlat=HOME[0], hlon=HOME[1], mode=5, armed=True, thr=55, sats=14, hdop=0.8,
          altmsl=160, volt=15.8, curr=12.3, mah=0, alt=0, vs=0, **{'as': 17.0}, gs=18.5, yaw=0, roll=0, pitch=0,
          wdir=270, wspd=4.2, wpn=0, wpd=0, wpb=0)

PAINT = [False]
# OD_COUNT=1: count the Lua instructions of every wakeup() / paint() / event() (what Ethos's
# per-call "Max instructions count reached" limit counts) and print the worst per page at exit
COUNT = os.environ.get('OD_COUNT') == '1'
CNT = {}
DIST = {}
WORST = {}
if COUNT:
    # OD_PROF_ALL=1: per-line profile of every call (sampled every 25), worst call per page printed at exit
    _cnt = L.execute('''PROF = {} PROF_ON = os.getenv("OD_PROF_ALL") == "1"
    return function(f, ...)
        local n = 0
        CALL = {}
        if PROF_ON then
          debug.sethook(function()
            n = n + 25
            local i = debug.getinfo(2, "Sl")
            if i then local k = i.short_src:match("[^/]+$") .. ":" .. i.currentline PROF[k] = (PROF[k] or 0) + 25 CALL[k] = (CALL[k] or 0) + 25 end
          end, "", 25)
        else
          debug.sethook(function() n = n + 1 end, "", 1)
        end
        local ok, e = pcall(f, ...)
        debug.sethook()
        if not ok then error(e, 0) end
        return n end''')
    def _counted(name, f):
        def g(*a):
            n = _cnt(f, *a)
            DIST.setdefault('%s p%s' % (name, widget.page), []).append(n)
            k0 = '%s p%s' % (name, widget.page)
            if n > WORST.get(k0, (0, None))[0]:
                c = L.eval('CALL')
                WORST[k0] = (n, sorted(((str(k), int(v)) for k, v in c.items()), key=lambda kv: -kv[1])[:25])
            if name == 'paint': MEM[0] = max(MEM[0], float(L.eval('collectgarbage("count")')))
            k = '%s p%s' % (name, widget.page)
            CNT[k] = max(CNT.get(k, 0), n)
        return g
    import atexit
    atexit.register(lambda: print('INSTRUCTIONS worst per call:', sorted(CNT.items(), key=lambda kv: -kv[1])))
    if os.environ.get('OD_PROF_ALL') == '1':
        atexit.register(lambda: [print('WORST', k, n, top[:8]) for k, (n, top) in sorted(WORST.items(), key=lambda kv: -kv[1][0])[:3]])
    _mem = L.eval('function() collectgarbage("collect") return collectgarbage("count") end')
    MEM = [0.0]
    atexit.register(lambda: print('LUA MEMORY KB now %.0f, peak seen %.0f' % (_mem(), MEM[0])))
if COUNT:
    wt['event0'], wt['wakeup0'], wt['paint0'] = wt['event'], wt['wakeup'], wt['paint']
    for _k in ('wakeup', 'paint', 'event'):
        wt[_k] = _counted(_k, wt[_k])
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
    widget.inavWp = 1          # INAV mission download is Off by default since the 0.3 series
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
    local n, v = debug.getupvalue(_W.wakeup0 or _W.wakeup, i)
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
    getU = L.execute('''return function(W, name) for i = 1, 300 do local n, v = debug.getupvalue(W.wakeup0 or W.wakeup, i)
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
    getMI = L.execute('''return function(W) for i = 1, 200 do local n, v = debug.getupvalue(W.wakeup0 or W.wakeup, i)
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
    # test43: the map page asks for a bigger window than the minimap; the loader fills it (and
    # its ring of one tile) within a few wakeups - the render shows the result, not the first frame
    getTL = L.execute('''return function(W) for i = 1, 300 do local n, v = debug.getupvalue(W.wakeup0 or W.wakeup, i)
        if n == nil then break end if n == "TL" then return v end end end''')
    TLm = getTL(wt)
    widget.page = 2
    for _ in range(3): step(0.2)
    assert TLm.pending() == 0 and TLm.cached() >= 20, 'map window loaded in 3 steps: pending %s cached %s' % (TLm.pending(), TLm.cached())
    print('  map page window: %d tiles cached after 3 steps' % TLm.cached())
    render('map_learned_%s.png' % tag, 2)
    widget.missionFile = 'test.waypoints'
    do_write(); do_read()
    for _ in range(40): step(0.2)
    render('main_%s.png' % tag, 1)
    for _ in range(40): step(0.2)
    widget.page = 2
    for _ in range(3): step(0.2)
    render('map_%s.png' % tag, 2)
    for _ in range(3): wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_RIGHT'], 0, 0)
    widget.page = 2
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
# test43: no PLANE / HOME view button (the "Map view" setting stays); + and - square, >= 48 px
assert widget.zoomMode == 0 and b.auto is None, 'aircraft-centred by default, no view button'
assert b.plus.w == b.plus.h and b.plus.w >= 48 and b.minus.w == b.plus.w, 'big square zoom buttons %s' % b.plus.w
assert b.minus.y > b.plus.y + b.plus.h, 'minus under plus'
# near misses (tester, X18 2026-11-11): a quarter of the button around it, the gap split in the middle,
# the press point counts; a tap away from the buttons still turns the page
def tapxy(x0, y0, x1=None, y1=None):
    wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_START'], x0, y0)
    wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], x0 if x1 is None else x1, y0 if y1 is None else y1)
pad = b.plus.w // 4
gap_mid = (b.plus.y + b.plus.h + b.minus.y) / 2
cxb = b.plus.x + b.plus.w // 2
for (tx, ty, d, what) in ((cxb, b.plus.y - pad + 2, -1, 'above +'), (b.plus.x - pad + 2, b.plus.y + 5, -1, 'left of +'),
                          (cxb, gap_mid - 1, -1, 'gap, upper half'), (cxb, gap_mid + 1, 1, 'gap, lower half'),
                          (cxb, b.minus.y + b.minus.h + pad - 2, 1, 'below -')):
    widget.level = 5
    tapxy(tx, ty)
    assert widget.page == 2 and widget.level == 5 + d, 'near miss %s: page %s level %s' % (what, widget.page, widget.level)
widget.level = 5
tapxy(cxb, b.plus.y + 5, b.plus.x - pad - 8, b.plus.y + 5)        # pressed on +, lifted off to the left
assert widget.page == 2 and widget.level == 4, 'press on +, lift outside: %s %s' % (widget.page, widget.level)
widget.level = lvl0
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_RIGHT'], 0, 0)
assert widget.level == lvl0 - 1, 'rotary'
# test42 page cycle: main, map, messages for ArduPilot only (INAV/BF send none); the flight stats
# and sensor check pages only when switched on (both off by default)
ENTER = lambda: wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.msgPage == 0 and widget.statsPage == 0 and widget.checkPage == 0, 'page settings default'
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_START'], 200, 200)
wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], 200, 200)
assert widget.page == (1 if NATIVE else 3), 'tap changes page (messages for ArduPilot only): %s' % widget.page
if not NATIVE:
    ENTER()
    assert widget.page == 1, 'stats and sensor check are off by default: %s' % widget.page
widget.checkPage = 1; widget.page = 2
ENTER()
if not NATIVE:
    assert widget.page == 3, 'messages before the sensor check'
    ENTER()
assert widget.page == 5, 'sensor check page switched on: %s' % widget.page
cv = Canvas(); drawn.clear(); wt['paint'](widget); cv.img.save(os.path.join(OUT, 'check_%s.png' % tag))
assert any('SENSOR CHECK' in t for t, c, x in drawn), 'sensor check page draws'
# rows that don't fit scroll: wheel right = further down, drag up = further down; zoom untouched
mx, rh, lv0, tz0 = widget.chkMax, widget.chkRowH, widget.level, widget.tz
for _ in range(50): wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_RIGHT'], 0, 0)
assert widget.chkScroll == mx, ('wheel to the end', widget.chkScroll, mx)
drawn.clear(); wt['paint'](widget)
assert any(t == 'rssi' for t, c, x in drawn), 'last sensor row visible at the end of the list'
if mx > 0:
    cv = Canvas(); drawn.clear(); wt['paint'](widget); cv.img.save(os.path.join(OUT, 'check_scrolled_%s.png' % tag))
    TE = consts['EVT_TOUCH']
    wt['event'](widget, TE, consts['TOUCH_START'], 300, 100)
    wt['event'](widget, TE, consts['TOUCH_MOVE'], 300, 100 + 2 * rh)
    wt['event'](widget, TE, consts['TOUCH_END'], 300, 100 + 2 * rh)
    assert widget.chkScroll == max(0, mx - 2) and widget.page == 5, ('drag down shows earlier rows', widget.chkScroll, widget.page)
for _ in range(50): wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_LEFT'], 0, 0)
assert widget.chkScroll == 0, 'wheel back to the top'
assert widget.level == lv0 and widget.tz == tz0, 'wheel on the sensor check page does not zoom the map'
print('sensor check scroll OK (rows hidden at the top: %d)' % mx)
ENTER()
assert widget.page == 1, 'enter wraps to page 1'
widget.msgPage = 1 if NATIVE else 2; widget.page = 2      # messages forced On (INAV) / Off (ArduPilot)
ENTER()
assert widget.page == (3 if NATIVE else 5), 'messages page setting On/Off: %s' % widget.page
widget.msgPage, widget.checkPage, widget.page = 0, 0, 1
os.remove(os.path.join(OUT, '_tmp.png'))
MAPmod = L.execute(open(os.path.join('x18' if W <= 480 else 'x20', 'map.lua'), encoding='utf8').read())   # the copy the loader picked
print('input checks OK')


# ------------------------------------------------------------------ flight summary
getV = L.execute('''return function(W, name) for i = 1, 300 do local n, v = debug.getupvalue(W.wakeup0 or W.wakeup, i)
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
# test43: the flight is also added to flights.txt (one entry per summary)
# test43: the flight is saved as logs/<model>-<YYYY-MM-DD>-<HHMMSS>.txt, a file per flight
import re as _re
def log_entries(): return len(os.listdir(LOGD))
_logs = sorted(os.listdir(LOGD))
assert len(_logs) == 1 and _re.match(_re.escape(SIM_MODEL) + r'-\d{4}-\d\d-\d\d-\d{6}\.txt$', _logs[0]), 'log file name %s' % _logs
last_entry = open(os.path.join(LOGD, _logs[0]), encoding='utf8').read()
assert ('Model          ' + SIM_MODEL) in last_entry and 'Flight time' in last_entry and 'Last position' in last_entry, 'flight log %s' % last_entry
log_n = log_entries()
f = FS.last()
print('summary: time %.0f dist %.0f home %s alt %s gspd %s as %s used %s volt %s curr %s lq %s rssi %s lost %s' % (
    f.time, f.dist, f.maxHome, f.maxAlt, f.maxGspd, f.maxAspd, f.used, f.minVolt, f.maxCurr, f.minLq, f.minRssi, f.lost))
if SPORT:
    # both Ethos copies (test40 change; X20 since test41b, X18 since test42): LQ = VFR (0xF010),
    # RSSI as the FC's own F.Port % (INAV/BF 0-100, ArduPilot 0-50 so x2, max 100)
    want = (100,) if S.fc == 'ArduPilot' else (87, 88)
    assert S.rssi in want and S.lq == 98, 'S.Port: LQ from VFR, RSSI %% (%s %s %s)' % (S.rssi, S.lq, S.fc)
elif not INAV:
    assert S.lq == 96 and S.rssi in (-72, -73), 'CRSF has LQ and RSSI (%s %s)' % (S.lq, S.rssi)
assert f.time > 100 and f.dist > 3000 and abs(f.maxAlt - 120) < 1 and f.lost == 0, 'summary values'
render('summary_%s.png' % tag, 4)
first_time = f.time

wt['event'](widget, consts['EVT_KEY'], consts['KEY_ROTARY_LEFT'], 0, 0)
assert widget.page == 4, 'rotary stays on the summary'
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 1, 'enter leaves the summary (sensor check off by default: back to page 1)'
widget.page = 3 if not NATIVE else 2
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 1, 'the summary is not in the cycle with "Flight stats page" Off: %s' % widget.page
widget.statsPage = 1                       # test42: switched on, it joins the cycle after a flight
widget.page = 3 if not NATIVE else 2
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 4, 'summary joins the cycle with "Flight stats page" On'
widget.statsPage = 0

st['armed'] = True                        # arming closes it, back to the main page
for _ in range(5): step(0.2)
assert widget.page == 1, 're-arm closes the summary to main, page %s' % widget.page
for _ in range(15): step(0.2)             # 3 s on the bench: too short to count
st['armed'] = False
for _ in range(10): step(0.2)
assert widget.page == 1 and FS.last().time == first_time, 'short arm shows nothing'
assert log_entries() == log_n, 'short arm adds no log file'

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
    volts = [(t, x) for t, c, x in ops if t.endswith('V') and t not in ('TX %.1fV' % TX_VOLTS[0], SIM_MODEL)
             and not t.startswith(('AVE CELL ', 'BATT'))]
    assert volts and all(t == '15.8V' and x > W * 0.56 for t, x in volts), 'voltage on the gauge only %s' % volts
    # the block's label line: the average cell (4 cells auto from 15.8 V)
    assert any(t == 'AVE CELL 3.95V' for t, c, x in ops), 'battery block label %s' % [t for t, c, x in ops if 'CELL' in t or t.startswith('BATT')]
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
# test42: the tapes are labelled with the unit alone; the blocks' second row is ALT | AS / GS
assert 'km/h' in txt and 'm' in txt and not any(t.startswith('ALT ') or t.startswith('AS km') for t in txt), 'unit-only tape labels'
assert not any(t.startswith('GSPD') for t in txt), 'no GSPD block'
assert 'ALT' in txt and '%dm' % round(S.alt) in txt, 'ALT block %s' % txt
f = FS.live()
def dist_txt(m): return '%dm' % int(m + 0.5) if m < 999.5 else '%.2fkm' % (m / 1000)
assert dist_txt(999.4) == '999m' and dist_txt(999.6) == '1.00km' and dist_txt(3293.79) == '3.29km'
NOTES = H >= 320            # the small notes are left out only on the narrowest screens
assert 'HOME' in txt and (not NOTES or 'TOT ' + dist_txt(f.dist) in txt), 'total distance in the home block %s' % txt
assert 'TOTAL DIST' not in txt, 'TOTAL DIST block gave its place to FLIGHT TIME %s' % txt
import re
assert 'FLIGHT TIME' in txt and any(re.fullmatch(r'\d\d:\d\d', t) for t in txt), 'flight time block %s' % txt
assert 'MAX GS km/h' not in txt and 'MAX AS km/h' not in txt, 'max speeds are on the summary only %s' % txt
if S.aspd is not None:
    assert 'AS / GS km/h' in txt and '%d / %d' % (round(S.aspd * 3.6), round(S.gspd * 3.6)) in txt, 'AS / GS block %s' % txt
else:
    assert 'GS km/h' in txt and str(round(S.gspd * 3.6)) in txt, 'GS block %s' % txt
assert f.maxCurr is None or not NOTES or 'MAX %.1fA' % f.maxCurr in txt, 'max current in the current block %s' % txt
assert cv.img.getpixel((3, H // 3)) != (20, 20, 20), 'horizon shows through the speed tape'
# test42: the vario strip has no background, the horizon shows through it (top of the strip,
# away from the bar, which grows from the middle)
_bodyY = round(H * 0.09); _bodyH = H - _bodyY - round(H * 0.075)
_vy = _bodyY + max(18, math.floor(_bodyH * 0.08)) + 16 + 3
assert cv.img.getpixel((round(W * 0.56) - 3, _vy)) != (20, 20, 20), 'horizon shows through the vario strip'
if NATIVE:
    # no airspeed: the tape's own value box is in the GS green, and no second GS box
    gs = [t for t, c, x in ops if c == GS_COL]
    assert f.maxAspd is None and gs == [str(round(S.gspd * 3.6))], 'tape shows ground speed in green, no GS box %s' % gs
else:
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
mb = widget.btns.minus
assert mb.x + mb.w <= W and mb.y + mb.h <= H, 'zoom buttons on the screen'
widget.page = 1

# no GPS fix: ArduPilot sends 0,0, which is no position; the map centres on the last good one
if not NATIVE and not TILES:
    # test43: kept in memory only (a reboot or a model switch clears it); no lastpos.txt
    posf = os.path.join(SD, 'scripts', 'omnideck', 'lastpos.txt')
    assert not os.path.isfile(posf), 'lastpos.txt is no longer written'
    la, lo = S.lat, S.lon
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

# ArduPilot over CRSF (ELRS) sends no 0x0800 in passthrough, only the native CRSF GPS frame:
# the position must follow the native sensor (X20 + ELRS, 2026-11-08: map kept the saved position).
# X20 and X18 (both copies have the fix since test42).
if not NATIVE and not SPORT:
    keep_pos = (st['lat'], st['lon'])
    def step_no800(dt=0.2):
        sim_time[0] += dt
        feed([(a, v) for a, v in packets(st) if a != 0x0800])
        native_vals.update({'GPS1': st['lat'], 'GPS2': st['lon']})
        for _ in range(4): wt['wakeup'](widget)
    for k in range(20):
        st['lat'], st['lon'] = project(keep_pos[0], keep_pos[1], 30 * (k + 1), 70)
        step_no800(0.2)
    assert S.fc == 'ArduPilot', 'still passthrough: %s' % S.fc
    assert abs(S.lat - st['lat']) < 1e-6 and abs(S.lon - st['lon']) < 1e-6, \
        'native CRSF position followed (%s, %s) vs (%s, %s)' % (S.lat, S.lon, st['lat'], st['lon'])
    native_vals.pop('GPS1', None); native_vals.pop('GPS2', None)
    st['lat'], st['lon'] = keep_pos
    for _ in range(12): step(0.2)
    assert abs(S.lat - st['lat']) < 1e-5, '0x0800 back in charge'
    print('ArduPilot CRSF native position OK')

# ArduPilot over Crossfire at 50 Hz: passthrough every 3 s, but the CRSF GPS frame every 1 s and the
# battery frame every 2 s. Between bursts ground speed, satellites, distance to home and the battery
# follow those sensors; at 150 Hz (passthrough every 0.2 s) they stay on passthrough.
if not NATIVE and not SPORT:
    S2 = Tm.s
    assert S2.homeLat is not None, 'home known before the 50 Hz test'
    AP_EXTRA[0] = True
    native_units['GPS speed'] = consts['UNIT_KILOMETER_PER_HOUR']
    def crsf_sensors(gs_kmh, sats, volt, curr, mah, lat, lon):
        native_vals.update({'GPS speed': gs_kmh, 'GPS Satellites': sats, 'Rx Batt': volt,
                            'Rx Current': curr, 'Rx Cons': mah, 'GPS1': lat, 'GPS2': lon})
    def tick(burst):
        sim_time[0] += 0.2
        feed([(a, v) for a, v in packets(st) if a != 0x0800] if burst else [])
        for _ in range(4): wt['wakeup'](widget)
    def link_msg(t):
        crsf_q.append([0xF1, 6] + list(t.encode()) + [0])
    # ELRS: ArduPilot keeps it on its fast schedule, so nothing here may change (3 s windows)
    link_msg('ELRS: Link rate 500Hz, Telemetry rate 62Hz')
    tick(True)
    crsf_sensors(72.0, 11, 15.1, 7.5, 3333, st['lat'], st['lon'])
    for _ in range(8): tick(False)
    assert S2.sats == min(st['sats'], 15), 'ELRS: no fill from CRSF sensors (sats %s)' % S2.sats
    for _ in range(9): tick(False)            # 3.4 s without passthrough
    assert not Tm.alive(), 'ELRS: lost after 3 s as before'
    for _ in range(5): tick(True)
    # TBS Crossfire at 50 Hz: ArduPilot's own message switches the slow-link handling on
    link_msg('CRSFv3: Link rate 50Hz, Telemetry rate 50Hz')
    tick(True)
    assert S2.crsfSlow == True, 'CRSFv3 50 Hz message read'
    # 150 Hz: passthrough every 0.2 s, CRSF sensors deliberately different: passthrough wins
    crsf_sensors(999.0, 3, 99.0, 99.0, 9999, st['lat'], st['lon'])
    for _ in range(10): tick(True)
    assert abs(S2.gspd - st['gs']) < 1.0 and S2.sats == min(st['sats'], 15) and abs(S2.volt - st['volt']) < 0.2,         '150 Hz: passthrough values kept (gs %s sats %s volt %s)' % (S2.gspd, S2.sats, S2.volt)
    # a 50 Hz message on a link that never pauses (an ELRS link named before the receiver answered):
    # still off - it also takes one real gap that ends with a burst
    assert not S2.crsfGap, 'no gap seen yet on a fast link'
    for _ in range(10): tick(False)           # 2 s gap ...
    tick(True)                                # ... ended by a burst: a slow link
    assert S2.crsfGap == True, 'gap seen'
    # 50 Hz: one burst, then CRSF frames only. The aircraft has moved 400 m since the burst.
    tick(True)
    lat1, lon1 = project(st['lat'], st['lon'], 400, 200)
    crsf_sensors(72.0, 11, 15.1, 7.5, 3333, lat1, lon1)
    for _ in range(3): tick(False)            # 0.6 s: passthrough still fresh enough
    assert S2.sats == min(st['sats'], 15), 'no fill within 1 s of a burst: sats %s' % S2.sats
    for _ in range(5): tick(False)            # 1.6 s after the burst
    exp_d = Tm.distBrg(lat1, lon1, S2.homeLat, S2.homeLon)[0]
    assert abs(S2.gspd - 20.0) < 0.05, '50 Hz: ground speed from CRSF GPS speed, got %s' % S2.gspd
    assert S2.sats == 11 and abs(S2.volt - 15.1) < 1e-6 and abs(S2.curr - 7.5) < 1e-6 and S2.mah == 3333,         '50 Hz: sats/battery from CRSF (%s %s %s %s)' % (S2.sats, S2.volt, S2.curr, S2.mah)
    assert abs(S2.homeDist - exp_d) < 1, '50 Hz: home distance from the CRSF position %s vs %s' % (S2.homeDist, exp_d)
    assert Tm.alive(), '50 Hz: link still alive 1.6 s after a burst'
    for _ in range(9): tick(False)            # 3.4 s: past the old 3 s window, no lost-link flash
    assert Tm.alive(), '50 Hz: still alive 3.4 s after a burst'
    crsf_sensors(90.0, 12, 15.0, 7.0, 3400, lat1, lon1)
    for _ in range(5): tick(False)            # 4.4 s: the next GPS / battery values come through
    assert abs(S2.gspd - 25.0) < 0.05 and S2.sats == 12 and S2.mah == 3400, '50 Hz: values keep moving'
    tick(True)                                # the next burst takes over again
    assert S2.sats == min(st['sats'], 15) and abs(S2.volt - st['volt']) < 0.2, 'burst: passthrough back in charge'
    link_msg('CRSFv3: Link rate 150Hz, Telemetry rate 150Hz')
    tick(True)
    assert not S2.crsfSlow, '150 Hz message: slow-link handling off'
    AP_EXTRA[0] = False
    for k in ('GPS speed', 'GPS Satellites', 'Rx Batt', 'Rx Current', 'Rx Cons', 'GPS1', 'GPS2'): native_vals.pop(k, None)
    for _ in range(12): step(0.2)
    print('ArduPilot CRSF 50 Hz fill OK')

# more than 15 satellites: passthrough has 4 bits, ArduPilot sends at most 15. S.Port: "15+";
# CRSF: the real count from the standard GPS frame's "GPS Satellites"
if not NATIVE:
    st['sats'] = 18
    for _ in range(6): step(0.2)
    assert Tm.s.sats == 15 and Tm.s.satsPlus == True, 'capped at 15: %s %s' % (Tm.s.sats, Tm.s.satsPlus)
    assert any(t.endswith(' 15+') for t, c, x in main_drawn()), 'top bar shows 15+'
    if not SPORT:
        AP_EXTRA[0] = True
        native_vals['GPS Satellites'] = 18
        for _ in range(8): step(0.2)
        assert Tm.s.sats == 18 and not Tm.s.satsPlus, 'CRSF real count: %s %s' % (Tm.s.sats, Tm.s.satsPlus)
        ops = main_drawn()
        assert any(t == '3D 18' for t, c, x in ops) and not any(t.endswith('15+') for t, c, x in ops), 'top bar shows 3D 18'
        native_vals.pop('GPS Satellites', None); AP_EXTRA[0] = False
    st['sats'] = 14
    for _ in range(20): step(0.2)
    assert Tm.s.sats == 14 and not Tm.s.satsPlus, 'back under 15: %s' % Tm.s.sats
    print('satellites above 15 OK')

# Betaflight 4.5: CRSF "GPS alt" is the GPS's sea-level altitude while disarmed and the height
# above the arming point once armed (flight/position.c). The reading at the arm edge was sea
# level, so everything after it came out a field elevation too low (X18 + BF + TBS, MAX ALT -278 m,
# 2026-11-08). Newer Betaflight sends sea level all along, which must still be subtracted.
if NATIVE and not SPORT and not INAV:
    FIELD = 300.0
    def gstep(v, n=1):
        for _ in range(n):
            native_vals['GPS alt'] = v
            step(0.2)
    st['armed'] = False
    gstep(FIELD, 35)                    # 7 s: "GPS alt" is found (sources are looked up again every 5 s)
    st['armed'] = True
    gstep(FIELD, 2)                     # armed in the mode text before the GPS frame jumps
    gstep(0.0, 3); gstep(25.0, 5)
    assert abs(S.alt - 25) < 1, 'BF 4.5: height above the arming point, not %s' % S.alt
    st['armed'] = False
    gstep(FIELD, 10)
    st['armed'] = True
    gstep(FIELD, 5); gstep(FIELD + 40, 5)
    assert abs(S.alt - 40) < 1, 'sea level all along: height above home, not %s' % S.alt
    st['armed'] = False
    native_vals.pop('GPS alt', None)
    for _ in range(30): step(0.2)
    print('Betaflight GPS altitude OK')

# home-centred view: armed -> closest step; flying out only zooms out, keeping the aircraft
# inside the map; flying back does not zoom in again
if not TILES:
    MAPr = getV(wt, 'MAP')
    # aircraft-centred and zoomed in so home is off the map: a small home icon on the edge
    widget.zoomMode = 0; widget.page = 2; widget.level = 1
    st['lat'], st['lon'] = project(HOME[0], HOME[1], 600, 30)     # well away from home
    for _ in range(10): step(0.2)
    cv = Canvas(); tris.clear(); texts_xy.clear(); wt['paint'](widget)
    rx, ry, rw_, rh_ = 0, round(H * 0.09), W, H - round(H * 0.09)
    # test43: home is the HUD's white H in a framed box (with the distance) kept inside the map
    homes = [(x, y) for tt, x, y in texts_xy if tt == 'H']
    assert len(homes) == 1, 'one home H on the map %s' % homes
    hx, hy = homes[0]
    assert hx < 60 or hx > W - 60 or hy < ry + 40 or hy > H - 70, 'home H on the edge (%s, %s)' % (hx, hy)
    assert not [p for c, p in tris if c == (80, 200, 255)], 'no house icon any more'
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

# home direction (test42): the top-right "Home arrow" panel - the OmniDeck mark's arrow, two
# triangles sharing the tip and the notch - and the HUD's H (only while home is within 45 degrees)
ARROW_FILL = (242, 245, 248)
def arrow_deg():
    main_drawn()
    tiles_y = round(H * 0.09) + min(W - round(W * 0.56) - 3, round((H - round(H * 0.09) - round(H * 0.075)) * 0.46))
    pts = [p for c, p in tris if c == ARROW_FILL and max(p[1], p[3], p[5]) <= tiles_y + 1 and p[0] > W * 0.56]
    if not pts: return None
    assert len(pts) == 2 and pts[0][:2] == pts[1][:2] and pts[0][4:6] == pts[1][2:4], 'arrow: tip and notch shared %s' % pts
    tx, ty, nx, ny = pts[0][0], pts[0][1], pts[0][4], pts[0][5]
    return math.degrees(math.atan2(tx - nx, ny - ty)) % 360
HUD_W = round(W * 0.56)
HUD_TAPE = max(46, math.floor(HUD_W * 0.17))
HUD_CX = HUD_TAPE + 4 + (HUD_W - 2 * HUD_TAPE - (8 if (H - round(H * 0.09) - round(H * 0.075)) >= 240 else 6) - 8) / 2
def h_x():
    xs = [x for t, c, x in main_drawn() if t == 'H']
    return xs[0] if xs else None
keep_panel = widget.topPanel
widget.topPanel = 1
lat0 = st['lat']
st['lat'] = lat0 + 0.006                  # ~670 m north of where it stands: home ~670 m south
st['armed'] = False
step(0.2); step(0.2)
assert arrow_deg() is None, 'Home arrow panel shows the logo before arming'
# arm where it stood (INAV/BF set home where they arm), then fly the 670 m north again
st['lat'] = lat0
st['armed'] = True
step(0.2); step(0.2)
st['lat'] = lat0 + 0.006
step(0.2); step(0.2)
for yaw in (0, 20, 340, 90, 200, 160):   # home is south (bearing ~180)
    st['yaw'] = yaw
    step(0.2); step(0.2)
    got = arrow_deg()
    want = (S.homeBrg - S.yaw) % 360
    assert got is not None and abs((got - want + 180) % 360 - 180) < 8, 'yaw %d: arrow %s, want %.0f' % (yaw, got, want)
    rel = (want + 180) % 360 - 180
    hx = h_x()
    # test43: the strip's width is +-90 deg for the H; past 90 it parks on home's end, and it goes
    # only with home within 5 deg of the tail
    tw_h = 2 * (HUD_CX - HUD_TAPE - 4)
    if abs(rel) <= 174:
        assert hx is not None, 'yaw %d: H shown for home %.0f deg off the nose' % (yaw, rel)
        assert abs(rel) < 10 or (hx > HUD_CX) == (rel > 0), 'yaw %d: H on the side of home (%.0f, x %s)' % (yaw, rel, hx)
        want_x = HUD_CX + max(-90, min(90, rel)) * tw_h / 180
        assert abs(hx - want_x) <= 24, 'yaw %d: H at %s, want ~%.0f (rel %.0f)' % (yaw, hx, want_x, rel)
        if abs(rel) >= 90:
            assert abs(abs(hx - HUD_CX) - tw_h / 2) <= 24, 'yaw %d: H parked on the end' % yaw
    elif abs(rel) >= 176:
        assert hx is None, 'yaw %d: no H for home %.0f deg off the nose' % (yaw, rel)
    if yaw == 160: render('main_homearrow_%s.png' % tag, 1)   # home 20 deg right: H and the panel arrow
st['lat'] = lat0
st['yaw'] = 0
st['armed'] = False
widget.topPanel = keep_panel
step(0.2); step(0.2)
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
# page switch (user 2026-11-27): default "Up previous, down next"; middle does nothing
assert fresh.pageSwMode == 2, ('page switch action default', fresh.pageSwMode)
PSW = [0]
G._PSW = lambda: PSW[0]
widget.pageSource = L.eval('{ name = function() return "SC" end, value = function() return _PSW() end }')
_sa = widget.sumAuto; widget.sumAuto = 0   # the summary opening on disarm is not the switch
widget.pageSwMode, widget.page = 2, 2
step(0.2); step(0.2)
assert widget.page == 2, ('page switch middle: page stays', widget.page)
PSW[0] = 1024; step(0.2); step(0.2)
_nx = widget.page
assert _nx != 2, 'page switch down: next page'
PSW[0] = 0; step(0.2); assert widget.page == _nx, 'back to middle: page stays'
PSW[0] = -1024; step(0.2); step(0.2)
assert widget.page == 2, ('page switch up: previous page', widget.page)
PSW[0] = 0; step(0.2); PSW[0] = -1024; step(0.2)
assert widget.page == 1, ('page switch up again: previous page', widget.page)
PSW[0] = 0; step(0.2)
# a switch that reads -100 / 0 / 100 (X20S 2026-11-27: nothing happened with a fixed +-300)
widget.swScale, widget.swLast3, widget.page = None, None, 2
step(0.2)
PSW[0] = 100; step(0.2); step(0.2)
assert widget.page != 2, ('-100..100 switch down: next page', widget.page)
PSW[0] = 0; step(0.2); PSW[0] = -100; step(0.2); step(0.2)
assert widget.page == 2, ('-100..100 switch up: previous page', widget.page)
PSW[0] = 0; step(0.2)
widget.pageSource, widget.sumAuto = None, _sa
print('page switch (up previous, down next) OK')
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
             'ALTH': 'althold', 'CHIR': 'chirp',
             'AIR': 'airmode'}   # acro with airmode on: shown as AIR, spoken "airmode" (test35-42 said ACRO)
    clips = {l.split('|')[0] for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'phrases.psv'), encoding='utf8') if '|' in l and l[0] != '#'}
    for m, clip in MODES.items():
        st['fm'] = m
        assert hear() == [clip], '%s -> %s' % (m, played)
        assert clip in clips, 'no phrase for ' + clip
        assert S.armed is True, m + ' reads as armed'
        if m == 'AIR': assert S.mode == 'AIR', 'AIR shown as AIR, not %s' % S.mode
        if m == 'ACRO': assert S.mode == 'ACRO', 'ACRO shown as ACRO, not %s' % S.mode
    # Betaflight disarmed: airmode on (permanent or by switch) "AIR*", airmode off "ACRO*"
    for raw, want in (('AIR*', 'AIR'), ('ACRO*', 'ACRO')):
        st['fm'] = raw
        hear()
        assert S.mode == want and S.armed is False, '%s -> %s armed %s' % (raw, S.mode, S.armed)
    st['fm'] = 'ACRO'                         # armed again for the checks below
    hear()
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
assert FS.last() is None, 'Talon Pro -> Plane A: the earlier flights are gone'
st['armed'] = True
for _ in range(60): step(0.2)
st['armed'] = False
for _ in range(10): step(0.2)
assert FS.last() is not None and widget.page == 4, 'a flight on Plane A before the switch'
MODEL_NAME[0] = 'Plane B'
wt['create']()                    # selecting a model re-creates its widgets
S_after = getS()
assert S_after.odMarker is None, 'new model: state cleared'
# test43: a fresh start - no last flight or flight time from the old model
assert FS.last() is None and FS.live() is None, 'new model: flight summary cleared'
# nor the old model's last position: with no fix yet the map has no LAST position
_pg = widget.page; widget.page = 2
cv = Canvas(); drawn.clear(); wt['paint'](widget)
assert 'LAST' not in [t for t, c, x in drawn], 'new model: no last position on the map'
widget.page = _pg
if True:
    # the welcome is said again after a model switch, as Yaapu does (X20 since test41b, X18 since test42)
    vmod.setVoice('Aria'); del played[:]
    for _ in range(6): wake_only(0.3)
    assert 'omniready' in played, 'welcome after a model switch, got %s' % played
    MODEL_NAME[0] = 'Plane B'; wt['create'](); del played[:]   # same model again: no welcome
    for _ in range(6): wake_only(0.3)
    assert 'omniready' not in played, 'no welcome without a switch, got %s' % played
    vmod.setVoice('off')
# the 1 s check in wakeup (Ethos re-creates the widget before model.name() changes) also clears
# the flight and leaves the summary page
st['armed'] = True
for _ in range(60): step(0.2)
st['armed'] = False
for _ in range(10): step(0.2)
assert FS.last() is not None and widget.page == 4, 'flight on Plane B'
# X18: Ethos builds the new model's widget ~2 s before model.name() changes, so the switch is
# seen by this check, not create(): the welcome must come from here too
vmod.setVoice('Aria'); del played[:]
MODEL_NAME[0] = 'Plane C'
for _ in range(3): wake_only(0.4)
assert FS.last() is None and widget.page != 4, 'wakeup model check: fresh start, page %s' % widget.page
for _ in range(6): wake_only(0.3)
assert 'omniready' in played, 'welcome after a switch seen by the wakeup check, got %s' % played
vmod.setVoice('off')
S_before.odMarker2 = 2
assert getS().odMarker2 == 2, 'the state table is reset in place (the UI holds it)'
print('model switch OK')

# THR: ArduPilot's own throttle output (0x5001); INAV / Betaflight send none, so the radio's
# throttle stick (label THR either way)
widget.page = 1
for stick, want in ((-1024, 0), (0, 50), (1024, 100), (410, 70)):
    STICK[0] = stick
    for _ in range(3): step(0.2)
    cv = Canvas(); drawn.clear(); wt['paint'](widget)
    txt = [t for t, c, x in drawn]
    S = getS()
    if NATIVE:
        assert S.thr == want and 'THR' in txt and '%d%%' % want in txt, 'stick %d -> %s %s' % (stick, S.thr, txt[-12:])
    else:
        assert 'THR' in txt and S.thr == st['thr'], 'ArduPilot THR %s (sent %s)' % (S.thr, st['thr'])
print('throttle OK (%s)' % ('stick' if NATIVE else 'ArduPilot output'))

# Flight stats page (user 2026-11-10): On = always in the page cycle, in flight too (the flight in
# progress); Off = never. Either way the disarm opens the summary, and it goes back to the main page
# after SUM_SHOW_S (15 s); a stats page opened by hand stays.
def page_txt(page):
    widget.page = page
    global cv
    cv = Canvas(); drawn.clear(); wt['paint'](widget)
    return [t for t, c, x in drawn]
MODEL_NAME[0] = 'Stats Plane'
for _ in range(3): wake_only(0.4)               # a fresh model: no flight yet
widget.statsPage, widget.sumAuto = 1, 1
st['armed'] = False
for _ in range(5): step(0.2)
assert 'No flight yet' in page_txt(4), 'stats page before any flight'
widget.page = 3 if not NATIVE else 2
for _ in range(4):
    if widget.page == 4: break
    wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
assert widget.page == 4, 'On: stats page in the cycle before the first flight (page %s)' % widget.page
st['armed'] = True
for _ in range(100): step(0.2)                  # 20 s armed
txt = page_txt(4)
assert 'FLIGHT TIME (NOW)' in txt, 'in flight the stats page shows the flight in progress %s' % txt[:12]
for _ in range(100): step(0.2)                  # opened by hand: stays, also past 15 s
assert widget.page == 4, 'stats page opened by hand stays in flight (page %s)' % widget.page
for statsPage in (1, 0):
    widget.statsPage = statsPage
    widget.page = 1
    st['armed'] = True
    for _ in range(60): step(0.2)
    st['armed'] = False
    for _ in range(10): step(0.2)
    assert widget.page == 4, 'statsPage %d: disarm opens the summary' % statsPage
    assert 'FLIGHT TIME' in page_txt(4)
    for _ in range(40): step(0.2)               # 8 s more (about 10 s open): still there
    assert widget.page == 4, 'statsPage %d: summary still open before 15 s' % statsPage
    for _ in range(40): step(0.2)               # past 15 s (opened ~1 s into the disarm steps): back to main
    assert widget.page == 1, 'statsPage %d: summary closed to main after 15 s (page %s)' % (statsPage, widget.page)
# moving away first cancels the timer
st['armed'] = True
for _ in range(60): step(0.2)
st['armed'] = False
for _ in range(10): step(0.2)
assert widget.page == 4
page_txt(4)                                     # drawn (on the radio every update): seen
widget.page = 2
for _ in range(100): step(0.2)
assert widget.page == 2, 'left the summary by hand: no jump back to main'
widget.statsPage = 0
print('flight stats page OK')

# ---- PARAMS page (6): ArduPilot only, S.Port / F.Port (MAVlite to a copy of ArduPilot's code)
sys.path.insert(0, HERE)
from fake_mavlite import FakeAP

def _plist_row(name, qon, path):
    # the row number (1-based) of a parameter on the PARAMS page, from plist.lua (Q rows hidden when not qon)
    import re as _re
    n = 0
    for _l in open(path, encoding='utf-8'):
        m = _re.match(r'\s*\{ "[^"]+", "([A-Z0-9_]+)"', _l)
        if not m: continue
        if not qon and '"q" }' in _l: continue
        n += 1
        if m.group(1) == name: return n
    raise KeyError(name)
_PL = os.path.join(SRC, 'x20' if W > 480 else 'x18', 'plist.lua')
NEWNAV = True   # two-column PARAMS page on X20 and X18 (Marcin 2026-11-15)

def _plist_pos(name, qon, path):
    # (tab number, row in that tab), both 0-based, on the two-column PARAMS page (X20 / EdgeTX)
    import re as _re
    tabs, rows = [], {}
    for _l in open(path, encoding='utf-8'):
        m = _re.match(r'\s*\{ "([^"]+)", "([A-Z0-9_]+)"', _l)
        if not m: continue
        if not qon and '"q" }' in _l: continue
        if m.group(1) not in rows: tabs.append(m.group(1)); rows[m.group(1)] = []
        rows[m.group(1)].append(m.group(2))
        if m.group(2) == name: return tabs.index(m.group(1)), rows[m.group(1)].index(name)
    raise KeyError(name)
def _goto(name, qon):
    if not NEWNAV:
        for _ in range(_plist_row(name, qon, _PL)): KEY('KEY_ROTARY_RIGHT')
        return
    t, r = _plist_pos(name, qon, _PL)
    for _ in range(20): KEY('KEY_ROTARY_LEFT')
    for _ in range(t): KEY('KEY_ROTARY_RIGHT')
    KEY('KEY_ENTER_BREAK')
    for _ in range(r): KEY('KEY_ROTARY_RIGHT')
# the PARAMS module from ui.lua's upvalues (test harness)
_PRx = L.eval('''function(wt)
  local seen = {}
  local function find(f, d)
    if type(f) ~= "function" or seen[f] or d > 4 then return nil end
    seen[f] = true
    for i = 1, 300 do
      local n, v = debug.getupvalue(f, i)
      if n == nil then break end
      if n == "PR" and type(v) == "table" then return v end
      local r = find(v, d + 1) if r then return r end
    end
  end
  -- OD_COUNT wraps wakeup / paint / event in Python: the Lua originals are kept as wakeup0 ...
  for _, k in ipairs({ "wakeup0", "paint0", "event0", "wakeup", "paint", "event" }) do local r = find(wt[k], 0) if r then return r end end
end''')
_ap = FakeAP({'Q_ENABLE': 1.0, 'AIRSPEED_CRUISE': 18.0, 'AIRSPEED_MIN': 12.0, 'TRIM_THROTTLE': 45.0,
              'THR_MAX': 100.0, 'ROLL_LIMIT_DEG': 45.0, 'PTCH_LIM_MAX_DEG': 20.0, 'STAB_PITCH_DOWN': 2.0,
              'ARSPD_USE': 1.0, 'ARMING_SKIPCHK': 512.0, 'Q_A_RAT_RLL_P': 0.135}, dup=True)
def _ap_push(t):
    if int(t['primId']) == 0x30: _ap.uplink(int(t['appId']), int(t['value']))
    return True
def _ap_pop():
    for tx in _ap.texts: send_text(tx, 4) if 'send_text' in globals() else None
    _ap.texts.clear()
    if not _ap.down: return None
    return L.table_from(list(_ap.down.pop(0)))
_old = (G._SPORTPUSH, G._POPMSPSPORT)
G._SPORTPUSH, G._POPMSPSPORT = _ap_push, _ap_pop
KEY = lambda k: wt['event'](widget, consts['EVT_KEY'], consts[k], 0, 0)
assert widget.paramsPage == 0, 'params page off by default'
widget.paramsPage = 1; widget.page = 2 if NATIVE else 3
wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
if NATIVE:
    # ---- INAV PARAMS page (X20 and X18 since 1.0.0c, INAV 9.1+ over MSPv2): read, save + EEPROM,
    # VTOL profiles, old INAV, in-flight lock from INAV's own status
    G._SPORTPUSH, G._POPMSPSPORT = _old            # the INAV MSP fake, not the ArduPilot one
    assert widget.page == 6, ('params page in the cycle for INAV', widget.page)
    # params.lua as ui.lua holds it (upvalue PR of one of the widget's functions, at any depth)
    _PRg = L.eval('''function(wt)
      local seen = {}
      local function find(f, d)
        if type(f) ~= "function" or seen[f] or d > 4 then return nil end
        seen[f] = true
        for i = 1, 300 do
          local n, v = debug.getupvalue(f, i)
          if n == nil then break end
          if n == "PR" and type(v) == "table" then return v end
          local r = find(v, d + 1) if r then return r end
        end
      end
      -- OD_COUNT wraps wakeup / paint / event in Python: the Lua originals are kept as wakeup0 ...
      for _, k in ipairs({ "wakeup0", "paint0", "event0", "wakeup", "paint", "event" }) do local r = find(wt[k], 0) if r then return r end end
    end''')
    # the Sensor check line (P.debug) at every step of INAV's start-up too: 1.0.0d stopped on the
    # variant / version / status steps, which carry no name (TX16S MK3 2026-11-25)
    _pr0 = None
    for _ in range(60):
        step(0.2)
        _pr0 = _pr0 or _PRg(wt)
        if _pr0 is not None: _pr0.debug()
    PRi = _PRg(wt)
    if _BF:
        # ---- Betaflight PARAMS (bfplist.lua; tools/fake_bf.py). OD_FC=BF45 / BF2025 / BF2026 / BFOLD
        if _BF == 'BFOLD':
            assert PRi.inav.variant == 'BTFL' and PRi.inav.state == 'bfold', ('old Betaflight refused', PRi.inav.state)
            render('bfparams_old_%s.png' % tag, 6)
            assert not _FBF.sets, 'nothing written to an unsupported Betaflight'
            print('Betaflight PARAMS (Ethos): API 1.45 gets the "needs 4.5 or 2025.12" screen OK')
        else:
            _api = {'BF2025': 47, 'BF2026': 48}.get(_BF, 46)
            assert PRi.inav.variant == 'BTFL' and PRi.inav.state == 'ready', ('Betaflight detected', PRi.inav.state)
            assert PRi.inav.ver == {46: '4.5.5', 47: '2025.12.5', 48: '2026.6.2'}[_api], PRi.inav.ver
            _w = 'max' if _api >= 47 else 'min'
            BF_TABS = [('PID', ['p_roll', 'i_roll', 'd_roll', 'p_pitch', 'i_pitch', 'd_pitch', 'p_yaw', 'i_yaw', 'd_yaw']),
                       ('FF D', ['f_roll', 'f_pitch', 'f_yaw'] + ['d_%s_%s' % (_w, a) for a in ('roll', 'pitch', 'yaw')] + ['d_max_gain', 'feedforward_transition', 'feedforward_averaging', 'feedforward_smooth_factor',
                                'feedforward_jitter_factor', 'feedforward_boost', 'feedforward_max_rate_limit']),
                       ('TUNE', ['anti_gravity_gain', 'iterm_relax_cutoff', 'tpa_mode', 'tpa_rate', 'tpa_breakpoint',
                                 'throttle_boost', 'dyn_idle_min_rpm', 'motor_output_limit', 'vbat_sag_compensation',
                                 'thrust_linear', 'angle_limit']),
                       ('RATES', ['roll_rc_rate', 'roll_srate', 'roll_expo', 'pitch_rc_rate', 'pitch_srate', 'pitch_expo',
                                  'yaw_rc_rate', 'yaw_srate', 'yaw_expo', 'thr_mid', 'thr_expo',
                                  'throttle_limit_type', 'throttle_limit_percent']),
                       ('FILTERS', ['gyro_lpf1_dyn_min_hz', 'gyro_lpf1_dyn_max_hz', 'gyro_lpf2_static_hz', 'dterm_lpf1_dyn_min_hz',
                                    'dterm_lpf1_dyn_max_hz', 'dterm_lpf2_static_hz', 'dyn_notch_count', 'dyn_notch_q',
                                    'dyn_notch_min_hz', 'dyn_notch_max_hz', 'rpm_filter_harmonics', 'rpm_filter_min_hz'])]
            def _pr(): return _PRg(wt)
            def _bv(n): p = _pr(); return p.valueOf(n) if p else None
            def _bwait(n, k=150):
                for _ in range(k):
                    if _bv(n) is not None: return
                    step(0.2)
            def _bgoto(name):
                t = [i for i, (g, rs) in enumerate(BF_TABS) if name in rs][0]
                r = BF_TABS[t][1].index(name)
                KEY('KEY_RTN_BREAK'); KEY('KEY_RTN_BREAK')
                widget.page = 6
                for _ in range(20): KEY('KEY_ROTARY_LEFT')
                for _ in range(t): KEY('KEY_ROTARY_RIGHT')
                KEY('KEY_ENTER_BREAK')
                for _ in range(r): KEY('KEY_ROTARY_RIGHT')
                _bwait(name)
                for _ in range(5): step(0.2)
            def _bsave(name, steps):
                _bgoto(name)
                KEY('KEY_ENTER_BREAK')
                for _ in range(5): step(0.2)
                for _ in range(abs(steps)): KEY('KEY_ROTARY_RIGHT' if steps > 0 else 'KEY_ROTARY_LEFT')
                n0, s0 = len(_FBF.sets), _FBF.stores
                KEY('KEY_ENTER_BREAK')
                for _ in range(60): step(0.2)
                assert _pr().phase() == 'Saved, verified and stored', (name, _pr().phase())
                assert _FBF.stores == s0 + 1, (name, 'EEPROM once', _FBF.stores - s0)
                return _FBF.sets[n0:]
            from fake_bf import PID, ADV, RC, FIL, get as _get
            _bwait('p_roll')
            assert [_bv(n) for n in ('p_roll', 'i_roll', 'd_roll', 'd_yaw')] == [45, 80, 40, 0], [_bv(n) for n in ('p_roll', 'i_roll', 'd_roll')]
            render('bfparams_pid_%s.png' % tag, 6)
            s = _bsave('p_roll', 2)
            assert _FBF.value(PID, 0) == 47 and s == [(202, 15)], ('PID', _FBF.value(PID, 0), s)
            adv0 = list(_FBF.block(ADV))
            s = _bsave('f_pitch', 3)
            a = _FBF.block(ADV)
            assert _FBF.value(ADV, 34, 2) == 128 and s == [(95, 39)] and a[:34] == adv0[:34] and a[36:] == adv0[36:], ('FF', s)
            _bwait('d_%s_roll' % _w)
            assert _bv('d_%s_roll' % _w) == 30, ('D %s roll' % _w, _bv('d_%s_roll' % _w))
            s = _bsave('roll_rc_rate', 1)
            assert _bv('roll_srate') == 670 and _FBF.value(RC, 0) == 8 and _FBF.value(RC, 12) == 7 and s == [(204, 14)], ('rates', _FBF.block(RC), s)
            render('bfparams_rates_%s.png' % tag, 6)
            # 3b the rows added for 1.0.0f (TUNE tab, FF details, throttle limit): one field each, the
            # SET cut at the end of that field's group, nothing else in the block changes
            adv1, rc1 = list(_FBF.block(ADV)), list(_FBF.block(RC))
            _bwait('tpa_breakpoint')
            got = [_bv(n) for n in ('anti_gravity_gain', 'tpa_rate', 'tpa_breakpoint', 'dyn_idle_min_rpm', 'angle_limit')]
            assert got == [80, 65, 1350, 3000, 60], ('TUNE reads', got)
            _bgoto('anti_gravity_gain')
            for _ in range(10): step(0.2)
            render('bfparams_tunelist_%s.png' % tag, 6)   # the TUNE group, all read (README screen)
            s = _bsave('anti_gravity_gain', 1)
            assert _FBF.value(ADV, 21, 2) == 85 and s == [(95, 23)], ('anti gravity', _FBF.value(ADV, 21, 2), s)
            s = _bsave('tpa_breakpoint', 2)
            assert _FBF.value(ADV, 59, 2) == 1370 and s == [(95, 61)], ('TPA breakpoint', _FBF.value(ADV, 59, 2), s)
            s = _bsave('tpa_mode', 1)
            assert _FBF.value(ADV, 57) == 1 and s == [(95, 61)], ('TPA mode PD -> D', _FBF.value(ADV, 57), s)
            s = _bsave('dyn_idle_min_rpm', 1)
            assert _FBF.value(ADV, 49) == 31 and s == [(95, 50)], ('dyn idle 3000 -> 3100 rpm', _FBF.value(ADV, 49), s)
            s = _bsave('feedforward_smooth_factor', -1)
            assert _FBF.value(ADV, 51) == 24 and s == [(95, 57)], ('FF smoothing', _FBF.value(ADV, 51), s)
            a = _FBF.block(ADV)
            assert [i for i in range(len(a)) if a[i] != adv1[i]] == [21, 49, 51, 57, 59], ('only those bytes', a, adv1)
            s = _bsave('throttle_limit_type', 2)
            r = _FBF.block(RC)
            assert _FBF.value(RC, 14) == 2 and s == [(204, 16)], ('throttle limit CLIP', _FBF.value(RC, 14), s)
            assert [i for i in range(len(r)) if r[i] != rc1[i]] == [14], ('only the limit type', r, rc1)
            render('bfparams_tune_%s.png' % tag, 6)
            fil0 = list(_FBF.block(FIL))
            s = _bsave('dyn_notch_max_hz', 1)
            f = _FBF.block(FIL)
            assert _get(f, 45, 2) == 610 and s == [(93, 47)] and _get(f, 20, 2) == 250 and f[:45] == fil0[:45] and f[47:] == fil0[47:], ('filters', s)
            render('bfparams_filters_%s.png' % tag, 6)
            _FBF.armed = True; st['armed'] = False
            _bgoto('i_pitch')
            for _ in range(20): step(0.2)
            assert _pr().inav.armed is True, _pr().inav.armed
            KEY('KEY_ENTER_BREAK')
            for _ in range(5): step(0.2)
            KEY('KEY_ROTARY_RIGHT')
            assert _pr().phase() == 'Armed: view only', _pr().phase()
            n0 = len(_FBF.sets)
            KEY('KEY_ENTER_BREAK')
            for _ in range(20): step(0.2)
            assert len(_FBF.sets) == n0, 'nothing set while armed'
            KEY('KEY_RTN_BREAK')
            _FBF.armed = False
            _FBF.pid_prof = 2
            for _ in range(40): step(0.2)
            _bgoto('p_roll')
            assert _pr().inav.profile == 2 and _bv('p_roll') == 47, ('profile 3', _pr().inav.profile, _bv('p_roll'))
            assert 'PID profile 3' in _pr().inavLine(), _pr().inavLine()
            print('Betaflight %s PARAMS (Ethos): detect, PID / FF / D %s / rates / filters saved + verified + stored with only their '
                  'group sent, armed lock, profile switch re-read OK' % (_pr().inav.ver, _w))
    elif INAV_SILENT:
        for _ in range(200): step(0.2)
        render('iparams_silent_%s.png' % tag, 6)
        print('INAV silent (stock mLRS): no-answer screen rendered')
    elif INAV_VER[0] < 9:
        assert PRi.inav.state == 'old', ('INAV 8: page says it needs 9.1', PRi.inav.state)
        render('iparams_old_%s.png' % tag, 6)
        print('INAV %d: "Parameters need INAV 9.1 or later" OK' % INAV_VER[0])
    elif INAV_VER[:2] == [9, 0]:
        assert PRi.inav.state == 'buggy', ('INAV 9.0: page says it needs 9.1', PRi.inav.state)
        render('iparams_90_%s.png' % tag, 6)
        print('INAV 9.0: "Parameters need INAV 9.1 or later" (empty setting replies) OK')
    elif INAV_SAFE_BUG:
        for _ in range(60): step(0.2)
        assert PRi.inav.state == 'ready'
        _nv = [PRi.valueOf(n) for n in ('max_angle_inclination_rll', 'max_angle_inclination_pit', 'roll_rate')]
        assert all(v is False for v in _nv), ('short replies -> n/a, never 0', _nv)
        assert PRi.stats.bad > 0
        render('iparams_short_%s.png' % tag, 6)
        print('INAV short setting replies: n/a (bad %d), no made-up 0 OK' % PRi.stats.bad)
    else:
        assert PRi.inav.state == 'ready' and PRi.inav.ver == '9.1.0', ('INAV detected', PRi.inav.state, PRi.inav.ver)
        _path = PRi.debugCore()
        if not SPORT:
            assert ('MSP bridge' if MLRS_BRIDGE else 'MSP native') in _path, ('MSP path picked', _path)
            print('INAV MSP path: %s OK' % ('mLRS bridge' if MLRS_BRIDGE else 'native CRSF'))
        assert PRi.inav.plat == 'AIRPLANE', ('platform read first', PRi.inav.plat)
        _v = lambda n: PRi.valueOf(n)
        assert abs(_v('max_angle_inclination_rll') - 45) < 1e-6 and abs(_v('fw_level_pitch_trim') - 1.5) < 1e-5, 'FLIGHT read and scaled'
        assert _v('roll_rate') == 180, ('roll_rate x10 deg/s', _v('roll_rate'))
        render('iparams_%s.png' % tag, 6)
        _ip = os.path.join(SRC, 'x20', 'iplist.lua')
        def _igoto(name):
            import re as _re2
            tabs, rows = [], {}
            for _l in open(_ip, encoding='utf-8'):
                m = _re2.match(r'\s*\{ "([^"]+)", "([a-z0-9_]+)"', _l)
                if not m: continue
                if m.group(1) not in rows: tabs.append(m.group(1)); rows[m.group(1)] = []
                rows[m.group(1)].append(m.group(2))
            for t in tabs:
                if name in rows[t]: ti, ri = tabs.index(t), rows[t].index(name)
            KEY('KEY_RTN_BREAK'); KEY('KEY_RTN_BREAK')
            widget.page = 6
            for _ in range(20): KEY('KEY_ROTARY_LEFT')
            for _ in range(ti): KEY('KEY_ROTARY_RIGHT')
            KEY('KEY_ENTER_BREAK')
            for _ in range(ri): KEY('KEY_ROTARY_RIGHT')
        # NAV THR: cruise throttle 1400 + 2 wheel steps, saved, read back, stored. Steps: 10 us on
        # the X20, 1 us on the X18 (its "+10" button is 10 steps = 10 us, 2026-11-25)
        _want = 1402 if W <= 480 else 1420
        _igoto('nav_fw_cruise_thr')
        for _ in range(60): step(0.2)
        assert _v('nav_fw_cruise_thr') == 1400, ('cruise thr read', _v('nav_fw_cruise_thr'))
        KEY('KEY_ENTER_BREAK'); 
        for _ in range(10): step(0.2)
        KEY('KEY_ROTARY_RIGHT'); KEY('KEY_ROTARY_RIGHT')
        _st0 = INAV_STORES[0]
        KEY('KEY_ENTER_BREAK')
        for _ in range(40): step(0.2)
        assert INAV_SET['nav_fw_cruise_thr']['v'] == _want, ('INAV got %d' % _want, INAV_SET['nav_fw_cruise_thr']['v'])
        assert INAV_STORES[0] == _st0 + 1, ('EEPROM written once after the save', INAV_STORES[0] - _st0)
        assert PRi.phase() == 'Saved, verified and stored', PRi.phase()
        render('iparams_saved_%s.png' % tag, 6)
        KEY('KEY_RTN_BREAK')
        # a lookup setting: INAV's own names, saved by index
        _igoto('nav_rth_alt_mode')
        for _ in range(40): step(0.2)
        KEY('KEY_ENTER_BREAK')
        for _ in range(10): step(0.2)
        KEY('KEY_ROTARY_LEFT')
        render('iparams_lookup_%s.png' % tag, 6)
        KEY('KEY_ENTER_BREAK')
        for _ in range(40): step(0.2)
        assert INAV_SET['nav_rth_alt_mode']['v'] == 3, ('AT_LEAST -> MAX (index 3)', INAV_SET['nav_rth_alt_mode']['v'])
        KEY('KEY_RTN_BREAK')
        # VTOL, fixed-wing profile active: hover PIDs are locked; FW PIDs read profile 1
        _igoto('mc_p_roll')
        for _ in range(60): step(0.2)
        KEY('KEY_ENTER_BREAK')
        for _ in range(20): step(0.2)
        assert 'multirotor' in PRi.phase(), ('hover PID locked in plane mode', PRi.phase())
        render('iparams_mclock_%s.png' % tag, 6)
        KEY('KEY_RTN_BREAK'); KEY('KEY_RTN_BREAK')
        # the VTOL switch: mixer + control profile 2 (MULTIROTOR); the hover tune is read again
        INAV_PROF['ctl'], INAV_PROF['mix'] = 1, 1
        _igoto('mc_p_roll')
        for _ in range(80): step(0.2)
        KEY('KEY_ENTER_BREAK')
        for _ in range(40): step(0.2)
        assert PRi.inav.plat == 'MULTIROTOR' and PRi.inav.profile == 1, ('platform / profile followed the switch', PRi.inav.plat, PRi.inav.profile)
        assert _v('mc_p_roll') == 40, ('hover P from profile 2', _v('mc_p_roll'))
        # armed, "Gains and trim": a hover gain changed in flight is set now, stored after the disarm
        widget.flightEdit = 1
        INAV_ARMED[0] = True; st['armed'] = True
        _sumAuto0 = widget.sumAuto; widget.sumAuto = 0
        for _ in range(5): step(0.2)
        widget.page = 6
        _st0 = INAV_STORES[0]
        KEY('KEY_ROTARY_RIGHT')
        KEY('KEY_ENTER_BREAK')
        for _ in range(40): step(0.2)
        assert INAV_SET['mc_p_roll']['v'][1] == 41, ('in-flight set on profile 2', INAV_SET['mc_p_roll']['v'])
        assert INAV_STORES[0] == _st0 and PRi.inav.dirty, 'not stored while armed'
        render('iparams_inflight_%s.png' % tag, 6)
        KEY('KEY_RTN_BREAK'); KEY('KEY_RTN_BREAK')
        widget.page = 1                                   # off the page: still stored after the disarm
        INAV_ARMED[0] = False; st['armed'] = False
        for _ in range(60): step(0.2)
        assert INAV_STORES[0] == _st0 + 1 and not PRi.inav.dirty, ('stored after the disarm, page left', INAV_STORES[0] - _st0, PRi.inav.dirty)
        widget.flightEdit = 0
        # INAV armed while the radio's flight mode sensor reads disarmed (X20S + ELRS, 2026-11-24):
        # "Edit in flight" Off -> view only, from INAV's own status
        INAV_ARMED[0] = True; st['armed'] = False
        widget.page = 6
        for _ in range(30): step(0.2)
        PRi = _PRg(wt)                                    # the module was unloaded off the page
        assert PRi.inav.armed is True, ('INAV status read as armed', PRi.inav.armed)
        _before = INAV_SET['mc_p_roll']['v'][1]
        _igoto('mc_p_roll')
        for _ in range(60): step(0.2)
        KEY('KEY_ENTER_BREAK')
        for _ in range(20): step(0.2)
        KEY('KEY_ROTARY_RIGHT')
        assert PRi.phase() == 'Armed: view only', ('locked from INAV status', PRi.phase())
        KEY('KEY_ENTER_BREAK')
        for _ in range(20): step(0.2)
        assert INAV_SET['mc_p_roll']['v'][1] == _before, 'nothing set while INAV is armed'
        render('iparams_inavarmed_%s.png' % tag, 6)
        # "Gains and trim" On, radio still reads disarmed: set now, the refused EEPROM write waits
        widget.flightEdit = 1
        _st0 = INAV_STORES[0]
        KEY('KEY_ENTER_BREAK')
        for _ in range(20): step(0.2)
        KEY('KEY_ROTARY_RIGHT')
        KEY('KEY_ENTER_BREAK')
        for _ in range(40): step(0.2)
        assert INAV_SET['mc_p_roll']['v'][1] == _before + 1, ('in-flight set', INAV_SET['mc_p_roll']['v'])
        for _ in range(40): step(0.2)
        assert INAV_STORES[0] == _st0 and PRi.inav.dirty, ('not stored while INAV is armed', INAV_STORES[0] - _st0, PRi.inav.dirty)
        KEY('KEY_RTN_BREAK'); KEY('KEY_RTN_BREAK')
        widget.page = 1
        INAV_ARMED[0] = False
        for _ in range(60): step(0.2)
        assert INAV_STORES[0] == _st0 + 1 and not PRi.inav.dirty, ('stored once INAV says disarmed', INAV_STORES[0] - _st0, PRi.inav.dirty)
        widget.sumAuto, widget.flightEdit = _sumAuto0, 0
        print('INAV params: read/scale, save+verify+EEPROM, lookup names, VTOL profile lock + switch, in-flight set stored at disarm, INAV-status arming lock OK')
    widget.page = 1
    G._SPORTPUSH, G._POPMSPSPORT = _ap_push, _ap_pop
else:
    assert widget.page == 6, 'params page in the cycle for ArduPilot: %s' % widget.page
    _gets = [0]
    _orig_crsf = G.crsf
    G.crsf = L.eval('function(c, count) return { getSensor = function(...) count() return c.getSensor(...) end } end')(_orig_crsf, lambda: _gets.__setitem__(0, _gets[0] + 1))
    for _ in range(40): step(0.2)
    G.crsf = _orig_crsf
    if not SPORT:
        assert _gets[0] == 0, 'params page over CRSF made %d CRSF sensor(s) of its own' % _gets[0]
        print('params page over CRSF: no second CRSF sensor (sends through telem.lua) OK')
    render('params_%s.png' % tag, 6)
    if NEWNAV:
        for _ in range(_plist_pos('TECS_CLMB_MAX', True, _PL)[0]): KEY('KEY_ROTARY_RIGHT')
        step(0.2)
        render('params_tabhi_%s.png' % tag, 6)       # TECS highlighted, FLIGHT still open
        KEY('KEY_ENTER_BREAK')
        for _ in range(30): step(0.2)
        for _ in range(20): KEY('KEY_ROTARY_RIGHT')   # stops at the last TECS row
        step(0.2)
        render('params_tecs_%s.png' % tag, 6)
        wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_START'], W // 2, 4)   # the top bar: no button there
        wt['event'](widget, consts['EVT_TOUCH'], consts['TOUCH_END'], W // 2, 4)
        if SPORT:
            assert widget.page == 6, ('a tap off the buttons keeps the params page', widget.page)
        else:   # CRSF here = the FC doesn't answer: that screen has no buttons, a tap still turns the page
            assert widget.page == 1, ('a tap on the doesnt-answer screen turns the page', widget.page)
            widget.page = 6
        KEY('KEY_RTN_BREAK')                          # rows -> tab column
    if SPORT:
        _armed0, _sum0 = st['armed'], widget.sumAuto
        widget.sumAuto = 0     # no flight summary on the disarm below (the sim never draws it, so it keeps opening)
        st['armed'] = True; step(0.2)
        _goto('AIRSPEED_CRUISE', True)
        for _ in range(40): step(0.2)   # the selected row is read first
        wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
        for _ in range(5): step(0.2)
        for _ in range(4): KEY('KEY_ROTARY_RIGHT')
        render('params_armed_%s.png' % tag, 6)
        wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
        for _ in range(5): step(0.2)
        assert _ap.sets == 0, 'armed: nothing written'
        st['armed'] = False
        for _ in range(3): step(0.2)
        widget.page = 6        # the disarm opened the flight summary (summary on disarm)
        wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
        for _ in range(5): step(0.2)
        for _ in range(4): KEY('KEY_ROTARY_RIGHT')
        render('params_edit_%s.png' % tag, 6)
        wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
        for _ in range(10): step(0.2)
        assert abs(_ap.p['AIRSPEED_CRUISE'] - 20.0) < 1e-6, ('saved', _ap.p['AIRSPEED_CRUISE'])
        render('params_saved_%s.png' % tag, 6)
        # leaving the page with a change not saved drops it (user 2026-11-27)
        if _PRx(wt).editing(): KEY('KEY_RTN_BREAK')
        for _ in range(3): step(0.2)
        wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)   # editor again
        for _ in range(5): step(0.2)
        for _ in range(2): KEY('KEY_ROTARY_RIGHT')
        assert _PRx(wt).editing() and abs(_PRx(wt)._draft()[0] - 21.0) < 1e-6, ('draft 21', _PRx(wt)._draft()[0])
        widget.page = 1
        for _ in range(3): step(0.2)
        widget.page = 6
        for _ in range(3): step(0.2)
        assert not _PRx(wt).editing(), 'editor closed after the page was left'
        assert abs(_ap.p['AIRSPEED_CRUISE'] - 20.0) < 1e-6, ('nothing saved', _ap.p['AIRSPEED_CRUISE'])
        print('Ethos PARAMS: unsaved edit dropped on leaving the page OK')
        KEY('KEY_RTN_BREAK')                          # editor already closed: rows -> tab column
        _goto('ARMING_SKIPCHK', True)
        for _ in range(10): step(0.2)
        wt['event'](widget, consts['EVT_KEY'], consts['KEY_ENTER_BREAK'], 0, 0)
        for _ in range(5): step(0.2)
        render('params_skipchk_%s.png' % tag, 6)
        for _ in range(3): KEY('KEY_ROTARY_LEFT')          # cursor 1 -> Save -> Back -> All off
        KEY('KEY_ENTER_BREAK')                             # All off
        render('params_skipchk_alloff_%s.png' % tag, 6)
        for _ in range(2): KEY('KEY_ROTARY_RIGHT')         # -> Save
        KEY('KEY_ENTER_BREAK')
        for _ in range(10): step(0.2)
        assert abs(_ap.p['ARMING_SKIPCHK'] - -1.0) < 1e-6, ('All off saves -1', _ap.p['ARMING_SKIPCHK'])
        print('ARMING_SKIPCHK All off: -1 saved and verified')
        KEY('KEY_RTN_BREAK'); KEY('KEY_RTN_BREAK')
        for _ in range(60): step(0.2)                         # the rest, Q rows included (Q_ENABLE 1)
        render('params_q_%s.png' % tag, 6, )
        st['armed'], widget.sumAuto = _armed0, _sum0
        for _ in range(3): step(0.2)
        print('params page S.Port: armed view-only, read, edit, save verified OK')
    if not NATIVE: widget.page = 6   # (the re-arm above can open the flight summary first)
    _pg0 = widget.page
    _r = wt['event'](widget, consts['EVT_KEY'], consts['KEY_RTN_BREAK' if NEWNAV else 'KEY_ENTER_BREAK'], 0, 0)
    assert widget.page == 1, ('RTN in the tab column (X18: ENTER, no row) leaves the params page', _pg0, widget.page, _r)
    if widget.apMission != 1:
        # the PARAMS code leaves memory 10 s after the page is left, and comes back when opened
        _mem = lambda: L.eval('function() collectgarbage("collect") return collectgarbage("count") end')()
        _m_open = _mem()
        for _ in range(25): step(0.2)          # 5 s on the main page: still loaded
        _m5 = _mem()
        for _ in range(35): step(0.2)          # past 10 s: unloaded
        _m12 = _mem()
        assert _m_open - _m12 > 100, ('params unloaded after 10 s', round(_m_open), round(_m5), round(_m12))
        assert _m_open - _m5 < 50, ('params kept for 10 s', round(_m_open), round(_m5))
        widget.page = 6
        for _ in range(25): step(0.2)
        render('params_reopen_%s.png' % tag, 6)
        print('params page: freed %d KB 10 s after leaving (%d -> %d KB), reopens OK' % (_m_open - _m12, _m_open, _m12))
        widget.page = 1
# ---- ArduPilot mission download + editor: editor on the X20 family only (X18: none)
if SPORT and not NATIVE:
    _ap.mission = [(16, 0, 0.0, 0.0, 0.0, 0.0, 0.0), (22, 3, st['lat'] + 0.001, st['lon'] + 0.001, 40.0, 0.0, 0.0)]
    for _i in range(4):
        _ap.mission.append((16, 3, st['lat'] + 0.003 * (_i + 1), st['lon'] + 0.002 * (_i % 2) - 0.001, 60.0, 0.0, 0.0))
    _ap.mission.append((21, 3, st['lat'] - 0.001, st['lon'], 0.0, 0.0, 0.0))
    if os.environ.get('OD_WPFILE'):   # a QGC WPL 110 file instead (item 0 = home)
        _ap.mission = []
        for _ln in open(os.environ['OD_WPFILE'], encoding='utf-8').read().splitlines()[1:]:
            _f = _ln.split('	')
            if len(_f) >= 12:
                _ap.mission.append((int(_f[3]), int(_f[2]), float(_f[8]), float(_f[9]), float(_f[10]), float(_f[4]), float(_f[6]), float(_f[5])))
        print('  mission from', os.environ['OD_WPFILE'], len(_ap.mission), 'items')
    _ap.mstamp += 1000
    widget.apMission, widget.page, widget.sumAuto = 1, 2, 0
    for _ in range(30): step(0.2)
    render('map_apmission_%s.png' % tag, 2)
    if os.environ.get('OD_PROFILE'):
        # where the instructions go with the mission downloaded: main page, then map page,
        # flying the circle, 30 s each (sampled every 25 instructions)
        import statistics
        PAINT[0] = True
        st['armed'] = True
        for _pg in (1, 2):
            widget.page = _pg
            for _ in range(10): step(0.2)
            CNT.clear(); DIST.clear(); WORST.clear()
            L.execute('PROF = {} PROF_ON = true')
            _calls = {'paint': [], 'wakeup': []}
            _old_counted = {}
            _nsteps = int(os.environ.get('OD_PROFILE_STEPS', '60'))
            _win = []
            for _k in range(_nsteps):
                _before = {k: len(v) for k, v in DIST.items()}
                step(0.2)
                if _k % 25 == 24:   # every 5 s of flight: the worst call in that window
                    _win.append({k: max(v[-100:]) for k, v in DIST.items()})
            print('   per 5 s window (worst call):'); [print('     t=%3ds %s' % ((i + 1) * 5, w)) for i, w in enumerate(_win)]
            L.execute('PROF_ON = false')
            prof = L.eval('PROF')
            items = sorted(((str(k), int(v)) for k, v in prof.items()), key=lambda kv: -kv[1])
            tot = sum(v for _, v in items)
            print('==== page %d: worst per call %s, sampled total %d' % (_pg, {k: v for k, v in CNT.items()}, tot))
            for k, v in DIST.items():
                v2 = sorted(v); print('   %s: calls %d median %d p95 %d max %d' % (k, len(v2), v2[len(v2)//2], v2[int(len(v2)*0.95)], v2[-1]))
            for k, (n, lines) in WORST.items():
                print('   -- worst %s (%d):' % (k, n)); [print('        %6d %s' % (c, l)) for l, c in lines[:18]]
            DIST.clear(); WORST.clear()
            for k, v in items[:30]: print('   %6d %5.1f%%  %s' % (v, 100.0 * v / tot, k))
        raise SystemExit(0)
    TE = consts['EVT_TOUCH']
    def _tap(x, y):
        wt['event'](widget, TE, consts['TOUCH_START'], int(x), int(y))
        wt['event'](widget, TE, consts['TOUCH_END'], int(x), int(y))
    eb = widget.editBtn
    if W <= 480:
        assert not eb, 'X18: no EDIT button (mission editor is X20 / TX16S only)'
        assert not os.path.exists(os.path.join(SRC, 'x18', 'medit.lua')), 'X18 copy carries no editor'
        print('X18: mission download yes, editor none OK')
    else:
        assert eb, 'X20: EDIT button on the map page'
        _tap(eb.x + eb.w / 2, eb.y + eb.h / 2)
        _getE = L.execute('''return function(W) for i = 1, 300 do local n, v = debug.getupvalue(W.event0 or W.event, i)
            if n == nil then break end if n == 'ED' then return v end end end''')
        ED = _getE(wt)
        assert ED and ED.active, 'X20: EDIT opens the editor'
        cv = Canvas(); wt['paint'](widget)
        d0 = ED._draft()[0]; n0 = len(d0)
        _tap(W * 0.72, H * 0.40)
        d1, s1 = ED._draft()[0], ED._draft()[1]
        assert len(d1) == n0 + 1 and d1[s1].alt == 60, ('X20: tap adds a waypoint at 60 m', len(d1), d1[s1].alt)
        cv = Canvas(); wt['paint'](widget)
        bl = ED._boxes(); bx = {str(bl[i].k): bl[i] for i in range(1, len(bl) + 1)}
        def _btn(k): b = bx[k]; _tap(b.x + b.w / 2, b.y + b.h / 2)
        _btn('+'); assert ED._draft()[0][s1].alt == 61, ('X20: + = altitude +1 m', ED._draft()[0][s1].alt)
        _btn('-'); assert ED._draft()[0][s1].alt == 60, ('X20: - = altitude -1 m', ED._draft()[0][s1].alt)
        _btn('Type')
        assert ED._draft()[0][ED._draft()[1]].cmd == 17, 'X20: Type -> LOITER UNLIM'
        _btn('Type'); _btn('Type'); _btn('Type'); _btn('+')
        d2, s2 = ED._draft()[0], ED._draft()[1]
        assert d2[s2].cmd == 21, ('X20: Type x4 -> Land', d2[s2].cmd)
        # a point far above the map: its legs must stop at the map edge, not cross the top bar
        # (X20S 2026-11-15: route lines over DISARMED / the info line)
        _bar = int(H * 0.09)
        cv = Canvas(); wt['paint'](widget); _top0 = cv.img.crop((0, 0, W, _bar)).tobytes()
        _lat0 = d2[s2].lat; d2[s2].lat = _lat0 + 0.02
        cv = Canvas(); wt['paint'](widget); _top1 = cv.img.crop((0, 0, W, _bar)).tobytes()
        render('medit_offmap_%s.png' % tag, 2)
        d2[s2].lat = _lat0
        assert _top0 == _top1, 'X20 editor: a leg to a point off the map is drawn over the top bar'
        print('X20 mission editor: route clipped to the map (point 2 km off the top) OK')
        render('medit_%s.png' % tag, 2)
        _btn('Send')
        for _ in range(40): step(0.2)
        assert len(_ap.mission) == len(d2) + 1 and _ap.mission[s2][0] == 21, ('X20: the aircraft holds the edited mission', len(_ap.mission))
        render('medit_sent_%s.png' % tag, 2)
        cv = Canvas(); wt['paint'](widget)
        bl = ED._boxes(); bx = {str(bl[i].k): bl[i] for i in range(1, len(bl) + 1)}
        _btn('Done')
        assert not ED.active and widget.page == 2, 'X20: Done leaves the editor'
        print('X20 mission editor: EDIT, add, +1 m / -1 m, Type, Send (written + verified), Done OK')
    widget.apMission = 0
    step(0.2)
widget.paramsPage, widget.page = 0, 1
G._SPORTPUSH, G._POPMSPSPORT = _old
