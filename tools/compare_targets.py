#!/usr/bin/env python3
"""Compare OmniDeck's separate targets, so a fix made in one can be carried to the
others on purpose (nothing is shared between them, see README / targets/).

    python tools/compare_targets.py                       overview: every file, which targets
                                                          hold the same copy, lines that differ
    python tools/compare_targets.py funcs telem.lua       functions in that file that differ,
                                                          and between which targets
    python tools/compare_targets.py diff telem.lua pt x18 x20
                                                          that function, x18 against x20
    python tools/compare_targets.py file ui.lua x18 x20   the whole file, x18 against x20

Targets: x20, x18 (Ethos, targets/ethos/), edgetx, opentx (targets/<name>/WIDGETS/OmniDeck/).
Line endings are ignored. Functions are the top-level ones ("function X(" / "local function
X(" at the start of a line, up to the "end" at the start of a line).
"""
import difflib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..'))
TARGETS = {
    'x20': os.path.join(REPO, 'targets', 'ethos', 'x20'),
    'x18': os.path.join(REPO, 'targets', 'ethos', 'x18'),
    'edgetx': os.path.join(REPO, 'targets', 'edgetx', 'WIDGETS', 'OmniDeck'),
    'opentx': os.path.join(REPO, 'targets', 'opentx', 'WIDGETS', 'OmniDeck'),
}
ORDER = ['x20', 'x18', 'edgetx', 'opentx']


def read(t, name):
    p = os.path.join(TARGETS[t], name)
    if not os.path.isfile(p):
        return None
    return open(p, encoding='utf-8', errors='replace').read().replace('\r\n', '\n')


def lua_files():
    names = set()
    for t in ORDER:
        if os.path.isdir(TARGETS[t]):
            names |= {n for n in os.listdir(TARGETS[t]) if n.endswith('.lua')}
    return sorted(names)


def groups(name):
    """targets holding the same text, in ORDER; missing targets left out"""
    out = []
    for t in ORDER:
        txt = read(t, name)
        if txt is None:
            continue
        for g in out:
            if g[1] == txt:
                g[0].append(t)
                break
        else:
            out.append(([t], txt))
    return out


def changed_lines(a, b):
    n = 0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a.split('\n'), b.split('\n'), autojunk=False).get_opcodes():
        if op != 'equal':
            n += max(i2 - i1, j2 - j1)
    return n


FUNC = re.compile(r'^(?:local\s+)?function\s+([\w.:]+)\s*\(', re.M)


def functions(txt):
    """{name: body} for top-level functions; a repeated name gets #2, #3"""
    out, lines, i = {}, txt.split('\n'), 0
    while i < len(lines):
        m = FUNC.match(lines[i])
        if m:
            j = i
            if not re.search(r'\bend\s*$', lines[i]) or lines[i].count('function') > lines[i].count('end'):
                j = i + 1
                while j < len(lines) and not re.match(r'^end\b', lines[j]):
                    j += 1
            name, k = m.group(1), 2
            while name in out:
                name = '%s#%d' % (m.group(1), k)
                k += 1
            out[name] = '\n'.join(lines[i:j + 1])
            i = j + 1
        else:
            i += 1
    return out


def overview():
    print('%-16s %s' % ('file', 'copies (targets with identical text), lines differing from the first copy'))
    for name in lua_files():
        gs = groups(name)
        missing = [t for t in ORDER if read(t, name) is None]
        parts = []
        for k, (ts, txt) in enumerate(gs):
            tag = '+'.join(ts)
            parts.append(tag if k == 0 else '%s (%d lines)' % (tag, changed_lines(gs[0][1], txt)))
        line = ' | '.join(parts)
        if missing:
            line += '   [not in: %s]' % ', '.join(missing)
        print('%-16s %s' % (name, line if len(gs) > 1 or missing else 'the same in all four'))


def funcs(name):
    per = {t: functions(read(t, name)) for t in ORDER if read(t, name) is not None}
    names = []
    for t in ORDER:
        for f in per.get(t, {}):
            if f not in names:
                names.append(f)
    print('%s: functions that are not the same in every target' % name)
    for f in names:
        bodies = {}
        for t in per:
            bodies.setdefault(per[t].get(f), []).append(t)
        if len(bodies) > 1:
            desc = ' | '.join('+'.join(ts) + ('' if b is not None else ' (absent)') for b, ts in bodies.items())
            print('  %-28s %s' % (f, desc))


def diff_func(name, func, a, b):
    fa, fb = functions(read(a, name) or '').get(func), functions(read(b, name) or '').get(func)
    if fa is None or fb is None:
        sys.exit('%s not found in %s' % (func, a if fa is None else b))
    if fa == fb:
        print('%s %s: the same in %s and %s' % (name, func, a, b))
        return
    sys.stdout.writelines(difflib.unified_diff(fa.split('\n'), fb.split('\n'), '%s:%s' % (a, name), '%s:%s' % (b, name), lineterm='\n', n=3))
    print()


def diff_file(name, a, b):
    ta, tb = read(a, name), read(b, name)
    if ta is None or tb is None:
        sys.exit('%s not in %s' % (name, a if ta is None else b))
    for l in difflib.unified_diff(ta.split('\n'), tb.split('\n'), '%s:%s' % (a, name), '%s:%s' % (b, name), lineterm='', n=3):
        print(l)


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a:
        overview()
    elif a[0] == 'funcs' and len(a) == 2:
        funcs(a[1])
    elif a[0] == 'diff' and len(a) == 5:
        diff_func(a[1], a[2], a[3], a[4])
    elif a[0] == 'file' and len(a) == 4:
        diff_file(a[1], a[2], a[3])
    else:
        sys.exit(__doc__)
