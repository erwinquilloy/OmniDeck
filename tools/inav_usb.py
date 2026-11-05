"""
Check OmniDeck's INAV mission decoding against a real INAV board over USB.

Reads the FC variant/version, mission info and every waypoint with plain MSPv1
over the USB serial port (read-only: nothing is written to the board). Each
reply is then cut into telemetry chunks exactly as INAV sends them over S.Port
and CRSF, fed through scripts/omnideck/mspclient.lua, and the Lua result is
compared with the bytes decoded here.

  python tools/inav_usb.py [COMx]        (port auto-detected if omitted)
  python tools/inav_usb.py --selftest     (no board: synthetic replies)

Close the INAV Configurator first (it holds the port). Upload a mission to the
board with the Configurator beforehand if it has none.
"""
import os, struct, sys, time
import serial, serial.tools.list_ports
from lupa import lua54

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'scripts', 'omnideck')


def pick_port():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if args:
        return args[0]
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        txt = (p.description or '') + ' ' + (p.manufacturer or '')
        if any(k in txt for k in ('STM', 'Virtual COM', 'INAV', 'AT32', 'CDC')):
            return p.device
    if len(ports) == 1:
        return ports[0].device
    sys.exit('no INAV board found; ports: %s' % [p.device + ' ' + (p.description or '') for p in ports])


def msp(ser, cmd, payload=b''):
    frame = bytes([len(payload), cmd]) + payload
    crc = 0
    for b in frame:
        crc ^= b
    ser.write(b'$M<' + frame + bytes([crc]))
    deadline = time.time() + 1.5
    buf = b''
    while time.time() < deadline:
        buf += ser.read(64)
        i = buf.find(b'$M')
        if i >= 0 and len(buf) >= i + 5:
            size, rcmd = buf[i + 3], buf[i + 4]
            if len(buf) >= i + 6 + size:
                if buf[i + 2:i + 3] == b'!':
                    raise RuntimeError('FC rejected cmd %d' % cmd)
                body = buf[i + 5:i + 5 + size]
                c = size ^ rcmd
                for b in body:
                    c ^= b
                if c != buf[i + 5 + size]:
                    raise RuntimeError('bad CRC on cmd %d' % cmd)
                if rcmd == cmd:
                    return body
                buf = buf[i + 6 + size:]
    raise RuntimeError('no reply to cmd %d' % cmd)


def chunks(cmd, body, transport):
    """the telemetry chunks INAV's msp_shared sends for this reply"""
    data = [len(body), cmd] + list(body)
    if transport == 'sport':
        c = 0
        for b in data:
            c ^= b
        data.append(c)
    per = 5 if transport == 'sport' else 57
    out, seq = [], 0
    for i in range(0, len(data), per):
        out.append([0x20 | (0x10 if i == 0 else 0) | seq] + data[i:i + per])
        seq = (seq + 1) & 0x0F
    return out



def check_in_lua(replies):
    """reassemble every real reply from its S.Port and CRSF chunks, then decode the WPs in Lua"""
    for transport in ('sport', 'crsf'):
        L = lua54.LuaRuntime(unpack_returned_tuples=True)
        M = L.execute(open(os.path.join(SRC, 'mspclient.lua'), encoding='utf8').read())
        for cmd, body in replies:
            done = False
            for c in chunks(cmd, body, transport):
                done = M._onChunk(L.table_from(c))
            assert done, 'reply %d not completed over %s' % (cmd, transport)
        print('%s: all %d replies reassembled' % (transport, len(replies)))
    L = lua54.LuaRuntime(unpack_returned_tuples=True)
    M = L.execute(open(os.path.join(SRC, 'mspclient.lua'), encoding='utf8').read())
    arm = L.execute("""local M = ... return function(cmd)
      for i = 1, 60 do local n = debug.getupvalue(M._handle, i) if n == nil then break end
        if n == "waitCmd" then debug.setupvalue(M._handle, i, cmd) end
        if n == "wpCount" then debug.setupvalue(M._handle, i, 255) end end end""", M)
    wpr = [b for c, b in replies if c == 118]
    for b in wpr:
        arm(118)
        M._handle(118, L.table_from(list(b)), False)
    wl = M.waypoints()
    assert len(wl) == len(wpr), (len(wl), len(wpr))
    for k, b in enumerate(wpr, 1):
        w = wl[k]
        lat, lon, alt = struct.unpack_from('<iii', b, 2)
        assert abs(w.lat - lat / 1e7) < 1e-9 and abs(w.lon - lon / 1e7) < 1e-9 and abs(w.alt - alt / 100) < 1e-9
        assert w.idx == b[0] and w.action == b[1] and w.flags == b[20]
    print('Lua decode matches for %d waypoint(s)' % len(wpr))


if '--selftest' in sys.argv:
    wp = lambda i, a, la, lo, al, fl: bytes([i, a]) + struct.pack('<iiihhh', int(la * 1e7), int(lo * 1e7), int(al * 100), 0, 0, 0) + bytes([fl])
    check_in_lua([(2, b'INAV'), (20, bytes([0, 120, 1, 3])), (118, wp(1, 1, 43.49, 142.89, 50, 0)),
                  (118, wp(2, 3, -33.86, 151.2, 80.5, 0)), (118, wp(3, 8, 51.5, -0.12, 0, 0xA5)), (121, bytes([3, 5, 1, 2, 0, 0, 0]))])
    sys.exit(0)

port = pick_port()
print('port', port)
ser = serial.Serial(port, 115200, timeout=0.05)
time.sleep(0.3)
ser.reset_input_buffer()
variant = msp(ser, 2).decode(errors='replace')
ver = msp(ser, 3)
print('FC %s %d.%d.%d' % (variant, ver[0], ver[1], ver[2]))
info = msp(ser, 20)
print('mission: max %d valid %d count %d' % (info[1], info[2], info[3]))
replies = [(2, msp(ser, 2)), (20, info)]
for i in range(1, info[3] + 1):
    b = msp(ser, 118, bytes([i]))
    replies.append((118, b))
    lat, lon, alt = struct.unpack_from('<iii', b, 2)
    p1, p2, p3 = struct.unpack_from('<hhh', b, 14)
    print('  WP%-3d action %d  %.7f %.7f  alt %.2f m  p1 %d p2 %d p3 %d  flags 0x%02X'
          % (b[0], b[1], lat / 1e7, lon / 1e7, alt / 100, p1, p2, p3, b[20]))
    if b[20] == 0xA5:
        break
nav = msp(ser, 121)
print('nav status: mode %d state %d activeWp %d error %d' % (nav[0], nav[1], nav[3], nav[4]))
replies.append((121, nav))
ser.close()
check_in_lua(replies)
