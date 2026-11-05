"""ArduPilot passthrough encoders shared by the Ethos and EdgeTX simulators
(bit layouts from libraries/AP_Frsky_Telem/AP_Frsky_SPort_Passthrough.cpp)."""
import math

# ------------------------------------------------------------------ AP encoders
def prep_number(number, digits, power):
    a = abs(int(number))
    if digits == 2 and power == 0:
        res = min(a, 63 if number < 0 else 127)
        if number < 0: res |= 1 << 6
    elif digits == 2 and power == 1:
        res = a << 1 if a < 100 else ((round(a * 0.1) << 1) | 1 if a < 1270 else 0xFF)
        if number < 0: res |= 1 << 8
    elif digits == 2 and power == 2:
        if a < 100: res = a << 2
        elif a < 1000: res = (round(a * 0.1) << 2) | 1
        elif a < 10000: res = (round(a * 0.01) << 2) | 2
        elif a < 127000: res = (round(a * 0.001) << 2) | 3
        else: res = 0x1FF
        if number < 0: res |= 1 << 9
    elif digits == 3 and power == 1:
        res = a << 1 if a < 1000 else ((round(a * 0.1) << 1) | 1 if a < 10240 else 0x7FF)
        if number < 0: res |= 1 << 11
    elif digits == 3 and power == 2:
        if a < 1000: res = a << 2
        elif a < 10000: res = (round(a * 0.1) << 2) | 1
        elif a < 100000: res = (round(a * 0.01) << 2) | 2
        elif a < 1024000: res = (round(a * 0.001) << 2) | 3
        else: res = 0xFFF
        if number < 0: res |= 1 << 12
    return res

def latlng(deg, is_lon):
    v = (abs(int(deg * 1e7)) // 100) * 6
    if deg < 0: v |= 0x40000000
    if is_lon: v |= 0x80000000
    return v & 0xFFFFFFFF

R = 6371000.0
def dist_brg(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * R * math.asin(min(1, math.sqrt(a)))
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return d, (math.degrees(math.atan2(y, x)) + 360) % 360

def project(lat, lon, d, brg):
    dd, b, p1, l1 = d / R, math.radians(brg), math.radians(lat), math.radians(lon)
    p2 = math.asin(math.sin(p1) * math.cos(dd) + math.cos(p1) * math.sin(dd) * math.cos(b))
    l2 = l1 + math.atan2(math.sin(b) * math.sin(dd) * math.cos(p1), math.cos(dd) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), math.degrees(l2)

def packets(st):
    """list of (appId, value) for one telemetry 'cycle' of vehicle state st"""
    out = []
    out.append((0x0800, latlng(st['lat'], False)))
    out.append((0x0800, latlng(st['lon'], True)))
    ap = (st['mode'] + 1) & 0x1F
    # bit 7 = ArduPilot's flying flag: follows armed unless a test sets st['flying']
    ap |= ((1 if st.get('flying', st['armed']) else 0) << 7) | ((1 if st['armed'] else 0) << 8)
    ap |= prep_number(st['thr'] * 0.63, 2, 0) << 19
    out.append((0x5001, ap))
    g = min(st['sats'], 15) | (st.get('fix', 3) << 4) | (prep_number(round(st['hdop'] * 100 * 0.1), 2, 1) << 6)
    g |= prep_number(round(st['altmsl'] * 100 * 0.1), 2, 2) << 22
    out.append((0x5002, g))
    b = round(st['volt'] * 10) & 0x1FF
    b |= prep_number(round(st['curr'] * 10), 2, 1) << 9
    b |= (min(int(st['mah']), 0x7FFF)) << 17
    out.append((0x5003, b))
    d, brg = dist_brg(st['lat'], st['lon'], st['hlat'], st['hlon'])
    h = prep_number(round(d), 3, 2) | ((round(brg * 0.00333 * 100) & 0x7F) << 25)
    h |= prep_number(round(st['alt'] * 10), 3, 2) << 12
    out.append((0x5004, h))
    v = prep_number(round(st['vs'] * 10), 2, 1)
    v |= prep_number(round(st['as'] * 10), 2, 1) << 9
    v |= (round(st['yaw'] * 100 * 0.05) & 0x7FF) << 17
    v |= 1 << 28
    out.append((0x5005, v))
    v2 = prep_number(round(st['gs'] * 10), 2, 1) << 9
    v2 |= (round(st['yaw'] * 100 * 0.05) & 0x7FF) << 17
    if not st.get('nogs'):                         # FRSKY_OPTIONS bit 0 off: airspeed only
        out.append((0x5005, v2 | prep_number(round(st['vs'] * 10), 2, 1)))
    a = round((st['roll'] * 100 + 18000) * 0.05) & 0x7FF
    a |= (round((st['pitch'] * 100 + 9000) * 0.05) & 0x3FF) << 11
    out.append((0x5006, a))
    out.append((0x5007, (1 << 24) | 1))            # frame type: fixed wing
    out.append((0x5007, (4 << 24) | 5000))         # battery capacity
    wind = prep_number(round(st['wdir'] / 3), 2, 0) | (prep_number(round(st['wspd'] * 10), 2, 1) << 7)
    out.append((0x500C, wind))
    wp = st['wpn'] | (prep_number(st['wpd'], 3, 2) << 11) | ((round(st['wpb'] * 0.333) & 0xFF) << 23)
    out.append((0x500D, wp & 0xFFFFFFFF))
    return out

def text_chunks(text, sev):
    """0x5000 chunks as get_next_msg_chunk() builds them (each sent 3 times)"""
    data = text.encode()[:50]
    chunks, i = [], 0
    while True:
        chunk, ch = 0, 1
        for k in range(4):
            if i >= len(data): ch = 0; break
            ch = data[i]; i += 1
            chunk |= ch << (3 - k) * 8
        end = (ch == 0) or i == 50
        if end:
            chunk |= (sev & 4) << 21; chunk |= (sev & 2) << 14; chunk |= (sev & 1) << 7
        chunks += [chunk] * 3
        if end: break
    return chunks

