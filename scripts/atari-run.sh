#!/usr/bin/env bash
# atari-run.sh — Run a MADS-produced XEX inside atari800-cl, halting on BRK.
#
# Usage:   atari-run.sh path/to/program.xex
#
# Sources .env from the project root for SBCL_BIN, ATARI800_CL_DIR, ROMS_DIR,
# and MAX_STEPS.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults.
SBCL_BIN="${SBCL_BIN:-sbcl}"
ATARI800_CL_DIR="${ATARI800_CL_DIR:-$HOME/src/atari800-cl}"
ROMS_DIR="${ROMS_DIR:-}"
MAX_STEPS="${MAX_STEPS:-20000000}"

# shellcheck disable=SC1091
[[ -f "$PROJECT_DIR/.env" ]] && source "$PROJECT_DIR/.env"

# ---------------------------------------------------------------------------
# 1.  Validate arguments.
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "usage: $(basename "$0") <program.xex>" >&2
  exit 3
fi

XEX="$1"
if [[ ! -f "$XEX" ]]; then
  echo "error: XEX file not found: $XEX" >&2
  exit 3
fi
XEX="$(cd "$(dirname "$XEX")" && pwd)/$(basename "$XEX")"

# ---------------------------------------------------------------------------
# 2.  Make sure atari800-cl is reachable by ASDF.  If a local-projects symlink
#     doesn't exist, create one so `ql:quickload :atari800-cl` succeeds.
# ---------------------------------------------------------------------------
LP_DIR="$HOME/quicklisp/local-projects"
if [[ -d "$LP_DIR" && ! -e "$LP_DIR/atari800-cl" ]]; then
  if [[ -d "$ATARI800_CL_DIR" ]]; then
    ln -s "$ATARI800_CL_DIR" "$LP_DIR/atari800-cl"
    echo "info: linked $ATARI800_CL_DIR -> $LP_DIR/atari800-cl"
  else
    echo "warning: ATARI800_CL_DIR ($ATARI800_CL_DIR) does not exist" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 3.  Build optional ROM flags.
# ---------------------------------------------------------------------------
ROM_ARGS=()
if [[ -n "$ROMS_DIR" ]]; then
  [[ -f "$ROMS_DIR/atariosxl.rom" ]] && ROM_ARGS+=("--os-rom"    "$ROMS_DIR/atariosxl.rom")
  [[ -f "$ROMS_DIR/ataribas.rom"  ]] && ROM_ARGS+=("--basic-rom" "$ROMS_DIR/ataribas.rom")
fi

# ---------------------------------------------------------------------------
# 4.  Launch SBCL on the runner.  --script auto-quits on EOF, suppresses
#     the banner, disables debugger, and treats fatal errors as exit 1.
# ---------------------------------------------------------------------------
RUNNER="$PROJECT_DIR/scripts/runner.lisp"

exec "$SBCL_BIN" --script "$RUNNER" \
  "$XEX" \
  --max-steps "$MAX_STEPS" \
  "${ROM_ARGS[@]}"
