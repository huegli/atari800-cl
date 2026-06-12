"""CLI text protocol codec.

The CLI protocol is line-oriented:
  request:  CMD:<verb> [args...]\\n
  reply:    OK:<data>\\n    or    ERR:<message>\\n
Multi-line OK replies join records with U+001E (record separator).
"""

from __future__ import annotations

import socket
from typing import Tuple

RECORD_SEPARATOR = "\x1e"


class CLIProtocolError(Exception):
    """Raised on malformed CLI lines (e.g. no terminator before EOF)."""


def encode_request(line: str) -> bytes:
    """Encode LINE as a UTF-8 byte string with a trailing newline."""
    if not line.endswith("\n"):
        line = line + "\n"
    return line.encode("utf-8")


def classify_reply(line: str) -> Tuple[str, str]:
    """Classify a reply LINE; return (status, data) where status is
    OK | ERR | UNKNOWN and DATA is whatever followed the prefix.
    """
    if line.startswith("OK:"):
        return "OK", line[3:].rstrip("\r\n")
    if line.startswith("ERR:"):
        return "ERR", line[4:].rstrip("\r\n")
    return "UNKNOWN", line.rstrip("\r\n")


def split_multiline(data: str) -> list[str]:
    """Split a multi-record OK payload on U+001E."""
    return data.split(RECORD_SEPARATOR)


def read_reply(sock: socket.socket, timeout: float | None = None) -> Tuple[str, str, str]:
    """Read a single newline-terminated reply from SOCK.

    Returns (status, data, raw_line) where RAW_LINE has the trailing
    newline stripped. Raises ConnectionError on EOF before any byte.
    Returns ('disconnect', '', '') if the server closed the connection
    *after* sending some bytes — caller decides how to handle it.
    Re-raises socket.timeout if no bytes arrive within TIMEOUT.
    """
    if timeout is not None:
        sock.settimeout(timeout)
    buf = bytearray()
    while True:
        try:
            chunk = sock.recv(4096)
        except (socket.timeout, TimeoutError):
            if not buf:
                raise
            # Partial — treat as malformed-but-loggable.
            raw = buf.decode("utf-8", errors="replace")
            raise CLIProtocolError(f"timeout reading reply; partial: {raw!r}")
        if not chunk:
            if not buf:
                raise ConnectionError("EOF before reply")
            # Server closed without a newline — return what we have.
            raw = buf.decode("utf-8", errors="replace")
            status, data = classify_reply(raw)
            return status, data, raw
        buf.extend(chunk)
        if b"\n" in buf:
            break
    line, _, _rest = buf.partition(b"\n")
    raw = line.decode("utf-8", errors="replace")
    status, data = classify_reply(raw)
    return status, data, raw


# ---------------------------------------------------------------------------
# Self-tests.

def _self_test() -> None:
    assert encode_request("CMD:ping") == b"CMD:ping\n"
    assert encode_request("CMD:ping\n") == b"CMD:ping\n"
    assert classify_reply("OK:pong") == ("OK", "pong")
    assert classify_reply("ERR:bad arg") == ("ERR", "bad arg")
    assert classify_reply("hello") == ("UNKNOWN", "hello")
    assert split_multiline(f"a{RECORD_SEPARATOR}b{RECORD_SEPARATOR}c") == ["a", "b", "c"]


if __name__ == "__main__":
    _self_test()
    print("cli_codec: ok")
