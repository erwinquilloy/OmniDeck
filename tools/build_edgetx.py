#!/usr/bin/env python3
"""Assemble the EdgeTX or OpenTX widget for an SD card.

    python tools/build_edgetx.py <SD root> [--otx] [--audio <folder with voice packs>]

Copies targets/edgetx (or, with --otx, targets/opentx): WIDGETS/OmniDeck/ and
SCRIPTS/TOOLS/, plus an empty missions folder and, with --audio, the voice packs.
EdgeTX and OpenTX are separate copies of OmniDeck: a change to one can't affect the
other (see tools/compare_targets.py). Copy WIDGETS and SCRIPTS to the radio's SD card.
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


if __name__ == '__main__':
    args = [a for a in sys.argv[1:]]
    audio = None
    if '--audio' in args:
        i = args.index('--audio')
        audio = args[i + 1]
        del args[i:i + 2]
    otx = '--otx' in args
    args = [a for a in args if a != '--otx']
    print(build(args[0], audio, otx))
