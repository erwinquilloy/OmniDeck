"""
ArduPilot's MAVlite side for the OmniDeck PARAMS tests: a copy of the uplink parser
(AP_Frsky_MAVlite_SPortToMAVlite.cpp), the param handler (AP_Frsky_MAVliteMsgHandler.cpp:
PARAM_REQUEST_READ 20 / PARAM_SET 23 -> PARAM_VALUE 22, "Param read failed (NAME)" for an
unknown name) and the downlink encoder (AP_Frsky_MAVlite_MAVliteToSPort.cpp).
dup=True sends every downlink frame twice, as ArduPilot does on F.Port.
"""
import struct

def ck(c, b):
    c += b; c += c >> 8; return c & 0xFF

class FakeAP:
    """ArduPilot side: uplink parser, param store, downlink encoder."""
    def __init__(self, params, dup=False):
        self.p = dict(params); self.down = []; self.dup = dup; self.reset(); self.texts = []
        self.sets = 0
    def reset(self):
        self.cs = 0; self.exp = 0; self.st = 'LEN'; self.buf = []
    def uplink(self, appid, value):
        raw = [appid & 0xFF, appid >> 8] + list(struct.pack('<I', value & 0xFFFFFFFF))
        seq = raw[0] & 0x3F
        if seq == 0: self.reset()
        if seq != self.exp: self.st = 'ERR'; return
        self.cs = ck(self.cs, seq); self.exp = seq + 1
        for b in raw[1:]:
            if self.st == 'LEN': self.len = b; self.cs = ck(self.cs, b); self.st = 'ID'
            elif self.st == 'ID':
                self.id = b; self.cs = ck(self.cs, b); self.st = 'CK' if self.len == 0 else 'PL'
            elif self.st == 'PL':
                self.buf.append(b); self.cs = ck(self.cs, b)
                if len(self.buf) >= self.len: self.st = 'CK'
            elif self.st == 'CK':
                if b != self.cs: self.st = 'ERR'; return
                self.st = 'DONE'; self.handle(self.id, bytes(self.buf)); return
    # Stratos mission download (AP_Frsky_MAVliteMsgHandler): compact MISSION_COUNT / MISSION_ITEM_INT
    mission = []          # [(cmd, frame, lat, lon, alt, p1, p3)], index 0 = home slot
    mstamp = 1000
    def mission_reply(self, mid, pl):
        if mid == 43:
            return 44, struct.pack('<HI', len(self.mission), self.mstamp)
        if mid == 51:
            seq = struct.unpack('<H', pl[:2])[0]
            if seq >= len(self.mission): return 47, struct.pack('<HB', seq, 13)
            it = self.mission[seq]
            cmd, frame, lat, lon, alt, p1, p3 = it[:7]
            p2 = it[7] if len(it) > 7 else 0.0
            return 73, struct.pack('<HHBiifff', seq, cmd, frame, int(round(lat * 1e7)), int(round(lon * 1e7)), alt, p1, p3) + struct.pack('<f', p2)
        # mission write (Stratos, OmniDeck's editor): same rules as AP_Frsky_MAVliteMsgHandler
        if mid == 45:
            if self.armed: return 47, struct.pack('<HB', 0xFFFF, 14)
            self.mission[:] = []; self.mstamp += 1
            return 47, struct.pack('<HB', 0xFFFF, 0)
        if mid == 73:
            seq, cmd, frame, x, y, z, p1, p3 = struct.unpack('<HHBiifff', pl[:25])
            p2 = struct.unpack('<f', pl[25:29])[0] if len(pl) >= 29 else 0.0
            if self.armed: return 47, struct.pack('<HB', seq, 14)
            total = len(self.mission)
            if seq == 0 or seq > max(total, 1): return 47, struct.pack('<HB', seq, 13)
            if abs(x) > 900000000: return 47, struct.pack('<HB', seq, 10)
            if total == 0: self.mission.append((16, 0, 0.0, 0.0, 0.0, 0.0, 0.0))
            f32 = lambda v: struct.unpack('<f', struct.pack('<f', v))[0]
            item = (cmd, frame, x / 1e7, y / 1e7, f32(z) + self.alt_bias, f32(p1), f32(p3), f32(p2))
            if seq < len(self.mission): self.mission[seq] = item
            else: self.mission.append(item)
            self.mstamp += 1
            return 47, struct.pack('<HB', seq, 0)
        return None
    armed = False
    alt_bias = 0.0      # tests: a write that stores something else than was sent
    def handle(self, mid, pl):
        r = self.mission_reply(mid, pl)
        if r:
            self.send_msg(r[0], r[1]); return
        if mid == 20:
            name = pl[:16].decode()
            if name not in self.p: self.texts.append('Param read failed (%s)' % name); return
            self.reply(name)
        elif mid == 23:
            v = struct.unpack('<f', pl[:4])[0]; name = pl[4:20].decode()
            if name not in self.p: self.texts.append('Param write failed (%s)' % name); return
            self.sets += 1
            self.p[name] = struct.unpack('<f', struct.pack('<f', v))[0]
            self.reply(name)
    def reply(self, name):
        self.send_msg(22, struct.pack('<f', self.p[name]) + name.encode()[:16])
    def send_msg(self, msgid, payload):
        msg = [len(payload), msgid] + list(payload)
        cs, seq, pk = 0, 0, None
        out = []
        def start():
            nonlocal seq, cs
            p = [seq]; cs = ck(cs, seq); seq += 1; return p
        pk = start()
        for b in msg:
            pk.append(b); cs = ck(cs, b)
            if len(pk) == 6: out.append(pk); pk = start()
        pk.append(cs); out.append(pk)
        for p in out:
            p += [0] * (6 - len(p))
            appid = p[0] | (p[1] << 8); val = struct.unpack('<I', bytes(p[2:6]))[0]
            self.down.append((appid, val))
            if self.dup: self.down.append((appid, val))

