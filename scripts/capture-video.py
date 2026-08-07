#!/usr/bin/env python3
"""Capture N frames of video from a running atari800-cl AESP server.

Connects to the AESP video port and writes every VIDEO_FRAME it receives
as a numbered image in a directory: frame00001.png, frame00002.png, ...
— the layout ffmpeg's `-i frame%05d.png` pattern expects, which is how
scripts/record.sh turns a capture into an mp4.

PNG needs Pillow; without it the frames are written as PPM instead (same
numbering, .ppm suffix) and ffmpeg reads those just as happily.

Usage:
    ./scripts/capture-video.py [-d DIR] [--frames N] [-H HOST]
                               [-p VIDEO_PORT] [--control-port PORT]
                               [--no-control] [--timeout SECS]
                               [--prefix NAME] [--format auto|png|ppm]

Defaults: HOST=127.0.0.1, VIDEO_PORT=47801, CONTROL_PORT=47800,
DIR=frames, frames=60 (one second of NTSC video), TIMEOUT=10.

Prints one line per completed capture run:

    VIDEO_CAPTURE dir=<dir> pattern=<prefix>%05d.<ext> frames=<n> first=<frame-no>

so a calling script can pick up the pattern without guessing.  The frame
numbers in the filenames are capture-relative (1..N); the emulator's own
frame counter for the first captured frame is reported as `first=`.

Frames pair 1:1 with the audio port's AUDIO_PCM messages — both are
pushed from the same post-frame hook — so a video and an audio capture
started together stay in sync without timestamps.

The protocol codec lives in scripts/aesp_client.py, shared with
capture-screenshot.py and capture-audio.py.
"""

from __future__ import annotations

import argparse
import socket
import sys
from pathlib import Path

import aesp_client as aesp


def capture_frames(host: str, video_port: int, timeout: float, frames: int,
                   width: int, height: int, out_dir: Path, prefix: str,
                   fmt: str) -> tuple[int, int, str]:
    """Capture FRAMES frames into OUT_DIR.

    Returns (count_written, first_emulator_frame_number, extension).
    """
    expected = width * height * 3
    out_dir.mkdir(parents=True, exist_ok=True)
    first_frame_no = -1
    ext = "png"
    written = 0
    with socket.create_connection((host, video_port), timeout=timeout) as s:
        s.settimeout(timeout)
        while written < frames:
            frame_no, rgb = aesp.read_video_frame(s, expected)
            if first_frame_no < 0:
                first_frame_no = frame_no
            path = out_dir / f"{prefix}{written + 1:05d}.png"
            actual = aesp.write_image(path, width, height, rgb, fmt)
            ext = actual.suffix.lstrip(".")
            written += 1
            if written % 60 == 0 or written == frames:
                print(f"  {written}/{frames} frames", file=sys.stderr)
    return written, first_frame_no, ext


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-d", "--dir", default="frames",
                   help="output directory for the frame images (default: frames)")
    p.add_argument("--prefix", default="frame",
                   help="filename prefix (default: frame)")
    p.add_argument("--frames", type=int, default=60,
                   help="number of frames to capture (default: 60)")
    p.add_argument("-H", "--host", default=aesp.DEFAULT_HOST,
                   help=f"AESP server host (default: {aesp.DEFAULT_HOST})")
    p.add_argument("-p", "--video-port", type=int, default=aesp.DEFAULT_VIDEO_PORT,
                   help=f"AESP video port (default: {aesp.DEFAULT_VIDEO_PORT})")
    p.add_argument("--control-port", type=int, default=aesp.DEFAULT_CONTROL_PORT,
                   help=f"AESP control port (default: {aesp.DEFAULT_CONTROL_PORT})")
    p.add_argument("--no-control", action="store_true",
                   help="skip VIDEO_SUBSCRIBE; use default 384x240 geometry")
    p.add_argument("--timeout", type=float, default=10.0,
                   help="socket timeout in seconds (default: 10)")
    p.add_argument("--format", choices=["auto", "png", "ppm"], default="auto",
                   help="image format (default: auto -> png if Pillow else ppm)")
    args = p.parse_args(argv)

    if args.frames <= 0:
        p.error("--frames must be positive")

    width, height, bpp = aesp.resolve_video_geometry(
        args.host, args.control_port, args.timeout, not args.no_control)
    if bpp != 24:
        print(f"error: unsupported bpp {bpp} (only 24-bit RGB supported)",
              file=sys.stderr)
        return 2

    out_dir = Path(args.dir)
    print(f"capturing {args.frames} frames from {args.host}:{args.video_port} "
          f"into {out_dir}/", file=sys.stderr)

    try:
        written, first, ext = capture_frames(
            args.host, args.video_port, args.timeout, args.frames,
            width, height, out_dir, args.prefix, args.format)
    except (OSError, RuntimeError, aesp.AESPError, ConnectionError) as e:
        print(f"error: video capture failed: {e}", file=sys.stderr)
        return 1

    print(f"VIDEO_CAPTURE dir={out_dir} "
          f"pattern={args.prefix}%05d.{ext} frames={written} first={first}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
