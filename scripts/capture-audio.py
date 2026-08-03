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

Frames pair 1:1 with the video port's VIDEO_FRAME messages -- the Nth
AUDIO_PCM describes the same frame as the Nth VIDEO_FRAME -- which is
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
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import wave
from pathlib import Path

AESP_MAGIC = 0xAE50
AESP_VERSION = 1
AESP_HEADER_SIZE = 8

MSG_AUDIO_PCM = 0x80
MSG_AUDIO_CONFIG = 0x81
MSG_AUDIO_SUBSCRIBE = 0x83

# Fallbacks matching src/aesp.lisp %AUDIO-CONFIG-PAYLOAD, used when the
# control-port exchange is skipped or fails.
DEFAULT_SAMPLE_RATE = 44744
DEFAULT_BITS = 8
DEFAULT_CHANNELS = 1


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
            raise ConnectionError(f"EOF after {len(buf)} of {n} bytes")
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


def fetch_audio_config(host: str, control_port: int,
                       timeout: float) -> tuple[int, int, int]:
    """Send AUDIO_SUBSCRIBE on the control port; return (rate, bits, channels).

    The server replies with AUDIO_CONFIG: sample-rate(u32) bits(u8)
    channels(u8).  Raises AESPError on an unexpected reply.
    """
    with socket.create_connection((host, control_port), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(encode_message(MSG_AUDIO_SUBSCRIBE))
        msg_type, payload = read_message(s)
        if msg_type != MSG_AUDIO_CONFIG:
            raise AESPError(
                f"expected AUDIO_CONFIG (0x{MSG_AUDIO_CONFIG:02X}), "
                f"got 0x{msg_type:02X}")
        if len(payload) < 6:
            raise AESPError(f"AUDIO_CONFIG payload too short: {len(payload)}")
        rate = struct.unpack(">I", payload[:4])[0]
        return rate, payload[4], payload[5]


def capture_audio(host: str, audio_port: int, timeout: float,
                  frames: int) -> bytes:
    """Connect to the audio port and collect FRAMES AUDIO_PCM payloads."""
    chunks: list[bytes] = []
    with socket.create_connection((host, audio_port), timeout=timeout) as s:
        s.settimeout(timeout)
        while len(chunks) < frames:
            msg_type, payload = read_message(s)
            if msg_type != MSG_AUDIO_PCM:
                print(f"  (ignoring non-PCM message 0x{msg_type:02X})",
                      file=sys.stderr)
                continue
            chunks.append(payload)
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
    p.add_argument("-H", "--host", default="127.0.0.1",
                   help="AESP server host (default: 127.0.0.1)")
    p.add_argument("-p", "--audio-port", type=int, default=47802,
                   help="AESP audio port (default: 47802)")
    p.add_argument("--control-port", type=int, default=47800,
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

    rate, bits, channels = DEFAULT_SAMPLE_RATE, DEFAULT_BITS, DEFAULT_CHANNELS
    if not args.no_control:
        try:
            rate, bits, channels = fetch_audio_config(
                args.host, args.control_port, args.timeout)
            print(f"AUDIO_CONFIG: {rate} Hz, {bits}-bit, {channels}ch",
                  file=sys.stderr)
        except (OSError, AESPError) as e:
            print(f"warning: AUDIO_CONFIG exchange failed ({e}); "
                  f"assuming {rate} Hz {bits}-bit {channels}ch", file=sys.stderr)

    try:
        pcm = capture_audio(args.host, args.audio_port, args.timeout,
                            args.frames)
    except (OSError, AESPError, ConnectionError) as e:
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
