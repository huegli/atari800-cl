"""Static protocol spec: AESP message inventory and CLI command inventory.

These are encoded explicitly so the harness doesn't have to scrape
docs/PROTOCOL.md at runtime. Treat this file as the normative spec
mirror; bump the version constants if the upstream spec changes.

Source: Attic docs/PROTOCOL.md (protocol version 0x01, frozen at 0.1.0).
"""

from __future__ import annotations

AESP_MAGIC = 0xAE50
AESP_VERSION = 0x01
AESP_HEADER_SIZE = 8
AESP_MAX_PAYLOAD = 16 * 1024 * 1024  # 16 MiB

# AESP default ports (Attic defaults; atari800-cl matches).
AESP_DEFAULT_CONTROL_PORT = 47800
AESP_DEFAULT_VIDEO_PORT = 47801
AESP_DEFAULT_AUDIO_PORT = 47802
AESP_DEFAULT_WS_PORT = 47803  # out of scope for first pass

# AESP message type inventory (name -> byte).
AESP_MESSAGES = {
    "PING": 0x00,
    "PONG": 0x01,
    "PAUSE": 0x02,
    "RESUME": 0x03,
    "RESET": 0x04,
    "STATUS": 0x05,
    "INFO": 0x06,
    "BOOT_FILE": 0x07,
    "ACK": 0x0F,
    "ERROR": 0x3F,
    "KEY_DOWN": 0x40,
    "KEY_UP": 0x41,
    "JOYSTICK": 0x42,
    "CONSOLE_KEYS": 0x43,
    "PADDLE": 0x44,
    "FRAME_RAW": 0x60,
    "FRAME_DELTA": 0x61,
    "FRAME_CONFIG": 0x62,
    "VIDEO_SUBSCRIBE": 0x63,
    "VIDEO_UNSUBSCRIBE": 0x64,
    "AUDIO_PCM": 0x80,
    "AUDIO_CONFIG": 0x81,
    "AUDIO_SYNC": 0x82,
    "AUDIO_SUBSCRIBE": 0x83,
    "AUDIO_UNSUBSCRIBE": 0x84,
}

AESP_TYPE_NAMES = {v: k for k, v in AESP_MESSAGES.items()}


def aesp_type_name(b: int) -> str:
    """Return the canonical name for byte B, or 'UNKNOWN(0xNN)'."""
    return AESP_TYPE_NAMES.get(b, f"UNKNOWN(0x{b:02X})")


# AESP ERROR payload codes.
AESP_ERR_INVALID_COMMAND = 0x01
AESP_ERR_INVALID_ADDRESS = 0x02
AESP_ERR_INVALID_PAYLOAD = 0x03
AESP_ERR_OPERATION_FAILED = 0x04
AESP_ERR_NOT_IMPLEMENTED = 0x05

AESP_ERROR_CODES = {
    AESP_ERR_INVALID_COMMAND: "InvalidCommand",
    AESP_ERR_INVALID_ADDRESS: "InvalidAddress",
    AESP_ERR_INVALID_PAYLOAD: "InvalidPayload",
    AESP_ERR_OPERATION_FAILED: "OperationFailed",
    AESP_ERR_NOT_IMPLEMENTED: "NotImplemented",
}


# CLI command inventory (verb -> family).
CLI_COMMANDS = {
    # Core / control
    "ping": "core",
    "pause": "core",
    "resume": "core",
    "step": "core",
    "stepover": "core",
    "until": "core",
    "boot": "core",
    "version": "core",
    "reset": "core",
    "status": "core",
    "quit": "core",
    "shutdown": "core",
    # Memory / CPU
    "read": "memory",
    "write": "memory",
    "fill": "memory",
    "screen": "memory",
    "registers": "cpu",
    "disassemble": "cpu",
    "assemble": "cpu",
    # Debugging
    "breakpoint": "debug",  # subcommands: set/clear/clearall/list
    # Disk / state / media
    "mount": "disk",
    "unmount": "disk",
    "drives": "disk",
    "state": "disk",  # save/load
    "screenshot": "media",
    # Input / BASIC / DOS
    "inject": "input",  # basic|keys
    "basic": "basic",
    "dos": "dos",
}


# atari800-cl MVP verbs (from src/cli-socket.lisp *cli-verbs*).
ATARI800_CL_SUPPORTED_VERBS = {
    "ping", "version", "pause", "resume", "reset",
    "status", "step", "read", "write", "fill", "registers",
    "quit",  # implemented inline in dispatch-cli-line
}

# Verbs atari800-cl recognizes but explicitly defers ("ERR:Not implemented").
ATARI800_CL_DEFERRED_VERBS = {
    "basic", "dos", "boot", "screen", "disassemble", "assemble", "breakpoint",
    "mount", "unmount", "drives", "state", "screenshot", "inject", "shutdown",
}


def atari800_cl_supports(verb: str) -> bool:
    """True iff atari800-cl currently implements VERB (not just recognizes it)."""
    return verb in ATARI800_CL_SUPPORTED_VERBS
