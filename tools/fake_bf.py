"""A Betaflight flight controller for the PARAMS page tests (sim_edgetx.py / sim.py, link "MSP").

Answers MSPv2 over the radio link like fake_inav_settings.FakeInav (same chunking, CRSF and S.Port),
with Betaflight's fixed-layout blocks instead of named settings. Modelled on msp.c of Betaflight
4.5.5 (MSP API 1.46) and 2025.12.5 (API 1.47):
  MSP_PID 112 / SET 202        15 bytes; SET reads all 15 with no length check
  MSP_PID_ADVANCED 94 / SET 95  SET: 17 bytes, then each later group only if enough bytes remain
  MSP_RC_TUNING 111 / SET 204   SET needs 10; roll rate / expo also moves pitch if they were equal
  MSP_FILTER_CONFIG 92 / SET 93 SET: 5 bytes (the first = gyro LPF1 low byte), then guarded groups
  MSP_STATUS_EX 150             armed = flight mode flags bit 0, PID profile at 10, rate profile at 14
  MSP_EEPROM_WRITE 250          refused while armed
A SET shorter than Betaflight reads without a check is answered with an error here (on a real FC it
would read past the request), so a client bug shows up as a failed save.
"""
from fake_inav_settings import FakeInav

PID, ADV, RC, FIL = 112, 94, 111, 92
SET = {202: PID, 95: ADV, 204: RC, 93: FIL}
# SET groups after the unconditional part: (start offset, length), each applied only if the bytes
# remaining are at least its length (msp.c "if (sbufBytesRemaining(src) >= N)")
GROUPS = {
    ADV: (17, [(17, 2), (19, 4), (23, 2), (25, 14), (39, 7), (46, 1), (47, 3), (50, 7), (57, 4)]),
    RC: (10, [(10, 1), (11, 1), (12, 1), (13, 1), (14, 2), (16, 6), (22, 1), (23, 1)]),
    FIL: (5, [(5, 8), (13, 4), (17, 1), (18, 10), (28, 9), (37, 8), (45, 2), (47, 2)]),
}


def put(b, o, v, n):
    for i in range(n): b[o + i] = (v >> (8 * i)) & 0xFF


def get(b, o, n): return sum(b[o + i] << (8 * i) for i in range(n))


