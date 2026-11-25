#!/usr/bin/env python3
"""Checks the Ethos tile loader (targets/ethos/x18|x20/tiles.lua, test43) against Ethos's real
lcd.loadBitmap behaviour, and measures its Lua cost against the test42 loader.

    python tools/test_tiles_ethos.py [--old <tiles.lua of an older test>]

Ethos (b14ckyy's ETHOS-API-QUIRKS notes, simulator 1.6.4-26.1.2): lcd.loadBitmap() returns a
handle at once and decodes at the first draw; a MISSING file gives a handle of width 0 (no error,
no nil). The stub here does the same. Cases: a JPG set, a PNG-only set (the test42 loader locked
in .jpg on the first missing-file handle and showed nothing), Yaapu's Google folder only, tiles
missing at the edge of the covered area, and how many wakeups fill a screen.
"""
import os
import shutil
import sys
import tempfile

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS = [os.path.join(HERE, '..', 'targets', 'ethos', d, 'tiles.lua') for d in ('x18', 'x20')]


def runtime(sd):
    L = LuaRuntime()
    L.globals()._SD = sd.replace('\\', '/')
    L.execute('''
      local rawopen = io.open
      io.open = function(p, m) return rawopen(_SD .. p, m) end
      LOADS = 0
      lcd = { loadBitmap = function(p)
        LOADS = LOADS + 1
        local f = rawopen(_SD .. p, "rb")
        if f then f:close() return { path = p, width = function() return 100 end } end
        return { path = nil, width = function() return 0 end }    -- Ethos: no error, no nil
      end }
      system = nil
    ''')
    return L


def make_tiles(sd, base, z, xs, ys, ext, esri=False, yaapu=None, skip=()):
    for x in xs:
        for y in ys:
            if (x, y) in skip:
                continue
            if yaapu:
                d = os.path.join(sd, 'bitmaps', 'yaapu', 'maps', yaapu, str(z), str(y))
                name = 's_%d%s' % (x, ext)
            else:
                d = os.path.join(sd, 'bitmaps', 'ethosmaps', 'maps', *base.split('/'), str(z), str(y if esri else x))
                name = '%d%s' % (x if esri else y, ext)
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, name), 'wb').write(b'x')


