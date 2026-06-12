"""AESP wire codec: 8-byte big-endian header + payload.

Pure functions: encode_message / decode_header / read_message. The
socket reader (read_message) is the only one that takes a file-like
object; everything else is byte-in, byte-out.
"""

from __future__ import annotations

import socket
import struct
from typing import Tuple

from protocol_spec import (
    AESP_HEADER_SIZE,
    AESP_MAGIC,
    AESP_MAX_PAYLOAD,
    AESP_VERSION,
)


class AESPProtocolError(Exception):
    """Raised on malformed AESP frames (bad magic/version/length)."""


def encode_message(msg_type: int, payload: bytes = b"") -> bytes:
    """Return the wire bytes for an AESP message.

    Header layout (big-endian):
      magic   u16 = 0xAE50
      version u8  = 0x01
      type    u8
      length  u32 (payload bytes)
    """
    if msg_type < 0 or msg_type > 0xFF:
        raise AESPProtocolError(f"type out of range: {msg_type}")
    if len(payload) > AESP_MAX_PAYLOAD:
        raise AESPProtocolError(f"payload too large: {len(payload)}")
    header = struct.pack(
        ">HBBI",
        AESP_MAGIC,
        AESP_VERSION,
        msg_type & 0xFF,
        len(payload),
    )
    return header + payload


def decode_header(header: bytes) -> Tuple[int, int]:
    """Validate an 8-byte HEADER; return (msg_type, payload_length)."""
    if len(header) < AESP_HEADER_SIZE:
        raise AESPProtocolError("short header")
    magic, version, msg_type, length = struct.unpack(">HBBI", header[:AESP_HEADER_SIZE])
    if magic != AESP_MAGIC:
        raise AESPProtocolError(f"bad magic 0x{magic:04X}")
    if version != AESP_VERSION:
        raise AESPProtocolError(f"bad version 0x{version:02X}")
    if length > AESP_MAX_PAYLOAD:
        raise AESPProtocolError(f"payload length too large: {length}")
    return msg_type, length


def encode_raw(magic: int, version: int, msg_type: int, length: int,
               payload: bytes = b"") -> bytes:
    """Build a raw frame, *bypassing* validation.

    Useful for negative test cases (bad magic, bad version, oversize length,
    truncated payload). The framework callers stamp deliberately invalid
    values here.
    """
    return struct.pack(">HBBI", magic & 0xFFFF, version & 0xFF,
                       msg_type & 0xFF, length & 0xFFFFFFFF) + payload


class _EOF(Exception):
    """Internal: peer closed before any bytes arrived this call."""


def _recv_exactly(sock: socket.socket, n: int, timeout: float | None = None) -> bytes:
    """Read exactly N bytes from SOCK.

    Distinguishes three failure modes so callers can classify them:
      - peer EOF before *any* byte arrives → raises _EOF (DISCONNECT)
      - timeout before any byte arrives → re-raises socket.timeout (TIMEOUT)
      - EOF/timeout after a partial read → returns what was read (truncated)
    """
    if timeout is not None:
        sock.settimeout(timeout)
    buf = bytearray()
    while len(buf) < n:
        try:
            chunk = sock.recv(n - len(buf))
        except (socket.timeout, TimeoutError):
            if not buf:
                raise
            return bytes(buf)
        if not chunk:
            if not buf:
                raise _EOF()
            return bytes(buf)
        buf.extend(chunk)
    return bytes(buf)


def read_message(sock: socket.socket, timeout: float | None = None) -> Tuple[int, bytes, bytes]:
    """Read one full AESP message from SOCK.

    Returns (msg_type, payload, raw_bytes) where RAW_BYTES is the header
    plus payload (for evidence capture).
      - raises ConnectionError on a clean EOF before any header byte
      - raises socket.timeout if nothing arrives within TIMEOUT
      - raises AESPProtocolError on a malformed/truncated frame
    """
    try:
        header = _recv_exactly(sock, AESP_HEADER_SIZE, timeout)
    except _EOF:
        raise ConnectionError("EOF before AESP header")
    if len(header) < AESP_HEADER_SIZE:
        raise AESPProtocolError(f"truncated header ({len(header)} bytes)")
    msg_type, length = decode_header(header)
    if length:
        try:
            payload = _recv_exactly(sock, length, timeout)
        except _EOF:
            raise AESPProtocolError("EOF mid-payload")
    else:
        payload = b""
    if len(payload) < length:
        raise AESPProtocolError(
            f"truncated payload (expected {length}, got {len(payload)})")
    return msg_type, payload, header + payload


# ---------------------------------------------------------------------------
# Self-tests (invoked from compare-protocols.py --self-test).

def _self_test() -> None:
    import io

    # Round-trip a PING.
    raw = encode_message(0x00)
    assert raw == bytes.fromhex("AE5001000000 0000".replace(" ", "")), raw.hex()
    msg_type, length = decode_header(raw)
    assert msg_type == 0x00 and length == 0, (msg_type, length)

    # Round-trip with a payload.
    raw = encode_message(0x06, b"hello")
    msg_type, length = decode_header(raw)
    assert msg_type == 0x06 and length == 5
    assert raw[AESP_HEADER_SIZE:] == b"hello"

    # Bad magic.
    try:
        decode_header(bytes.fromhex("0000010000000000"))
    except AESPProtocolError:
        pass
    else:
        raise AssertionError("expected bad-magic error")

    # Bad version.
    try:
        decode_header(bytes.fromhex("AE5002000000 0000".replace(" ", "")))
    except AESPProtocolError:
        pass
    else:
        raise AssertionError("expected bad-version error")

    # Oversize length.
    try:
        decode_header(bytes.fromhex("AE5001 00 FFFFFFFF".replace(" ", "")))
    except AESPProtocolError:
        pass
    else:
        raise AssertionError("expected oversize-length error")

    # Reader on a closed/empty stream.
    class _S:
        def __init__(self, data: bytes):
            self._b = io.BytesIO(data)
        def recv(self, n: int) -> bytes:
            return self._b.read(n)
        def settimeout(self, t):
            pass

    s = _S(b"")
    try:
        read_message(s)  # type: ignore[arg-type]
    except ConnectionError:
        pass
    else:
        raise AssertionError("expected ConnectionError on empty")

    s = _S(encode_message(0x05, b"\x01"))
    msg_type, payload, raw = read_message(s)  # type: ignore[arg-type]
    assert msg_type == 0x05 and payload == b"\x01" and len(raw) == 9


if __name__ == "__main__":
    _self_test()
    print("aesp_codec: ok")
