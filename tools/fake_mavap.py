"""A pymavlink 'ArduPilot' for the mLRS bridge tests (test_mavbridge.py, test_ethos_bridge.py):
PARAM_REQUEST_READ / PARAM_SET, mission download and the standard upload, a telemetry stream
around them (and Mission Planner's mission traffic to another target), frames cut as mLRS does."""
import random

from pymavlink.dialects.v20 import ardupilotmega as mav


class FakeAP:
    """ArduPilot over MAVLink: params, mission download, standard upload; a telemetry stream around it."""
    def __init__(self):
        self.mv = mav.MAVLink(None, srcSystem=1, srcComponent=1)
        self.rxp = mav.MAVLink(None); self.rxp.robust_parsing = True
        self.p = {'AIRSPEED_CRUISE': 18.0, 'TRIM_THROTTLE': 45.0, 'Q_ENABLE': 0.0, 'ARMING_SKIPCHK': 512.0,
                  'TECS_CLMB_MAX': 5.0, 'RLL_RATE_P': 0.08}
        self.mission = [(16, 0, -35.36, 149.16, 0.0, 0, 0, 0)]   # home: cmd, frame, lat, lon, alt, p1, p2, p3
        self.out = b''
        self.armed = False
        self.loss = 0.0
        self.sets = 0
        self.upload = None      # (count, received items)
        self.acks = []
        self.got_ack_download = 0
        self.rnd = random.Random(5)
        self.frames_in = 0

    def emit(self, m, lossy=True):
        if lossy and self.rnd.random() < self.loss: return
        self.out += m.pack(self.mv)

    def from_radio(self, cmd, data):
        assert cmd == 0xAA and data[0] == 0 and data[1] == len(data) - 2 and data[1] <= 58, (cmd, data[:3], len(data))
        self.frames_in += 1
        for m in self.rxp.parse_buffer(bytes(data[2:])) or []:
            self.handle(m)

    def handle(self, m):
        t = m.get_type()
        if t == 'HEARTBEAT':
            self.hellos = getattr(self, 'hellos', 0) + 1
        elif t == 'PARAM_REQUEST_READ':
            assert m.target_system == 1 and m.target_component == 1 and m.param_index == -1
            drop = getattr(self, 'drop_names', {})
            if drop.get(m.param_id, 0) > 0:      # this answer lost on the way (test: n/a must heal)
                drop[m.param_id] -= 1
                return
            if m.param_id in self.p:
                self.emit(self.mv.param_value_encode(m.param_id.encode(), self.p[m.param_id], 9, len(self.p), 0))
        elif t == 'PARAM_SET':
            if m.param_id in self.p:
                self.p[m.param_id] = m.param_value; self.sets += 1
                if getattr(self, 'drop_set_replies', 0) > 0:   # saved, but the answer lost (full link)
                    self.drop_set_replies -= 1
                    return
                self.emit(self.mv.param_value_encode(m.param_id.encode(), self.p[m.param_id], 9, len(self.p), 0))
        elif t == 'MISSION_REQUEST_LIST':
            self.emit(self.mv.mission_count_encode(m.get_srcSystem(), m.get_srcComponent(), len(self.mission), 0))
        elif t == 'MISSION_REQUEST_INT':
            if m.seq < len(self.mission):
                c, f, la, lo, al, p1, p2, p3 = self.mission[m.seq]
                self.emit(self.mv.mission_item_int_encode(m.get_srcSystem(), m.get_srcComponent(), m.seq, f, c, 0, 1,
                                                          p1, p2, p3, 0, int(round(la * 1e7)), int(round(lo * 1e7)), al, 0))
        elif t == 'MISSION_ACK':
            self.got_ack_download += 1
        elif t == 'MISSION_COUNT':
            if self.armed is True and False: pass
            self.upload = (m.count, {}, m.get_srcSystem(), m.get_srcComponent())
            self.emit(self.mv.mission_request_int_encode(m.get_srcSystem(), m.get_srcComponent(), 0, 0))
        elif t == 'MISSION_ITEM_INT':
            if not self.upload: return
            n, items, ss, sc = self.upload
            items[m.seq] = (m.command, m.frame, m.x / 1e7, m.y / 1e7, m.z, m.param1, m.param2, m.param3)
            nxt = m.seq + 1
            if nxt < n:
                self.emit(self.mv.mission_request_int_encode(ss, sc, nxt, 0))
            else:
                self.mission = [items[i] for i in range(n)]
                self.upload = None
                self.acks.append(0)
                self.emit(self.mv.mission_ack_encode(ss, sc, 0, 0))

    def tick(self, t):
        if int(t * 20) % 20 == 0:
            self.emit(self.mv.heartbeat_encode(1, 3, 0, 0, 4), lossy=False)
            # Mission Planner (255/190) downloading on the same stream: must be ignored
            self.emit(self.mv.mission_count_encode(255, 190, 7, 0), lossy=False)
            self.emit(self.mv.mission_item_int_encode(255, 190, 1, 3, 16, 0, 1, 0, 0, 0, 0, 1, 2, 3, 0), lossy=False)
        self.emit(self.mv.attitude_encode(int(t * 1000), 0.1, 0.2, 0.3, 0, 0, 0), lossy=False)
        self.emit(self.mv.vfr_hud_encode(18.0, 19.0, 90, 50, 120.0, 0.5), lossy=False)

    def frames(self):
        fr = []
        if getattr(self, 'needs_hello', False) and self.frames_in == 0:
            self.out = b''          # the mLRS module: no bridge frames before the radio speaks
            return fr
        budget = getattr(self, 'bytes_per_tick', None)   # the link's capacity: the rest waits (queue)
        while self.out and (budget is None or budget > 0):
            n = min(len(self.out), self.rnd.randint(10, 58))
            if budget is not None: budget -= n
            fr.append([0, n] + list(self.out[:n])); self.out = self.out[n:]
        return fr
