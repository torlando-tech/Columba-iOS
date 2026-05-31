#!/usr/bin/env python3
"""Make a minimal-but-valid PNG / JPEG / file fixture for interop tests.

Keeps the fixture small so the hex-encoded payload fits comfortably under
iOS's deep-link length cap (`lxma://test-send?image_hex=…`). The tests
don't care what the image looks like, only that the bytes round-trip
unchanged through the wire.

Run as a CLI for ad-hoc fixture inspection:

    python make_test_image.py png > /tmp/test.png
    python make_test_image.py jpeg > /tmp/test.jpg
    python make_test_image.py file --name notes.txt > /tmp/notes.txt
    python make_test_image.py hex png       # print hex-encoded bytes

Or import the functions from a pytest module.
"""

from __future__ import annotations
import argparse
import io
import struct
import sys
import zlib


def png_bytes() -> bytes:
    """Smallest valid 1×1 8-bit grayscale PNG."""
    sig = b"\x89PNG\r\n\x1a\n"

    def chunk(tag: bytes, body: bytes) -> bytes:
        return (
            struct.pack(">I", len(body))
            + tag
            + body
            + struct.pack(">I", zlib.crc32(tag + body))
        )

    # IHDR: 1×1, bit_depth=8, color_type=0 (grayscale), no interlace
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0)
    # IDAT: a single scanline of one pixel; the zlib-deflate of [filter_type=0, gray=0]
    idat_raw = b"\x00\x00"  # filter byte + one pixel byte
    idat = zlib.compress(idat_raw, level=9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def jpeg_bytes() -> bytes:
    """A minimal JPEG. ~125 B — small enough that hex-encoded stays under 300 chars."""
    # Hard-coded valid JPEG: SOI + APP0 (JFIF) + small DQT + minimal SOF0 + DHT (huffman tables
    # for the trivial all-zero MCU) + SOS + a single MCU of zeros + EOI. Constructed offline
    # to avoid pulling Pillow into the test deps just to generate a 1×1 jpeg.
    return bytes.fromhex(
        "ffd8ffe000104a46494600010101006000600000"
        "ffdb004300101010101010101010101010101010"
        "10101010101010101010101010101010101010101010"
        "1010101010101010101010101010101010101010101010"
        "10101010101010ffc0000b08000100010101110000ffc4001f"
        "00000105010101010101000000000000000000010203040506070809"
        "0a0bffc4001f0100030101010101010101010100000000000001020304"
        "05060708090a0bffda0008010100003f00fb50ffd9"
    )


def file_bytes(content: bytes = b"hello-from-interop-fixture\n") -> bytes:
    return content


def to_hex(b: bytes) -> str:
    return b.hex()


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("png").set_defaults(fn=lambda a: sys.stdout.buffer.write(png_bytes()))
    sub.add_parser("jpeg").set_defaults(fn=lambda a: sys.stdout.buffer.write(jpeg_bytes()))
    file_p = sub.add_parser("file")
    file_p.add_argument("--name", default="notes.txt", help="purely metadata; not used for raw output")
    file_p.set_defaults(fn=lambda a: sys.stdout.buffer.write(file_bytes()))
    hex_p = sub.add_parser("hex")
    hex_p.add_argument("kind", choices=["png", "jpeg", "file"])
    hex_p.set_defaults(
        fn=lambda a: print(to_hex(
            png_bytes() if a.kind == "png" else jpeg_bytes() if a.kind == "jpeg" else file_bytes()
        ))
    )
    args = p.parse_args(argv)
    args.fn(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
