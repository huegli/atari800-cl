#!/usr/bin/env python3
"""Top-level CLI for the protocol comparison harness.

Three execution modes:
  --self-test       run unit-test-equivalent self checks on codecs/spec
  --probe           run environment capability probes, print JSON
  (default)         run cases against one or both implementations

Exit codes:
  0  all required cases passed (or accepted_difference)
  1  at least one required case failed
  2  harness/configuration error
  3  live testing not possible in this environment
"""

from __future__ import annotations

import argparse
import datetime
import json
import logging
import os
import sys
from contextlib import suppress

# Make sibling modules importable when invoked directly.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import aesp_codec  # noqa: E402
import cli_codec   # noqa: E402
import probes      # noqa: E402
import reporters   # noqa: E402
import runner      # noqa: E402
from adapters import AtticAdapter, Atari800CLAdapter  # noqa: E402


DEFAULT_ATTIC_DIR = "/Users/nikolai/Source/Repos/GitHub/huegli/attic"
DEFAULT_ATARI_DIR = "/Users/nikolai/common-lisp/atari800-cl"


def _build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="compare-protocols",
        description="Compare atari800-cl and Attic against the frozen AESP/CLI specs.")
    p.add_argument("--self-test", action="store_true",
                   help="Run codec/spec self-tests and exit.")
    p.add_argument("--probe", action="store_true",
                   help="Run environment capability probes and exit.")
    p.add_argument("--attic-dir", default=DEFAULT_ATTIC_DIR)
    p.add_argument("--atari800-cl-dir", default=DEFAULT_ATARI_DIR)
    p.add_argument("--implementations", default="attic,atari800-cl",
                   help="Comma-separated subset of: attic, atari800-cl.")
    p.add_argument("--protocols", default="aesp,cli",
                   help="Comma-separated subset of: aesp, cli.")
    p.add_argument("--cases", default="all",
                   help="`all` or comma-separated case IDs.")
    p.add_argument("--case-file", action="append", default=[],
                   help="Extra case file path (repeatable).")
    p.add_argument("--case-dir",
                   help="Directory of case files (default: cases/ next to this script).")
    p.add_argument("--mode", default="live",
                   choices=["live", "adapter-only", "dry-run"])
    p.add_argument("--atari-lisp", default="sbcl", choices=["sbcl", "lispworks"])
    p.add_argument("--report-dir",
                   help="Where to put the timestamped run directory.")
    p.add_argument("--timeout", type=float, default=10.0,
                   help="Per-case response timeout, seconds.")
    p.add_argument("--keep-servers-on-failure", action="store_true")
    p.add_argument("--no-build-attic", action="store_true",
                   help="Skip `swift build` before `swift run` (faster reruns).")
    p.add_argument("--verbose", "-v", action="store_true")
    return p


def _self_test() -> int:
    aesp_codec._self_test()  # type: ignore[attr-defined]
    cli_codec._self_test()   # type: ignore[attr-defined]
    print("self-test: ok")
    return 0


def _do_probe(args) -> int:
    result = probes.run_all(args.attic_dir, args.atari800_cl_dir)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def _filter_cases(all_cases: list[dict], cases_arg: str, protocols: set[str]) -> list[dict]:
    cases = [c for c in all_cases if c.get("protocol") in protocols]
    if cases_arg != "all":
        wanted = {x.strip() for x in cases_arg.split(",") if x.strip()}
        cases = [c for c in cases if c.get("id") in wanted]
    return cases


def _now_stamp() -> str:
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def _start_adapter(name: str, args, log_dir: str):
    """Return an adapter or raise."""
    if name == "attic":
        return AtticAdapter(
            args.attic_dir, log_dir=log_dir,
            build_first=not args.no_build_attic,
        )
    if name == "atari800-cl":
        return Atari800CLAdapter(
            args.atari800_cl_dir, log_dir=log_dir, lisp=args.atari_lisp,
        )
    raise ValueError(f"unknown implementation: {name}")


