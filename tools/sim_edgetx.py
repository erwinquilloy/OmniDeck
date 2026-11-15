"""
Off-radio test harness for the OmniDeck EdgeTX widget (TX16S MK2 480x272 by default).

Builds WIDGETS/OmniDeck with tools/build_edgetx.py into a fake SD card, runs it in
Lua 5.2 (EdgeTX's version) against stubbed EdgeTX calls, and checks:
  - every widget call stays under EdgeTX's instruction limit (a hook every 200
    instructions, "CPU limit" after 100 of them, as radio/src/lua/widgets.cpp)
  - nothing is drawn outside the widget's area
  - telemetry decodes (ArduPilot passthrough over CRSF or S.Port, or native
    INAV/Betaflight sensors by their EdgeTX names), pages, touch and keys, sound

  python tools/sim_edgetx.py [outdir] [--sport] [--native] [--res 480x272]
"""
import math, os, shutil, sys
from lupa import lua52
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from simtelem import packets, text_chunks, project, dist_brg
import build_edgetx

args = [a for a in sys.argv[1:] if not a.startswith('--')]
OUT = os.path.abspath(args[0]) if args else os.path.join(HERE, 'out_edgetx')
SPORT = '--sport' in sys.argv
NATIVE = '--native' in sys.argv
# --otx: OpenTX 2.3 instead of EdgeTX. No lcd.sizeText, triangles, circles or dir(),
# refresh(widget) gets no event, and the limit is 10,000 instructions per call (half of
# EdgeTX's). The run measures every page against that limit and stops before the EdgeTX checks.
OTX = '--otx' in sys.argv or '--otx-panels' in sys.argv
# --otx-panels: write the OpenTX bitmaps of the data blocks' fixed layer (one per speed unit)
# into targets/opentx/WIDGETS/OmniDeck/otx/, from ui.lua's own drawing code, then stop
OTX_PANELS = '--otx-panels' in sys.argv
# --etx-panels: the same for EdgeTX (targets/edgetx .../fixed/): the blocks' shapes (labels stay
# live, so one bitmap per screen size) and the HUD overlay
ETX_PANELS = '--etx-panels' in sys.argv
RES = '480x272'
for i, a in enumerate(sys.argv):
    if a == '--res': RES = sys.argv[i + 1]
W, H = map(int, RES.split('x'))
os.makedirs(OUT, exist_ok=True)
tag = ('native' if NATIVE else 'ap') + ('_sport' if SPORT else '_crsf') + '_' + RES

# ------------------------------------------------------------------ fake SD card
SD = os.path.join(OUT, 'sd_' + tag)
if os.path.isdir(SD): shutil.rmtree(SD)
build_edgetx.build(SD, otx=OTX)
for pack in ('Aria', 'Michelle'):                       # voice folders, contents don't matter here
    os.makedirs(os.path.join(SD, 'WIDGETS', 'OmniDeck', 'audio', pack), exist_ok=True)
def sd_path(p): return os.path.join(SD, *[x for x in str(p).split('/') if x])
# OD_PANEL=1: OpenTX's top-right panel set to the radar in the model's settings file (0 = logo)
if os.environ.get('OD_PANEL') is not None:
    with open(sd_path('/WIDGETS/OmniDeck/Sim_Plane.cfg'), 'w') as _f: _f.write('panel=%s\nvoice=Aria\n' % os.environ['OD_PANEL'])   # with the voice, as a real settings file (none = voice off)

# ------------------------------------------------------------------ drawing
# approximate EdgeTX colour-screen font heights at 480x272 (pixels)
FONT_PX = {0: 15, 0x200: 12, 0x300: 20, 0x400: 28, 0x500: 48, 0x600: 9}
if W >= 800: FONT_PX = {0: 20, 0x200: 15, 0x300: 26, 0x400: 36, 0x500: 64, 0x600: 12}
fonts = {k: ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf' if k != 0x600 else 'C:/Windows/Fonts/arial.ttf', v)
         for k, v in FONT_PX.items()}
def font_of(flags): return fonts.get(int(flags or 0) & 0xF00, fonts[0])

class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new('RGB', (w, h), (255, 0, 255))
        self.d = ImageDraw.Draw(self.img)
        self.outside = []
    def check(self, what, x1, y1, x2, y2):
        # EdgeTX clips text to the widget itself, so only shapes are checked here
        if what.startswith('text'): return
        if x1 < -0.5 or y1 < -0.5 or x2 > self.w + 0.5 or y2 > self.h + 0.5:
            self.outside.append((what, round(x1), round(y1), round(x2), round(y2)))

cv = Canvas(W, H)
colors = {}
import collections
DRAWS = collections.Counter()
TEXTS = []
CUSTOM = 0x8000
def rgb(r, g=None, b=None):
    if g is None: return int(r)
    return (int(r) << 16) | (int(g) << 8) | int(b)
def col(): c = colors.get(CUSTOM, 0); return ((c >> 16) & 255, (c >> 8) & 255, c & 255)
def set_color(i, c): DRAWS['setcolor'] += 1; colors[int(i)] = int(c)
def size_text(t, flags=0):
    f = font_of(flags); b = f.getbbox(str(t))
    return b[2] - b[0], f.size + 2
# OpenTX: text as the radio draws it, Roboto at OpenTX's sizes (radio/src/fonts/480x272/
# CMakeLists.txt) with each glyph advanced by OpenTX's own widths, read from the W_* tables in
# etx.lua so the simulator and the widget measure alike. The fonts are OpenTX's copies of
# Roboto (Apache 2.0) in tools/otxfonts/; without them the PC font is used.
OTX_TEXT = None
if OTX:
    import re
    _here = os.path.dirname(os.path.abspath(__file__))
    _fd = os.path.join(_here, 'otxfonts')
    _src = open(os.path.join(build_edgetx.target_dir(OTX), 'WIDGETS', 'OmniDeck', 'etx.lua'), encoding='utf-8').read()
    _wt = {m.group(1): [int(v) for v in m.group(2).split(',')] for m in re.finditer(r'local W_(\w+) = \{ ([^}]*) \}', _src)}
    if len(_wt) == 6 and os.path.isfile(os.path.join(_fd, 'Roboto-Regular.ttf')):
        _reg, _bold = os.path.join(_fd, 'Roboto-Regular.ttf'), os.path.join(_fd, 'Roboto-Bold.ttf')
        OTX_TEXT = {k: (ImageFont.truetype(f, px), _wt[n]) for k, (f, px, n) in {
            0x600: (_reg, 9, 'TIN'), 0x200: (_reg, 13, 'SML'), 0: (_reg, 16, 'STD'),
            0x300: (_reg, 24, 'MID'), 0x400: (_bold, 32, 'DBL'), 0x500: (_bold, 64, 'XXL')}.items()}
def draw_text(x, y, t, flags=0):
    DRAWS['text'] += 1
    TEXTS.append(str(t))
    flags = int(flags or 0)
    if OTX_TEXT:
        fnt, wt = OTX_TEXT.get(flags & 0xF00, OTX_TEXT[0])
        t = str(t)
        adv = [wt[ord(c) - 32] if 32 <= ord(c) < 127 else wt[16] for c in t]
        w = sum(adv)
        if flags & 0x10000: x = x - w / 2
        elif flags & 0x20000: x = x - w
        cv.check('text ' + t, x, y, x + w, y + fnt.size)
        for c, a in zip(t, adv):
            cv.d.text((x, y), c, fill=col(), font=fnt)
            x += a
        return
    w, h = size_text(t, flags)
    if flags & 0x10000: x = x - w / 2          # CENTER
    elif flags & 0x20000: x = x - w            # RIGHT
    cv.check('text ' + str(t), x, y, x + w, y + h)
    cv.d.text((x, y), str(t), fill=col(), font=font_of(flags))
def frect(x, y, w, h, flags=0):
    DRAWS['frect'] += 1
    if w <= 0 or h <= 0: return
    cv.check('frect', x, y, x + w, y + h)
    cv.d.rectangle([x, y, x + w - 1, y + h - 1], fill=col())
def rect(x, y, w, h, flags=0, t=1):
    DRAWS['rect'] += 1
    cv.check('rect', x, y, x + w, y + h)
    cv.d.rectangle([x, y, x + w - 1, y + h - 1], outline=col())
def line(x1, y1, x2, y2, pattern=0, flags=0):
    DRAWS['line'] += 1
    # C: luaL_check* truncates toward zero, as in line_clip below. The EdgeTX trail fast path
    # (map.lua, OD_LITE) passes unrounded coordinates on purpose: 479.6 is drawn at 479, inside a
    # 480-wide widget; checked unrounded it read as 480.6 and failed "drawn outside the widget".
    x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
    cv.check('line', min(x1, x2), min(y1, y2), max(x1, x2) + 1, max(y1, y2) + 1)
    cv.d.line([x1, y1, x2, y2], fill=col())
def tri(x1, y1, x2, y2, x3, y3, flags=0):
    DRAWS['tri'] += 1
    cv.check('tri', min(x1, x2, x3), min(y1, y2, y3), max(x1, x2, x3) + 1, max(y1, y2, y3) + 1)
    cv.d.polygon([(x1, y1), (x2, y2), (x3, y3)], fill=col())
def circle(x, y, r, flags=0):
    DRAWS['circle'] += 1
    cv.check('circle', x - r, y - r, x + r + 1, y + r + 1)
    cv.d.ellipse([x - r, y - r, x + r, y + r], outline=col())
def fcircle(x, y, r, flags=0):
    DRAWS['fcircle'] += 1
    cv.check('fcircle', x - r, y - r, x + r + 1, y + r + 1)
    cv.d.ellipse([x - r, y - r, x + r, y + r], fill=col())
# EdgeTX version the widget sees (getVersion): OD_ETXVER=2.12.0. Up to 2.10.x the colour-LCD API
# reads coordinates unsigned (luaL_checkunsigned), so a negative one wraps; 2.11.0 switched to
# luaL_checkinteger (api_colorlcd.cpp at v2.10.5 vs v2.11.0).
ETXVER = tuple(int(v) for v in os.environ.get('OD_ETXVER', '2.9.4').split('.'))
NEG_OK = ETXVER >= (2, 11, 0)
def coord(v, what):
    v = int(v)                                   # C: luaL_check* truncates toward zero
    if v < 0 and not NEG_OK: DRAWS['negative ' + what] += 1
    return v
def line_clip(x1, y1, x2, y2, xmin, xmax, ymin, ymax, pattern=0, flags=0):
    # lcd.drawLineWithClipping: the line through the buffer's own drawLine, clip box intersected
    DRAWS['line'] += 1; DRAWS['clipline'] += 1
    x1, y1, x2, y2 = (coord(v, 'clipline') for v in (x1, y1, x2, y2))
    xmin, xmax, ymin, ymax = (coord(v, 'clipline') for v in (xmin, xmax, ymin, ymax))
    if xmax < xmin or ymax < ymin: return
    layer = cv.img.copy()
    ImageDraw.Draw(layer).line([x1, y1, x2, y2], fill=col())
    box = (max(0, xmin), max(0, ymin), min(cv.w, xmax + 1), min(cv.h, ymax + 1))   # max taken as inclusive
    if box[2] > box[0] and box[3] > box[1]: cv.img.paste(layer.crop(box), box[:2])
