#!/usr/bin/env python3
"""Capture a single screenshot from a running atari800-cl AESP server.

The AESP server (started by scripts/run-with-servers.sh) pushes one
VIDEO_FRAME message per emulated NTSC frame to every client connected to
its video port.  Each frame is:

    payload[0:4]   -- big-endian u32 frame number
    payload[4:]    -- 384 * 240 * 3 bytes of 24-bit RGB pixel data
                      (row-major, top scanline first, no padding)

This script connects to the video port, reads the first VIDEO_FRAME,
and writes it to a PNG (via Pillow if available) or a PPM (no deps).

Usage:
    ./scripts/capture-screenshot.py [-o OUTFILE] [-H HOST]
                                    [-p VIDEO_PORT] [--timeout SECS]
                                    [--frames N] [--control-port PORT]

Defaults: HOST=127.0.0.1, VIDEO_PORT=47801, CONTROL_PORT=47800,
OUTFILE=screenshot.png, TIMEOUT=10, frames=1 (single capture).

If --frames N (>1) is given, the Nth frame received is saved instead; useful
to let the emulator settle past the cold-reset screen.

Optionally sends a VIDEO_SUBSCRIBE on the control port first to fetch
FRAME_CONFIG and verify the geometry before reading frames.  This matches
what a real Attic client would do, though the atari800-cl server pushes
frames to every video-port connection regardless.
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from pathlib import Path

AESP_MAGIC = 0xAE50
AESP_VERSION = 1
AESP_HEADER_SIZE = 8

MSG_PING = 0x00
MSG_PONG = 0x01
MSG_ACK = 0x0F
MSG_ERROR = 0x3F
MSG_FRAME_CONFIG = 0x62
MSG_VIDEO_SUBSCRIBE = 0x63
MSG_VIDEO_FRAME = 0x65

# Default geometry from the atari800-cl server (see src/aesp.lisp
# %FRAME-CONFIG-PAYLOAD).  Used only if --control-port is skipped or the
# FRAME_CONFIG exchange fails.
DEFAULT_WIDTH = 384
DEFAULT_HEIGHT = 240
DEFAULT_BPP = 24


class AESPError(Exception):
    """Malformed AESP frame or unexpected server reply."""


def encode_message(msg_type: int, payload: bytes = b"") -> bytes:
    return struct.pack(">HBBI", AESP_MAGIC, AESP_VERSION, msg_type & 0xFF,
                       len(payload)) + payload


def recv_exactly(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError(
                f"EOF after {len(buf)} of {n} bytes")
        buf.extend(chunk)
    return bytes(buf)


def read_message(sock: socket.socket) -> tuple[int, bytes]:
    header = recv_exactly(sock, AESP_HEADER_SIZE)
    magic, version, msg_type, length = struct.unpack(">HBBI", header)
    if magic != AESP_MAGIC:
        raise AESPError(f"bad magic 0x{magic:04X}")
    if version != AESP_VERSION:
        raise AESPError(f"bad version 0x{version:02X}")
    payload = recv_exactly(sock, length) if length else b""
    return msg_type, payload


def fetch_frame_config(host: str, control_port: int, timeout: float) -> tuple[int, int, int]:
    """Send VIDEO_SUBSCRIBE on the control port; return (w, h, bpp).

    The server replies with FRAME_CONFIG: width(u16) height(u16) bpp(u8)
    fps(u8).  Raises AESPError on an unexpected reply.
    """
    with socket.create_connection((host, control_port), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(encode_message(MSG_VIDEO_SUBSCRIBE))
        msg_type, payload = read_message(s)
        if msg_type != MSG_FRAME_CONFIG:
            raise AESPError(
                f"expected FRAME_CONFIG (0x{MSG_FRAME_CONFIG:02X}), "
                f"got 0x{msg_type:02X}")
        if len(payload) < 6:
            raise AESPError(f"FRAME_CONFIG payload too short: {len(payload)}")
        width, height = struct.unpack(">HH", payload[:4])
        bpp = payload[4]
        return width, height, bpp


def capture_frame(host: str, video_port: int, timeout: float,
                  skip: int, expected_bytes: int) -> tuple[int, bytes]:
    """Connect to the video port and read until the (skip+1)th VIDEO_FRAME.

    Returns (frame_number, rgb_bytes).  Non-frame messages are ignored.
    """
    with socket.create_connection((host, video_port), timeout=timeout) as s:
        s.settimeout(timeout)
        frames_seen = 0
        while True:
            msg_type, payload = read_message(s)
            if msg_type != MSG_VIDEO_FRAME:
                # Video port should only push frames; warn and continue.
                print(f"  (ignoring non-frame message 0x{msg_type:02X})",
                      file=sys.stderr)
                continue
            if len(payload) < 4:
                raise AESPError("VIDEO_FRAME payload shorter than 4 bytes")
            frame_no = struct.unpack(">I", payload[:4])[0]
            rgb = payload[4:]
            if len(rgb) != expected_bytes:
                raise AESPError(
                    f"frame {frame_no}: expected {expected_bytes} RGB bytes, "
                    f"got {len(rgb)}")
            if frames_seen < skip:
                frames_seen += 1
                print(f"  frame {frame_no} skipped ({frames_seen}/{skip})",
                      file=sys.stderr)
                continue
            return frame_no, rgb


def write_png(path: Path, width: int, height: int, rgb: bytes) -> None:
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        raise RuntimeError("Pillow not available; use --format ppm")
    Image.frombytes("RGB", (width, height), rgb).save(path)


def write_ppm(path: Path, width: int, height: int, rgb: bytes) -> None:
    header = f"P6\n{width} {height}\n255\n".encode("ascii")
    with open(path, "wb") as f:
        f.write(header)
        f.write(rgb)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-o", "--out", default="screenshot.png",
                   help="output file (default: screenshot.png)")
    p.add_argument("-H", "--host", default="127.0.0.1",
                   help="AESP server host (default: 127.0.0.1)")
    p.add_argument("-p", "--video-port", type=int, default=47801,
                   help="AESP video port (default: 47801)")
    p.add_argument("--control-port", type=int, default=47800,
                   help="AESP control port (default: 47800)")
    p.add_argument("--no-control", action="store_true",
                   help="skip VIDEO_SUBSCRIBE; use default 384x240 geometry")
    p.add_argument("--frames", type=int, default=1,
                   help="save the Nth frame received (default: 1 = first)")
    p.add_argument("--timeout", type=float, default=10.0,
                   help="socket timeout in seconds (default: 10)")
    p.add_argument("--format", choices=["auto", "png", "ppm"], default="auto",
                   help="output format (default: auto -> png if Pillow else ppm)")
    args = p.parse_args(argv)

    if args.frames < 1:
        p.error("--frames must be >= 1")

    # Resolve geometry.
    width, height, bpp = DEFAULT_WIDTH, DEFAULT_HEIGHT, DEFAULT_BPP
    if not args.no_control:
        try:
            width, height, bpp = fetch_frame_config(
                args.host, args.control_port, args.timeout)
            print(f"FRAME_CONFIG: {width}x{height} {bpp}bpp")
        except (OSError, AESPError) as e:
            print(f"warning: FRAME_CONFIG fetch failed ({e}); "
                  f"using default {width}x{height}", file=sys.stderr)

    if bpp != 24:
        print(f"error: unsupported bpp {bpp} (only 24-bit RGB supported)",
              file=sys.stderr)
        return 2

    expected = width * height * 3
    print(f"connecting to video port {args.host}:{args.video_port} "
          f"(expecting {expected} RGB bytes/frame)")

    try:
        frame_no, rgb = capture_frame(
            args.host, args.video_port, args.timeout,
            skip=args.frames - 1, expected_bytes=expected)
    except (OSError, AESPError) as e:
        print(f"error: capture failed: {e}", file=sys.stderr)
        return 1

    print(f"captured frame #{frame_no} ({len(rgb)} bytes)")

    out = Path(args.out)
    fmt = args.format
    if fmt == "auto":
        try:
            import PIL  # noqa: F401
            fmt = "png"
        except ImportError:
            fmt = "ppm"

    # Override format by extension if user didn't force it.
    if args.format == "auto":
        ext = out.suffix.lower()
        if ext == ".ppm":
            fmt = "ppm"
        elif ext == ".png":
            fmt = "png"

    try:
        if fmt == "png":
            write_png(out, width, height, rgb)
        else:
            write_ppm(out, width, height, rgb)
    except Exception as e:
        print(f"error: write failed: {e}", file=sys.stderr)
        # PPM fallback if PNG failed.
        if fmt == "png":
            fallback = out.with_suffix(".ppm")
            print(f"  falling back to PPM: {fallback}", file=sys.stderr)
            write_ppm(fallback, width, height, rgb)
            out = fallback
        else:
            return 1

    print(f"wrote {out} ({width}x{height}, {fmt.upper()})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
