#!/usr/bin/env python3
"""Generate a 1024x1024 DeepSeek-Harness app icon (RGBA PNG) using only stdlib.

DeepSeek brand-ish blue gradient. The PNG is consumed by `iconutil` to produce
the .icns set bundled into the .app. Replace with real artwork later.
"""
import os
import zlib
import struct

W = H = 1024


def pixel(x: int, y: int):
    nx, ny = x / (W - 1), y / (H - 1)
    r = int(0x33 + (0x6E - 0x33) * ny)
    g = int(0x58 + (0x8B - 0x58) * ny)
    b = int(0xE0 + (0xFF - 0xE0) * nx)
    return (r, g, b, 255)


def build_png() -> bytes:
    raw = bytearray()
    for y in range(H):
        raw.append(0)  # PNG filter type 0 (None) per scanline
        for x in range(W):
            r, g, b, a = pixel(x, y)
            raw += bytes((r, g, b, a))
    return b"".join(
        [
            b"\x89PNG\r\n",
            b"\x1a\n",
            _chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)),
            _chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
            _chunk(b"IEND", b""),
        ]
    )


def _chunk(typ: bytes, data: bytes) -> bytes:
    body = typ + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "src-tauri", "icons", "icon.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(build_png())
    print("wrote", os.path.abspath(out))
