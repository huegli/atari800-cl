"""Run a case suite against one or more implementations.

The runner sequences:
  load cases -> validate -> connect channels -> send request ->
  read response(s) -> normalize -> match expectation -> classify ->
  write evidence.

It is the only module that owns sockets at execution time. Codecs and
normalizers are pure; this file glues them to live processes.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import time
from contextlib import suppress
from typing import Optional

import aesp_codec
import cli_codec
import normalizers
from expectations import classify, match_aesp, match_cli, validate_case
from protocol_spec import AESP_MESSAGES

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Case loaders.

def load_case_file(path: str) -> list[dict]:
    """Load cases from a JSON file (a top-level list of case objects).

    YAML is supported if PyYAML happens to be installed, but we keep
    JSON as the default so the harness has zero non-stdlib deps.
    """
    with open(path) as f:
        text = f.read()
    if path.endswith((".yaml", ".yml")):
        try:
            import yaml  # type: ignore
            data = yaml.safe_load(text)
        except ImportError:
            raise RuntimeError(
                f"YAML case file but PyYAML not installed: {path}")
    else:
        data = json.loads(text)
    if not isinstance(data, list):
        raise ValueError(f"case file must be a list, got {type(data).__name__}: {path}")
    return data


def load_cases(case_dir: str) -> list[dict]:
    """Walk CASE_DIR, return all cases concatenated."""
    cases: list[dict] = []
    for name in sorted(os.listdir(case_dir)):
        path = os.path.join(case_dir, name)
        if os.path.isfile(path) and name.endswith((".json", ".yaml", ".yml")):
            cases.extend(load_case_file(path))
    return cases


# ---------------------------------------------------------------------------
# Per-case execution.

def _aesp_channel_socket(adapter, channel: str) -> socket.socket:
    if channel == "control":
        return adapter.connect_aesp_control()
    if channel == "video":
        return adapter.connect_aesp_video()
    if channel == "audio":
        return adapter.connect_aesp_audio()
    raise ValueError(f"unknown AESP channel: {channel}")


def _encode_aesp_request(request: dict) -> bytes:
    """Encode a request-block (either {type, payload_hex} or {raw_hex}) to bytes."""
    if "type" in request:
        name = request["type"]
        if name not in AESP_MESSAGES:
            raise ValueError(f"unknown AESP type {name!r}")
        payload = bytes.fromhex(request.get("payload_hex", "") or "")
        return aesp_codec.encode_message(AESP_MESSAGES[name], payload)
    if "raw_hex" in request:
        return bytes.fromhex(request["raw_hex"])
    raise ValueError("AESP request needs 'type' or 'raw_hex'")


def _execute_aesp(adapter, case: dict, timeout: float, raw_dir: str, impl_name: str) -> dict:
    """Run an AESP case (single or multi-step) against ADAPTER."""
    channel = case.get("channel", "control")
    case_timeout = case.get("timeout", timeout)
    case_id = case["id"]
    raw_req_path = os.path.join(raw_dir, f"{case_id}.{impl_name}.request.bin")
    raw_resp_path = os.path.join(raw_dir, f"{case_id}.{impl_name}.response.bin")

    if "steps" in case:
        steps = [(s["request"], s.get("expectation", {})) for s in case["steps"]]
        final_expectation = case.get("expectation", {})
    else:
        steps = [(case["request"], case["expectation"])]
        final_expectation = case["expectation"]

    try:
        request_bytes_list = [_encode_aesp_request(req) for req, _ in steps]
    except ValueError as e:
        return {"pass": False, "reason": str(e),
                "normalized": normalizers.normalize_timeout(0.0)}

    sock = _aesp_channel_socket(adapter, channel)
    raw_req_log = bytearray()
    raw_resp_log = bytearray()
    last_normalized: Optional[dict] = None
    step_results: list[dict] = []
    try:
        for (req, expectation), request_bytes in zip(steps, request_bytes_list):
            raw_req_log.extend(request_bytes)
            sock.sendall(request_bytes)
            try:
                # When a step expects no response, don't block on a read.
                wants_no_response = (
                    (expectation.get("response", {}) or {}).get("no_response")
                    or (expectation.get("response", {}) or {}).get("accept_no_response")
                )
                step_timeout = 1.0 if wants_no_response else case_timeout
                msg_type, payload, raw = aesp_codec.read_message(
                    sock, timeout=step_timeout)
                normalized = normalizers.normalize_aesp(msg_type, payload, raw)
                raw_resp_log.extend(raw)
            except ConnectionError:
                normalized = normalizers.normalize_disconnect()
            except aesp_codec.AESPProtocolError as e:
                normalized = normalizers.normalize_timeout(case_timeout)
                normalized["semantic_fields"]["protocol_error"] = str(e)
            except (socket.timeout, TimeoutError):
                normalized = normalizers.normalize_timeout(case_timeout)
            if expectation:
                ok, reason = match_aesp(normalized, expectation)
            else:
                ok, reason = True, "no per-step expectation"
            step_results.append({"request": req, "pass": ok, "reason": reason,
                                 "normalized": normalized})
            last_normalized = normalized
            if not ok and not case.get("continue_on_step_failure"):
                break
    finally:
        with suppress(OSError):
            sock.close()
        with open(raw_req_path, "wb") as f:
            f.write(bytes(raw_req_log))
        with open(raw_resp_path, "wb") as f:
            f.write(bytes(raw_resp_log))

    all_steps_pass = all(s["pass"] for s in step_results)
    if all_steps_pass and final_expectation:
        ok, reason = match_aesp(last_normalized or {}, final_expectation)
    else:
        if not step_results:
            ok, reason = False, "no steps"
        else:
            ok = all_steps_pass
            reason = "; ".join(f"step {i}: {s['reason']}"
                                for i, s in enumerate(step_results) if not s["pass"]) \
                     or "ok"

    return {"pass": ok, "reason": reason,
            "normalized": last_normalized or normalizers.normalize_timeout(0.0),
            "steps": step_results}


def _verb_of(line: str) -> Optional[str]:
    """Extract the verb from a CLI request line (drops a CMD: prefix)."""
    s = line.lstrip()
    if s.upper().startswith("CMD:"):
        s = s[4:]
    tokens = s.split()
    return tokens[0].lower() if tokens else None


def _do_one_cli_request(sock: socket.socket, line: str,
                        timeout: float) -> tuple[dict, str]:
    """Send one CLI line on SOCK, normalize the reply, return (normalized, raw)."""
    verb = _verb_of(line)
    request_bytes = cli_codec.encode_request(line.rstrip("\n"))
    sock.sendall(request_bytes)
    try:
        status, data, raw = cli_codec.read_reply(sock, timeout=timeout)
        return normalizers.normalize_cli(verb, status, data, raw), raw
    except ConnectionError:
        return normalizers.normalize_cli_disconnect(), ""
    except cli_codec.CLIProtocolError as e:
        n = normalizers.normalize_cli_timeout(timeout)
        n["semantic_fields"]["protocol_error"] = str(e)
        return n, ""
    except (socket.timeout, TimeoutError):
        return normalizers.normalize_cli_timeout(timeout), ""


_UNSUPPORTED_HINTS = ("not implemented", "unknown command", "unimplemented",
                      "not supported", "no such command")


def _is_unsupported_cli(normalized: dict) -> bool:
    """True if the impl signaled a feature gap via CLI ERR text.

    Recognises both atari800-cl's two flavors (`ERR:Not implemented` for
    deferred verbs, `ERR:unknown command "X"` for truly unknown verbs)
    and the most common Attic-side phrasings.
    """
    if normalized.get("status") != "ERR":
        return False
    data = normalized.get("data", "").lower()
    return any(h in data for h in _UNSUPPORTED_HINTS)


def _execute_cli(adapter, case: dict, timeout: float, raw_dir: str, impl_name: str) -> dict:
    """Run a single CLI case (single request or multi-step) against ADAPTER."""
    case_timeout = case.get("timeout", timeout)
    case_id = case["id"]
    raw_req_path = os.path.join(raw_dir, f"{case_id}.{impl_name}.request.txt")
    raw_resp_path = os.path.join(raw_dir, f"{case_id}.{impl_name}.response.txt")

    # Resolve to a list of (line, expectation) steps.
    if "steps" in case:
        steps = [(s["request"]["line"], s.get("expectation", {})) for s in case["steps"]]
        final_expectation = case.get("expectation", {})
    else:
        steps = [(case["request"]["line"], case["expectation"])]
        final_expectation = case["expectation"]

    sock = adapter.connect_cli()
    raw_req_log = bytearray()
    raw_resp_log = bytearray()
    last_normalized: Optional[dict] = None
    step_results: list[dict] = []
    try:
        for line, expectation in steps:
            raw_req_log.extend(cli_codec.encode_request(line.rstrip("\n")))
            normalized, raw = _do_one_cli_request(sock, line, case_timeout)
            raw_resp_log.extend((raw + "\n").encode("utf-8"))
            if expectation:
                ok, reason = match_cli(normalized, expectation)
            else:
                ok, reason = True, "no per-step expectation"
            step_results.append({"line": line, "pass": ok, "reason": reason,
                                 "normalized": normalized})
            last_normalized = normalized
            if not ok and not case.get("continue_on_step_failure"):
                break
    finally:
        with suppress(OSError):
            sock.close()
        with open(raw_req_path, "wb") as f:
            f.write(bytes(raw_req_log))
        with open(raw_resp_path, "wb") as f:
            f.write(bytes(raw_resp_log))

    # Final pass-bit: every step passed AND the final-expectation matches the
    # last normalized reply.
    all_steps_pass = all(s["pass"] for s in step_results)
    if all_steps_pass and final_expectation:
        ok, reason = match_cli(last_normalized or {}, final_expectation)
    else:
        if not step_results:
            ok, reason = False, "no steps"
        else:
            failures = [s for s in step_results if not s["pass"]]
            ok = all_steps_pass
            reason = "; ".join(f"step {i}: {s['reason']}"
                                for i, s in enumerate(step_results) if not s["pass"]) \
                     or "ok"

    result = {"pass": ok, "reason": reason,
              "normalized": last_normalized or normalizers.normalize_cli_timeout(0.0),
              "steps": step_results}
    if last_normalized and _is_unsupported_cli(last_normalized):
        result["unsupported"] = True
    return result


def execute_case(case: dict, adapters: dict, *, timeout: float, raw_dir: str) -> dict:
    """Run CASE against every adapter; return a result record."""
    errs = validate_case(case)
    if errs:
        return {
            "id": case.get("id", "<unknown>"),
            "protocol": case.get("protocol"),
            "classification": "harness_error",
            "reason": "; ".join(errs),
            "per_impl": {},
            "expectation_required": case.get("expectation", {}).get("required", {}),
        }

    per_impl: dict[str, dict] = {}
    for impl, adapter in adapters.items():
        if adapter is None:
            continue
        try:
            if case["protocol"] == "aesp":
                result = _execute_aesp(adapter, case, timeout, raw_dir, impl)
            elif case["protocol"] == "cli":
                result = _execute_cli(adapter, case, timeout, raw_dir, impl)
            else:
                result = {"pass": False, "reason": f"unknown protocol {case['protocol']!r}",
                          "normalized": {}}
        except Exception as e:  # noqa: BLE001
            log.exception("case %s failed against %s", case["id"], impl)
            result = {"pass": False, "reason": f"harness exception: {e}", "normalized": {}}
        # Mark unsupported when expectation matched as deferred and impl confirmed.
        result["supported"] = True
        per_impl[impl] = result

    classification = classify(case, per_impl)
    reason = "; ".join(
        f"{impl}: {r['reason']}" for impl, r in per_impl.items() if not r["pass"]
    ) or "all required pass"
    return {
        "id": case["id"],
        "protocol": case.get("protocol"),
        "classification": classification,
        "reason": reason,
        "per_impl": per_impl,
        "expectation_required": case.get("expectation", {}).get("required", {}),
    }
