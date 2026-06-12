"""Normalize raw protocol responses into semantic records.

These are deliberately schema-light dictionaries: just enough structure
for `expectations.py` to match against, and just enough provenance
(raw_payload_hex, raw_payload_sha256) to debug a failed comparison.

Two normalizers: `normalize_aesp` for binary AESP frames,
`normalize_cli` for CLI text replies. Both are pure; they don't talk
to sockets.
"""

from __future__ import annotations

import hashlib
import json
import re
import struct
from typing import Any

from protocol_spec import (
    AESP_ERROR_CODES,
    AESP_MESSAGES,
    AESP_TYPE_NAMES,
    aesp_type_name,
)


# ---------------------------------------------------------------------------
# AESP.

def _payload_class(msg_type: int, payload: bytes) -> str:
    """Classify a payload for cross-implementation comparison."""
    if msg_type == AESP_MESSAGES["ERROR"]:
        return "error"
    if msg_type == AESP_MESSAGES["INFO"]:
        # Try JSON first; fall through to text/binary.
        try:
            json.loads(payload.decode("utf-8"))
            return "json"
        except (ValueError, UnicodeDecodeError):
            return "text" if _looks_textual(payload) else "binary"
    if msg_type in (AESP_MESSAGES["STATUS"],):
        return "status"
    if msg_type == AESP_MESSAGES["FRAME_CONFIG"]:
        return "frame_config"
    if msg_type == AESP_MESSAGES["AUDIO_CONFIG"]:
        return "audio_config"
    if msg_type == AESP_MESSAGES["FRAME_RAW"]:
        return "frame"
    if msg_type == AESP_MESSAGES["FRAME_DELTA"]:
        return "frame_delta"
    if msg_type == AESP_MESSAGES["AUDIO_PCM"]:
        return "audio"
    if msg_type == AESP_MESSAGES["AUDIO_SYNC"]:
        return "audio_sync"
    return "empty" if not payload else "binary"


def _looks_textual(payload: bytes) -> bool:
    """True if all bytes are printable-ish."""
    if not payload:
        return False
    return all(0x20 <= b <= 0x7E or b in (0x09, 0x0A, 0x0D) for b in payload)


def _decode_frame_config(payload: bytes) -> dict | None:
    """Decode the spec'd 6-byte FRAME_CONFIG payload."""
    if len(payload) != 6:
        return None
    w, h, bpp, fps = struct.unpack(">HHBB", payload)
    return {"width": w, "height": h, "bytes_per_pixel": bpp, "fps": fps}


def _decode_audio_config(payload: bytes) -> dict | None:
    """Decode the spec'd 6-byte AUDIO_CONFIG payload."""
    if len(payload) != 6:
        return None
    rate, bits, channels = struct.unpack(">IBB", payload)
    return {"sample_rate": rate, "bits": bits, "channels": channels}


def _decode_error(payload: bytes) -> dict | None:
    """Decode an ERROR payload: 1 byte code + UTF-8 message."""
    if not payload:
        return {"code": None, "code_name": None, "message": ""}
    code = payload[0]
    msg = payload[1:].decode("utf-8", errors="replace")
    return {
        "code": code,
        "code_name": AESP_ERROR_CODES.get(code, f"Unknown(0x{code:02X})"),
        "message": msg,
    }


def _decode_info(payload: bytes) -> dict | None:
    """Try to decode INFO as JSON; fall back to text."""
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        return None
    try:
        return {"json": json.loads(text), "text": text}
    except ValueError:
        return {"text": text}


def normalize_aesp(msg_type: int, payload: bytes,
                   raw_bytes: bytes | None = None) -> dict[str, Any]:
    """Convert an AESP frame into a comparison-friendly record."""
    name = aesp_type_name(msg_type)
    payload_class = _payload_class(msg_type, payload)
    semantic: dict[str, Any] = {}
    if msg_type == AESP_MESSAGES["STATUS"] and len(payload) >= 1:
        # Per spec: byte0 0x01 = running. atari800-cl also encodes bit1 for
        # cpu-halted. Surface both readings.
        semantic["state"] = "running" if (payload[0] & 0x01) else "paused"
        semantic["cpu_halted"] = bool(payload[0] & 0x02)
    if msg_type == AESP_MESSAGES["FRAME_CONFIG"]:
        decoded = _decode_frame_config(payload)
        if decoded:
            semantic.update(decoded)
    if msg_type == AESP_MESSAGES["AUDIO_CONFIG"]:
        decoded = _decode_audio_config(payload)
        if decoded:
            semantic.update(decoded)
    if msg_type == AESP_MESSAGES["ERROR"]:
        decoded = _decode_error(payload)
        if decoded:
            semantic.update(decoded)
    if msg_type == AESP_MESSAGES["INFO"]:
        decoded = _decode_info(payload)
        if decoded:
            semantic.update(decoded)
    if msg_type == AESP_MESSAGES["ACK"]:
        # Spec says ACK contains 1 byte = type being acked. atari800-cl
        # currently sends an empty payload; the comparison framework treats
        # this as an accepted_difference rather than a hard failure.
        semantic["acked_type"] = payload[0] if len(payload) >= 1 else None
        semantic["acked_type_name"] = (
            aesp_type_name(payload[0]) if len(payload) >= 1 else None
        )

    return {
        "type": name,
        "type_byte": msg_type,
        "valid_header": True,
        "payload_length": len(payload),
        "payload_class": payload_class,
        "semantic_fields": semantic,
        "raw_payload_hex": payload.hex(),
        "raw_payload_sha256": hashlib.sha256(payload).hexdigest(),
        "raw_size": len(raw_bytes or b""),
    }


