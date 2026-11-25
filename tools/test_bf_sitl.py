#!/usr/bin/env python3
"""The Betaflight PARAMS rows (bfplist.lua) against a real Betaflight: the SITL build, over MSP.

    python3 tools/test_bf_sitl.py <betaflight SITL binary> <rows.json> <api minor 46|47>

rows.json: bfplist.lua's rows after forVersion(api) (name, MSP command, offset, size, prefix
length, raw limits), exported with lupa. For every row: read its block, write a changed value
the way params.lua does (the block as read, the field changed, cut at the end of its group),
read the block back: the field must hold the new value and every other byte must be unchanged.
Then the CLI on the same port ('#', "get <name>") must show every new value under the row's
name, so offsets, sizes, names and the group cut are all checked against the firmware itself.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

elf, rows_path, api = sys.argv[1], sys.argv[2], int(sys.argv[3])
spec = json.load(open(rows_path))
ROWS, SETC = spec['rows'], {int(k): v for k, v in spec['set'].items()}


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0xD5) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


class MSP:
    def __init__(self, port=5761):
        for _ in range(100):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=2)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise SystemExit('SITL port %d did not open' % port)
        self.buf = b''

    def req(self, cmd, payload=b''):
        body = bytes([0]) + cmd.to_bytes(2, 'little') + len(payload).to_bytes(2, 'little') + bytes(payload)
        self.s.sendall(b'$X<' + body + bytes([crc8(body)]))
        t0 = time.time()
        while time.time() - t0 < 3:
            try:
                self.buf += self.s.recv(4096)
            except socket.timeout:
                pass
            i = self.buf.find(b'$X')
            while i >= 0 and len(self.buf) >= i + 9:
                d = self.buf[i + 2:i + 3]
                c = int.from_bytes(self.buf[i + 4:i + 6], 'little')
                n = int.from_bytes(self.buf[i + 6:i + 8], 'little')
                if len(self.buf) < i + 9 + n: break
                data = self.buf[i + 8:i + 8 + n]
                self.buf = self.buf[i + 9 + n:]
                if c == cmd: return list(data), d == b'!'
                i = self.buf.find(b'$X')
        raise SystemExit('no MSP answer to %d' % cmd)

    def cli(self, lines):
        self.s.sendall(b'#')
        time.sleep(0.5)
        out = b''
        for ln in lines:
            self.s.sendall(ln.encode() + b'\r\n')
            time.sleep(0.15)
        t0 = time.time()
        while time.time() - t0 < 2:
            try:
                out += self.s.recv(65536)
            except socket.timeout:
                break
        return out.decode('latin-1')


def raw(b, r):
    o = r['off']
    return b[o] | (b[o + 1] << 8 if r['size'] == 2 else 0)


run = tempfile.mkdtemp(prefix='bfsitl_params_')
p = subprocess.Popen([elf], cwd=run, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
fails = []
try:
    time.sleep(1.5)
    m = MSP()
    v, _ = m.req(1)
    print('MSP API %d.%d' % (v[1], v[2]))
    assert v[1] == 1 and v[2] == api, ('API version', v)
    want = {}
    for r in ROWS:
        before, err = m.req(r['cmd'])
        assert not err and len(before) >= spec['minlen'][str(r['cmd'])], (r['name'], 'block', len(before))
        # a feature this build leaves out (dyn notch / RPM filter): the page shows n/a, nothing written
        if r.get('feat') == 'notch' and before[45] | (before[46] << 8) < 200 or r.get('feat') == 'rpm' and before[44] < 30:
            print('n/a  %-22s not in this build (the page shows n/a)' % r['name'])
            continue
        old = raw(before, r)
        new = old + 1 if old + 1 <= r['rmax'] else old - 1
        if new < r['rmin']: new = r['rmin']
        pl = before[:r['len']]
        pl[r['off']] = new & 0xFF
        if r['size'] == 2: pl[r['off'] + 1] = (new >> 8) & 0xFF
        _, err = m.req(SETC[r['cmd']], pl)
        after, _ = m.req(r['cmd'])
        changed = [i for i in range(min(len(before), len(after))) if before[i] != after[i] and not (r['off'] <= i < r['off'] + r['size'])]
        got = raw(after, r)
        ok = not err and got == new and not changed
        print('%s %-22s %5d -> %5d  set %3d+%-2d  %s' % ('OK  ' if ok else 'FAIL', r['name'], old, got, SETC[r['cmd']], len(pl),
              ('other bytes changed at ' + str(changed)) if changed else ''))
        if not ok: fails.append(r['name'])
        want[r['name']] = new
    out = m.cli(['get ' + n for n in want])
    for n, val in want.items():
        line = [l for l in out.splitlines() if l.strip().startswith(n + ' =')]
        cli = int(line[0].split('=')[1].split()[0]) if line else None
        if cli != val:
            fails.append(n + ' (CLI)')
            print('FAIL CLI %-22s shows %s, MSP wrote %d' % (n, cli, val))
    print('CLI: %d of %d names show the written value' % (sum(1 for n in want if n + ' (CLI)' not in fails), len(want)))
finally:
    p.kill()
print('ALL PASS' if not fails else 'FAILED: ' + ', '.join(fails))
sys.exit(1 if fails else 0)