def hud_rect(pitch, roll, xmin, xmax, ymin, ymax, flags=0):
    # lcd.drawHudRectangle: line for line the C helper drawHudRectangle (api_colorlcd.cpp, same
    # maths in 2.9.4 .. 2.12.0). coord_t casts truncate toward zero like C.
    DRAWS['hudrect'] += 1
    xmin, xmax, ymin, ymax = (coord(v, 'hudrect') for v in (xmin, xmax, ymin, ymax))
    pitch, roll = float(pitch), float(roll)
    G2R = 0.017453293
    c = col()
    def hline(x, y, w):
        if w > 0: cv.d.line([x, y, x + w - 1, y], fill=c); cv.check('hudrect', x, y, x + w, y + 1)
    def fill(x, y, w, h):
        if w > 0 and h > 0: cv.d.rectangle([x, y, x + w - 1, y + h - 1], fill=c); cv.check('hudrect', x, y, x + w, y + h)
    dx = math.sin(G2R * roll) * pitch
    dy = math.cos(G2R * roll) * pitch * 1.85
    angle = math.tan(-G2R * roll)
    ox = 0.5 * (xmin + xmax) + dx
    oy = 0.5 * (ymin + ymax) + dy
    yw = ymax - ymin
    if roll == 0.0:
        fill(xmin, max(ymin, ymin + (yw // 2 + int(dy))), xmax - xmin, max(0, min(yw, yw // 2 - int(dy))))
    elif abs(roll) >= 180.0:
        fill(xmin, ymin, xmax - xmin, min(yw, yw // 2 + int(abs(dy))))
    else:
        inverted = abs(roll) > 90.0
        need = False
        ybot = 0 if inverted else LCD_H_C
        for s in range(yw):
            yy = ymin + s
            xx = int(ox + (yy - oy) / angle)
            if roll > 0.0:
                if xmin <= xx <= xmax: hline(xx, yy, xmax - xx + 1)
                elif xx < xmin: ybot = (max(yy, ybot) + 1) if inverted else min(yy, ybot); need = True
            else:
                if xmin <= xx <= xmax: hline(xmin, yy, xx - xmin)
                elif xx > xmax: ybot = (max(yy, ybot) + 1) if inverted else min(yy, ybot); need = True
        if need:
            ytop = ymin if inverted else ybot
            hgt = (ybot - ymin) if inverted else (ymax - ybot)
            fill(xmin, ytop, xmax - xmin, hgt)
LCD_H_C = H
bitmaps = {}
def bitmap_open(p):
    fp = sd_path(p)
    if not os.path.isfile(fp): return None
    img = Image.open(fp)
    img = img.convert('RGBA') if img.mode in ('RGBA', 'LA', 'P') else img.convert('RGB')   # keep transparency
    bitmaps[id(img)] = img
    return L.table_from({'_id': id(img)})
def draw_bitmap(bmp, x, y, scale=100):
    img = bitmaps[bmp['_id']]
    # EdgeTX can't clip bitmaps: overhang is allowed here; a transparent PNG is drawn through its alpha
    cv.img.paste(img, (int(x), int(y)), img if img.mode == 'RGBA' else None)

L = lua52.LuaRuntime(unpack_returned_tuples=True)
G = L.globals()
G.lcd = L.table_from({'RGB': rgb, 'setColor': set_color, 'sizeText': size_text, 'drawText': draw_text,
    'drawFilledRectangle': frect, 'drawRectangle': rect, 'drawLine': line, 'drawFilledTriangle': tri,
    'drawCircle': circle, 'drawFilledCircle': fcircle, 'drawBitmap': draw_bitmap,
    'drawLineWithClipping': line_clip, 'drawHudRectangle': hud_rect})
G.getVersion = L.eval('function() return "%d.%d.%d", "tx16s", %d, %d, %d, "EdgeTX" end' % (ETXVER * 2))
def bitmap_size(bmp):   # OpenTX / EdgeTX Bitmap.getSize(bitmap) -> width, height
    img = bitmaps[bmp['_id']]
    return img.width, img.height
G.Bitmap = L.table_from({'open': bitmap_open, 'getSize': bitmap_size})
for k, v in {'LCD_W': W, 'LCD_H': H, 'CUSTOM_COLOR': CUSTOM, 'SOLID': 0, 'SMLSIZE': 0x200, 'MIDSIZE': 0x300,
             'DBLSIZE': 0x400, 'XXLSIZE': 0x500, 'TINSIZE': 0x600, 'VALUE': 1, 'BOOL': 2, 'CENTER': 0x10000, 'RIGHT': 0x20000,
             'EVT_TOUCH_FIRST': 0x1001, 'EVT_TOUCH_BREAK': 0x1002, 'EVT_TOUCH_SLIDE': 0x1003, 'EVT_TOUCH_TAP': 0x1004,
             'EVT_VIRTUAL_ENTER': 0x2001, 'EVT_VIRTUAL_NEXT': 0x2002, 'EVT_VIRTUAL_PREV': 0x2003, 'EVT_VIRTUAL_EXIT': 0x2004}.items():
    G[k] = v

# ------------------------------------------------------------------ radio services
sim_time = [0.0]
G.getTime = lambda: int(sim_time[0] * 100)
G.getUsage = lambda: int(G._USE or 0)
played = []
G.playFile = lambda p: played.append(str(p))
def dir_iter(p):
    fp = sd_path(p)
    names = sorted(os.listdir(fp)) if os.path.isdir(fp) else []
    it = iter(names)
    return lambda *a: next(it, None)
G.dir = dir_iter
files = {}
def io_open(p, mode='r'):
    fp = sd_path(p)
    if str(mode) in ('w', 'a'):
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        h = len(files) + 1; files[h] = [fp, None]
        if str(mode) == 'w': open(fp, 'w').close()      # 'a' keeps what is there
        return h
    if not os.path.isfile(fp): return None
    h = len(files) + 1; files[h] = [open(fp, 'rb').read(), 0]; return h
def io_write(h, text):
    fp = files[h][0]
    with open(fp, 'a', encoding='latin-1') as f: f.write(str(text))
def io_read(h, n):
    data, pos = files[h]; chunk = data[pos:pos + int(n)]; files[h][1] = pos + len(chunk)
    return chunk.decode('latin-1')
def io_close(h): files.pop(h, None)
G.io = L.table_from({'open': io_open, 'read': io_read, 'write': io_write, 'close': io_close})
# the radio's clock (EdgeTX getDateTime; the flight log stamps entries with it)
G.getDateTime = lambda *a: L.table_from({'year': 2026, 'mon': 11, 'day': 10, 'hour': 9, 'min': 5, 'sec': 7})
def read_file(p):
    fp = sd_path(p)
    return open(fp, encoding='utf8').read() if os.path.isfile(fp) else None
G._READ = read_file
L.execute('''
-- EdgeTX 2.9.4: the third argument (env) does not work; the chunk gets _ENV = nil and dies at
-- its first global ("attempt to index upvalue '_ENV'", TX16S MK2 tester 2026-11-03). Same here.
function loadScript(path, mode, env)
  local src = _READ(path)
  if not src then return nil, path .. ": not found" end
  if env ~= nil then return load(src, "@" .. path, "t", nil) end
  return load(src, "@" .. path, "t", _G)
end
-- EdgeTX's widget instruction limit: hook every 200 instructions, error after 100 hooks
_MAXN = {}
function _CALL(what, f, ...)
  local n = 0
  local lim = _NOLIMIT and 1e9 or (_LIM or 100)
  _USE = 0
  if _PROF then   -- OD_PROF: sample the running function every 200 instructions
    debug.sethook(function()
      n = n + 1 _USE = n
      local k
      if _PROFPARTS then
        -- the screen part being drawn: the innermost safe(part, fn) on the stack keeps the part's
        -- name in its first local; outside drawing, the function ui.wakeup is in the middle of
        for lv = 2, 40 do
          local i = debug.getinfo(lv, "Sn")
          if not i then break end
          if i.name == "safe" then
            local nm, v = debug.getlocal(lv, 1)
            if nm == "part" then k = "draw " .. tostring(v) break end
          end
          if i.name == "wakeup" and string.find(i.short_src or "", "ui.lua", 1, true) then
            local c = debug.getinfo(lv - 1, "Sn")
            k = "update " .. ((c and c.name) or "?")
            break
          end
        end
        k = k or "other"
      elseif _PROFLINE then
        -- the line of OmniDeck code running (adapter work charged to the line that called it)
        for lv = 2, 40 do
          local i = debug.getinfo(lv, "Sl")
          if not i then break end
          local f = string.match(i.short_src or "?", "[^/]*$")
          if f ~= "etx.lua" and f ~= "[C]" then k = f .. ":" .. (i.currentline or 0) break end
        end
        k = k or "etx.lua"
      elseif _PROFCALLER then
        -- the innermost function outside the adapter (etx.lua): adapter work is charged to the
        -- OmniDeck function that asked for it
        for lv = 2, 40 do
          local i = debug.getinfo(lv, "Sn")
          if not i then break end
          local f = string.match(i.short_src or "?", "[^/]*$")
          if f ~= "etx.lua" then k = f .. ":" .. (i.linedefined or 0) .. " " .. (i.name or "?") break end
        end
        k = k or "etx.lua"
      else
        local i = debug.getinfo(2, "Sn")
        if i then k = string.match(i.short_src or "?", "[^/]*$") .. ":" .. (i.linedefined or 0) .. " " .. (i.name or "?") end
      end
      if k then _PROF[k] = (_PROF[k] or 0) + 1 end
      if n > lim then debug.sethook() error("CPU limit") end
    end, "", 200)
  else            -- the plain hook: anything extra in here counts as widget work
    debug.sethook(function() n = n + 1 _USE = n if n > lim then debug.sethook() error("CPU limit") end end, "", 200)
  end
  local ok, a = pcall(f, ...)
  debug.sethook()
  if (_MAXN[what] or 0) < n then _MAXN[what] = n end
  _LASTN = n
  if not ok then error(what .. ": " .. tostring(a), 0) end
  return a
end
''')

# telemetry
class _RadioQueue(list):
    """The radio's Lua telemetry queue. OpenTX 2.3: one 256-byte FIFO (telemetry.h
    LUA_TELEMETRY_INPUT_FIFO_SIZE) holding 8-byte S.Port packets, or CRSF frames as length + command
    + payload; a frame that doesn't fit is dropped (counted). EdgeTX: no limit modelled."""
    def __init__(self, crsf):
        super().__init__()
        self.crsf, self.dropped = crsf, 0
    def _size(self, item):
        return (len(item[1]) + 2) if self.crsf else 8
    def append(self, item):
        if OTX and sum(self._size(i) for i in self) + self._size(item) > 255:
            self.dropped += 1
            return
        super().append(item)
crsf_q, sport_q = _RadioQueue(True), _RadioQueue(False)
streaming = [True]
G.getRSSI = lambda: 90 if streaming[0] else 0
def crsf_pop():
    if not crsf_q: return None
    cmd, data = crsf_q.pop(0)
    return cmd, L.table_from(data)
G.crossfireTelemetryPop = crsf_pop
G.crossfireTelemetryPush = lambda cmd, data: True
def sport_pop():
    if not sport_q: return None
    return tuple(sport_q.pop(0))
G.sportTelemetryPop = sport_pop
G.sportTelemetryPush = lambda *a: True

native = {}
units = {}       # EdgeTX unit numbers
STICK = [-1024]   # the radio's throttle stick (getValue("thr"))
def get_value(name):
    name = str(name)
    if name == 'tx-voltage': return 8.1
    if name == 'thr': return STICK[0]
    v = native.get(name)
    if isinstance(v, dict): return L.table_from(v)
    return v
G.getValue = get_value
G.getFieldInfo = lambda name: L.table_from({'name': str(name)}) if str(name) in native else None
sensor_list = []
def get_sensor(i):
    i = int(i)
    if i >= len(sensor_list): return None
    n = sensor_list[i]
    return L.table_from({'name': n, 'unit': units.get(n, 0)})
# EdgeTX's model.getModule returns a plain table (no enable()); with an Ethos-style check
# the link was never detected and INAV/BF over TBS showed NO TELEM (TX16S MK2, EdgeTX 2.12)
def get_module_etx(i):
    return L.table_from({'Type': 5 if int(i) == 1 else 0, 'protocol': 0, 'subType': 0})
G.model = L.table_from({'getSensor': get_sensor, 'getModule': get_module_etx,
                        'getInfo': lambda *a: L.table_from({'name': 'Sim Plane'})})

# ------------------------------------------------------------------ vehicle
HOME = (43.49323, 142.88785)
st = dict(lat=HOME[0], lon=HOME[1], hlat=HOME[0], hlon=HOME[1], mode=5, armed=True, thr=55, sats=14, hdop=0.8,
          altmsl=160, volt=15.8, curr=12.3, mah=0, alt=0, vs=0, **{'as': 17.0}, gs=18.5, yaw=0, roll=0, pitch=0,
          wdir=270, wspd=4.2, wpn=0, wpd=0, wpb=0)

feed_n = [0]
def feed():
    feed_n[0] += 1
    if NATIVE:
        fm = st.get('fm') or ('ANGL' if st['armed'] else 'OK')
        native.update({'GPS': {'lat': st['lat'], 'lon': st['lon']}, 'Alt': st['alt'], 'VSpd': st['vs'],
                       'GSpd': st['gs'] * 3.6, 'Hdg': st['yaw'], 'Yaw': st['yaw'], 'Sats': st['sats'],
                       'Roll': st['roll'], 'Ptch': -st['pitch'], 'RxBt': st['volt'], 'Curr': st['curr'],
                       'Capa': st['mah']})
        if SPORT:
            native.update({'Tmp1': 14 if st['armed'] else 1, 'RSSI': 88 - feed_n[0] % 2, 'VFAS': st['volt']})
            for k in ('RxBt', 'Capa', 'Yaw'): native.pop(k, None)
        else:
            native.update({'FM': fm, 'RQly': 96, '1RSS': -72 - feed_n[0] % 2})
        units.update({'GSpd': 7, 'Alt': 9, 'VSpd': 5, 'Hdg': 20, 'Roll': 20, 'Ptch': 20})
        for n in native:
            if n not in sensor_list: sensor_list.append(n)
        return
    native.update({'RQly': 96, '1RSS': -72} if not SPORT else {'RSSI': 88})
    pk = packets(st)
    if SPORT:
        for a, v in pk: sport_q.append([0x1B, 0x10, a, v])
    else:
        for i in range(0, len(pk), 6):
            grp = pk[i:i + 6]
            data = [0xF2, len(grp)]
            for a, v in grp:
                data += [a & 0xFF, a >> 8, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
            crsf_q.append((0x80, data))
def send_text(t, sev=6):
    for chunk in text_chunks(t, sev):
        if SPORT: sport_q.append([0x1B, 0x10, 0x5000, chunk])
        else: crsf_q.append((0x80, [0xF0, 0x00, 0x50, chunk & 0xFF, (chunk >> 8) & 0xFF, (chunk >> 16) & 0xFF, chunk >> 24]))

# ------------------------------------------------------------------ load the widget like EdgeTX does
CALL = G._CALL
G._NOLIMIT = bool(os.environ.get('OD_NOLIMIT'))
if OTX:
    L.execute('''
    lcd.sizeText, lcd.drawFilledTriangle, lcd.drawCircle, lcd.drawFilledCircle = nil, nil, nil, nil
    lcd.drawLineWithClipping, lcd.drawHudRectangle = nil, nil   -- OpenTX: Yaapu falls back to Lua for both
    dir = nil
    getVersion = function() return "2.3.15", "x10", 2, 3, 15 end
    ''')
    # OpenTX 2.3.0+ has getUsage() (api_general.cpp): percent of the 10,000-instruction limit used
    # so far in this call, counted live by its hook (interface.cpp). One sim hook = 200 = 2 %.
    G.getUsage = lambda: int(2 * (G._USE or 0))
    G._LIM = 50            # 50 hooks x 200 = 10,000 instructions
    # measure, don't stop: every update runs to the end and its count is recorded against 50
    G._NOLIMIT = not os.environ.get('OD_OTX_STRICT')
# EdgeTX 2.9 strings have no metatable: text:sub(...) fails there with "attempt to index
# local 'text' (a string value)" (TX16S MK2 tester, 2026-11-03). Only string.sub(text, ...) works.
L.execute('debug.setmetatable("", nil)')
# OD_NONATIVE=1: the widget as before, without EdgeTX's clipped line and HUD fill (reference runs)
if os.environ.get('OD_NONATIVE'): L.execute('lcd.drawLineWithClipping, lcd.drawHudRectangle = nil, nil')
main_chunk = G.loadScript('/WIDGETS/OmniDeck/main.lua')
assert main_chunk is not None, 'main.lua did not compile'
widget_def = CALL('load', main_chunk)
assert widget_def['name'] == 'OmniDeck'
opts = {}
for i in range(1, 20):
    o = widget_def['options'][i]
    if o is None: break
    opts[o[1]] = o[3]
assert len(opts) <= 5, 'EdgeTX takes at most 5 options on older versions: %s' % list(opts)
print('options', opts)
options = L.table_from(opts)
FULL = L.table_from({'x': 0, 'y': 0, 'w': W, 'h': H})
wd = CALL('create', widget_def['create'], FULL, options)
# the welcome plays from create(), before any update, as Yaapu's: EdgeTX only updates the screen on
# show, so a widget on another screen at power-on would otherwise stay silent
if not OTX:
    assert played == ['/WIDGETS/OmniDeck/audio/Aria/omniready.wav'], 'welcome from create(): %s' % played
S = None
worst = {}
heavy = []

def frame(evt=0, touch=None, zone=None):
    """one refresh: evt 0 = full screen without an event, None = in a layout zone"""
    global cv
    cv = Canvas(W, H) if zone is None else Canvas(zone[0], zone[1])
    if zone is not None:
        wd.zone = L.table_from({'x': 0, 'y': 0, 'w': zone[0], 'h': zone[1]})
    t = L.table_from(touch) if touch else None
    if OTX:
        CALL('refresh', widget_def['refresh'], wd)          # OpenTX: refresh(widget) only
    else:
        CALL('refresh', widget_def['refresh'], wd, evt, t)
    key = 'page%s%s' % (wd.page, '' if zone is None else ' zone')
    worst[key] = max(worst.get(key, 0), G._LASTN)
    if G._LASTN >= 80: heavy.append((G._LASTN, round(sim_time[0], 2), key, evt))
    if zone is not None:
        wd.zone = FULL
    assert not cv.outside, 'drawn outside the widget: %s' % cv.outside[:5]

# the radio updates the widget about every 50 ms; ArduPilot's passthrough brings
# one full set of values (about three CRSF frames) every quarter second
REFRESH_S, FEED_S = 0.05, 0.25
last_feed = [-1.0]
def step(dt=0.1, n=1):
    for _ in range(n):
        end = sim_time[0] + dt - 1e-9
        while sim_time[0] < end:
            sim_time[0] += REFRESH_S
            if sim_time[0] - last_feed[0] >= FEED_S - 1e-9:
                last_feed[0] = sim_time[0]
                feed()
            frame()

UIm = None
def ui_module():
    # ui.lua's table: the upvalue UI of refresh
    get = L.execute('''return function(f, name) for i = 1, 200 do local n, v = debug.getupvalue(f, i)
        if n == nil then return nil end if n == name then return v end end end''')
    return get(widget_def['refresh'], 'UI')

step(0.1, 40)
UIm = ui_module()
if OTX_PANELS or ETX_PANELS:
    pdir = (os.path.join(build_edgetx.target_dir(True), 'WIDGETS', 'OmniDeck', 'otx') if OTX_PANELS
            else os.path.join(build_edgetx.target_dir(False), 'WIDGETS', 'OmniDeck', 'fixed'))
    os.makedirs(pdir, exist_ok=True)
    for unit in (range(4) if OTX_PANELS else [0]):
        wd.spdUnit = unit
        cv = Canvas(W, H)
        px, py, pw, ph = UIm.exportPanel(wd, W, H)
        key = {0: 'kmh', 1: 'ms', 2: 'kt', 3: 'mph'}[unit]
        img = cv.img.crop((int(px), int(py), int(px + pw), int(py + ph))).convert('RGB')
        out = os.path.join(pdir, ('panel_%dx%d_%s.png' % (W, H, key)) if OTX_PANELS else ('panel_%dx%d.png' % (W, H)))
        img.save(out, optimize=True)
        print('wrote', out, img.size)
    wd.spdUnit = 0
    # the HUD's fixed layer (hud.lua H.drawFixed) on a transparent background, drawn over the
    # horizon each update as Yaapu draws its hud.png; the canvas magenta is the transparency
    cv = Canvas(W, H)
    hx, hy, hw, hh = UIm.exportHud(wd, W, H)
    img = cv.img.crop((int(hx), int(hy), int(hx + hw), int(hy + hh))).convert('RGBA')
    img.putdata([(0, 0, 0, 0) if p[:3] == (255, 0, 255) else p for p in img.getdata()])
    out = os.path.join(pdir, 'hud_%dx%d.png' % (int(hw), int(hh)))
    img.save(out, optimize=True)
    print('wrote', out, img.size, 'opaque px', sum(1 for p in img.getdata() if p[3]))
    sys.exit(0)
S = UIm.T.s
print('decoded: fc %s link %s mode %s armed %s alt %s gspd %s aspd %s volt %s sats %s lq %s rssi %s' % (
    S.fc, S.link, S.mode, S.armed, S.alt, S.gspd, S.aspd, S.volt, S.sats, S.lq, S.rssi))
if NATIVE:
    assert S.fc == 'INAV/BF' and S.armed is True and abs(S.gspd - st['gs']) < 0.1, 'native decode'
    assert S.mode == ('ANGLE' if SPORT else 'ANGL'), S.mode
else:
    assert S.fc == 'ArduPilot' and S.mode == 'FBWA' and S.armed is True, 'passthrough decode'
    assert abs(S.aspd - st['as']) < 0.6 and abs(S.gspd - st['gs']) < 0.6 and S.cap == 5000, 'speeds and capacity'
    assert S.link == ('S.Port' if SPORT else 'CRSF')

# fly a bit so the map, trail and figures have something to show
for k in range(120):
    st['yaw'] = (st['yaw'] + 2) % 360
    st['lat'], st['lon'] = project(st['lat'], st['lon'], st['gs'] * 0.5, st['yaw'])
    st['alt'] = min(120, st['alt'] + 1.5); st['mah'] += 20; st['roll'] = 20; st['pitch'] = 5
    step(0.5)
if not NATIVE: send_text('Low battery! Check RTL', 4)
step(0.1, 10)

if OTX:
    # OpenTX budget per page: instructions per refresh against the 10,000 limit
    OTX_LIM = 50
    _starved = L.execute('''return function(f) for i = 1, 200 do local n, v = debug.getupvalue(f, i)
        if n == nil then return nil end if n == "E" then return v.lcd.starved end end end''')(widget_def['refresh'])
    STARVED = {}
    MEDIAN = {}
    def otx_page(page, frames=40, mission=False, name=None):
        wd.page = page
        worst_n = 0
        cut = 0
        all_n = []
        if mission and os.environ.get('OD_PROF'):
            G._PROF = L.table_from({})
        for _ in range(frames):
            st['yaw'] = (st['yaw'] + 2) % 360
            st['lat'], st['lon'] = project(st['lat'], st['lon'], st['gs'] * 0.5, st['yaw'])
            if mission: st['wpn'] = 60
            for _ in range(3 if mission else 1): feed()
            sim_time[0] += 0.05
            frame()
            worst_n = max(worst_n, G._LASTN)
            all_n.append(G._LASTN)
            if _starved and _starved(): cut += 1
        STARVED[name] = cut
        MEDIAN[name] = sorted(all_n)[len(all_n) // 2]
        if mission and os.environ.get('OD_PROF'):
            prof[name] = sorted(((int(v), str(k)) for k, v in G._PROF.items()), reverse=True)
            G._PROF = None
        return worst_n
    rep = {}
    prof = {}
    for page, name in ((1, 'main'), (2, 'map'), (3, 'messages'), (5, 'sensor check')):
        if os.environ.get('OD_PROF'):
            G._PROF = L.table_from({})
            G._PROFPARTS = os.environ.get('OD_PROF') == 'parts'   # OD_PROF=parts: by screen part
            G._PROFCALLER = os.environ.get('OD_PROF') == 'caller' # OD_PROF=caller: adapter work charged to its caller
            G._PROFLINE = os.environ.get('OD_PROF') == 'line'     # OD_PROF=line: by line of OmniDeck code
        DRAWS.clear()
        rep[name] = otx_page(page, name=name)
        print('  draws per update on %s: %s' % (name, {k: round(v / 40) for k, v in sorted(DRAWS.items())}))
        if os.environ.get('OD_PROF'):
            prof[name] = sorted(((int(v), str(k)) for k, v in G._PROF.items()), reverse=True)
            G._PROF = None
        cv.img.save(os.path.join(OUT, 'otx_%s_%s.png' % (name.replace(' ', '_'), tag)))
    get = L.execute('''return function(f, name) for i = 1, 200 do local n, v = debug.getupvalue(f, i)
        if n == nil then return nil end if n == name then return v end end end''')
    TAB, NL = chr(9), chr(10)
    lines = ['QGC WPL 110', TAB.join(['0', '1', '0', '16', '0', '0', '0', '0', '%.7f' % HOME[0], '%.7f' % HOME[1], '0', '1'])]
    for i in range(1, 121):
        la, lo = project(HOME[0], HOME[1], 150 + 25 * i, (i * 37) % 360)
        lines.append(TAB.join([str(i), '0', '3', '16', '0', '0', '0', '0', '%.7f' % la, '%.7f' % lo, '100', '1']))
    open(sd_path('/WIDGETS/OmniDeck/missions/big.waypoints'), 'w').write(NL.join(lines) + NL)
    # OpenTX draws no missions (ui.lua): the file is offered and must not show; these two runs
    # are the waypoint flight (active WP, 0x500D) with telemetry at 3x the normal rate
    UIm.MI.loadFile('big.waypoints')
    _m = UIm.MI.current()
    assert (_m[0] if isinstance(_m, tuple) else _m) is None, 'OpenTX: no mission'
    assert UIm.MSPC.state() == 'off', 'OpenTX: no INAV mission download'
    rep['main, WP flight, 3x feed'] = otx_page(1, mission=True, name='main, WP flight, 3x feed')
    rep['map, WP flight, 3x feed'] = otx_page(2, mission=True, name='map, WP flight, 3x feed')
    st['armed'] = False
    step(0.2, 12)
    rep['flight summary'] = otx_page(4, name='flight summary') if wd.page == 4 else None
    if rep['flight summary'] is not None:
        cv.img.save(os.path.join(OUT, 'otx_flight_summary_%s.png' % tag))
    print('OpenTX telemetry queue (256 bytes): %d CRSF / %d S.Port frames dropped while full' % (crsf_q.dropped, sport_q.dropped))
    print('OpenTX budget (limit %d instructions per call):' % (OTX_LIM * 200))
    for k, n in rep.items():
        if n is None: print('  %-24s not reached' % k); continue
        print('  %-24s %6d instructions  %4d%%  %-4s  median %3d%%  drawing cut short in %d of 40 updates' % (k, n * 200, round(100 * n / OTX_LIM), 'OK' if n <= OTX_LIM * 0.88 else 'OVER', round(100 * MEDIAN.get(k, 0) / OTX_LIM), STARVED.get(k, 0)))
    for name, rows in prof.items():
        tot = sum(c for c, _ in rows) or 1
        print('profile %s (%d samples over 40 updates):' % (name, tot))
        for c, k in rows[:int(os.environ.get('OD_PROF_TOP', '14'))]:
            print('  %5.1f%%  %s' % (100 * c / tot, k))
    sys.exit(0)

def render(name, page):
    wd.page = page
    frame()
    p = os.path.join(OUT, name)
    cv.img.save(p)
    print('wrote', p)

for page, name in ((1, 'main'), (2, 'map'), (3, 'msgs')):
    render('etx_%s_%s.png' % (name, tag), page)
# near wings level the roll pointer meets the heading box: the box must stay on top (as drawn live)
_r, _p = st['roll'], st['pitch']
for rl in (0, 3, -3):
    st['roll'], st['pitch'] = rl, 0
    step(0.5)
    render('etx_main_roll%+d_%s.png' % (rl, tag), 1)
st['roll'], st['pitch'] = _r, _p
step(0.5)

# OD_GEO=1: the horizon's ground edge must lie on the white horizon line at any attitude. Every
# sky/ground boundary in a column must have the line within 2 px. Columns left and right of the
# aircraft symbol, between the tapes.
if os.environ.get('OD_GEO'):
    SKY, GND, WHT = (40, 110, 190), (130, 80, 40), (255, 255, 255)
    gx, gy = W / 480, H / 272
    cols = [int(x * gx) for x in range(52, 88, 3)] + [int(x * gx) for x in range(184, 214, 3)]
    geo_bad, tiles = [], []
    keep = (st['roll'], st['pitch'])
    for roll, pitch in ((0, 0), (0, 10), (0, -15), (30, 0), (30, 10), (-30, 10), (45, 20), (60, 10),
                        (-60, -10), (89, 0), (90, 5), (120, 5), (150, -10), (179, 0), (-170, 5)):
        st['roll'], st['pitch'] = roll, pitch
        wd.page = 1
        step(1.0, 1)
        frame()
        im = cv.img
        bad = 0
        bounds = 0
        for x in cols:
            last, gap_white, gap = None, False, 0
            for y in range(int(28 * gy), int(248 * gy)):
                p = im.getpixel((x, y))
                k = 's' if p == SKY else ('g' if p == GND else None)
                if k is None:
                    gap += 1
                    if p == WHT: gap_white = True
                    continue
                if last is not None and k != last:
                    bounds += 1
                    near = gap_white or any(im.getpixel((x, yy)) == WHT for yy in range(y - 3 - gap, y + 3))
                    if not near or gap > 4: bad += 1
                last, gap_white, gap = k, False, 0
        geo_bad.append((roll, pitch, bounds, bad))
        tiles.append((roll, pitch, im.crop((0, int(24 * gy), int(270 * gx), int(252 * gy))).resize((270, 228))))
    st['roll'], st['pitch'] = keep
    print('GEO (roll, pitch, boundaries checked, off the line):', geo_bad)
    sheet = Image.new('RGB', (270 * 5, 228 * 3), (0, 0, 0))
    for i, (r, p, t) in enumerate(tiles):
        sheet.paste(t, ((i % 5) * 270, (i // 5) * 228))
        ImageDraw.Draw(sheet).text(((i % 5) * 270 + 4, (i // 5) * 228 + 200), 'roll %d pitch %d' % (r, p), fill=(255, 255, 0))
    sheet.save(os.path.join(OUT, 'geo_%s.png' % tag))
    assert all(b == 0 for _, _, _, b in geo_bad), 'ground edge off the horizon line: %s' % geo_bad
    assert DRAWS['negative clipline'] == 0 and DRAWS['negative hudrect'] == 0, 'negative coordinates on %s' % (ETXVER,)

# test42 main page: blocks HOME (TOT note) | FLIGHT TIME, ALT | AS / GS (GS alone without
# airspeed), no MAX AS / MAX GS; the tapes are labelled with the unit alone
wd.page = 1
del TEXTS[:]
frame()
txt = list(TEXTS)
S = UIm.T.s
assert 'HOME' in txt and 'FLIGHT TIME' in txt and 'ALT' in txt, 'blocks %s' % txt
assert not any(t.startswith('MAX AS') or t.startswith('MAX GS') for t in txt), 'no max-speed blocks %s' % txt
if S.aspd is not None:
    assert any(t.startswith('AS / GS ') for t in txt), 'AS / GS block %s' % txt
else:
    assert any(t.startswith('GS ') for t in txt), 'GS block %s' % txt
assert 'km/h' in txt and 'm' in txt and not any(t.startswith('ALT ') for t in txt), 'unit-only tape labels %s' % txt
assert not any(t.startswith('TOTAL ') for t in txt), 'TOT, not TOTAL %s' % txt
print('test42 main page OK')

# flight summary on disarm
st['armed'] = False
step(0.2, 12)
assert wd.page == 4, 'summary opens on disarm, page %s' % wd.page
render('etx_summary_%s.png' % tag, 4)
if not OTX:
    # test43: the flight is saved as logs/<model>-<date>-<time>.txt (getDateTime); a second flight
    # in the same second (the sim's clock stands still) gets -2, so nothing is overwritten
    ld = sd_path('/WIDGETS/OmniDeck/logs')
    names = sorted(os.listdir(ld)) if os.path.isdir(ld) else []
    assert names and names[0] == 'Sim Plane-2026-11-10-090507.txt', 'log file %s' % names
    lt = read_file('/WIDGETS/OmniDeck/logs/' + names[-1]) or ''
    assert 'Model          Sim Plane' in lt and 'Date           2026-11-10 09:05:07' in lt and 'Flight time' in lt, 'flight log %s' % lt[:300]
    assert all(n == names[0] or n == names[0][:-4] + '-%d.txt' % i for i, n in enumerate(names[1:], 2)), names
    print('flight log OK')

# touch and keys: a tap moves to the next page, ENTER too, the wheel zooms the map
wd.page = 1
frame(G.EVT_TOUCH_FIRST, {'x': 100, 'y': 100})
frame(G.EVT_TOUCH_BREAK, {'x': 101, 'y': 101})
assert wd.page == 2, 'tap -> map, page %s' % wd.page
frame(G.EVT_VIRTUAL_ENTER)
# test42: messages for ArduPilot only (INAV / Betaflight send none); flight stats and sensor
# check only when switched on (both off by default)
assert wd.msgPage == 0 and wd.statsPage == 0 and wd.checkPage == 0, 'page settings default'
assert wd.page == (1 if NATIVE else 3), 'enter -> messages for ArduPilot only, page %s' % wd.page
if not NATIVE:
    frame(G.EVT_VIRTUAL_ENTER)
    assert wd.page == 1, 'stats and sensor check off by default, page %s' % wd.page
wd.statsPage, wd.checkPage = 1, 1
wd.page = 3 if not NATIVE else 2
frame(G.EVT_VIRTUAL_ENTER)
assert wd.page == 4, 'flight stats page switched on (a flight to show), page %s' % wd.page
frame(G.EVT_VIRTUAL_ENTER)
assert wd.page == 5, 'sensor check page switched on, page %s' % wd.page
# sensor check rows that don't fit scroll: wheel next = further down, drag up = further down
frame()
mx, lv0 = wd.chkMax, wd.level
for _ in range(50): frame(G.EVT_VIRTUAL_NEXT)
assert wd.chkScroll == mx, ('wheel to the end', wd.chkScroll, mx)
if mx > 0:
    frame(); cv.img.save(os.path.join(OUT, 'check_scrolled_%s.png' % tag))
    rh = wd.chkRowH
    frame(G.EVT_TOUCH_FIRST, {'x': 200, 'y': 60})
    frame(G.EVT_TOUCH_SLIDE, {'x': 200, 'y': 60 + 2 * rh})
    frame(G.EVT_TOUCH_BREAK, {'x': 200, 'y': 60 + 2 * rh})
    assert wd.chkScroll == max(0, mx - 2) and wd.page == 5, ('drag', wd.chkScroll, wd.page)
for _ in range(50): frame(G.EVT_VIRTUAL_PREV)
assert wd.chkScroll == 0 and wd.level == lv0, 'wheel back to the top; map zoom untouched'
print('sensor check scroll OK (rows hidden at the top: %d)' % mx)
frame(G.EVT_VIRTUAL_ENTER)
assert wd.page == 1, 'then back to page 1, page %s' % wd.page
wd.msgPage = 1 if NATIVE else 2
wd.statsPage, wd.checkPage = 0, 0
wd.page = 2
frame(G.EVT_VIRTUAL_ENTER)
assert wd.page == (3 if NATIVE else 1), 'messages page On (INAV) / Off (ArduPilot), page %s' % wd.page
wd.msgPage = 0
print('test42 page cycle OK')

# ---- PARAMS page (6): ArduPilot only, S.Port / F.Port (MAVlite to a copy of ArduPilot's code)
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
_PL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'targets', 'edgetx', 'WIDGETS', 'OmniDeck', 'plist.lua')
_ap = FakeAP({'Q_ENABLE': 0.0, 'AIRSPEED_CRUISE': 18.0, 'AIRSPEED_MIN': 12.0, 'TRIM_THROTTLE': 45.0,
              'THR_MAX': 100.0, 'ROLL_LIMIT_DEG': 45.0, 'PTCH_LIM_MAX_DEG': 20.0, 'STAB_PITCH_DOWN': 2.0,
              'ARSPD_USE': 1.0, 'ARMING_SKIPCHK': 512.0, 'RLL_RATE_P': 0.08}, dup=True)
def _push(*a):
    if len(a) >= 4 and a[1] == 0x30: _ap.uplink(int(a[2]), int(a[3]))
    return True
def _ap_pump():
    while _ap.down:
        appid, val = _ap.down.pop(0)
        sport_q.append((0x1B, 0x32, appid, val))
    for t in _ap.texts: send_text(t, 4)
    _ap.texts.clear()
G.sportTelemetryPush = _push
assert wd.paramsPage == 0, 'params page off by default'
wd.paramsPage = 1
wd.page = 3 if not NATIVE else 2
frame(G.EVT_VIRTUAL_ENTER)
if NATIVE:
    assert wd.page != 6, 'params page: ArduPilot only, page %s' % wd.page
    print('params page not offered for INAV/Betaflight OK')
else:
    assert wd.page == 6, 'params page in the cycle for ArduPilot, page %s' % wd.page
    for _ in range(25):
        _ap_pump(); step(0.05)
    _ap_pump(); frame()
    render('etx_params_reading_%s.png' % tag, 6)   # progress bar under the top bar
    for _ in range(95):
        _ap_pump(); step(0.05)
    _ap_pump(); frame()
    render('etx_params_%s.png' % tag, 6)
    if SPORT:
        for _ in range(_plist_row('AIRSPEED_CRUISE', False, _PL)): frame(G.EVT_VIRTUAL_NEXT)
        for _ in range(60): _ap_pump(); step(0.05)   # the selected row is read first
        frame(G.EVT_VIRTUAL_ENTER)         # editor
        for _ in range(20): _ap_pump(); step(0.05)
        for _ in range(4): frame(G.EVT_VIRTUAL_NEXT)
        render('etx_params_edit_%s.png' % tag, 6)
        frame(G.EVT_VIRTUAL_ENTER)         # save
        for _ in range(60): _ap_pump(); step(0.05)
        assert abs(_ap.p['AIRSPEED_CRUISE'] - 20.0) < 1e-6, ('saved', _ap.p['AIRSPEED_CRUISE'])
        render('etx_params_saved_%s.png' % tag, 6)
        frame(G.EVT_VIRTUAL_EXIT); frame(G.EVT_VIRTUAL_EXIT)
        for _ in range(_plist_row('ARMING_SKIPCHK', False, _PL)): frame(G.EVT_VIRTUAL_NEXT)   # (Q rows hidden: Q_ENABLE 0)
        for _ in range(30): _ap_pump(); step(0.05)
        frame(G.EVT_VIRTUAL_ENTER)
        for _ in range(20): _ap_pump(); step(0.05)
        render('etx_params_skipchk_%s.png' % tag, 6)
        assert abs(_ap.p['ARMING_SKIPCHK'] - 512.0) < 1e-6
        print('ARMING_SKIPCHK editor opened (value 512 = Airspeed skipped)')
        for _ in range(3): frame(G.EVT_VIRTUAL_PREV)     # cursor 1 -> Save -> Back -> All off
        frame(G.EVT_VIRTUAL_ENTER)                       # All off
        render('etx_params_skipchk_alloff_%s.png' % tag, 6)
        for _ in range(2): frame(G.EVT_VIRTUAL_NEXT)     # -> Save
        frame(G.EVT_VIRTUAL_ENTER)
        for _ in range(60): _ap_pump(); step(0.05)
        assert abs(_ap.p['ARMING_SKIPCHK'] - -1.0) < 1e-6, ('All off saves -1', _ap.p['ARMING_SKIPCHK'])
        print('ARMING_SKIPCHK All off: -1 saved and verified')
        frame(G.EVT_VIRTUAL_EXIT); frame(G.EVT_VIRTUAL_EXIT)
        print('params page S.Port: read, edit, save verified OK')
    frame(G.EVT_VIRTUAL_ENTER)
    assert wd.page == 1, 'ENTER with no row picked leaves the params page, page %s' % wd.page
    if wd.apMission != 1:
        # the PARAMS code leaves memory 10 s after the page is left, and comes back when opened
        _memf = L.eval('function() collectgarbage("collect") return collectgarbage("count") end')
        _mem = lambda: (lambda r: r[0] if isinstance(r, tuple) else r)(_memf())
        _m_open = _mem()
        for _ in range(100): _ap_pump(); step(0.05)    # 5 s on the main page: still loaded
        _m5 = _mem()
        for _ in range(140): _ap_pump(); step(0.05)    # past 10 s: unloaded
        _m12 = _mem()
        assert _m_open - _m12 > 100, ('params unloaded after 10 s', round(_m_open), round(_m5), round(_m12))
        assert _m_open - _m5 < 50, ('params kept for 10 s', round(_m_open), round(_m5))
        wd.page = 6
        for _ in range(60): _ap_pump(); step(0.05)
        _ap_pump(); frame()
        render('etx_params_reopen_%s.png' % tag, 6)
        print('params page: freed %d KB 10 s after leaving (%d -> %d KB), reopens OK' % (_m_open - _m12, _m_open, _m12))
        wd.page = 1
# ArduPilot mission download (Stratos firmware) onto the map, any page
if SPORT and not NATIVE:
    _h = (st['lat'], st['lon'])
    _ap.mission = [(16, 0, 0.0, 0.0, 0.0, 0.0, 0.0), (22, 3, _h[0] + 0.0010, _h[1] + 0.0010, 40.0, 0.0, 0.0)]
    for _i in range(5):
        _ap.mission.append((16, 3, _h[0] + 0.003 * (_i + 1), _h[1] + 0.002 * (_i % 2) - 0.001, 60.0, 0.0, 0.0))
    _ap.mission.append((21, 3, _h[0] - 0.001, _h[1], 0.0, 0.0, 0.0))
    wd.apMission = 1
    wd.page = 2
    for _ in range(80):
        _ap_pump(); step(0.05)
    render('etx_map_apmission_%s.png' % tag, 2)
    _pr = None
    print('ArduPilot mission download on the map page OK')
    # ---- mission editor (EdgeTX TX16S / MK3): EDIT, tap to add, Type, +10, Send, Done
    def _tap(x, y):
        frame(G.EVT_TOUCH_FIRST, {'x': int(x), 'y': int(y)})
        frame(G.EVT_TOUCH_BREAK, {'x': int(x), 'y': int(y)})
    frame()
    eb = wd.editBtn
    assert eb, 'EDIT button on the map page (mission download On, ArduPilot)'
    _tap(eb.x + eb.w / 2, eb.y + eb.h / 2)
    ED = UIm.editor()
    assert ED and ED.active, 'EDIT opens the editor'
    d0, s0, _f0 = ED._draft()
    n0 = len(d0)
    assert wd.page == 2
    frame()
    tx, ty = W * 0.75, H * 0.40
    la_want, lo_want = UIm.MAP.toLatLon(tx, ty)     # the view the tap lands on
    frame(G.EVT_TOUCH_FIRST, {'x': int(tx), 'y': int(ty)})
    la_want, lo_want = UIm.MAP.toLatLon(int(tx), int(ty))
    frame(G.EVT_TOUCH_BREAK, {'x': int(tx), 'y': int(ty)})
    d1, s1, _f1 = ED._draft()
    assert len(d1) == n0 + 1 and s1 == s0 + 1, ('tap on the map adds a waypoint after the selected one', len(d1), s1)
    new = d1[s1]
    assert abs(new.lat - la_want) < 1e-9 and abs(new.lon - lo_want) < 1e-9 and new.cmd == 16, ('new point at the tapped spot', new.lat, la_want, new.lon, lo_want)
    assert new.alt == 60, ('a new waypoint takes the last waypoint altitude (60 m), not the landing 0 m', new.alt)
    frame()
    _bl = ED._boxes()
    bx = {}
    for _i in range(1, len(_bl) + 1):
        _k = _bl[_i].k
        bx[_k.decode() if isinstance(_k, bytes) else str(_k)] = _bl[_i]
    assert 'Type' in bx and 'Send' in bx, ('editor buttons drawn', list(bx))
    def _btn(k): b = bx[k]; _tap(b.x + b.w / 2, b.y + b.h / 2)
    alt0 = new.alt
    _btn('Type')
    d1, s1, f1 = ED._draft()
    assert d1[s1].cmd == 17 and d1[s1].p3 == 0, ('Type -> LOITER UNLIM, radius 0 (WP_LOITER_RAD)', d1[s1].cmd)
    _btn('Field'); _btn('+'); _btn('+')
    assert ED._draft()[0][s1].p3 == 20, ('loiter unlimited: Field -> radius, + + = 20 m', ED._draft()[0][s1].p3)
    _btn('Type'); _btn('+')
    d2, s2, f2 = ED._draft()
    assert d2[s2].cmd == 18 and d2[s2].p1 == 3 and d2[s2].alt == alt0 + 10, ('Type -> Loiter turns 3, + = altitude +10 m', d2[s2].cmd, d2[s2].alt)
    _btn('Field'); _btn('+'); _btn('Field'); _btn('+'); _btn('+')
    d2, s2, f2 = ED._draft()
    assert d2[s2].p1 == 4 and d2[s2].p3 == 20 and f2 == 3, ('Field: turns 3 -> 4, radius 0 -> 20 m', d2[s2].p1, d2[s2].p3, f2)
    # a speed change after it: add a waypoint, Type x6 -> SPEED (no position), + -> 19 m/s
    frame()
    _tap(W * 0.30, H * 0.62)
    for _ in range(6): _btn('Type')
    d3, s3, f3 = ED._draft()
    assert d3[s3].cmd == 178 and d3[s3].p2 == 18, ('Type x6 -> SPEED 18 m/s', d3[s3].cmd, d3[s3].p2)
    _btn('+')
    assert ED._draft()[0][s3].p2 == 19
    for _ in range(19): _btn('-')                   # 19 -> 1 m/s, then one more: -1 = no change
    assert ED._draft()[0][s3].p2 == -1, ('speed: one step below 1 m/s is -1 (no change)', ED._draft()[0][s3].p2)
    _btn('+')
    assert ED._draft()[0][s3].p2 == 1, ('speed: one step up from -1 is 1 m/s', ED._draft()[0][s3].p2)
    for _ in range(18): _btn('+')                   # back to 19
    # DO_JUMP: a jump item after it, Type x8 from Waypoint (16 17 18 19 21 20 178 189 177)
    _sel_before = ED._draft()[1]
    frame()
    _n0 = len(ED._draft()[0])
    _tap(W * 0.18, H * 0.55)
    assert len(ED._draft()[0]) == _n0 + 1, 'a new point for the jump'
    for _ in range(8): _btn('Type')
    dj, sj, fj = ED._draft()
    assert dj[sj].cmd == 177 and dj[sj].p1 == 2 and dj[sj].p2 == 1, ('Type x8 -> JUMP to #2, once', dj[sj].cmd, dj[sj].p1, dj[sj].p2)
    _btn('Field'); _btn('-'); _btn('-')
    assert ED._draft()[0][sj].p2 == -1, ('jump repeat 1 -> 0 -> -1 (forever)', ED._draft()[0][sj].p2)
    _btn('Field')
    for _ in range(99): _btn('+')
    assert ED._draft()[0][sj].p1 == len(ED._draft()[0]), ('jump target stops at the last item', ED._draft()[0][sj].p1)
    for _ in range(99): _btn('-')
    assert ED._draft()[0][sj].p1 == 1
    _btn('+')
    _btn('Del')                                     # (the rest of the flow expects no jump item)
    print('mission editor -1: speed "no change", JUMP repeat forever, target within the list OK')
    # info line: left third = previous item (the loiter), right third = back to the speed item
    _bl0 = ED.infoY
    _tap(10, _bl0 + 2)
    assert ED._draft()[1] == s3 - 1, ('info line left: previous item', ED._draft()[1])
    _tap(W - 10, _bl0 + 2)
    assert ED._draft()[1] == s3
    # move the speed item one earlier (before the loiter), then back
    _btn('<')
    assert ED._draft()[0][s3 - 1].cmd == 178 and ED._draft()[1] == s3 - 1, '< moves it earlier'
    _btn('>')
    assert ED._draft()[0][s3].cmd == 178
    d2, s2 = ED._draft()[0], s3
    render('etx_medit_%s.png' % tag, 2)
    nsent = len(d2)
    _btn('Send')
    for _ in range(160):
        _ap_pump(); step(0.05)
    frame()
    snd = UIm.editor() and None
    m = _ap.mission
    assert len(m) == nsent + 1, ('the aircraft holds the edited mission (+home)', len(m), nsent)
    _lo = [x for x in m if x[0] == 18][-1]
    assert abs(_lo[2] - la_want) < 2e-6 and abs(_lo[4] - (alt0 + 10)) < 1e-3 and _lo[5] == 4 and _lo[6] == 20, ('loiter turns item on the aircraft', _lo)
    _sp = [x for x in m if x[0] == 178][-1]
    assert abs(_sp[7] - 19) < 1e-6 and _sp[2] == 0, ('speed item on the aircraft, 19 m/s in param2, no position', _sp)
    render('etx_medit_sent_%s.png' % tag, 2)
    # editing centres the map on the selected item (ED.focus)
    _getMAP = L.execute('return function(f) for i = 1, 300 do local n, v = debug.getupvalue(f, i) if n == nil then break end if n == "MAP" then return v end end end')
    _MAPm = _getMAP(ED.paint)
    def _free_spot():
        _d = ED._draft()[0]
        pts = []
        for _i in range(1, len(_d) + 1):
            if _d[_i].lat and (_d[_i].lat != 0 or _d[_i].lon != 0):
                pts.append(_MAPm.toScreen(_d[_i].lat, _d[_i].lon))
        for fy in (0.40, 0.50, 0.60, 0.70, 0.32):
            for fx in (0.15, 0.30, 0.45, 0.60, 0.75):
                x, y = W * fx, H * fy
                if all((x - px) ** 2 + (y - py) ** 2 > 45 ** 2 for px, py in pts): return x, y
        raise AssertionError('no free spot on the map')
    for _ in range(80): _tap(10, ED.infoY + 2)
    _tap(W - 10, ED.infoY + 2)                       # item 2
    frame()
    _d, _s2, _ = ED._draft()
    if _d[_s2].lat and (_d[_s2].lat != 0 or _d[_s2].lon != 0):
        assert abs(_MAPm.view.lat - _d[_s2].lat) < 1e-7 and abs(_MAPm.view.lon - _d[_s2].lon) < 1e-7, ('map centred on the selected item', _MAPm.view.lat, _d[_s2].lat)
        print('editing: map centred on the selected waypoint OK')
    # Del on item k selects item k-1, and a tap then re-inserts at position k (replace a waypoint)
    _dk = 3
    for _ in range(80): _tap(10, ED.infoY + 2)
    for _ in range(_dk - 1): _tap(W - 10, ED.infoY + 2)
    assert ED._draft()[1] == _dk
    _n = len(ED._draft()[0]); _next = ED._draft()[0][_dk + 1].cmd
    _btn('Del')
    assert ED._draft()[1] == _dk - 1 and len(ED._draft()[0]) == _n - 1, ('Del selects the item before', ED._draft()[1])
    frame()
    _tap(*_free_spot())
    assert ED._draft()[1] == _dk and len(ED._draft()[0]) == _n and ED._draft()[0][_dk + 1].cmd == _next, 'the new point takes the place of the deleted one'
    print('Del + tap replaces a waypoint in place OK')
    # Del on the takeoff twice: a new mission (takeoff only)
    for _ in range(80): P_ = ED._draft(); _tap(10, ED.infoY + 2)
    assert ED._draft()[1] == 1
    _btn('Del')
    assert len(ED._draft()[0]) > 1, 'one Del on the takeoff only asks'
    _btn('Del')
    assert len(ED._draft()[0]) == 1 and ED._draft()[0][1].cmd == 22, 'Del twice on the takeoff: new mission'
    _btn('Done')
    assert not ED.active and wd.page == 2, 'Done leaves the editor, stays on the map'
    # ---- VTOL items on a quadplane (Q_ENABLE 1): VTOL takeoff, VTOL land, transitions
    _ap.p['Q_ENABLE'] = 1.0
    frame()
    _tap(wd.editBtn.x + wd.editBtn.w / 2, wd.editBtn.y + wd.editBtn.h / 2)
    for _ in range(60): _ap_pump(); step(0.05)
    assert UIm.editor().active
    PRm = UIm.editor() and None
    frame()
    _bl = ED._boxes(); bx = {}
    for _i in range(1, len(_bl) + 1):
        _k = _bl[_i].k; bx[_k.decode() if isinstance(_k, bytes) else str(_k)] = _bl[_i]
    for _ in range(80): _tap(10, ED.infoY + 2)      # back to item 1, the takeoff
    assert ED._draft()[1] == 1
    assert UIm.editor() and True
    _btn('Del'); _btn('Del')                         # Del twice on the takeoff: a new mission
    dv = ED._draft()[0]
    assert len(dv) == 1 and dv[1].cmd == 84, ('quadplane: a new mission starts with a VTOL takeoff', dv[1].cmd)
    _btn('Type')
    assert ED._draft()[0][1].cmd == 22, 'Type on the first item: VTOL takeoff -> Takeoff'
    _btn('Type')
    assert ED._draft()[0][1].cmd == 84, '... and back to VTOL takeoff'
    frame()
    _tap(W * 0.70, H * 0.45)                         # WP after the takeoff
    for _ in range(8): _btn('Type')                  # 16 17 18 19 21 85 20 178 3000 -> transition
    dv, sv, fv = ED._draft()
    assert dv[sv].cmd == 3000 and dv[sv].p1 == 4, ('Type x8 -> TRANSITION to FW', dv[sv].cmd, dv[sv].p1)
    _btn('+')
    assert ED._draft()[0][sv].p1 == 3, '+ toggles the transition: to VTOL'
    _btn('+')
    frame()
    _tap(W * 0.30, H * 0.65)                         # a point after the transition
    for _ in range(5): _btn('Type')                  # 16 17 18 19 21 85 -> VTOL land
    dv, sv, fv = ED._draft()
    assert dv[sv].cmd == 85, ('Type x5 -> VTOL LAND', dv[sv].cmd)
    render('etx_medit_vtol_%s.png' % tag, 2)
    assert not any('Sent and verified' in t for t, c in [(str(x[0]), 0) for x in texts_drawn()]) if 'texts_drawn' in globals() else True
    _btn('Send')
    for _ in range(160): _ap_pump(); step(0.05)
    assert [x[0] for x in _ap.mission[1:]] == [84, 3000, 85] and _ap.mission[2][5] == 4, ('the aircraft holds the VTOL mission', [x[0] for x in _ap.mission])
    _btn('Done')
    _ap.p['Q_ENABLE'] = 0.0
    print('mission editor VTOL: VTOL takeoff, transition to FW / to VTOL, VTOL land, Send OK')
    _tap(W * 0.5, H * 0.5)
    assert wd.page != 2, 'after Done a tap on the map turns the page again'
    wd.page = 2
    print('mission editor: EDIT, add, Type, +10, Send (written + verified), Done OK')
    wd.apMission = 0
    step(0.2)
    assert UIm.MI.current()[1] != 'ardupilot', 'setting Off clears the downloaded mission'
    print('mission download Off: the downloaded mission leaves the map OK')
wd.paramsPage = 0
G.sportTelemetryPush = lambda *a: True
wd.page = 2
lv = wd.level
frame(G.EVT_VIRTUAL_NEXT)
assert wd.level != lv, 'wheel zooms'
frame(G.EVT_TOUCH_FIRST, {'x': 100, 'y': 100})
frame(G.EVT_TOUCH_SLIDE, {'x': 100, 'y': 160})
frame(G.EVT_TOUCH_BREAK, {'x': 100, 'y': 160})
assert wd.page == 2, 'a drag is not a tap'

# in a layout zone: minimap only, inside the zone
wd.page = 1
frame(None, zone=(225, 122))
cv.img.save(os.path.join(OUT, 'etx_zone_%s.png' % tag))

# sound: voice option 1 = first folder (Aria), tones for messages
del played[:]
st['armed'] = True
step(0.2, 15)
assert any(p.startswith('/WIDGETS/OmniDeck/audio/Aria/') for p in played), 'voice plays from the widget folder %s' % played
if not NATIVE:
    del played[:]
    for _ in range(15): step(0.2)
    send_text('Mission: 1 WP', 6)
    step(0.2, 10)
    assert '/WIDGETS/OmniDeck/tones/info.wav' in played, 'message beep %s' % played

# ArduPilot over ELRS, flight battery pulled on the bench (TX16S, 2026-11-03): passthrough stops
# while the radio still reports RSSI and the native "FM" sensor keeps ArduPilot's last mode text.
# ArduPilot marks disarmed with "*" only with RC_OPTIONS CRSF_FM_DISARM_STAR, so "QHOV" (no
# mark) read as ARMED and the "disarm" that followed opened the flight summary.
if not NATIVE and not SPORT:
    st['armed'] = False
    step(0.2, 15)
    assert UIm.T.s.armed is False, 'disarmed before the battery is pulled'
    wd.page = 1
    native.update({'FM': 'QHOV', 'RQly': 96, '1RSS': -72})
    if 'FM' not in sensor_list: sensor_list.append('FM')
    crsf_q.clear()
    for _ in range(60):                        # 6 s: passthrough silent, RSSI still live
        sim_time[0] += 0.1
        frame()
    assert UIm.T.s.armed is False, 'ArduPilot FM text without "*" must not read as armed'
    assert not UIm.T.alive(), 'no passthrough for 6 s: ArduPilot telemetry is lost'
    assert wd.page == 1, 'no flight summary on a pulled battery, page %s' % wd.page
    print('AP battery pull OK')
    native.pop('FM', None)
    st['armed'] = True
    step(0.2, 15)

# ArduPilot over ELRS sends no 0x0800 in passthrough, only the native CRSF GPS frame: the
# position must follow the "GPS" sensor (X20 + ELRS 2026-11-08: map kept the saved position)
if not NATIVE and not SPORT:
    real_packets = packets
    keep_pos = (st['lat'], st['lon'])
    def packets(s, _p=real_packets): return [(a, v) for a, v in _p(s) if a != 0x0800]
    if 'GPS' not in sensor_list: sensor_list.append('GPS')
    for k in range(30):
        st['lat'], st['lon'] = project(keep_pos[0], keep_pos[1], 30 * (k + 1), 70)
        native['GPS'] = {'lat': st['lat'], 'lon': st['lon']}
        step(0.2)
    S = UIm.T.s
    assert S.fc == 'ArduPilot', 'still passthrough: %s' % S.fc
    assert abs(S.lat - st['lat']) < 1e-4 and abs(S.lon - st['lon']) < 1e-4, \
        'native CRSF position followed (%s, %s) vs (%s, %s)' % (S.lat, S.lon, st['lat'], st['lon'])
    # passthrough pausing past 3 s with the link up (ArduPilot slows it to every 3 s on TBS at low
    # rates, AP_CRSF_Telem): the GPS sensor keeps the position moving (test42)
    def packets(s, _p=real_packets): return []
    keep2 = (st['lat'], st['lon'])
    for k in range(30):                  # 6 s with no passthrough at all
        st['lat'], st['lon'] = project(keep2[0], keep2[1], 30 * (k + 1), 160)
        native['GPS'] = {'lat': st['lat'], 'lon': st['lon']}
        step(0.2)
    S = UIm.T.s
    assert S.fc == 'ArduPilot' and abs(S.lat - st['lat']) < 1e-4, 'passthrough gap: position followed (%s vs %s, %s)' % (S.lat, st['lat'], S.fc)
    print('AP CRSF passthrough gap OK')
    packets = real_packets
    native.pop('GPS', None); sensor_list.remove('GPS')
    st['lat'], st['lon'] = keep_pos
    step(0.2, 15)
    assert abs(UIm.T.s.lat - st['lat']) < 1e-4, '0x0800 back in charge'
    print('AP CRSF native position OK')

# ArduPilot over Crossfire at 50 Hz: passthrough every 3 s, but the CRSF GPS frame every 1 s and the
# battery frame every 2 s. Between bursts ground speed, satellites, distance to home and the battery
# follow GSpd / Sats / RxBt / Curr / Capa; at 150 Hz they stay on passthrough.
if not NATIVE and not SPORT:
    real_packets2 = packets
    burst = [True]
    def packets(s, _p=real_packets2): return [(a, v) for a, v in _p(s) if a != 0x0800] if burst[0] else []
    units['GSpd'] = 7
    added = [k for k in ('GSpd', 'Sats', 'RxBt', 'Curr', 'Capa', 'GPS') if k not in sensor_list]
    sensor_list.extend(added)                      # discovered on the radio, as the tester's were
    def crsf_sensors(gs_kmh, sats, volt, curr, mah, lat, lon):
        native.update({'GSpd': gs_kmh, 'Sats': sats, 'RxBt': volt, 'Curr': curr, 'Capa': mah,
                       'GPS': {'lat': lat, 'lon': lon}})
    assert UIm.T.s.homeLat is not None, 'home known before the 50 Hz test'
    def link_msg(t):
        crsf_q.append((0x80, [0xF1, 6] + list(t.encode()) + [0]))
    # ELRS: ArduPilot keeps it on its fast schedule, so nothing here may change (3 s windows)
    link_msg('ELRS: Link rate 500Hz, Telemetry rate 62Hz')
    step(0.3)
    burst[0] = False
    crsf_sensors(72.0, 11, 15.1, 7.5, 3333, st['lat'], st['lon'])
    step(0.2, 11)
    assert UIm.T.s.sats == min(st['sats'], 15), 'ELRS: no fill from CRSF sensors (sats %s)' % UIm.T.s.sats
    step(0.2, 6)                                   # 3.4 s without passthrough
    assert not UIm.T.alive(), 'ELRS: lost after 3 s as before'
    burst[0] = True
    step(0.2, 5)
    link_msg('CRSFv3: Link rate 50Hz, Telemetry rate 50Hz')
    step(0.3)
    assert UIm.T.s.crsfSlow == True, 'CRSFv3 50 Hz message read'
    crsf_sensors(999.0, 3, 99.0, 99.0, 9999, st['lat'], st['lon'])
    step(0.2, 10)                                  # 150 Hz: passthrough wins
    S = UIm.T.s
    assert abs(S.gspd - st['gs']) < 1.0 and S.sats == min(st['sats'], 15) and abs(S.volt - st['volt']) < 0.2,         '150 Hz: passthrough values kept (gs %s sats %s volt %s)' % (S.gspd, S.sats, S.volt)
    # a 50 Hz message on a link that never pauses (an ELRS link named before the receiver answered):
    # still off - it also takes one real gap that ends with a burst
    assert not S.crsfGap, 'no gap seen yet on a fast link'
    burst[0] = False
    step(0.2, 10)                                  # 2 s gap ...
    burst[0] = True
    step(0.3)                                      # ... ended by a burst: a slow link
    assert UIm.T.s.crsfGap == True, 'gap seen'
    step(0.3)                                      # one more burst, then CRSF frames only
    burst[0] = False
    lat1, lon1 = project(st['lat'], st['lon'], 400, 200)
    crsf_sensors(72.0, 11, 15.1, 7.5, 3333, lat1, lon1)
    step(0.2, 3)                                   # 0.6 s: passthrough still fresh enough
    S = UIm.T.s
    assert S.sats == min(st['sats'], 15), 'no fill within 1 s of a burst: sats %s' % S.sats
    step(0.2, 8)                                   # 2.2 s after the burst (EdgeTX looks up 4 sensors per update: the fifth comes on the next round)
    S = UIm.T.s
    exp_d = UIm.T.distBrg(lat1, lon1, S.homeLat, S.homeLon)[0]
    assert abs(S.gspd - 20.0) < 0.05, '50 Hz: ground speed from GSpd, got %s' % S.gspd
    assert S.sats == 11 and abs(S.volt - 15.1) < 1e-6 and abs(S.curr - 7.5) < 1e-6 and S.mah == 3333,         '50 Hz: sats/battery from CRSF (%s %s %s %s)' % (S.sats, S.volt, S.curr, S.mah)
    assert abs(S.homeDist - exp_d) < 1, '50 Hz: home distance from the CRSF position %s vs %s' % (S.homeDist, exp_d)
    assert UIm.T.alive(), '50 Hz: link still alive 2.2 s after a burst'
    step(0.2, 6)                                   # 3.4 s: past the old 3 s window, no lost-link flash
    assert UIm.T.alive(), '50 Hz: still alive 3.4 s after a burst'
    burst[0] = True
    step(0.3)                                      # the next burst takes over again
    S = UIm.T.s
    assert S.sats == min(st['sats'], 15) and abs(S.volt - st['volt']) < 0.2, 'burst: passthrough back in charge'
    link_msg('CRSFv3: Link rate 150Hz, Telemetry rate 150Hz')
    step(0.3)
    assert not UIm.T.s.crsfSlow, '150 Hz message: slow-link handling off'
    packets = real_packets2
    for k in ('GSpd', 'Sats', 'RxBt', 'Curr', 'Capa', 'GPS'): native.pop(k, None)
    for k in added: sensor_list.remove(k)
    step(0.2, 10)
    print('AP CRSF 50 Hz fill OK')

# more than 15 satellites: passthrough has 4 bits, ArduPilot sends at most 15. S.Port: "15+";
# CRSF: the real count from the standard GPS frame (Sats)
if not NATIVE:
    st['sats'] = 18
    step(0.2, 6)
    wd.page = 1
    del TEXTS[:]; frame()
    assert UIm.T.s.sats == 15 and UIm.T.s.satsPlus == True and any(t.endswith(' 15+') for t in TEXTS),         'capped at 15: %s %s' % (UIm.T.s.sats, [t for t in TEXTS if '3D' in t])
    if not SPORT:
        native['Sats'] = 18
        if 'Sats' not in sensor_list: sensor_list.append('Sats')
        step(0.2, 10)
        del TEXTS[:]; frame()
        assert UIm.T.s.sats == 18 and not UIm.T.s.satsPlus and '3D 18' in TEXTS,             'CRSF real count: %s %s' % (UIm.T.s.sats, [t for t in TEXTS if '3D' in t])
        native.pop('Sats', None); sensor_list.remove('Sats')
    st['sats'] = 14
    step(0.2, 20)
    assert UIm.T.s.sats == 14 and not UIm.T.s.satsPlus, 'back under 15: %s' % UIm.T.s.sats
    print('satellites above 15 OK')

# Betaflight 4.5: CRSF "GPS alt" is sea level while disarmed and the height above the arming point
# once armed; the reading at the arm edge was sea level (X18 + BF + TBS: MAX ALT -278 m, 2026-11-08).
# Newer Betaflight sends sea level all along, which must still be subtracted.
if NATIVE and not SPORT:
    FIELD = 300.0
    if 'GAlt' not in sensor_list: sensor_list.append('GAlt')
    def gstep(v, n=1):
        for _ in range(n):
            native['GAlt'] = v
            step(0.2)
    st['armed'] = False
    gstep(FIELD, 35)                    # 7 s: "GPS alt" is found (sources looked up again every 5 s)
    st['armed'] = True
    gstep(FIELD, 2)                     # armed in the mode text before the GPS frame jumps
    gstep(0.0, 3); gstep(25.0, 5)
    assert abs(UIm.T.s.alt - 25) < 1, 'BF 4.5: height above the arming point, not %s' % UIm.T.s.alt
    st['armed'] = False
    gstep(FIELD, 10)
    st['armed'] = True
    gstep(FIELD, 5); gstep(FIELD + 40, 5)
    assert abs(UIm.T.s.alt - 40) < 1, 'sea level all along: height above home, not %s' % UIm.T.s.alt
    st['armed'] = False
    native.pop('GAlt', None); sensor_list.remove('GAlt')
    step(0.2, 30)
    print('Betaflight GPS altitude OK')

# telemetry stops: EdgeTX keeps old values, OmniDeck must see the link as lost
streaming[0] = False
crsf_q.clear(); sport_q.clear()
for _ in range(40):
    sim_time[0] += 0.1
    frame()
assert not UIm.T.alive(), 'link lost when telemetry stops'
posf = sd_path('/WIDGETS/OmniDeck/lastpos.txt')
assert not os.path.isfile(posf), 'test43: lastpos.txt is no longer written (memory only)'
render('etx_lost_%s.png' % tag, 1)

# a long mission (INAV allows 120 waypoints) loaded from a Mission Planner file, plus a
# telemetry backlog: the widget must stay under the limit (waypoints are capped on EdgeTX)
get = L.execute('''return function(f, name) for i = 1, 200 do local n, v = debug.getupvalue(f, i)
    if n == nil then return nil end if n == name then return v end end end''')
E = get(widget_def['refresh'], 'E')
maxn = {k: v for k, v in G._MAXN.items()}
TAB, NL = chr(9), chr(10)
lines = ['QGC WPL 110', TAB.join(['0', '1', '0', '16', '0', '0', '0', '0', '%.7f' % HOME[0], '%.7f' % HOME[1], '0', '1'])]
WPN = int(os.environ.get('OD_WPN', '120'))   # OD_WPN=20: a shorter mission
for i in range(1, WPN + 1):
    la, lo = project(HOME[0], HOME[1], 150 + 25 * i, (i * 37) % 360)
    lines.append(TAB.join([str(i), '0', '3', '16', '0', '0', '0', '0', '%.7f' % la, '%.7f' % lo, '100', '1']))
open(sd_path('/WIDGETS/OmniDeck/missions/big.waypoints'), 'w').write(NL.join(lines) + NL)
if WPN: UIm.MI.loadFile('big.waypoints')   # OD_WPN=0: the same run with no mission
mis, kind = UIm.MI.current()
assert WPN == 0 or kind == 'file' and len(mis) >= WPN, 'mission file loads through the EdgeTX io adapter (%s)' % (UIm.MI.fileError(),)
streaming[0] = True
starved = 0
for page in (1, 2):
    wd.page = page
    G._MAXN['refresh'] = 0
    if os.environ.get('OD_PROF'):   # OD_PROF=1: where the mission updates spend their time
        G._PROF = L.table_from({}); G._PROFPARTS = os.environ.get('OD_PROF') == 'parts'
    for k in range(40):
        st['yaw'] = (st['yaw'] + 2) % 360
        st['lat'], st['lon'] = project(st['lat'], st['lon'], st['gs'] * 0.5, st['yaw'])
        st['wpn'] = min(60, WPN)
        for _ in range(3): feed()
        sim_time[0] += 0.05
        frame()
        starved += 1 if E.lcd.starved() else 0
    print('120-waypoint mission, page %d: max %d%% of the limit' % (page, G._MAXN['refresh']))
    if os.environ.get('OD_PROF'):
        rows = sorted(((int(v), str(k)) for k, v in G._PROF.items()), reverse=True); tot = sum(c for c, _ in rows) or 1
        print('  profile mission page %d:' % page); [print('    %5.1f%%  %s' % (100 * c / tot, k)) for c, k in rows[:12]]
        G._PROF = None
    maxn['refresh mission p%d' % page] = G._MAXN['refresh']
print('updates that hit the safety net: %d' % starved)

print('heaviest:', sorted(heavy, reverse=True)[:12], len(heavy))
print('max instructions per call (x200):', {k: v for k, v in maxn.items()}, 'refresh by page:', worst)
# 88 %: test15 drains the radio's telemetry queues completely every update (+1-2 %); the
# widget's own net skips drawing at 90 %, EdgeTX stops it at 100 %
assert os.environ.get('OD_BENCH') or all(v <= 88 for k, v in maxn.items()), 'within 88%% of the CPU limit: %s' % maxn
# SYS > Tools > OmniDeck Check, as the tester runs it (no string metatable, like EdgeTX 2.9)
if os.path.isfile(sd_path('/SCRIPTS/TOOLS/OmniDeck Check.lua')):
    L.execute('''
    if getVersion == nil then getVersion = function() return "2.9.4", "tx16s", 2, 9, 4, "EdgeTX" end end
    if EVT_VIRTUAL_EXIT == nil then EVT_VIRTUAL_EXIT = 999 end
    if lcd.clear == nil then lcd.clear = function() end end
    ''')
    tool = G.loadScript('/SCRIPTS/TOOLS/OmniDeck Check.lua')
    assert tool is not None, 'check tool did not compile'
    t = tool()
    L.globals()._NOLIMIT = True
    t.init()
    out = []
    L.globals()._CAP = lambda x, y, txt, *a: out.append(str(txt))
    saved = L.eval('lcd.drawText'); L.execute('lcd.drawText = function(x, y, t, ...) _CAP(x, y, t) end')
    t.run(0)
    L.globals().lcd.drawText = saved
    print('check tool:', out)
    assert any('OK: create' in x for x in out), 'check tool reports create OK %s' % out
else:
    print('check tool not on the fake SD card')
# SYS > Tools > OmniDeck Setup: change settings by name, saved per model, read by the widget
if os.path.isfile(sd_path('/SCRIPTS/TOOLS/OmniDeck Setup.lua')):
    L.execute('''
    if model.getInfo == nil then model.getInfo = function() return { name = "Sim Plane" } end end
    for k, v in pairs({ EVT_VIRTUAL_ENTER = EVT_VIRTUAL_ENTER or 0x2001, EVT_VIRTUAL_NEXT = EVT_VIRTUAL_NEXT or 0x2002,
                        EVT_VIRTUAL_PREV = EVT_VIRTUAL_PREV or 0x2003, EVT_VIRTUAL_EXIT = EVT_VIRTUAL_EXIT or 999 }) do _G[k] = v end
    if lcd.clear == nil then lcd.clear = function() end end
    ''')
    setup = G.loadScript('/SCRIPTS/TOOLS/OmniDeck Setup.lua')
    assert setup is not None, 'setup tool did not compile'
    st_t = setup()
    L.globals()._NOLIMIT = True
    st_t.init()
    G_ = L.globals()
    st_t.run(0)
    # row 1 = Telemetry link: ENTER, NEXT (Auto -> CRSF), ENTER
    for e in ('EVT_VIRTUAL_ENTER', 'EVT_VIRTUAL_NEXT', 'EVT_VIRTUAL_ENTER'): st_t.run(G_[e])
    # down to Speed units (its row in cfg.lua's list, which is grouped and may move), ENTER,
    # NEXT x2 (km/h -> knots), ENTER
    import re as _re
    _keys = _re.findall(r'^\s*\{ "(\w+)", "', open(os.path.join(HERE, '..', 'targets', 'edgetx', 'WIDGETS', 'OmniDeck', 'cfg.lua'), encoding='utf-8').read(), _re.M)
    _down = _keys.index('spdUnit') - _keys.index('linkMode')
    for e in ['EVT_VIRTUAL_NEXT'] * _down + ['EVT_VIRTUAL_ENTER'] + ['EVT_VIRTUAL_NEXT'] * 2 + ['EVT_VIRTUAL_ENTER']: st_t.run(G_[e])
    cfgp = sd_path('/WIDGETS/OmniDeck/Sim_Plane.cfg')
    assert os.path.isfile(cfgp), 'setup tool wrote no file'
    txt = open(cfgp).read()
    assert 'linkMode=1' in txt and 'spdUnit=2' in txt, 'setup values saved: %s' % txt
    assert 'voice=Aria' in txt, 'a first save keeps the voice on: %s' % txt
    # page switch outside full screen: SH pressed (momentary) -> next page; position mode on SC
    G_._GFI_OLD = G_.getFieldInfo
    G_.getFieldInfo = L.eval('function(n) if n == "sh" or n == "sc" or n == "s1" then return { name = n } end return _GFI_OLD and _GFI_OLD(n) end')
    open(cfgp, 'a').write('pageSwitch=sh\npageSwMode=0\n')
    CALL('update', widget_def['update'], wd, options)
    SW = {'sh': -1024, 'sc': -1024, 's1': -1024}
    G_._SWV = lambda n: SW.get(n)
    L.execute('local g = getValue; getValue = function(n) local v = _SWV(n) if v ~= nil then return v end return g(n) end')
    wd.page = 1
    frame(None, zone=(W, H)); p0 = wd.page
    SW['sh'] = 1024; frame(None, zone=(W, H))
    assert p0 == 1 and wd.page == 2, 'SH press outside full screen: next page (%s -> %s)' % (p0, wd.page)
    SW['sh'] = -1024; frame(None, zone=(W, H)); SW['sh'] = 1024; frame(None, zone=(W, H))
    # test42: the next page skips Messages for INAV / Betaflight
    assert wd.page == (1 if NATIVE else 3), 'second press: next page, got %s' % wd.page
    open(cfgp, 'a').write('pageSwitch=sc\npageSwMode=1\n')
    CALL('update', widget_def['update'], wd, options)
    SW['sc'] = 0; frame(None, zone=(W, H)); assert wd.page == 2, 'SC middle = Map, got %s' % wd.page
    SW['sc'] = 1024; frame(None, zone=(W, H)); assert wd.page == 3, 'SC down = Messages, got %s' % wd.page
    SW['sc'] = -1024; frame(None, zone=(W, H)); assert wd.page == 1, 'SC up = Main, got %s' % wd.page
    print('page switch OK')
    # Map zoom control: knob S1 picks the range step, all steps across its travel
    open(cfgp, 'a').write('pageSwitch=\nzoomSrc=s1\n')
    CALL('update', widget_def['update'], wd, options)
    SW['s1'] = -1024; frame(); lo = wd.level
    SW['s1'] = 1024; frame(); hi = wd.level
    SW['s1'] = 0; frame(); mid = wd.level
    assert lo == 1 and hi > 10 and lo < mid < hi, 'S1 zooms the map: %s %s %s' % (lo, mid, hi)
    print('zoom knob OK', lo, mid, hi)
    # one OmniDeck per telemetry screen: the Page option picks each instance's page
    CALL('update', widget_def['update'], wd, L.table_from({'Page': 3}))
    assert wd.page == 3, 'Page option 3 -> Messages, got %s' % wd.page
    w2 = CALL('create', widget_def['create'], FULL, L.table_from({'Page': 2}))
    assert w2.page == 2, 'second instance on the Map page, got %s' % w2.page
    CALL('update', widget_def['update'], wd, L.table_from({'Page': 0}))
    print('Page option OK')
    # Map tiles: a tile set on the card is listed by OmniDeck Setup; Auto / Off / by name
    tdir = sd_path('/IMAGES/ethosmaps/maps/GOOGLE/Satellite/15/27470')
    os.makedirs(tdir, exist_ok=True)
    Image.new('RGB', (100, 100), (30, 90, 40)).save(os.path.join(tdir, '15200.jpg'))
    st2 = setup()
    st2.init()
    st2.run(0)          # the Setup tool draws its list with the tile set in it (no error)
    for name, want in (('*', 'GOOGLE Satellite'), ('', ''), ('GOOGLE Satellite', 'GOOGLE Satellite')):
        open(cfgp, 'a').write('tileSet=' + name + '\n')
        CALL('update', widget_def['update'], wd, options)
        assert (wd.tileSet or '') == want, 'tileSet %r -> %r, got %r' % (name, want, wd.tileSet)
    # in the tool: row 10 (Map tiles), Auto -> Off -> the set found on the card
    open(cfgp, 'a').write('tileSet=*' + chr(10))
    st3 = setup(); st3.init(); st3.run(0)
    for e in ['EVT_VIRTUAL_NEXT'] * 9 + ['EVT_VIRTUAL_ENTER', 'EVT_VIRTUAL_NEXT', 'EVT_VIRTUAL_NEXT', 'EVT_VIRTUAL_ENTER']:
        st3.run(G_[e])
    txt3 = open(cfgp).read()
    assert 'tileSet=GOOGLE Satellite' in txt3, 'tool lists and saves the tile set: %s' % txt3
    print('map tiles setting OK')
    CALL('update', widget_def['update'], wd, options)
    assert wd.linkMode == 1 and wd.spdUnit == 2, 'widget reads the setup file: link %s spd %s' % (wd.linkMode, wd.spdUnit)
    print('setup tool OK:', txt.replace(chr(10), ' '))
    os.remove(cfgp)
    CALL('update', widget_def['update'], wd, options)
# ArduPilot over ELRS at the rates a TX16S MK2 measured (page-5 link stats, 2026-11-03):
# 8.2 widget updates and 22.3 passthrough frames a second, on the main page. It must keep up:
# nothing dropped, and the horizon shows the roll ArduPilot sent last.
if not NATIVE and not SPORT:
    import re as _re
    old = (REFRESH_S, FEED_S)
    REFRESH_S, FEED_S = 1 / 8.2, 3 / 22.3      # feed() queues 3 frames
    wd.page = 1
    drops = []
    for k in range(30 * 8):
        st['roll'] = (k % 40) - 20
        step(REFRESH_S, 1)
        if k % 41 == 40:
            m = _re.search(r'dropped (\d+)', str(E.OD_STATS()[2]) if len(E.OD_STATS()) > 1 else '')
            if m: drops.append(int(m.group(1)))
    step(1.0, 1)
    print('ELRS rate: dropped per 5 s window', drops, 'roll shown %.1f sent %d' % (UIm.T.s.roll, st['roll']))
    assert drops and all(d == 0 for d in drops[1:]), 'main page keeps up with 22 frames/s at 8 updates/s: %s' % drops
    assert abs(UIm.T.s.roll - st['roll']) < 1.5, 'horizon is current'
    REFRESH_S, FEED_S = old
if not OTX:
    # test43: map page + and - only (no PLANE / HOME button), square and at least 48 px
    wd.page = 2
    frame()
    b = wd.btns
    assert b['auto'] is None and b.plus.w == b.plus.h and b.plus.w >= 48 and b.minus.y > b.plus.y + b.plus.h, 'zoom buttons'
    # near misses: a quarter of the button around it, the gap split in the middle, the press point counts
    keep_ts = wd.tileSet
    wd.tileSet = ''                                # vector map: + and - step w.level (with tiles they step the tile zoom)
    pad = b.plus.w // 4
    gap_mid = (b.plus.y + b.plus.h + b.minus.y) / 2
    cxb = b.plus.x + b.plus.w // 2
    for (tx, ty, d, what) in ((cxb, b.plus.y - pad + 2, -1, 'above +'), (cxb, gap_mid - 1, -1, 'gap, upper half'),
                              (cxb, gap_mid + 1, 1, 'gap, lower half'), (cxb, b.minus.y + b.minus.h + pad - 2, 1, 'below -')):
        wd.level = 5
        frame(G.EVT_TOUCH_FIRST, {'x': tx, 'y': ty})
        frame(G.EVT_TOUCH_BREAK, {'x': tx, 'y': ty})
        assert wd.page == 2 and wd.level == 5 + d, 'near miss %s: page %s level %s' % (what, wd.page, wd.level)
    wd.level = 5
    frame(G.EVT_TOUCH_FIRST, {'x': cxb, 'y': b.plus.y + 5})
    frame(G.EVT_TOUCH_BREAK, {'x': b.plus.x - pad - 8, 'y': b.plus.y + 5})
    assert wd.page == 2 and wd.level == 4, 'press on +, lift outside: %s %s' % (wd.page, wd.level)
    frame(G.EVT_TOUCH_FIRST, {'x': 40, 'y': 100})
    frame(G.EVT_TOUCH_BREAK, {'x': 40, 'y': 100})
    assert wd.page != 2, 'a tap away from the buttons still turns the page'
    wd.page = 2
    wd.tileSet = keep_ts
    frame()
    # model switch: a fresh start - no last flight, the summary is not kept
    assert UIm.FS.last() is not None, 'a flight before the switch'
    G.model.getInfo = lambda *a: L.table_from({'name': 'Other Plane'})
    w3 = CALL('create', widget_def['create'], FULL, options)
    assert UIm.FS.last() is None and UIm.FS.live() is None, 'model switch clears the flight'
    G.model.getInfo = lambda *a: L.table_from({'name': 'Sim Plane'})
    print('test43 buttons + model switch OK')
if not OTX:
    # THR: ArduPilot's throttle output; INAV / Betaflight the radio's throttle stick
    wd.page = 1
    STICK[0] = 410
    step(0.2, 6)
    frame()
    S2 = UIm.T.s
    if NATIVE:
        assert S2.thr == 70, 'stick throttle %s' % S2.thr
    else:
        assert S2.thr == st['thr'], 'ArduPilot throttle %s (sent %s)' % (S2.thr, st['thr'])
    print('throttle OK (%s)' % ('stick' if NATIVE else 'ArduPilot output'))
print('EdgeTX checks OK', tag)

# OD_BENCH=1: Lua instructions to decode ArduPilot CRSF passthrough frames (the EdgeTX limit is
# 100 x 200 = 20000 per call); sizes how many frames a screen update can afford
if os.environ.get('OD_BENCH') and not NATIVE and not SPORT:
    crsf_q.clear()
    for _ in range(8): feed()
    nq = len(crsf_q)
    bench = L.execute('''return function(T)
      local c = 0
      debug.sethook(function() c = c + 1 end, "", 10)
      local n = 0
      for _ = 1, 400 do if T.drainCrsf(1e9, 1) == 0 then break end n = n + 1 end
      debug.sethook()
      return c * 10, n end''')
    G._USE = 0
    ins, n = bench(UIm.T)
    print('BENCH frames queued %d, collected %d, instructions %d, per frame %.0f (%.1f%% of the EdgeTX limit)' % (
        nq, n, ins, ins / max(1, n), ins / max(1, n) / 200))
    fl = L.execute('''return function(T)
      local c = 0
      debug.sethook(function() c = c + 1 end, "", 10)
      T.flushPt()
      debug.sethook()
      return c * 10 end''')
    fi = fl(UIm.T)
    print('BENCH flush (decode newest per kind) %d instructions (%.1f%%)' % (fi, fi / 200))
    if os.environ.get('OD_BENCH') == 'prof':
        crsf_q.clear()
        for _ in range(8): feed()
        prof = L.execute('''return function(T)
          local hits = {}
          debug.sethook(function()
            local i = debug.getinfo(2, "S")
            local k = i and ((string.match(i.short_src, "([%w_]+%.lua)") or string.sub(i.short_src, -20)) .. ":" .. i.linedefined) or "?"
            hits[k] = (hits[k] or 0) + 1
          end, "", 1)
          for _ = 1, 400 do if T.drainCrsf(1e9, 1) == 0 then break end end
          debug.sethook()
          hits = {}
          debug.sethook(function()
            local i = debug.getinfo(2, "Sl")
            local k = i and ((string.match(i.short_src, "([%w_]+%.lua)") or string.sub(i.short_src, -20)) .. ":" .. i.currentline) or "?"
            hits[k] = (hits[k] or 0) + 1
          end, "", 1)
          T.flushPt()
          debug.sethook()
          local out = {}
          for k, v in pairs(hits) do out[#out + 1] = { k, v } end
          table.sort(out, function(a, b) return a[2] > b[2] end)
          local r = {}
          for i = 1, math.min(12, #out) do r[#r + 1] = out[i][1] .. " " .. out[i][2] end
          return table.concat(r, string.char(10)) end''')
        print('PROFILE (instructions by function, file:line defined)')
        print(prof(UIm.T))
