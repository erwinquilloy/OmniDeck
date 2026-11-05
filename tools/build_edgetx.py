#!/usr/bin/env python3
"""Assemble the EdgeTX widget folder.

    python tools/build_edgetx.py <SD root> [--audio <folder with voice packs>]

Writes <SD root>/WIDGETS/OmniDeck/: the shared modules from scripts/omnideck (all but
the Ethos main.lua), the EdgeTX main.lua and etx.lua from edgetx/WIDGETS/OmniDeck,
the message tones, an empty missions folder and, with --audio, the voice packs.
Copy the WIDGETS folder to the root of the radio's SD card.
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, '..')
SHARED = os.path.join(REPO, 'scripts', 'omnideck')
EDGETX = os.path.join(REPO, 'edgetx', 'WIDGETS', 'OmniDeck')


def build(sd_root, audio=None):
    dst = os.path.join(sd_root, 'WIDGETS', 'OmniDeck')
    os.makedirs(dst, exist_ok=True)
    for name in sorted(os.listdir(SHARED)):
        if name.endswith('.lua') and name != 'main.lua':
            shutil.copyfile(os.path.join(SHARED, name), os.path.join(dst, name))
    for name in sorted(os.listdir(EDGETX)):
        if name.endswith('.lua'):
            shutil.copyfile(os.path.join(EDGETX, name), os.path.join(dst, name))
    shutil.copytree(os.path.join(SHARED, 'tones'), os.path.join(dst, 'tones'), dirs_exist_ok=True)
    # SYS > Tools > OmniDeck Check: says why the widget is missing from the widget list
    tools = os.path.join(sd_root, 'SCRIPTS', 'TOOLS')
    os.makedirs(tools, exist_ok=True)
    for tool in ('OmniDeck Check.lua', 'OmniDeck Setup.lua'):
        shutil.copyfile(os.path.join(REPO, 'edgetx', 'SCRIPTS', 'TOOLS', tool), os.path.join(tools, tool))
    os.makedirs(os.path.join(dst, 'missions'), exist_ok=True)
    if audio:
        for pack in sorted(os.listdir(audio)):
            src = os.path.join(audio, pack)
            if os.path.isdir(src):
                shutil.copytree(src, os.path.join(dst, 'audio', pack), dirs_exist_ok=True)
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
    if len(args) != 1:
        sys.exit(__doc__)
    print('built', build(args[0], audio))
