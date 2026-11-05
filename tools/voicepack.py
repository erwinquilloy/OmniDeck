#!/usr/bin/env python3
"""Build OmniDeck voice packs from tools/phrases.psv.

    pip install edge-tts imageio-ffmpeg
    python tools/voicepack.py <output folder> [Aria Christopher Michelle ...]

Each voice becomes <output folder>/<voice>/<name>.wav: 16-bit mono 32 kHz PCM,
the format Yaapu's own Ethos sounds use. File names match Yaapu's, so a Yaapu
language folder copied to /scripts/omnideck/audio/<name>/ also works; it just stays
silent for the phrases Yaapu doesn't have (telemetry lost, course hold, ...).

The text goes to Microsoft's free Edge speech service. Only the phrases in
phrases.psv are sent.
"""

import asyncio
import os
import subprocess
import sys
import tempfile

import edge_tts
import imageio_ffmpeg

HERE = os.path.dirname(os.path.abspath(__file__))
VOICES = {
    'Aria': 'en-US-AriaNeural',
    'Christopher': 'en-US-ChristopherNeural',
    'Michelle': 'en-US-MichelleNeural',
    # EdgeTX refuses sound paths over 45 characters ("Path too long" popup): with
    # /WIDGETS/OmniDeck/audio/ and the longest clip (initializing.wav) a pack name can have
    # at most 4 letters. Christopher and Michelle are Ethos-only for that reason.
    'Guy': 'en-US-GuyNeural',
}
FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
PARALLEL = 4


def phrases():
    with open(os.path.join(HERE, 'phrases.psv'), encoding='utf8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                name, text = line.split('|', 1)
                yield name, text


async def make(voice, name, text, out, gate):
    wav = os.path.join(out, name + '.wav')
    if os.path.exists(wav):
        return
    async with gate:
        with tempfile.TemporaryDirectory() as tmp:
            mp3 = os.path.join(tmp, 'a.mp3')
            for attempt in range(4):
                try:
                    await edge_tts.Communicate(text, voice).save(mp3)
                    break
                except Exception:
                    if attempt == 3:
                        raise
                    await asyncio.sleep(2 + attempt * 3)
            subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', '-i', mp3,
                            '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11',
                            '-ar', '32000', '-ac', '1', '-c:a', 'pcm_s16le', wav], check=True)


async def main():
    root = sys.argv[1]
    names = sys.argv[2:] or list(VOICES)
    items = list(phrases())
    gate = asyncio.Semaphore(PARALLEL)
    for pack in names:
        out = os.path.join(root, pack)
        os.makedirs(out, exist_ok=True)
        await asyncio.gather(*(make(VOICES[pack], n, t, out, gate) for n, t in items))
        print(pack, len(os.listdir(out)), 'files')


if __name__ == '__main__':
    asyncio.run(main())
