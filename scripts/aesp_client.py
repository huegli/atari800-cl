"""Shared AESP client helpers for the capture scripts.

AESP is atari800-cl's binary protocol (see README "Protocol servers" and
src/aesp.lisp).  Every message is an 8-byte big-endian header — magic
0xAE50, version 1, a 1-byte type, a 4-byte payload length — followed by
the payload.  The server listens on three ports: control, video, audio.

This module holds everything capture-screenshot.py, capture-video.py and
capture-audio.py would otherwise duplicate: the codec, the two subscribe
exchanges that fetch geometry / audio format, the frame readers, and the
image writers.  Scripts import it as a sibling module — Python puts a
script's own directory on sys.path, so `import aesp_client` works from
any working directory.

Nothing here talks to the emulator beyond the protocol; the server is
started by scripts/atari-run.sh or scripts/record.sh.
"""

from __future__ import annotations

import socket
import struct
import sys
from pathlib import Path

AESP_MAGIC = 0xAE50
AESP_VERSION = 1
AESP_HEADER_SIZE = 8

# Message types (src/aesp.lisp; matches the Attic project's
# docs/PROTOCOL.md and tools/protocol-comparison/protocol_spec.py).
MSG_PING = 0x00
MSG_PONG = 0x01
MSG_ACK = 0x0F
MSG_ERROR = 0x3F
MSG_FRAME_RAW = 0x60
MSG_FRAME_CONFIG = 0x62
MSG_VIDEO_SUBSCRIBE = 0x63
MSG_AUDIO_PCM = 0x80
MSG_AUDIO_CONFIG = 0x81
MSG_AUDIO_SUBSCRIBE = 0x83

# Defaults matching src/aesp.lisp's %FRAME-CONFIG-PAYLOAD and
# %AUDIO-CONFIG-PAYLOAD, used when the control-port exchange is skipped.
# FRAME_RAW is cropped to the Attic project's 336-pixel visible width
# (see +AESP-FRAME-RAW-WIDTH+ in src/aesp.lisp) -- these are only the
# fallback used when --no-control skips the FRAME_CONFIG exchange.
DEFAULT_WIDTH = 336
DEFAULT_HEIGHT = 240
DEFAULT_BYTES_PER_PIXEL = 4  # BGRA8888
DEFAULT_SAMPLE_RATE = 44744
DEFAULT_BITS = 8
DEFAULT_CHANNELS = 1

# Default ports.
DEFAULT_HOST = "127.0.0.1"
DEFAULT_CONTROL_PORT = 47800
DEFAULT_VIDEO_PORT = 47801
DEFAULT_AUDIO_PORT = 47802

# NTSC frame rate the emulator runs at; ffmpeg wants it for muxing.
NTSC_FPS = 59.92


class AESPError(Exception):
    """Malformed AESP frame or unexpected server reply."""


# ---------------------------------------------------------------------------
# Codec


def encode_message(msg_type: int, payload: bytes = b"") -> bytes:
    """Frame PAYLOAD as an AESP message of MSG_TYPE."""
    return struct.pack(">HBBI", AESP_MAGIC, AESP_VERSION, msg_type & 0xFF,
                       len(payload)) + payload


def recv_exactly(sock: socket.socket, n: int) -> bytes:
    """Read exactly N bytes, raising ConnectionError on a short stream."""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError(f"EOF after {len(buf)} of {n} bytes")
        buf.extend(chunk)
    return bytes(buf)


def read_message(sock: socket.socket) -> tuple[int, bytes]:
    """Read one AESP message; return (type, payload)."""
    header = recv_exactly(sock, AESP_HEADER_SIZE)
    magic, version, msg_type, length = struct.unpack(">HBBI", header)
    if magic != AESP_MAGIC:
        raise AESPError(f"bad magic 0x{magic:04X}")
    if version != AESP_VERSION:
        raise AESPError(f"bad version 0x{version:02X}")
    payload = recv_exactly(sock, length) if length else b""
    return msg_type, payload


# ---------------------------------------------------------------------------
# Control-port subscribe exchanges


