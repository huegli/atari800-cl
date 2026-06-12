"""Write per-run reports: summary.json, summary.md, cases.jsonl, ...

Reports are written into a single timestamped directory chosen by the
runner. Everything here is text/JSON; no live state.
"""

from __future__ import annotations

import json
import os
import subprocess
from collections import Counter
from typing import Iterable


def _safe_run(args: list[str], cwd: str | None = None) -> str:
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=10, cwd=cwd)
        return (out.stdout or out.stderr).strip()
    except Exception as e:  # noqa: BLE001
        return f"(unavailable: {e})"


def collect_env(attic_dir: str, atari_dir: str) -> dict:
    """Snapshot the environment for inclusion in summary.json."""
    return {
        "os": _safe_run(["uname", "-srm"]),
        "python": _safe_run(["python3", "--version"]),
        "swift": _safe_run(["swift", "--version"]).splitlines()[:1],
        "sbcl": _safe_run(["sbcl", "--version"]),
        "lispworks": _safe_run(["lw-console", "-version"]),
        "attic_commit": _safe_run(["git", "rev-parse", "HEAD"], cwd=attic_dir),
        "attic_branch": _safe_run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=attic_dir),
        "atari800_cl_commit": _safe_run(["git", "rev-parse", "HEAD"], cwd=atari_dir),
        "atari800_cl_branch": _safe_run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=atari_dir),
    }


def write_summary_json(path: str, *,
                       env: dict,
                       probes: dict,
                       cases: list[dict],
                       launch_commands: dict,
                       attic_dir: str,
                       atari_dir: str) -> None:
    counts = Counter(c["classification"] for c in cases)
    summary = {
        "environment": env,
        "probes": probes,
        "launch_commands": launch_commands,
        "paths": {
            "attic_dir": attic_dir,
            "atari800_cl_dir": atari_dir,
        },
        "counts": dict(counts),
        "case_count": len(cases),
    }
    with open(path, "w") as f:
        json.dump(summary, f, indent=2)


def write_cases_jsonl(path: str, cases: Iterable[dict]) -> None:
    with open(path, "w") as f:
        for case in cases:
            json.dump(case, f)
            f.write("\n")


def write_summary_md(path: str, *,
                     env: dict,
                     probes: dict,
                     cases: list[dict],
                     launch_commands: dict,
                     attic_dir: str,
                     atari_dir: str) -> None:
    counts = Counter(c["classification"] for c in cases)
    lines = [
        "# Protocol comparison summary",
        "",
        "## Environment",
        f"- OS: `{env['os']}`",
        f"- Python: `{env['python']}`",
        f"- Swift: `{env['swift']}`",
        f"- SBCL: `{env['sbcl']}`",
        f"- LispWorks: `{env['lispworks']}`",
        "",
        "## Repos",
        f"- atari800-cl @ {env['atari800_cl_commit']} ({env['atari800_cl_branch']}) — `{atari_dir}`",
        f"- attic @ {env['attic_commit']} ({env['attic_branch']}) — `{attic_dir}`",
        "",
        "## Launch commands",
    ]
    for impl, cmd in launch_commands.items():
        lines.append(f"- `{impl}`: `{cmd}`")
    lines += ["", "## Probes"]
    for name, result in probes.items():
        if name == "summary" or not isinstance(result, dict):
            continue
        if "available" not in result:
            continue
        ok = "OK" if result["available"] else "UNAVAILABLE"
        detail = result.get("detail", "")
        lines.append(f"- `{name}`: {ok} — {detail}")
    summary = probes.get("summary") or {}
    if summary:
        lines += ["", "### Capability summary"]
        for k, v in summary.items():
            lines.append(f"- `{k}`: {v}")
    lines += ["", "## Case counts"]
    for cls, n in counts.most_common():
        lines.append(f"- `{cls}`: {n}")
    lines += ["", "## Per-case results"]
    lines += ["", "| Case | Classification | Reason |", "| --- | --- | --- |"]
    for case in cases:
        reason = case.get("reason", "")
        # Markdown table: replace pipes in reason text.
        reason = reason.replace("|", "\\|")
        lines.append(f"| {case['id']} | {case['classification']} | {reason} |")
    lines.append("")
    with open(path, "w") as f:
        f.write("\n".join(lines))


def write_failures_md(path: str, cases: list[dict]) -> None:
    """Detailed per-failure dump (failure-class cases only)."""
    fail_classes = {"atari800_cl_failure", "attic_failure", "both_failure"}
    fails = [c for c in cases if c["classification"] in fail_classes]
    lines = ["# Failed cases", ""]
    if not fails:
        lines.append("_None — all required cases passed or were accepted-difference._")
    for case in fails:
        lines += [
            f"## {case['id']} — {case['classification']}",
            f"- Reason: {case.get('reason', '')}",
            "",
            "### Per-implementation results",
        ]
        for impl, result in case.get("per_impl", {}).items():
            lines += [
                f"- **{impl}**: pass={result.get('pass')} — {result.get('reason', '')}",
                f"  - normalized: `{json.dumps(result.get('normalized', {}), default=str)}`",
            ]
        lines.append("")
    with open(path, "w") as f:
        f.write("\n".join(lines))


def write_feature_matrix(path: str, cases: list[dict]) -> None:
    """Per-case implementation support matrix."""
    lines = [
        "# Feature matrix",
        "",
        "| Case | Protocol | Attic expected | Attic observed | atari800-cl expected | atari800-cl observed | Classification |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for case in cases:
        req = case.get("expectation_required", {})
        per = case.get("per_impl", {})
        def cell(impl):
            r = per.get(impl)
            if not r:
                return "n/a"
            return "pass" if r.get("pass") else r.get("reason", "fail")
        lines.append(
            f"| {case['id']} | {case.get('protocol', '?')} "
            f"| {'required' if req.get('attic', True) else 'optional'} | {cell('attic')} "
            f"| {'required' if req.get('atari800-cl', True) else 'optional'} | {cell('atari800-cl')} "
            f"| {case['classification']} |"
        )
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def ensure_run_dir(reports_root: str, timestamp: str) -> str:
    run_dir = os.path.join(reports_root, timestamp)
    os.makedirs(os.path.join(run_dir, "raw"), exist_ok=True)
    os.makedirs(os.path.join(run_dir, "logs"), exist_ok=True)
    return run_dir
