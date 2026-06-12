#!/usr/bin/env bash
# Developer entry point for the protocol comparison harness.
#
# Forwards all arguments to tools/protocol-comparison/compare-protocols.py
# after verifying that Python, Swift, SBCL, and the Attic repo are present.
# Common usage:
#   scripts/compare-attic-protocols.sh --probe
#   scripts/compare-attic-protocols.sh --self-test
#   scripts/compare-attic-protocols.sh                       # run all cases
#   scripts/compare-attic-protocols.sh --implementations atari800-cl
#   scripts/compare-attic-protocols.sh --cases cli.core.ping,aesp.control.ping

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ATTIC_DIR="${ATTIC_DIR:-/Users/nikolai/Source/Repos/GitHub/huegli/attic}"
SCRIPT="$ROOT/tools/protocol-comparison/compare-protocols.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found on PATH" >&2
  exit 2
fi

# Probe-only and self-test runs don't need swift/sbcl/attic — let them through.
case " $* " in
  *" --self-test "*|*" --probe "*)
    exec python3 "$SCRIPT" --attic-dir "$ATTIC_DIR" --atari800-cl-dir "$ROOT" "$@"
    ;;
esac

if ! command -v swift >/dev/null 2>&1; then
  echo "warning: swift not found on PATH; Attic adapter will fail" >&2
fi
if ! command -v sbcl >/dev/null 2>&1; then
  echo "warning: sbcl not found on PATH; atari800-cl adapter will fail" >&2
fi
if [ ! -d "$ATTIC_DIR" ]; then
  echo "warning: Attic directory not found: $ATTIC_DIR" >&2
fi

exec python3 "$SCRIPT" --attic-dir "$ATTIC_DIR" --atari800-cl-dir "$ROOT" "$@"
