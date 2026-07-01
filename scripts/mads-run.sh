#!/usr/bin/env bash
# mads-run.sh — Build a MADS source file and, on success, run the resulting
# XEX in atari800-cl.  Bound to a separate BBEdit keystroke from mads-build.
#
# Usage:   mads-run.sh path/to/source.asm
# Exit:    propagates the runner's exit code on a clean build,
#          or the build's exit code on a build failure.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
  echo "usage: $(basename "$0") <source.asm>" >&2
  exit 3
fi

SRC="$1"
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
SRC_DIR="$(dirname "$SRC")"
SRC_STEM="$(basename "${SRC%.*}")"
XEX="$SRC_DIR/build/${SRC_STEM}.xex"

# 1.  Build.  If MADS fails, mads-build.sh already jumped BBEdit to the
#     first error — propagate the exit code and stop.
if ! "$SCRIPT_DIR/mads-build.sh" "$SRC"; then
  rc=$?
  echo "==> build failed (rc=$rc); skipping run."
  exit "$rc"
fi

# 2.  Sanity check: the XEX must exist.
if [[ ! -f "$XEX" ]]; then
  echo "error: expected output not found: $XEX" >&2
  exit 2
fi

# 3.  Run.
exec "$SCRIPT_DIR/atari-run.sh" "$XEX"
