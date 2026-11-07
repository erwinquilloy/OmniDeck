#!/usr/bin/env python3
"""Assemble the EdgeTX or OpenTX widget for an SD card.

    python tools/build_edgetx.py <SD root> [--otx] [--audio <folder with voice packs>]
    python tools/build_edgetx.py --zip <out.zip> [--otx] [--audio-from <older OmniDeck zip>]

Copies targets/edgetx (or, with --otx, targets/opentx): WIDGETS/OmniDeck/ and
SCRIPTS/TOOLS/, plus an empty missions folder and, with --audio, the voice packs.
EdgeTX and OpenTX are separate copies of OmniDeck: a change to one can't affect the
other (see tools/compare_targets.py). Copy WIDGETS and SCRIPTS to the radio's SD card.
--zip: the tester package instead: WIDGETS/ and SCRIPTS/ plus the target's INSTALL.txt, voice
packs taken from an older package (--audio-from; they are not in the repository), paths with
forward slashes.
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, '..')


def target_dir(otx=False):
    return os.path.join(REPO, 'targets', 'opentx' if otx else 'edgetx')


def build(sd_root, audio=None, otx=False):
    src = target_dir(otx)
    shutil.copytree(os.path.join(src, 'WIDGETS'), os.path.join(sd_root, 'WIDGETS'), dirs_exist_ok=True)
    shutil.copytree(os.path.join(src, 'SCRIPTS'), os.path.join(sd_root, 'SCRIPTS'), dirs_exist_ok=True)
    dst = os.path.join(sd_root, 'WIDGETS', 'OmniDeck')
    os.makedirs(os.path.join(dst, 'missions'), exist_ok=True)
    if audio:
        for pack in sorted(os.listdir(audio)):
            p = os.path.join(audio, pack)
            if os.path.isdir(p):
                shutil.copytree(p, os.path.join(dst, 'audio', pack), dirs_exist_ok=True)
    # compiled copies from an older version would shadow the new sources
    for name in os.listdir(dst):
        if name.endswith('.luac'):
            os.remove(os.path.join(dst, name))
    return dst


def build_zip(out_zip, otx=False, audio_from=None):
    import tempfile, zipfile, re
    with tempfile.TemporaryDirectory() as sd:
        build(sd, None, otx)
        names = []
        with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as z:
            inst = os.path.join(target_dir(otx), 'INSTALL.txt')
            if os.path.isfile(inst):
                z.write(inst, 'INSTALL.txt')
            for root, dirs, files in os.walk(sd):
                dirs.sort()
                rel = os.path.relpath(root, sd).replace(os.sep, '/')
                if not files and not dirs:
                    z.writestr(zipfile.ZipInfo(rel + '/'), b'')     # the empty missions folder
                for f in sorted(files):
                    arc = (rel + '/' if rel != '.' else '') + f
                    z.write(os.path.join(root, f), arc)
            if audio_from:
                with zipfile.ZipFile(audio_from) as old:
                    for n in old.namelist():
                        if n.startswith('WIDGETS/OmniDeck/audio/') and n.lower().endswith('.wav'):
                            z.writestr(n, old.read(n))
        with zipfile.ZipFile(out_zip) as z:
            assert z.testzip() is None
            names = z.namelist()
    assert all(chr(92) not in n for n in names)   # no backslashes
    ui = open(os.path.join(target_dir(otx), 'WIDGETS', 'OmniDeck', 'ui.lua'), encoding='utf-8').read()
    ver = re.search(r'local VERSION = "([^"]+)"', ui).group(1)
    packs = sorted({n.split('/')[3] for n in names if n.startswith('WIDGETS/OmniDeck/audio/') and n.count('/') >= 4})
    print('%s: %s %s, %d files, voice packs: %s' % (out_zip, 'OpenTX' if otx else 'EdgeTX', ver, len(names), ', '.join(packs) or 'none'))
    return out_zip


if __name__ == '__main__':
    args = [a for a in sys.argv[1:]]
    if '--zip' in args:
        i = args.index('--zip')
        out = args[i + 1]
        old = args[args.index('--audio-from') + 1] if '--audio-from' in args else None
        build_zip(out, '--otx' in args, old)
        sys.exit(0)
    audio = None
    if '--audio' in args:
        i = args.index('--audio')
        audio = args[i + 1]
        del args[i:i + 2]
    otx = '--otx' in args
    args = [a for a in args if a != '--otx']
    print(build(args[0], audio, otx))
