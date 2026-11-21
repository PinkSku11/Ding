"""Writes a solid-colour PNG: solid-png.py PATH WIDTH HEIGHT R G B"""
import struct
import sys
import zlib

path, w, h, r, g, b = sys.argv[1], *map(int, sys.argv[2:7])
raw = (b"\x00" + bytes([r, g, b]) * w) * h


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(path, "wb").write(png)
print("wrote", path)