def fill(L, TL, z, x0, y0, x1, y1, max_wakeups=200):
    """paint + wakeup until nothing is pending; returns wakeups used"""
    TL.want(z, x0, y0, x1, y1, (x0 + x1) // 2, (y0 + y1) // 2)
    for n in range(1, max_wakeups + 1):
        TL.process()
        if TL.pending() == 0:
            return n
    return None


def shown(TL, z, x0, y0, x1, y1):
    got = {}
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            b = TL.get(z, x, y)
            got[(x, y)] = None if b is None else (False if b is False else b.path)
    return got


def check(path):
    name = os.path.basename(os.path.dirname(path))
    z, x0, y0, x1, y1 = 16, 1000, 2000, 1008, 2004          # an X20 full map: 9 x 5 tiles
    rx, ry = range(x0 - 1, x1 + 2), range(y0 - 1, y1 + 2)   # plus the ring of one

    def fresh(setup):
        sd = tempfile.mkdtemp()
        setup(sd)
        L = runtime(sd)
        TL = L.execute('return dofile(...)', path)
        return sd, L, TL

    # 1. JPG set: every tile shown, centre first, in a few wakeups
    sd, L, TL = fresh(lambda sd: make_tiles(sd, 'GOOGLE/Satellite', z, rx, ry, '.jpg'))
    TL.setSet(L.table_from({'provider': 'GOOGLE', 'type': 'Satellite', 'minZ': 14, 'maxZ': 18}))
    TL.want(z, x0, y0, x1, y1, 1004, 2002)
    TL.process(1, 1)
    first = [k for k, v in shown(TL, z, x0, y0, x1, y1).items() if v]
    assert first == [(1004, 2002)], 'centre tile first: %s' % first
    n = fill(L, TL, z, x0, y0, x1, y1)
    s = shown(TL, z, x0, y0, x1, y1)
    assert all(isinstance(v, str) and v.endswith('.jpg') for v in s.values()), 'jpg set shown'
    assert TL.cached() == len(rx) * len(ry), 'visible + ring cached: %s' % TL.cached()
    print('  %s jpg set: %d tiles + ring in %d wakeups (test42: %d)' % (name, len(s), n, (len(rx) * len(ry) + 1) // 2))
    shutil.rmtree(sd)

    # 2. PNG-only set: the format is found with io.open, so PNG tiles show
    sd, L, TL = fresh(lambda sd: make_tiles(sd, 'ESRI/Satellite', z, rx, ry, '.png', esri=True))
    TL.setSet(L.table_from({'provider': 'ESRI', 'type': 'Satellite', 'minZ': 14, 'maxZ': 18}))
    fill(L, TL, z, x0, y0, x1, y1)
    s = shown(TL, z, x0, y0, x1, y1)
    assert all(isinstance(v, str) and v.endswith('.png') for v in s.values()), 'png-only set shown: %s' % list(s.values())[:3]
    print('  %s png-only ESRI set: shown' % name)
    shutil.rmtree(sd)

    # 3. Yaapu's Google folder only
    sd, L, TL = fresh(lambda sd: make_tiles(sd, None, z, rx, ry, '.png', yaapu='GoogleSatelliteMap'))
    TL.setSet(L.table_from({'provider': 'GOOGLE', 'type': 'Satellite', 'minZ': 14, 'maxZ': 18, 'dirY': 'GoogleSatelliteMap'}))
    fill(L, TL, z, x0, y0, x1, y1)
    s = shown(TL, z, x0, y0, x1, y1)
    assert all(isinstance(v, str) and '/yaapu/' in v for v in s.values()), 'yaapu fallback shown'
    print('  %s Yaapu Google folder: shown' % name)
    shutil.rmtree(sd)

    # 4. edge of the covered area: the right two columns are missing. The fast path hands back
    #    empty handles; the idle check (drawn tiles only) turns each into false
    miss = {(x, y) for x in (x1 - 1, x1, x1 + 1) for y in ry}
    sd, L, TL = fresh(lambda sd: make_tiles(sd, 'GOOGLE/Satellite', z, rx, ry, '.jpg', skip=miss))
    TL.setSet(L.table_from({'provider': 'GOOGLE', 'type': 'Satellite', 'minZ': 14, 'maxZ': 18}))
    fill(L, TL, z, x0, y0, x1, y1)
    clock = L.eval('function(t) os.clock = function() return t end end')
    t = 1000.0
    for _ in range(200):
        t += 0.31
        clock(t)
        TL.process()
        if TL.unverified() == 0 or all(v is False for k, v in shown(TL, z, x0, y0, x1, y1).items() if k in miss):
            break
    s = shown(TL, z, x0, y0, x1, y1)
    bad = [k for k, v in s.items() if (k in miss) != (v is False)]
    assert not bad, 'missing tiles marked, present ones kept: %s' % bad[:5]
    print('  %s missing tiles at the edge: marked as missing after the idle check' % name)
    shutil.rmtree(sd)

    # 5. moving one tile east: the left column goes, the new column (and ring) is queued
    sd, L, TL = fresh(lambda sd: make_tiles(sd, 'GOOGLE/Satellite', z, range(x0 - 1, x1 + 3), ry, '.jpg'))
    TL.setSet(L.table_from({'provider': 'GOOGLE', 'type': 'Satellite', 'minZ': 14, 'maxZ': 18}))
    fill(L, TL, z, x0, y0, x1, y1)
    n = fill(L, TL, z, x0 + 1, y0, x1 + 1, y1)
    assert TL.cached() == len(rx) * len(ry), 'cache window follows: %s' % TL.cached()
    assert all(isinstance(v, str) for v in shown(TL, z, x0 + 1, y0, x1 + 1, y1).values())
    print('  %s one tile east: new column in %d wakeup(s)' % (name, n))
    shutil.rmtree(sd)

    # 6. Lua cost per paint (want + get of every visible tile) and per filling wakeup
    sd, L, TL = fresh(lambda sd: make_tiles(sd, 'GOOGLE/Satellite', z, rx, ry, '.jpg'))
    TL.setSet(L.table_from({'provider': 'GOOGLE', 'type': 'Satellite', 'minZ': 14, 'maxZ': 18}))
    count = L.eval('''function(f, ...)
      local n = 0
      debug.sethook(function() n = n + 1 end, "", 1)
      f(...)
      debug.sethook()
      return n end''')
    paint = L.eval('''function(TL, z, x0, y0, x1, y1) return function()
      TL.want(z, x0, y0, x1, y1, (x0 + x1) // 2, (y0 + y1) // 2)
      for ty = y0, y1 do for tx = x0, x1 do TL.get(z, tx, ty) end end end end''')(TL, z, x0, y0, x1, y1)
    paint()
    worst = 0
    while True:
        worst = max(worst, count(TL.process))
        if TL.pending() == 0:
            break
    print('  %s Lua per paint (45 tiles): %d   worst filling wakeup: %d   (rebuild included)' % (
        name, count(paint), worst))
    shutil.rmtree(sd)


def main():
    for p in TARGETS:
        check(os.path.normpath(p))
    print('tile loader checks OK')


if __name__ == '__main__':
    main()
