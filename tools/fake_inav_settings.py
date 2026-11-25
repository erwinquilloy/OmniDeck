"""INAV 9.1 named settings over MSPv2 on the radio link, for tools/sim_edgetx.py.

The same answers as the fake in tools/sim.py (fc_msp.c: MSP_FC_VARIANT 2, MSP_FC_VERSION 3,
MSP_EEPROM_WRITE 250 refused while armed, MSP2_COMMON_SETTING 0x1003 / _SET_SETTING 0x1004 /
_SETTING_INFO 0x1007, MSP2_INAV_STATUS 0x2000), packed as msp_shared.c sends them:
  chunk = status (0x40 v2 | 0x10 first | 0x80 error | seq) + bytes
  CRSF:   request type 0x7A [0xC8, 0xEA, chunk...], reply type 0x7B [0xEA, 0xC8, chunk...]
  S.Port: request primId 0x30 (appId = bytes 1-2, value = bytes 3-6), reply primId 0x32
  bridge=True: mLRS (mspX) with Tx Ser Port = cbridge and the MSP-over-cbridge Tx firmware: CRSF MSP
          (0x7A) is dropped; raw MSPv2 frames ($X< / $X> / $X!) go in bridge frames: mLRS "mb" envelopes
          0x81 / 0x82 (0x66, seq, size, up to 57) or 0xAA, answered in the type last received
          [chunk byte, size, up to 58 bytes]
"""
import struct

def _s(t, mn, mx, v, sec=0, look=None): return {'t': t, 'min': mn, 'max': mx, 'v': v, 'sec': sec, 'look': look}

