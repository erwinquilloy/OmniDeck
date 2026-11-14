"""mavcore.lua against pymavlink: request encoding, stream parsing over random envelope splits."""
import os, random, struct, sys
from lupa import lua52, lua54
from pymavlink.dialects.v20 import ardupilotmega as mav
HERE = os.path.dirname(os.path.abspath(__file__))
fails = 0
def check(name, ok):
    global fails
    print(('PASS ' if ok else 'FAIL ') + name); fails += 0 if ok else 1
for ver, RT in (('lua52', lua52), ('lua54', lua54)):
    L = RT.LuaRuntime()
    M = L.execute(open(os.path.join(HERE, 'mavcore.lua'), encoding='utf-8').read())
    # 1 request: pymavlink parses what we send
    req = bytes(list(M.paramRequest('AIRSPEED_CRUISE').values()))
    m = mav.MAVLink(None); m.robust_parsing = True
    msgs = m.parse_buffer(req) or []
    check('%s: PARAM_REQUEST_READ parses in pymavlink (crc ok)' % ver,
          len(msgs) == 1 and msgs[0].get_type() == 'PARAM_REQUEST_READ' and msgs[0].param_id == 'AIRSPEED_CRUISE'
          and msgs[0].param_index == -1 and msgs[0].target_system == 1)
    # 2 stream: heartbeat + noise packets + PARAM_VALUE, split into random envelopes
    ap = mav.MAVLink(None, srcSystem=1, srcComponent=1)
    stream = b''
    stream += ap.heartbeat_encode(1, 3, 0, 0, 4).pack(ap)
    for i in range(20):
        stream += ap.attitude_encode(i, 0.1, 0.2, 0.3, 0, 0, 0).pack(ap)
        stream += ap.vfr_hud_encode(18.0, 19.0, 90, 50, 120.0, 0.5).pack(ap)
    stream += ap.param_value_encode(b'AIRSPEED_CRUISE', 18.5, 9, 1000, 120).pack(ap)
    stream += ap.param_value_encode(b'TECS_CLMB_MAX', -2.25, 9, 1000, 1001).pack(ap)
    got = []
    M.onParam = lambda n, v: got.append((n, v))
    random.seed(1)
    i = 0
    while i < len(stream):
        n = random.randint(1, 58)
        chunk = stream[i:i + n]; i += n
        M.feed(L.table_from([0, len(chunk)] + list(chunk)))
    st = M.stats
    check('%s: all %d packets found' % (ver, 43), st.packets == 43 and st.bad == 0)
    check('%s: autopilot id from HEARTBEAT (1/1)' % ver, M.target == 1 and M.targetComp == 1)
    check('%s: PARAM_VALUE decoded (%s)' % (ver, got), len(got) == 2 and got[0][0] == 'AIRSPEED_CRUISE' and abs(got[0][1] - 18.5) < 1e-6 and abs(got[1][1] + 2.25) < 1e-6)
    # 3 float round trip
    for v in (0.0, 1.0, -1.0, 0.135, 18.5, 1048575.0, 1e-5):
        b = list(M.f2b(v).values())
        check('%s: f2b(%g) == struct' % (ver, v), bytes(b) == struct.pack('<f', v))
print('%d failed' % fails)
sys.exit(1 if fails else 0)
