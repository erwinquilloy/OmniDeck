#!/usr/bin/env python3
"""Compile Lua for EdgeTX black-and-white radios on the PC: Lua 5.3 bytecode with 32-bit
integers and floats, debug info stripped - the format EdgeTX 2.12 writes as .luac on a TX12 MK2
(header 1b 4c 75 61 53 00 19 93 0d 0a 1a 0a 04 04 04 04 04).

    python tools/luac32.py <file.lua> [out.luac]
    python tools/luac32.py --check <file.lua> <radio-made.luac>   (byte-for-byte comparison)

Why: compiling a large script on the radio needs the parser's working memory on top of
everything already loaded; OmniDeck Mono's telemetry code ran out of memory there ("telem.lua:
not enough memory", TX12 MK2, 2026-11-12). Shipped as .luac, the radio only loads it.

How: desktop Lua 5.3 (lupa) compiles and strips (string.dump(f, true)); its 64-bit dump is then
rewritten field by field: size_t 8 -> 4, lua_Integer 8 -> 4, lua_Number double -> float.
An integer constant outside 32 bits becomes a float constant, as the radio's own lexer does.
"""
import struct, sys
from lupa import lua53

SIG = b'\x1bLua\x53\x00\x19\x93\r\n\x1a\n'
T_NIL, T_BOOL, T_FLT, T_INT, T_SHR, T_LNG = 0, 1, 3, 19, 4, 20


class Reader:
    def __init__(self, b): self.b, self.i = b, 0
    def byte(self): v = self.b[self.i]; self.i += 1; return v
    def raw(self, n): v = self.b[self.i:self.i + n]; self.i += n; return v
    def int(self): return struct.unpack('<i', self.raw(4))[0]
    def size(self): return struct.unpack('<Q', self.raw(8))[0]
    def integer(self): return struct.unpack('<q', self.raw(8))[0]
    def number(self): return struct.unpack('<d', self.raw(8))[0]
    def string(self):
        n = self.byte()
        if n == 0xFF: n = self.size()
        return None if n == 0 else self.raw(n - 1)


class Writer:
    def __init__(self): self.o = bytearray()
    def byte(self, v): self.o.append(v)
    def raw(self, b): self.o += b
    def int(self, v): self.o += struct.pack('<i', v)
    def integer(self, v): self.o += struct.pack('<i', v)
    def number(self, v): self.o += struct.pack('<f', v)
    def string(self, s):
        if s is None: self.byte(0); return
        n = len(s) + 1
        if n < 0xFF: self.byte(n)
        else: self.byte(0xFF); self.o += struct.pack('<I', n)
        self.raw(s)


def function(r, w):
    w.string(r.string())                       # source (stripped: none)
    w.int(r.int()); w.int(r.int())             # linedefined, lastlinedefined
    w.byte(r.byte()); w.byte(r.byte()); w.byte(r.byte())   # numparams, is_vararg, maxstacksize
    n = r.int(); w.int(n); w.raw(r.raw(4 * n))  # code
    n = r.int(); w.int(n)                       # constants
    for _ in range(n):
        t = r.byte()
        if t == T_NIL: w.byte(t)
        elif t == T_BOOL: w.byte(t); w.byte(r.byte())
        elif t == T_FLT: w.byte(t); w.number(r.number())
        elif t == T_INT:
            v = r.integer()
            if -2 ** 31 <= v < 2 ** 31: w.byte(t); w.integer(v)
            else: w.byte(T_FLT); w.number(float(v))
        elif t in (T_SHR, T_LNG): w.byte(t); w.string(r.string())
        else: raise ValueError('constant type %d' % t)
    n = r.int(); w.int(n)                       # upvalues: instack, idx
    for _ in range(n): w.byte(r.byte()); w.byte(r.byte())
    n = r.int(); w.int(n)                       # nested functions
    for _ in range(n): function(r, w)
    n = r.int(); w.int(n); w.raw(r.raw(4 * n))  # lineinfo (0 when stripped)
    n = r.int(); w.int(n)                       # locvars
    for _ in range(n): w.string(r.string()); w.int(r.int()); w.int(r.int())
    n = r.int(); w.int(n)                       # upvalue names
    for _ in range(n): w.string(r.string())


def compile_lua(src, name='=?'):
    L = lua53.LuaRuntime(encoding=None)
    dump = L.eval('function(s, n) return string.dump(assert(load(s, n, "t")), true) end')
    b = dump(src.encode('utf-8') if isinstance(src, str) else src, name.encode())
    b = bytes(b)
    r = Reader(b)
    if r.raw(12) != SIG: raise ValueError('not a Lua 5.3 dump')
    if r.raw(5) != bytes([4, 8, 4, 8, 8]): raise ValueError('desktop Lua is not 64-bit int/size_t/double')
    r.raw(8); r.raw(8)                          # LUAC_INT, LUAC_NUM
    w = Writer()
    w.raw(SIG); w.raw(bytes([4, 4, 4, 4, 4]))
    w.integer(0x5678); w.number(370.5)
    w.byte(r.byte())                            # sizeupvalues of the main function
    function(r, w)
    if r.i != len(b): raise ValueError('trailing bytes: %d' % (len(b) - r.i))
    return bytes(w.o)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == '--check':
        mine = compile_lua(open(a[1], 'rb').read())
        theirs = open(a[2], 'rb').read()
        same = mine == theirs
        first = next((i for i in range(min(len(mine), len(theirs))) if mine[i] != theirs[i]), None)
        print('%s: %d bytes, radio %d bytes, identical: %s%s' % (a[1], len(mine), len(theirs), same,
              '' if same else ' (first difference at byte %s)' % first))
        sys.exit(0 if same else 1)
    if not a:
        sys.exit(__doc__)
    out = a[1] if len(a) > 1 else a[0][:-4] + '.luac'
    data = compile_lua(open(a[0], 'rb').read())
    open(out, 'wb').write(data)
    print(out, len(data), 'bytes')