def _run_live(args) -> int:
    case_dir = args.case_dir or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "cases")
    all_cases = runner.load_cases(case_dir)
    for cf in args.case_file:
        all_cases.extend(runner.load_case_file(cf))
    protocols = {p.strip() for p in args.protocols.split(",") if p.strip()}
    cases = _filter_cases(all_cases, args.cases, protocols)
    if not cases:
        print("no cases selected; nothing to do", file=sys.stderr)
        return 2

    impls = [x.strip() for x in args.implementations.split(",") if x.strip()]
    if not impls:
        print("no implementations selected", file=sys.stderr)
        return 2

    reports_root = args.report_dir or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "reports")
    run_dir = reporters.ensure_run_dir(reports_root, _now_stamp())
    raw_dir = os.path.join(run_dir, "raw")
    logs_dir = os.path.join(run_dir, "logs")

    adapters: dict[str, object | None] = {name: None for name in impls}
    launch_commands: dict[str, str] = {}
    started: list[str] = []
    try:
        # Probes first — abort if live mode requested but not possible.
        probe_result = probes.run_all(args.attic_dir, args.atari800_cl_dir)
        if not probe_result["summary"]["live_tcp"] and "attic" in impls + ["atari800-cl"]:
            print("TCP loopback unavailable; cannot run live tests", file=sys.stderr)
            json.dump(probe_result, sys.stderr, indent=2)
            return 3
        if not probe_result["summary"]["live_unix"]:
            print("WARNING: Unix-domain sockets unavailable; CLI cases will fail.",
                  file=sys.stderr)

        for name in impls:
            adapter = _start_adapter(name, args, logs_dir)
            adapter.start(timeout=180.0)
            adapters[name] = adapter
            started.append(name)
            ep = adapter.endpoints
            launch_commands[name] = (
                f"control={ep.aesp_control} video={ep.aesp_video} "
                f"audio={ep.aesp_audio} cli={ep.cli_socket}"
            )

        # Execute cases.
        results: list[dict] = []
        for case in cases:
            logging.info("running %s", case.get("id"))
            results.append(runner.execute_case(
                case, adapters, timeout=args.timeout, raw_dir=raw_dir))
    finally:
        if not (args.keep_servers_on_failure and any(
                r.get("classification") in {"atari800_cl_failure", "attic_failure",
                                            "both_failure", "harness_error"}
                for r in (results if "results" in dir() else []))):
            for name in started:
                with suppress(Exception):
                    adapters[name].stop()  # type: ignore[union-attr]

    # Reports.
    env = reporters.collect_env(args.attic_dir, args.atari800_cl_dir)
    reporters.write_summary_json(
        os.path.join(run_dir, "summary.json"),
        env=env, probes=probe_result, cases=results,
        launch_commands=launch_commands,
        attic_dir=args.attic_dir, atari_dir=args.atari800_cl_dir,
    )
    reporters.write_summary_md(
        os.path.join(run_dir, "summary.md"),
        env=env, probes=probe_result, cases=results,
        launch_commands=launch_commands,
        attic_dir=args.attic_dir, atari_dir=args.atari800_cl_dir,
    )
    reporters.write_cases_jsonl(os.path.join(run_dir, "cases.jsonl"), results)
    reporters.write_failures_md(os.path.join(run_dir, "failures.md"), results)
    reporters.write_feature_matrix(os.path.join(run_dir, "feature-matrix.md"), results)

    fail_classes = {"atari800_cl_failure", "attic_failure", "both_failure", "harness_error"}
    failed = [r for r in results if r["classification"] in fail_classes]
    print(f"report: {run_dir}")
    print(f"cases: {len(results)} run, {len(failed)} failed")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    args = _build_arg_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if args.self_test:
        return _self_test()
    if args.probe:
        return _do_probe(args)
    if args.mode == "adapter-only":
        # Run cases without launching adapters (codec/spec coverage only).
        # For now this is equivalent to self-test.
        return _self_test()
    return _run_live(args)


if __name__ == "__main__":
    sys.exit(main())