def fetch_frame_config(host: str, control_port: int,
                       timeout: float) -> tuple[int, int, int]:
    """Send VIDEO_SUBSCRIBE on the control port; return (width, height,
    bytes_per_pixel).

    The server replies with FRAME_CONFIG: width(u16) height(u16)
    bytes-per-pixel(u8) fps(u8).  Raises AESPError on an unexpected reply.
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
        return width, height, payload[4]


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


def resolve_video_geometry(host: str, control_port: int, timeout: float,
                           use_control: bool) -> tuple[int, int, int]:
    """Geometry from the server, falling back to the built-in defaults.

    Returns (width, height, bytes_per_pixel).  A failed exchange warns and
    falls back rather than aborting: the video port pushes frames to every
    connection regardless of subscription, so a capture can still succeed
    without the control port.
    """
    if not use_control:
        return DEFAULT_WIDTH, DEFAULT_HEIGHT, DEFAULT_BYTES_PER_PIXEL
    try:
        width, height, bpp = fetch_frame_config(host, control_port, timeout)
        print(f"FRAME_CONFIG: {width}x{height} {bpp} bytes/pixel", file=sys.stderr)
        return width, height, bpp
    except (OSError, AESPError) as e:
        print(f"warning: FRAME_CONFIG fetch failed ({e}); using default "
              f"{DEFAULT_WIDTH}x{DEFAULT_HEIGHT}", file=sys.stderr)
        return DEFAULT_WIDTH, DEFAULT_HEIGHT, DEFAULT_BYTES_PER_PIXEL


# ---------------------------------------------------------------------------
# Frame readers


def read_video_frame(sock: socket.socket, expected_bytes: int) -> bytes:
    """Read messages until one FRAME_RAW arrives; return its BGRA payload.

    The payload is exactly width*height*4 bytes of BGRA8888, row-major, top
    scanline first -- no frame-number prefix (see docs/PROTOCOL.md in the
    Attic project).  EXPECTED_BYTES is width*height*4.
    """
    while True:
        msg_type, payload = read_message(sock)
        if msg_type != MSG_FRAME_RAW:
            print(f"  (ignoring non-frame message 0x{msg_type:02X})",
                  file=sys.stderr)
            continue
        if len(payload) != expected_bytes:
            raise AESPError(
                f"expected {expected_bytes} BGRA bytes, got {len(payload)}")
        return payload


def read_audio_pcm(sock: socket.socket) -> bytes:
    """Read messages until one AUDIO_PCM arrives; return its raw samples.

    The payload has no header of its own: its length IS the sample count
    (746-747 mono u8 samples per NTSC frame at 44,744 Hz).
    """
    while True:
        msg_type, payload = read_message(sock)
        if msg_type != MSG_AUDIO_PCM:
            print(f"  (ignoring non-PCM message 0x{msg_type:02X})",
                  file=sys.stderr)
            continue
        return payload


# ---------------------------------------------------------------------------
# Image output


def have_pillow() -> bool:
    """True when Pillow is importable, i.e. PNG output is available."""
    try:
        import PIL  # noqa: F401
        return True
    except ImportError:
        return False


def bgra_to_rgb(bgra: bytes) -> bytes:
    """Drop the alpha byte and swap B/R: BGRA8888 -> RGB (3 bytes/pixel).

    Pure Python via bytearray slice assignment (C-implemented, no per-pixel
    loop) so this has no Pillow/numpy dependency -- needed for the PPM
    fallback path, and used unconditionally so write_png/write_ppm both take
    plain RGB.
    """
    rgb = bytearray(len(bgra) // 4 * 3)
    rgb[0::3] = bgra[2::4]  # R
    rgb[1::3] = bgra[1::4]  # G
    rgb[2::3] = bgra[0::4]  # B
    return bytes(rgb)


def write_png(path: Path, width: int, height: int, rgb: bytes) -> None:
    """Write RGB as a PNG.  Requires Pillow."""
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        raise RuntimeError("Pillow not available; use PPM output instead")
    Image.frombytes("RGB", (width, height), rgb).save(path)


def write_ppm(path: Path, width: int, height: int, rgb: bytes) -> None:
    """Write RGB as a binary PPM (P6) — no dependencies."""
    with open(path, "wb") as f:
        f.write(f"P6\n{width} {height}\n255\n".encode("ascii"))
        f.write(rgb)


def write_image(path: Path, width: int, height: int, bgra: bytes,
                fmt: str = "auto") -> Path:
    """Convert BGRA (the FRAME_RAW wire format) to RGB and write it to
    PATH; return the path actually written.

    "auto" picks PNG when Pillow is installed and PPM otherwise, except
    that an explicit .ppm suffix always means PPM.  When PNG was asked
    for implicitly but Pillow is missing, the suffix is rewritten to
    .ppm rather than putting PPM bytes in a .png file — the same
    convention scripts/atari-run.sh and minimal-xl/run.sh expect.  An
    explicit fmt="png" without Pillow raises instead of falling back.
    """
    rgb = bgra_to_rgb(bgra)
    if fmt == "auto":
        fmt = "ppm" if path.suffix.lower() == ".ppm" or not have_pillow() else "png"
    if fmt == "png":
        write_png(path, width, height, rgb)
        return path
    if path.suffix.lower() != ".ppm":
        path = path.with_suffix(".ppm")
    write_ppm(path, width, height, rgb)
    return path
