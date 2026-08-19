#!/usr/bin/env python3
"""Capture POKEY audio from a running atari800-cl AESP server into a WAV.

The AESP server pushes one AUDIO_PCM message per emulated NTSC frame to
every client connected to its audio port.  The payload is raw mono
unsigned-8 PCM with no header of its own -- the payload length IS the
sample count (746 or 747 samples per frame at 44,744 Hz, the 1.79 MHz
CPU clock divided by 40).

Synthesis is attached only while at least one audio client is connected,
and it switches on at the end of the frame during which this script
connects, so the first push arrives one frame later.  That means the
capture always starts on a frame boundary with no partial buffer.

Frames pair 1:1 with the video port's FRAME_RAW messages -- the Nth
AUDIO_PCM describes the same frame as the Nth FRAME_RAW -- which is
what lets scripts/record.sh mux the two streams without timestamps.

Usage:
    ./scripts/capture-audio.py [-o OUT.wav] [-H HOST] [-p AUDIO_PORT]
                               [--frames N] [--timeout SECS]
                               [--control-port PORT] [--no-control]

Defaults: HOST=127.0.0.1, AUDIO_PORT=47802, CONTROL_PORT=47800,
OUT=audio.wav, frames=60 (one second of NTSC video), TIMEOUT=10.

Like capture-screenshot.py, this optionally sends AUDIO_SUBSCRIBE on the
control port first to fetch AUDIO_CONFIG and use the server's declared
rate/format, which is what a real Attic client would do.

The protocol codec lives in scripts/aesp_client.py, shared with
capture-screenshot.py and capture-video.py.
"""

from __future__ import annotations

import argparse
import socket
import sys
import wave
from pathlib import Path

import aesp_client as aesp


def capture_audio(host: str, audio_port: int, timeout: float,
                  frames: int) -> bytes:
    """Connect to the audio port and collect FRAMES AUDIO_PCM payloads."""
    chunks: list[bytes] = []
    with socket.create_connection((host, audio_port), timeout=timeout) as s:
        s.settimeout(timeout)
        while len(chunks) < frames:
            chunks.append(aesp.read_audio_pcm(s))
            if len(chunks) % 60 == 0 or len(chunks) == frames:
                total = sum(len(c) for c in chunks)
                print(f"  {len(chunks)}/{frames} frames, {total} samples",
                      file=sys.stderr)
    return b"".join(chunks)


def write_wav(path: Path, pcm: bytes, rate: int, bits: int,
              channels: int) -> None:
    if bits != 8:
        raise RuntimeError(f"only 8-bit PCM is supported, server said {bits}")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(1)          # 8-bit; WAV stores it unsigned, as we do
        w.setframerate(rate)
        w.writeframes(pcm)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-o", "--out", default="audio.wav",
                   help="output WAV file (default: audio.wav)")
    p.add_argument("-H", "--host", default=aesp.DEFAULT_HOST,
                   help="AESP server host (default: 127.0.0.1)")
    p.add_argument("-p", "--audio-port", type=int, default=aesp.DEFAULT_AUDIO_PORT,
                   help="AESP audio port (default: 47802)")
    p.add_argument("--control-port", type=int, default=aesp.DEFAULT_CONTROL_PORT,
                   help="AESP control port (default: 47800)")
    p.add_argument("--no-control", action="store_true",
                   help="skip AUDIO_SUBSCRIBE; assume 44744 Hz mono u8")
    p.add_argument("--frames", type=int, default=60,
                   help="number of emulated frames to capture (default: 60)")
    p.add_argument("--timeout", type=float, default=10.0,
                   help="socket timeout in seconds (default: 10)")
    args = p.parse_args(argv)

    if args.frames <= 0:
        print("error: --frames must be positive", file=sys.stderr)
        return 2

    rate, bits, channels = aesp.DEFAULT_SAMPLE_RATE, aesp.DEFAULT_BITS, aesp.DEFAULT_CHANNELS
    if not args.no_control:
        try:
            rate, bits, channels = aesp.fetch_audio_config(
                args.host, args.control_port, args.timeout)
            print(f"AUDIO_CONFIG: {rate} Hz, {bits}-bit, {channels}ch",
                  file=sys.stderr)
        except (OSError, aesp.AESPError) as e:
            print(f"warning: AUDIO_CONFIG exchange failed ({e}); "
                  f"assuming {rate} Hz {bits}-bit {channels}ch", file=sys.stderr)

    try:
        pcm = capture_audio(args.host, args.audio_port, args.timeout,
                            args.frames)
    except (OSError, aesp.AESPError, ConnectionError) as e:
        print(f"error: audio capture failed: {e}", file=sys.stderr)
        return 1

    out = Path(args.out)
    try:
        write_wav(out, pcm, rate, bits, channels)
    except (OSError, RuntimeError) as e:
        print(f"error: could not write {out}: {e}", file=sys.stderr)
        return 1

    seconds = len(pcm) / rate if rate else 0.0
    print(f"wrote {out} ({len(pcm)} samples, {seconds:.2f}s at {rate} Hz)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
