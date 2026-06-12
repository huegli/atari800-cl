"""Server adapters: launch Attic and atari800-cl, connect transports.

Each adapter wraps a running emulator-server process and provides
uniform `connect_aesp_*` / `connect_cli` methods that return a socket
ready for the codecs in aesp_codec.py / cli_codec.py.

Adapters never assume the server is ready immediately after `Popen` —
they wait on a readiness signal (a known line on stdout, or a successful
PING on the control port) before returning to the caller.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import suppress
from dataclasses import dataclass
from typing import Optional

import aesp_codec
from protocol_spec import AESP_MESSAGES

log = logging.getLogger(__name__)


@dataclass
class Endpoints:
    """Where the running server is listening."""
    host: str
    aesp_control: int
    aesp_video: int
    aesp_audio: int
    cli_socket: Optional[str]


# ---------------------------------------------------------------------------
# Shared helpers.

def _allocate_tcp_port_triple() -> tuple[int, int, int]:
    """Find three free contiguous-ish TCP ports.

    We don't need them adjacent; Attic accepts them independently. We
    just need three ports nothing else owns. Bind/release pattern is
    standard for tests.
    """
    socks = [socket.socket(socket.AF_INET, socket.SOCK_STREAM) for _ in range(3)]
    ports: list[int] = []
    for s in socks:
        s.bind(("127.0.0.1", 0))
        ports.append(s.getsockname()[1])
    for s in socks:
        s.close()
    return ports[0], ports[1], ports[2]


def _allocate_unix_socket_path(prefix: str) -> str:
    d = tempfile.mkdtemp(prefix=f"{prefix}-")
    return os.path.join(d, "cli.sock")


def _pump_stream_to_file(stream, path: str, line_callback=None) -> threading.Thread:
    """Drain STREAM into PATH; invoke LINE_CALLBACK on each newline-terminated line."""
    def _run():
        with open(path, "wb") as f:
            for line in iter(stream.readline, b""):
                f.write(line)
                f.flush()
                if line_callback:
                    try:
                        line_callback(line.decode("utf-8", errors="replace").rstrip("\r\n"))
                    except Exception:  # noqa: BLE001
                        log.debug("log callback failed", exc_info=True)
    t = threading.Thread(target=_run, name=f"pump-{os.path.basename(path)}", daemon=True)
    t.start()
    return t


def _tcp_connect_retry(host: str, port: int, timeout: float = 10.0,
                       interval: float = 0.05) -> socket.socket:
    deadline = time.time() + timeout
    last_err: Optional[Exception] = None
    while time.time() < deadline:
        try:
            s = socket.create_connection((host, port), timeout=2.0)
            s.settimeout(None)
            return s
        except OSError as e:
            last_err = e
            time.sleep(interval)
    raise ConnectionError(f"could not connect to {host}:{port}: {last_err}")


def _unix_connect_retry(path: str, timeout: float = 10.0,
                        interval: float = 0.05) -> socket.socket:
    deadline = time.time() + timeout
    last_err: Optional[Exception] = None
    while time.time() < deadline:
        if os.path.exists(path):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(path)
                return s
            except OSError as e:
                last_err = e
        time.sleep(interval)
    raise ConnectionError(f"could not connect to unix socket {path}: {last_err}")


def _ping_aesp(host: str, port: int, timeout: float = 5.0) -> bool:
    """Use a fresh socket to PING the control port; True if PONG arrives."""
    try:
        s = _tcp_connect_retry(host, port, timeout=timeout)
    except ConnectionError:
        return False
    try:
        s.sendall(aesp_codec.encode_message(AESP_MESSAGES["PING"]))
        msg_type, _payload, _raw = aesp_codec.read_message(s, timeout=timeout)
        return msg_type == AESP_MESSAGES["PONG"]
    except (OSError, aesp_codec.AESPProtocolError, ConnectionError):
        return False
    finally:
        with suppress(OSError):
            s.close()


# ---------------------------------------------------------------------------
# Base.

class Adapter:
    name: str = "abstract"

    def __init__(self, log_dir: str):
        self.log_dir = log_dir
        os.makedirs(log_dir, exist_ok=True)
        self.proc: Optional[subprocess.Popen] = None
        self.endpoints: Optional[Endpoints] = None
        self._stdout_thread: Optional[threading.Thread] = None
        self._stderr_thread: Optional[threading.Thread] = None
        self._ready_lines: list[str] = []
        self._ready_event = threading.Event()

    # Lifecycle ----------------------------------------------------------
    def start(self, timeout: float = 60.0) -> Endpoints:
        raise NotImplementedError

    def stop(self, timeout: float = 5.0) -> None:
        if not self.proc:
            return
        if self.proc.poll() is None:
            try:
                self.proc.send_signal(signal.SIGTERM)
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                with suppress(subprocess.TimeoutExpired):
                    self.proc.wait(timeout=timeout)
        if self._stdout_thread:
            self._stdout_thread.join(timeout=1.0)
        if self._stderr_thread:
            self._stderr_thread.join(timeout=1.0)
        # Clean up Unix socket file if the server didn't.
        if self.endpoints and self.endpoints.cli_socket:
            with suppress(OSError):
                os.unlink(self.endpoints.cli_socket)
        self.proc = None

    # Connections --------------------------------------------------------
    def connect_aesp_control(self, timeout: float = 5.0) -> socket.socket:
        assert self.endpoints
        return _tcp_connect_retry(self.endpoints.host,
                                  self.endpoints.aesp_control, timeout=timeout)

    def connect_aesp_video(self, timeout: float = 5.0) -> socket.socket:
        assert self.endpoints
        return _tcp_connect_retry(self.endpoints.host,
                                  self.endpoints.aesp_video, timeout=timeout)

    def connect_aesp_audio(self, timeout: float = 5.0) -> socket.socket:
        assert self.endpoints
        return _tcp_connect_retry(self.endpoints.host,
                                  self.endpoints.aesp_audio, timeout=timeout)

    def connect_cli(self, timeout: float = 5.0) -> socket.socket:
        assert self.endpoints and self.endpoints.cli_socket
        return _unix_connect_retry(self.endpoints.cli_socket, timeout=timeout)


# ---------------------------------------------------------------------------
# Attic adapter — drives `swift run AtticServer`.

class AtticAdapter(Adapter):
    name = "attic"

    def __init__(self, attic_dir: str, log_dir: str,
                 build_first: bool = True,
                 silent: bool = True):
        super().__init__(log_dir)
        self.attic_dir = attic_dir
        self.build_first = build_first
        self.silent = silent

    def start(self, timeout: float = 180.0) -> Endpoints:
        # Attic's CLI flag parser doesn't accept port 0 → ephemeral; pick three
        # free ports ourselves up front.
        control, video, audio = _allocate_tcp_port_triple()
        cli_sock = _allocate_unix_socket_path("attic")
        # If the file exists from a prior run, remove it.
        with suppress(OSError):
            os.unlink(cli_sock)

        # `swift run AtticServer` builds-and-runs. Build separately first so the
        # printed readiness signal isn't mixed with compile noise.
        if self.build_first:
            with open(os.path.join(self.log_dir, "attic.build.log"), "wb") as f:
                r = subprocess.run(
                    ["swift", "build", "--product", "AtticServer"],
                    cwd=self.attic_dir, stdout=f, stderr=subprocess.STDOUT,
                    timeout=timeout,
                )
            if r.returncode != 0:
                raise RuntimeError(
                    f"swift build failed; see {self.log_dir}/attic.build.log")

        cmd = [
            "swift", "run", "--skip-build", "AtticServer",
            "--control-port", str(control),
            "--video-port", str(video),
            "--audio-port", str(audio),
            "--socket-path", cli_sock,
        ]
        if self.silent:
            cmd.append("--silent")

        log.info("starting Attic: %s", " ".join(cmd))
        self.proc = subprocess.Popen(
            cmd, cwd=self.attic_dir,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            preexec_fn=os.setsid if os.name == "posix" else None,
        )
        self._stdout_thread = _pump_stream_to_file(
            self.proc.stdout, os.path.join(self.log_dir, "attic.stdout.log"))
        self._stderr_thread = _pump_stream_to_file(
            self.proc.stderr, os.path.join(self.log_dir, "attic.stderr.log"))

        self.endpoints = Endpoints(
            host="127.0.0.1",
            aesp_control=control,
            aesp_video=video,
            aesp_audio=audio,
            cli_socket=cli_sock,
        )

        # Wait for the AESP control port to PONG. This is the most reliable
        # readiness check; stdout logs are noisy and reformat across versions.
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(
                    f"Attic exited early (code {self.proc.returncode}); "
                    f"see {self.log_dir}/attic.stderr.log")
            if _ping_aesp("127.0.0.1", control, timeout=1.0):
                log.info("Attic ready: control=%d video=%d audio=%d cli=%s",
                         control, video, audio, cli_sock)
                return self.endpoints
            time.sleep(0.2)
        raise TimeoutError(f"Attic AESP control port {control} did not respond in {timeout}s")

    def stop(self, timeout: float = 5.0) -> None:
        # Terminate the whole process group — `swift run` spawns a child binary.
        if self.proc and self.proc.poll() is None and os.name == "posix":
            with suppress(ProcessLookupError):
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        super().stop(timeout=timeout)


# ---------------------------------------------------------------------------
# atari800-cl adapter — drives an SBCL/LispWorks subprocess.

class Atari800CLAdapter(Adapter):
    name = "atari800-cl"

    def __init__(self, atari_dir: str, log_dir: str,
                 lisp: str = "sbcl",
                 quicklisp_software: Optional[str] = None):
        super().__init__(log_dir)
        self.atari_dir = atari_dir
        self.lisp = lisp
        self.quicklisp_software = (
            quicklisp_software
            or os.environ.get("QUICKLISP_SOFTWARE")
            or os.path.expanduser("~/quicklisp/dists/quicklisp/software")
        )

    def _sbcl_cmd(self, script: str, cache: str) -> list[str]:
        root_path = self.atari_dir.rstrip("/") + "/"
        ql_path = self.quicklisp_software.rstrip("/") + "/"
        cache_path = cache.rstrip("/") + "/"
        return [
            shutil.which("sbcl") or "sbcl",
            "--noinform", "--no-userinit", "--non-interactive",
            "--eval", "(require :asdf)",
            "--eval", (
                f"(asdf:initialize-output-translations "
                f"'(:output-translations (t (#P\"{cache_path}\" :implementation)) "
                f":ignore-inherited-configuration))"
            ),
            "--eval", (
                f"(asdf:initialize-source-registry "
                f"'(:source-registry (:tree #P\"{root_path}\") "
                f"(:tree #P\"{ql_path}\") :ignore-inherited-configuration))"
            ),
            "--load", script,
        ]

    def _lispworks_cmd(self, script: str) -> list[str]:
        return [
            shutil.which("lw-console") or "lw-console",
            "-eval",
            (
                f"(mp:initialize-multiprocessing \"a800-launcher\" () "
                f"  (lambda () "
                f"    (load \"~/quicklisp/setup.lisp\") "
                f"    (load \"{script}\")))"
            ),
        ]

    def start(self, timeout: float = 120.0) -> Endpoints:
        if not os.path.isdir(self.quicklisp_software):
            raise FileNotFoundError(
                f"Quicklisp software not found: {self.quicklisp_software}")

        # Pre-allocate endpoints so we don't have to wait for a stdout line.
        control, video, audio = _allocate_tcp_port_triple()
        cli_sock = _allocate_unix_socket_path("a800")
        with suppress(OSError):
            os.unlink(cli_sock)

        script = os.path.join(
            self.atari_dir, "tools/protocol-comparison/start-atari800-cl-server.lisp")
        if not os.path.exists(script):
            raise FileNotFoundError(f"missing launcher script: {script}")

        env = dict(os.environ)
        env["A800_CONTROL_PORT"] = str(control)
        env["A800_VIDEO_PORT"] = str(video)
        env["A800_AUDIO_PORT"] = str(audio)
        env["A800_CLI_SOCKET"] = cli_sock
        env["A800_HOST"] = "127.0.0.1"

        cache = os.path.join(self.atari_dir, ".cache/fasls")
        os.makedirs(cache, exist_ok=True)

        if self.lisp == "sbcl":
            cmd = self._sbcl_cmd(script, cache)
        elif self.lisp == "lispworks":
            cmd = self._lispworks_cmd(script)
        else:
            raise ValueError(f"unknown lisp: {self.lisp}")

        log.info("starting atari800-cl (%s): %s", self.lisp, " ".join(cmd))
        self.proc = subprocess.Popen(
            cmd, cwd=self.atari_dir, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            preexec_fn=os.setsid if os.name == "posix" else None,
        )

        def on_stdout_line(line: str):
            if "ATARI800-CL-READY" in line:
                self._ready_lines.append(line)
                self._ready_event.set()

        self._stdout_thread = _pump_stream_to_file(
            self.proc.stdout,
            os.path.join(self.log_dir, "atari800-cl.stdout.log"),
            line_callback=on_stdout_line,
        )
        self._stderr_thread = _pump_stream_to_file(
            self.proc.stderr,
            os.path.join(self.log_dir, "atari800-cl.stderr.log"))

        self.endpoints = Endpoints(
            host="127.0.0.1",
            aesp_control=control,
            aesp_video=video,
            aesp_audio=audio,
            cli_socket=cli_sock,
        )

        if not self._ready_event.wait(timeout=timeout):
            if self.proc.poll() is not None:
                raise RuntimeError(
                    f"atari800-cl exited early (code {self.proc.returncode}); "
                    f"see {self.log_dir}/atari800-cl.stderr.log")
            raise TimeoutError(
                f"atari800-cl did not signal readiness within {timeout}s")

        # Parse the readiness JSON (the part after the prefix).
        try:
            line = self._ready_lines[-1]
            _, json_blob = line.split("ATARI800-CL-READY ", 1)
            info = json.loads(json_blob.strip())
            self.endpoints = Endpoints(
                host=info.get("host", "127.0.0.1"),
                aesp_control=int(info["aesp_control"]),
                aesp_video=int(info["aesp_video"]),
                aesp_audio=int(info["aesp_audio"]),
                cli_socket=info["cli_socket"],
            )
        except (ValueError, KeyError, IndexError, json.JSONDecodeError) as e:
            raise RuntimeError(f"could not parse readiness line: {e}")

        # Sanity-PING the control port now that we believe the server is up.
        if not _ping_aesp(self.endpoints.host, self.endpoints.aesp_control, timeout=5.0):
            raise RuntimeError("atari800-cl AESP did not PONG after readiness")
        log.info("atari800-cl ready: control=%d video=%d audio=%d cli=%s",
                 self.endpoints.aesp_control, self.endpoints.aesp_video,
                 self.endpoints.aesp_audio, self.endpoints.cli_socket)
        return self.endpoints

    def stop(self, timeout: float = 5.0) -> None:
        if self.proc and self.proc.poll() is None and os.name == "posix":
            with suppress(ProcessLookupError):
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        super().stop(timeout=timeout)
