#!/usr/bin/env python3
"""Capture a single screenshot from a running atari800-cl AESP server.

The AESP server (started by scripts/atari-run.sh or scripts/record.sh)
pushes one FRAME_RAW message per emulated NTSC frame to every client
connected to its video port.  Each frame is exactly 384 * 240 * 4 bytes
of BGRA8888 pixel data (row-major, top scanline first, no padding, no
frame-number prefix -- see docs/PROTOCOL.md in the Attic project).

This script connects to the video port, reads the first FRAME_RAW, converts
it to RGB, and writes it to a PNG (via Pillow if available) or a PPM (no
deps).

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

The protocol codec lives in scripts/aesp_client.py, shared with
capture-video.py and capture-audio.py.
"""

from __future__ import annotations

import argparse
import socket
import sys
from pathlib import Path

import aesp_client as aesp


def capture_frame(host: str, video_port: int, timeout: float,
                  skip: int, expected_bytes: int) -> bytes:
    """Connect to the video port and read until the (skip+1)th FRAME_RAW.

    Returns its BGRA payload.  Non-frame messages are ignored.
    """
    with socket.create_connection((host, video_port), timeout=timeout) as s:
        s.settimeout(timeout)
        for skipped in range(skip):
            aesp.read_video_frame(s, expected_bytes)
            print(f"  frame skipped ({skipped + 1}/{skip})", file=sys.stderr)
        return aesp.read_video_frame(s, expected_bytes)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-o", "--out", default="screenshot.png",
                   help="output file (default: screenshot.png)")
    p.add_argument("-H", "--host", default=aesp.DEFAULT_HOST,
                   help=f"AESP server host (default: {aesp.DEFAULT_HOST})")
    p.add_argument("-p", "--video-port", type=int, default=aesp.DEFAULT_VIDEO_PORT,
                   help=f"AESP video port (default: {aesp.DEFAULT_VIDEO_PORT})")
    p.add_argument("--control-port", type=int, default=aesp.DEFAULT_CONTROL_PORT,
                   help=f"AESP control port (default: {aesp.DEFAULT_CONTROL_PORT})")
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

    width, height, bpp = aesp.resolve_video_geometry(
        args.host, args.control_port, args.timeout, not args.no_control)
    if bpp != 4:
        print(f"error: unsupported bytes-per-pixel {bpp} (only BGRA32 supported)",
              file=sys.stderr)
        return 2

    expected = width * height * bpp
    print(f"connecting to video port {args.host}:{args.video_port} "
          f"(expecting {expected} BGRA bytes/frame)")

    try:
        bgra = capture_frame(
            args.host, args.video_port, args.timeout,
            skip=args.frames - 1, expected_bytes=expected)
    except (OSError, aesp.AESPError) as e:
        print(f"error: capture failed: {e}", file=sys.stderr)
        return 1

    print(f"captured frame ({len(bgra)} bytes)")

    try:
        written = aesp.write_image(Path(args.out), width, height, bgra,
                                   args.format)
    except (OSError, RuntimeError) as e:
        print(f"error: write failed: {e}", file=sys.stderr)
        return 1

    print(f"wrote {written}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