def normalize_disconnect(reason: str = "EOF") -> dict[str, Any]:
    """Record a connection-closed observation."""
    return {
        "type": "DISCONNECT",
        "type_byte": None,
        "valid_header": False,
        "payload_length": 0,
        "payload_class": "disconnect",
        "semantic_fields": {"reason": reason},
        "raw_payload_hex": "",
        "raw_payload_sha256": hashlib.sha256(b"").hexdigest(),
        "raw_size": 0,
    }


def normalize_timeout(timeout: float) -> dict[str, Any]:
    """Record a no-response observation."""
    return {
        "type": "TIMEOUT",
        "type_byte": None,
        "valid_header": False,
        "payload_length": 0,
        "payload_class": "timeout",
        "semantic_fields": {"timeout_s": timeout},
        "raw_payload_hex": "",
        "raw_payload_sha256": hashlib.sha256(b"").hexdigest(),
        "raw_size": 0,
    }


# ---------------------------------------------------------------------------
# CLI.

_REGISTERS_RE = re.compile(
    r"A=\$?(?P<a>[0-9A-Fa-f]+)\s+X=\$?(?P<x>[0-9A-Fa-f]+)\s+Y=\$?(?P<y>[0-9A-Fa-f]+)"
    r"\s+(?:S|SP)=\$?(?P<s>[0-9A-Fa-f]+)\s+P=\$?(?P<p>[0-9A-Fa-f]+)\s+PC=\$?(?P<pc>[0-9A-Fa-f]+)"
)
_HEX_BYTE_LIST = re.compile(r"^(?:[0-9A-Fa-f]{2})(?:[\s,]+(?:[0-9A-Fa-f]{2}))*$")


def _classify_cli_data(verb: str | None, data: str) -> str:
    """Heuristic data-class label for cross-impl comparison."""
    if not data:
        return "empty"
    if verb == "ping":
        return "pong"
    if verb == "version":
        return "version"
    if verb == "status":
        return "status"
    if verb == "registers" or _REGISTERS_RE.search(data):
        return "registers"
    if verb == "read":
        # atari800-cl: "DE AD BE EF"; Attic: "data DE,AD,BE,EF". Both yield
        # `memory_dump` once you strip prefix / split tokens.
        return "memory_dump"
    if verb == "step":
        return "step_result"
    if verb == "drives":
        return "list"
    if data.startswith("ASM "):
        return "asm_session"
    return "text"


def normalize_cli(verb: str | None, status: str, data: str, raw_line: str) -> dict[str, Any]:
    """Convert a CLI reply into a comparison-friendly record."""
    semantic: dict[str, Any] = {}
    data_class = _classify_cli_data(verb, data)
    if data_class == "registers":
        m = _REGISTERS_RE.search(data)
        if m:
            semantic["registers"] = {k.upper(): int(v, 16) for k, v in m.groupdict().items()}
    if data_class == "memory_dump":
        # Attic prefixes the byte list with the word "data" — strip non-hex
        # leading words so they don't contribute spurious hex pairs (the "da"
        # in "data" would otherwise read as 0xDA).
        body = data
        m = re.match(r"^\s*(?:data\s+)?(.*)$", body, re.IGNORECASE)
        if m:
            body = m.group(1)
        tokens = re.findall(r"[0-9A-Fa-f]{2}", body)
        if tokens:
            semantic["bytes"] = [int(t, 16) for t in tokens]
            semantic["byte_count"] = len(tokens)
    if verb == "version":
        semantic["text"] = data
    if verb == "status":
        semantic["text"] = data
        # Try to extract "running" or "paused" if present.
        for token in data.lower().split():
            if token in {"running", "paused"}:
                semantic["state"] = token
                break
        # Look for PC=.
        pc = re.search(r"pc\s*=\s*\$?([0-9A-Fa-f]+)", data, re.IGNORECASE)
        if pc:
            semantic["pc"] = int(pc.group(1), 16)
    return {
        "status": status,
        "verb": verb,
        "data": data,
        "data_class": data_class,
        "semantic_fields": semantic,
        "raw_line": raw_line,
    }


def normalize_cli_disconnect() -> dict[str, Any]:
    return {
        "status": "disconnect",
        "verb": None,
        "data": "",
        "data_class": "disconnect",
        "semantic_fields": {},
        "raw_line": "",
    }


def normalize_cli_timeout(timeout: float) -> dict[str, Any]:
    return {
        "status": "timeout",
        "verb": None,
        "data": "",
        "data_class": "timeout",
        "semantic_fields": {"timeout_s": timeout},
        "raw_line": "",
    }
