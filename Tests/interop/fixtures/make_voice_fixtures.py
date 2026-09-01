#!/usr/bin/env python3
"""Generate voice interop fixtures deterministically.

Codec2 (wire modes 0x04/0x08/0x09): pycodec2 encode of a 2.0s 8k mono
440 Hz sine, raw frame concatenation - NO header byte, exactly what iOS
`Codec2RawFile` and Android emit. Byte count is pinned to
`bytes_per_frame * n_frames`; a deviation fails the build.

Opus (wire mode 0x10): valid Ogg/Opus produced by ffmpeg libopus at each
iOS profile's rate/channel count. These are small enough to ride the
`lxma://test-send` deep link (hex param well under iOS's URL cap).

The Ogg granule correctness that makes Sideband playback work is NOT
produced here - it is produced by iOS's own `OggOpusFileWriter` (outbound
iOS->Sideband tests exercise that) and by Sideband's own toolchain
(inbound Sideband->iOS tests use Sideband-originated Ogg, the
known-good reference). Fixtures here are *inputs* to both directions.
"""
import math
import os
import struct
import subprocess
import sys

import numpy as np

FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "ffprobe")


def sine_pcm(rate: int, secs: float, freq: float = 440.0, amp: int = 8000) -> bytes:
    n = int(rate * secs)
    out = bytearray()
    for i in range(n):
        out += struct.pack("<h", int(amp * math.sin(2 * math.pi * freq * i / rate)))
    return bytes(out)


def encode_codec2(samples: bytes, rate: int, bitrate: int, out_path: str) -> dict:
    import pycodec2
    c2 = pycodec2.Codec2(int(bitrate))
    spf = c2.samples_per_frame()
    bpf = c2.bytes_per_frame()
    n_samples = len(samples) // 2
    n_frames = n_samples // spf
    pcm = np.frombuffer(samples, dtype=np.int16)
    out = bytearray()
    for i in range(n_frames):
        out += c2.encode(pcm[i * spf:(i + 1) * spf])
    data = bytes(out)
    expected = bpf * n_frames
    if len(data) != expected:
        raise AssertionError(
            f"codec2_{bitrate}: pycodec2 emitted {len(data)} bytes, "
            f"expected {expected} (bpf={bpf} x {n_frames} frames)"
        )
    with open(out_path, "wb") as f:
        f.write(data)
    return {"spf": spf, "bpf": bpf, "frames": n_frames, "bytes": len(data)}


def encode_opus(pcm: bytes, rate: int, channels: int, bitrate: str,
                out_path: str) -> dict:
    tmp = out_path + ".pcm"
    with open(tmp, "wb") as f:
        f.write(pcm)
    subprocess.run(
        [FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
         "-f", "s16le", "-ar", str(rate), "-ac", str(channels), "-i", tmp,
         "-c:a", "libopus", "-b:a", bitrate, "-application", "voip", out_path],
        check=True,
    )
    os.unlink(tmp)
    # ffprobe must agree it is a real Ogg/Opus stream (the plan requires
    # the artifact to be validated before the live matrix counts it).
    probe = subprocess.run(
        [FFPROBE, "-hide_banner", "-v", "error", "-show_entries",
         "format=format_name:stream=codec_name,sample_rate,channels",
         "-of", "default=nw=1", out_path],
        capture_output=True, text=True, check=True,
    ).stdout
    assert "ogg" in probe.lower(), f"{out_path}: ffprobe format != ogg:\n{probe}"
    assert "opus" in probe.lower(), f"{out_path}: ffprobe codec != opus:\n{probe}"
    return {"bytes": os.path.getsize(out_path), "probe": probe.strip()}


def generate_all(out_dir: str) -> dict:
    os.makedirs(out_dir, exist_ok=True)
    manifest = {}

    codec2_modes = {0x04: 1200, 0x08: 2400, 0x09: 3200}
    for mode, bitrate in codec2_modes.items():
        info = encode_codec2(
            sine_pcm(8000, 2.0), 8000, bitrate,
            f"{out_dir}/c2_{bitrate}.c2",
        )
        info["wire_mode"] = mode
        info["src"] = "pycodec2"
        manifest[f"c2_{bitrate}"] = info

    opus_profiles = [
        ("opus_medium", 24000, 1, "6k"),    # voiceMedium: 24k mono
        ("opus_high", 48000, 1, "10k"),     # voiceHigh: 48k mono
        ("opus_max", 48000, 2, "16k"),      # voiceMax: 48k stereo
    ]
    # 0.5s clips: the iOS->Sideband cells ride the lxma://test-send deep link,
    # and the custom-scheme URL is truncated at a fixed point (~954B payload).
    # 0.5s keeps every Opus fixture under that cap while still exercising the
    # Opus container, granules, and rate/channel config. (Codec2 cells use
    # 2.0s above and already pass byte-identical - they prove the field-7
    # packing path.)
    OPUS_SECS = 0.5
    for name, rate, ch, br in opus_profiles:
        if ch == 2:
            mono = sine_pcm(rate, OPUS_SECS)
            stereo = bytearray()
            for i in range(0, len(mono), 2):
                stereo += mono[i:i + 2] + mono[i:i + 2]
            pcm = bytes(stereo)
        else:
            pcm = sine_pcm(rate, OPUS_SECS)
        info = encode_opus(pcm, rate, ch, br, f"{out_dir}/{name}.ogg")
        info["wire_mode"] = 0x10
        info["src"] = f"ffmpeg-libopus-{rate}hz-{ch}ch-{OPUS_SECS}s"
        manifest[name] = info

    import json
    with open(f"{out_dir}/manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)
    return manifest


if __name__ == "__main__":
    out = generate_all(sys.argv[1] if len(sys.argv) > 1 else "fixtures")
    for name, info in out.items():
        print(f"{name}: mode=0x{info['wire_mode']:02x} bytes={info['bytes']} src={info['src']}")
    print(f"\n{len(out)} fixtures -> {sys.argv[1] if len(sys.argv) > 1 else 'fixtures'}/")
