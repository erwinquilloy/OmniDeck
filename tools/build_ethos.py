#!/usr/bin/env python3
"""Build the Ethos package of OmniDeck (one zip for every Ethos radio).

    python tools/build_ethos.py <out.zip> [--audio <folder with voice packs>]
                                          [--audio-from <older OmniDeck Ethos zip>]
                                          [--install <INSTALL.txt>]

The zip holds scripts/omnideck/ as it goes on the radio's SD card:
    main.lua      the loader: picks x18/ (screens 480 px wide or less) or x20/
    x18/, x20/    the two separate copies of OmniDeck (targets/ethos/x18, x20)
    tones/, logos/, missions/ (empty), audio/<pack>/ (voice packs, if given)
plus INSTALL.txt at the top (targets/ethos/INSTALL.txt unless --install names another;
its first line gets the version from x20/ui.lua). Voice packs are not in the repository (14 MB
each): take them from a folder (--audio) or from an older tester zip (--audio-from).
Paths in the zip use forward slashes (PowerShell's Compress-Archive writes backslashes,
which break on Mac and Linux).
"""
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, '..', 'targets', 'ethos'))
DST = 'scripts/omnideck/'
CODE = ('x18', 'x20')


def version(tree):
    txt = open(os.path.join(SRC, tree, 'ui.lua'), encoding='utf-8').read()
    m = re.search(r'local VERSION = "([^"]+)"', txt)
    return m.group(1) if m else '?'


def files():
    """(path in the zip, bytes) for everything in targets/ethos"""
    out = [(DST + 'main.lua', open(os.path.join(SRC, 'main.lua'), 'rb').read())]
    for sub in CODE + ('tones', 'logos'):
        base = os.path.join(SRC, sub)
        for root, _, names in os.walk(base):
            for n in sorted(names):
                if n.endswith('.luac'):
                    continue   # compiled copies would shadow the sources
                p = os.path.join(root, n)
                rel = os.path.relpath(p, SRC).replace(os.sep, '/')
                out.append((DST + rel, open(p, 'rb').read()))
    return out


def audio_files(folder=None, older_zip=None):
    out = []
    if folder:
        for root, _, names in os.walk(folder):
            for n in sorted(names):
                if n.lower().endswith('.wav'):
                    rel = os.path.relpath(os.path.join(root, n), folder).replace(os.sep, '/')
                    out.append((DST + 'audio/' + rel, open(os.path.join(root, n), 'rb').read()))
    if older_zip:
        with zipfile.ZipFile(older_zip) as z:
            for n in z.namelist():
                if n.startswith(DST + 'audio/') and n.lower().endswith('.wav'):
                    out.append((n, z.read(n)))
    return out


def build(out_zip, audio=None, audio_from=None, install=None):
    entries = files() + audio_files(audio, audio_from)
    install = install or os.path.join(SRC, 'INSTALL.txt')
    if os.path.isfile(install):
        txt = open(install, 'rb').read().decode('utf-8')
        txt = re.sub(r'^OmniDeck \S+', 'OmniDeck ' + version('x20'), txt, count=1)
        entries.append(('INSTALL.txt', txt.encode('utf-8')))
    with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo(DST + 'missions/'), b'')
        for name, data in entries:
            z.writestr(name, data)
    with zipfile.ZipFile(out_zip) as z:
        assert z.testzip() is None
        names = z.namelist()
        # every sound must be a real WAV: 23 Aria clips were all zeros (a copy cut short) in every
        # package up to test41, and the radio just stays silent for them
        blank = [n for n in names if n.lower().endswith('.wav') and z.read(n)[:4] != b'RIFF']
    if blank:
        os.remove(out_zip)
        sys.exit('not WAV files (%d), package removed: %s' % (len(blank), ', '.join(blank[:8])))
    assert all('\\' not in n for n in names)
    packs = sorted({n.split('/')[3] for n in names if n.startswith(DST + 'audio/') and n.count('/') >= 4})
    print('%s: %d files | x18 %s | x20 %s | voice packs: %s' % (
        out_zip, len(names), version('x18'), version('x20'), ', '.join(packs) or 'none'))
    return out_zip


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0].startswith('--'):
        sys.exit(__doc__)
    opts = {}
    for k in ('--audio', '--audio-from', '--install'):
        if k in a:
            i = a.index(k)
            opts[k] = a[i + 1]
            del a[i:i + 2]
    build(a[0], opts.get('--audio'), opts.get('--audio-from'), opts.get('--install'))
