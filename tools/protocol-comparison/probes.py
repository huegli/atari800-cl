"""Environment capability probes.

These let the harness decide whether to skip an implementation,
skip a transport, or report a case as `inconclusive` instead of
failing. Each probe is cheap and non-destructive: bind/connect a
loopback socket, run a tool with --version, etc.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
from dataclasses import dataclass, asdict
from typing import Optional


@dataclass
class ProbeResult:
    """Per-capability probe outcome.

    AVAILABLE is the high-level yes/no; DETAIL is a short human string
    (program version, error message, port number) saved into reports
    so a failed run is debuggable from the JSON alone.
    """
    name: str
    available: bool
    detail: str = ""


# ---------------------------------------------------------------------------
# Network capability probes.

def probe_tcp_bind() -> ProbeResult:
    """Try binding a TCP loopback listener on an ephemeral port."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.listen(1)
        s.close()
        return ProbeResult("tcp_bind", True, f"bound 127.0.0.1:{port}")
    except OSError as e:
        return ProbeResult("tcp_bind", False, f"{e.errno}: {e.strerror}")


def probe_tcp_connect() -> ProbeResult:
    """Bind a listener, connect to it from the same process."""
    try:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client.connect(("127.0.0.1", port))
        conn, _ = listener.accept()
        client.close()
        conn.close()
        listener.close()
        return ProbeResult("tcp_connect", True, f"127.0.0.1:{port}")
    except OSError as e:
        return ProbeResult("tcp_connect", False, f"{e.errno}: {e.strerror}")


def probe_unix_bind() -> ProbeResult:
    """Try binding a Unix-domain socket under a temp dir."""
    if not hasattr(socket, "AF_UNIX"):
        return ProbeResult("unix_bind", False, "AF_UNIX not supported")
    path = None
    try:
        # Use a short path under TMPDIR to dodge the ~104-char sun_path cap.
        tmpdir = tempfile.mkdtemp(prefix="a800probe-")
        path = os.path.join(tmpdir, "p.sock")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(path)
        s.listen(1)
        s.close()
        return ProbeResult("unix_bind", True, path)
    except OSError as e:
        return ProbeResult("unix_bind", False, f"{e.errno}: {e.strerror}")
    finally:
        if path and os.path.exists(path):
            try:
                os.unlink(path)
            except OSError:
                pass
        if path:
            try:
                os.rmdir(os.path.dirname(path))
            except OSError:
                pass


def probe_unix_connect() -> ProbeResult:
    """Bind a Unix-domain listener and connect to it."""
    if not hasattr(socket, "AF_UNIX"):
        return ProbeResult("unix_connect", False, "AF_UNIX not supported")
    tmpdir = path = None
    try:
        tmpdir = tempfile.mkdtemp(prefix="a800probe-")
        path = os.path.join(tmpdir, "p.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(path)
        conn, _ = listener.accept()
        client.close()
        conn.close()
        listener.close()
        return ProbeResult("unix_connect", True, path)
    except OSError as e:
        return ProbeResult("unix_connect", False, f"{e.errno}: {e.strerror}")
    finally:
        if path and os.path.exists(path):
            try:
                os.unlink(path)
            except OSError:
                pass
        if tmpdir:
            try:
                os.rmdir(tmpdir)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Tool/repo probes.

def probe_tool(name: str, version_flag: str = "--version") -> ProbeResult:
    """Check that NAME is on PATH and runs with VERSION_FLAG."""
    path = shutil.which(name)
    if not path:
        return ProbeResult(name, False, "not on PATH")
    try:
        out = subprocess.run(
            [path, version_flag], capture_output=True, text=True, timeout=10
        )
        first = (out.stdout or out.stderr).strip().splitlines()[:1]
        return ProbeResult(name, out.returncode == 0,
                           first[0] if first else f"exit {out.returncode}")
    except (OSError, subprocess.TimeoutExpired) as e:
        return ProbeResult(name, False, str(e))


def probe_path(label: str, path: str, must_contain: Optional[list[str]] = None) -> ProbeResult:
    """Check that PATH exists and (optionally) contains the listed entries."""
    if not os.path.isdir(path):
        return ProbeResult(label, False, f"not a directory: {path}")
    for needed in must_contain or []:
        p = os.path.join(path, needed)
        if not os.path.exists(p):
            return ProbeResult(label, False, f"missing entry: {needed}")
    return ProbeResult(label, True, path)


# ---------------------------------------------------------------------------
# Aggregator.

def run_all(attic_dir: str, atari800_cl_dir: str) -> dict:
    """Run every probe; return a JSON-friendly dict."""
    results = {
        "tcp_bind": probe_tcp_bind(),
        "tcp_connect": probe_tcp_connect(),
        "unix_bind": probe_unix_bind(),
        "unix_connect": probe_unix_connect(),
        "swift": probe_tool("swift"),
        "sbcl": probe_tool("sbcl", "--version"),
        "lispworks": probe_tool("lw-console", "-version"),
        "python3": probe_tool("python3", "--version"),
        "attic_dir": probe_path(
            "attic_dir", attic_dir,
            must_contain=["Package.swift", "Sources/AtticServer"],
        ),
        "atari800_cl_dir": probe_path(
            "atari800_cl_dir", atari800_cl_dir,
            must_contain=["atari800-cl.asd", "src", "scripts/test-sbcl.sh"],
        ),
    }
    out = {k: asdict(v) for k, v in results.items()}
    out["summary"] = {
        "live_tcp": results["tcp_bind"].available and results["tcp_connect"].available,
        "live_unix": results["unix_bind"].available and results["unix_connect"].available,
        "attic_runnable": results["swift"].available and results["attic_dir"].available,
        "atari800_cl_runnable": (
            results["sbcl"].available and results["atari800_cl_dir"].available
        ),
    }
    return out


if __name__ == "__main__":
    import argparse
    import json
    import sys

    ap = argparse.ArgumentParser(description="Run environment capability probes.")
    ap.add_argument("--attic-dir",
                    default="/Users/nikolai/Source/Repos/GitHub/huegli/attic")
    ap.add_argument("--atari800-cl-dir",
                    default="/Users/nikolai/common-lisp/atari800-cl")
    args = ap.parse_args()
    json.dump(run_all(args.attic_dir, args.atari800_cl_dir), sys.stdout, indent=2)
    sys.stdout.write("\n")