class FakeBF(FakeInav):
    def __init__(self, api=46, bridge=False, nofeat=False):
        super().__init__(bridge=bridge)
        self.api = api
        self.nofeat = nofeat    # a build without USE_DYN_NOTCH_FILTER / USE_RPM_FILTER: zeros, writes ignored
        self.pid_prof, self.rate_prof = 0, 0
        self.sets = []          # (cmd, payload length) of every SET taken
        # one set of blocks per PID profile / rate profile (the FC answers for the active one)
        self.prof = [self._profile(i) for i in range(4)]
        self.rates = [self._rates(i) for i in range(4)]
        self.fil_global = None
        self.fil = [self._filters(i) for i in range(4)]

    def _profile(self, i):
        p = [0] * 15
        for ax, (P, I, D) in enumerate(((45, 80, 40), (47, 84, 46), (45, 80, 0))):
            p[ax * 3:ax * 3 + 3] = [P + i, I, D]
        a = [0] * 61                                          # the same 61 bytes on 4.5 / 2025.12 / 2026.6
        for o, v in ((32, 120), (34, 125), (36, 120)): put(a, o, v, 2)
        a[39:43] = [30, 34, 0, 37]
        a[17], a[30], a[46], a[47], a[49] = 60, 5, 15, 100, 30   # angle limit, throttle boost, relax cutoff, motor limit, dyn idle
        put(a, 21, 80, 2)                                     # anti gravity
        a[51:55] = [25, 15, 100, 7]                           # FF smoothing, boost, max rate limit, jitter
        a[57], a[58] = 0, 65; put(a, 59, 1350, 2)             # TPA mode PD, rate 65 %, breakpoint 1350
        return {PID: p, ADV: a}

    def _rates(self, i):
        r = [0] * (24 if self.api >= 47 else 23)
        r[0], r[1], r[2], r[3], r[4] = 7, 0, 67, 67, 67      # ACTUAL: centre 70 deg/s, max 670
        r[6], r[7] = 50, 0
        r[10], r[11], r[12], r[13] = 0, 7, 7, 0
        r[22] = 3 if i == 0 else 0                           # rates_type: profile 1 ACTUAL, others BETAFLIGHT
        return r

    def _filters(self, i):
        f = [0] * 49
        put(f, 20, 250, 2); f[0] = 250 & 0xFF                # gyro LPF1 static (also the low byte at 0)
        put(f, 22, 500, 2)                                   # gyro LPF2
        put(f, 26, 150, 2)                                   # D-term LPF2
        for o, v in ((29, 250), (31, 500), (33, 75), (35, 150), (39, 300), (41, 100), (45, 600)): put(f, o, v, 2)
        f[43], f[44], f[48] = 3, 100, 3
        if self.api >= 48:   # 2026.6 (API 1.48): RPM fade range u16, RPM Q u16, 3 harmonic weights
            f += [50, 0, 0xF4, 0x01, 100, 100, 100]
        if self.nofeat:
            for o in (37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 48): f[o] = 0
        return f

    def block(self, cmd):
        if cmd in (PID, ADV): return self.prof[self.pid_prof][cmd]
        if cmd == RC: return self.rates[self.rate_prof]
        return self.fil[self.pid_prof]

    def value(self, cmd, off, n=1): return get(self.block(cmd), off, n)

    def reply(self, cmd, p):
        if cmd == 2: return [ord(c) for c in 'BTFL'], False
        if cmd == 1: return [0, 1, self.api], False
        if cmd == 3:
            if self.api >= 48: return [26, 6, 2] + [8] + [ord(c) for c in '2026.6.2'], False
            return ([25, 12, 5] + [9] + [ord(c) for c in '2025.12.5']) if self.api >= 47 else [4, 5, 5], False
        if cmd == 150:
            out = [0, 0, 0, 0, 0, 0] + [1 if self.armed else 0, 0, 0, 0] + [self.pid_prof, 0, 0, 4, self.rate_prof]
            out = out + [0, 30, 0, 0, 0, 0, 0]
            return (out + [3, 0]) if self.api >= 48 else out, False   # 2026.6: battery profile count / index
        if cmd == 250:
            if self.armed: return [], True
            self.stores += 1
            return [], False
        if cmd in (PID, ADV, RC, FIL): return list(self.block(cmd)), False
        if cmd in SET:
            get_cmd = SET[cmd]
            b = self.block(get_cmd)
            if get_cmd == PID:
                if len(p) < 15: return [], True
                b[0:15] = p[0:15]
                self.sets.append((cmd, len(p)))
                return [], False
            first, groups = GROUPS[get_cmd]
            if len(p) < first: return [], True
            if get_cmd == RC:
                # roll rc rate / expo: pitch follows when it was equal (msp.c MSP_SET_RC_TUNING)
                if b[12] == b[0]: b[12] = p[0]
                if b[13] == b[1]: b[13] = p[1]
                b[0:10] = p[0:10]
            elif get_cmd == FIL:
                b[0:5] = p[0:5]
                put(b, 20, p[0], 2)                          # the first byte sets gyro LPF1 (u8)
                keep = list(b) if self.nofeat else None
            else:
                b[0:first] = p[0:first]
            pos = first
            for start, n in groups:
                if start >= len(b): break
                if len(p) - pos >= n:
                    b[start:start + n] = p[pos:pos + n]
                    pos += n
            if get_cmd == FIL and self.nofeat:
                for o in (37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 48): b[o] = 0   # not compiled in: discarded
            self.sets.append((cmd, len(p)))
            return [], False
        return [], True