def settings():
    S = {
        'max_angle_inclination_rll': _s(3, 100, 900, 450), 'max_angle_inclination_pit': _s(3, 100, 900, 350),
        'fw_level_pitch_trim': _s(5, -10, 10, 1.5), 'roll_rate': _s(0, 4, 180, 18), 'pitch_rate': _s(0, 4, 180, 9),
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
    for ax, fw, mc in (('roll', (5, 7, 0, 50), (40, 30, 23)), ('pitch', (5, 7, 0, 50), (40, 30, 23)), ('yaw', (6, 10, None, 60), (85, 45, None))):
        for k, v in zip(('p', 'i', 'd', 'ff'), fw):
            if v is not None: S['fw_%s_%s' % (k, ax)] = _s(2, 0, 255, [v, v + 100], 0x10)
        for k, v in zip(('p', 'i', 'd'), mc):
            if v is not None: S['mc_%s_%s' % (k, ax)] = _s(2, 0, 255, [v + 100, v], 0x10)
    return S

_FMT = {0: '<B', 1: '<b', 2: '<H', 3: '<h', 4: '<I', 5: '<f'}


class FakeInav:
    def __init__(self, ver=(9, 1, 0), bridge=False):
        self.bridge, self._raw = bridge, []
        self.bridge_mb, self.bridge_types = True, set()   # mLRS: mb (0x82) before the radio speaks
        self.ver = list(ver)
        self.set = settings()
        self.prof = {'ctl': 0, 'mix': 0}
        self.armed = False
        self.stores = 0
        self.req = []
        self.down = []          # ('crsf', data) or ('sport', appId, value), in order
        self._buf, self._seq = None, 0

    def _val(self, s):
        v = s['v']
        return v[self.prof['mix' if s['sec'] == 0x20 else 'ctl']] if isinstance(v, list) else v

    def _enc(self, t, v): return list(struct.pack(_FMT[t], v))

    def _dec(self, t, b):
        n = struct.calcsize(_FMT[t])
        return struct.unpack(_FMT[t], bytes(b[:n]))[0] if len(b) >= n else None

    def reply(self, cmd, p):
        """(payload, error) for one request"""
        if cmd == 2: return [ord(c) for c in 'INAV'], False
        if cmd == 3: return self.ver, False
        if cmd == 0x2000:
            return [0] * 9 + list((4 if self.armed else 0).to_bytes(4, 'little')) + [0] * 8 + [self.prof['mix']], False
        if cmd == 250:
            if self.armed: return [], True
            self.stores += 1
            return [], False
        if cmd in (0x1003, 0x1004, 0x1007):
            if 0 not in p: return [], True
            i = p.index(0)
            name, rest = bytes(p[:i]).decode(), p[i + 1:]
            s = self.set.get(name)
            if s is None: return [], True
            if cmd == 0x1003: return self._enc(s['t'], self._val(s)), False
            if cmd == 0x1004:
                v = self._dec(s['t'], rest)
                if v is None or v < s['min'] or v > s['max']: return [], True
                if isinstance(s['v'], list): s['v'][self.prof['mix' if s['sec'] == 0x20 else 'ctl']] = v
                else: s['v'] = v
                return [], False
            out = list(name.encode()) + [0] + [0, 0, s['t'], s['sec'], 0x40 if s['look'] else 0]
            out += list((s['min'] & 0xFFFFFFFF).to_bytes(4, 'little')) + list((s['max'] & 0xFFFFFFFF).to_bytes(4, 'little'))
            out += [7, 0]
            out += [self.prof['ctl'], 3] if s['sec'] == 0x10 else ([self.prof['mix'], 2] if s['sec'] == 0x20 else [0, 0])
            for nm in (s['look'] or []): out += list(nm.encode()) + [0]
            return out + self._enc(s['t'], self._val(s)), False
        return None, False

    def chunk(self, c, transport):
        """one request chunk from the radio (status byte first)"""
        st = c[0]
        if st & 0x10: self._buf = list(c[1:])
        elif self._buf is not None: self._buf += list(c[1:])
        b = self._buf
        if b is None or len(b) < 5: return
        cmd, size = b[1] | (b[2] << 8), b[3] | (b[4] << 8)
        if len(b) < 5 + size: return
        self._buf = None
        self.req.append(cmd)
        out, err = self.reply(cmd, b[5:5 + size])
        if out is None: return
        body = [0, cmd & 0xFF, cmd >> 8, len(out) & 0xFF, len(out) >> 8] + out
        per = 5 if transport == 'sport' else 57
        for i in range(0, len(body), per):
            ch = [0x40 | (0x10 if i == 0 else 0) | (0x80 if err else 0) | self._seq] + body[i:i + per]
            self._seq = (self._seq + 1) & 0x0F
            if transport == 'sport':
                ch += [0] * (6 - len(ch))
                self.down.append(('sport', ch[0] | (ch[1] << 8), ch[2] | (ch[3] << 8) | (ch[4] << 16) | (ch[5] << 24)))
            else:
                self.down.append(('crsf', [0xEA, 0xC8] + ch))

    @staticmethod
    def _crc8x(c, b):
        c ^= b
        for _ in range(8): c = ((c << 1) ^ 0xD5) & 0xFF if c & 0x80 else (c << 1) & 0xFF
        return c

    def _bridge_in(self, raw):
        b = self._raw
        b += raw
        while True:
            while b and b[0] != 0x24: b.pop(0)
            if len(b) < 8: return
            if b[1] != 0x58 or b[2] != 0x3C: b.pop(0); continue
            size = b[6] | (b[7] << 8)
            if len(b) < 9 + size: return
            frame, crc = b[3:8 + size], b[8 + size]
            del b[:9 + size]
            c = 0
            for x in frame: c = self._crc8x(c, x)
            if c != crc: continue
            cmd = frame[1] | (frame[2] << 8)
            self.req.append(cmd)
            out, err = self.reply(cmd, frame[5:])
            if out is None: continue
            body = [0, cmd & 0xFF, cmd >> 8, len(out) & 0xFF, len(out) >> 8] + out
            c = 0
            for x in body: c = self._crc8x(c, x)
            f = [0x24, 0x58, 0x21 if err else 0x3E] + body + [c]
            k = 57 if self.bridge_mb else 58
            for i in range(0, len(f), k):
                ch = f[i:i + k]
                self.down.append(('bridge', (0x82, [0x66, 0, len(ch)] + ch) if self.bridge_mb else (0xAA, [0, len(ch)] + ch)))

    def crsf_push(self, cmd, data):
        if self.bridge:
            if cmd == 0x81 and len(data) >= 3 and data[0] == 0x66:
                self.bridge_mb = True; self.bridge_types.add(cmd); self._bridge_in(list(data[3:3 + data[2]]))
            elif cmd == 0xAA and len(data) >= 2:
                self.bridge_mb = False; self.bridge_types.add(cmd); self._bridge_in(list(data[2:2 + data[1]]))
            return True
        if cmd == 0x7A and len(data) >= 3: self.chunk(list(data[2:]), 'crsf')
        return True

    def sport_push(self, phys, prim, app, value):
        if prim == 0x30:
            v = int(value) & 0xFFFFFFFF
            self.chunk([app & 0xFF, (app >> 8) & 0xFF, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24], 'sport')
        return True
