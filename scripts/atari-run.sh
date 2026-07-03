#!/usr/bin/env bash
# atari-run.sh — Run a MADS-produced XEX inside atari800-cl, halting on BRK,
# or running a fixed number of frames and capturing a screenshot.
#
# Usage:
#   atari-run.sh <program.xex> [-frame <n>] [-o <screenshot.png>]
#   atari-run.sh -frame <n> <program.xex> -o out.png
#
# Without -frame: single-steps the CPU until BRK (or the step budget) and
# prints register state.  With -frame <n>: runs <n> full NTSC frames inside
# atari800-cl, then uses scripts/capture-screenshot.py over the AESP video
# port to save a screenshot (PNG via Pillow, or PPM fallback).
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
# 1.  Parse arguments.  Positional: XEX path.  Options: -frame <n>, -o <path>.
# ---------------------------------------------------------------------------
FRAME_COUNT=""
SCREENSHOT_OUT="screenshot.png"
XEX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -frame|--frame)
      [[ $# -ge 2 ]] || { echo "error: -frame requires a value" >&2; exit 3; }
      FRAME_COUNT="$2"; shift 2 ;;
    -o|--out)
      [[ $# -ge 2 ]] || { echo "error: -o requires a value" >&2; exit 3; }
      SCREENSHOT_OUT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
usage: $(basename "$0") <program.xex> [-frame <n>] [-o <screenshot.png>]

Without -frame: run until BRK and print CPU state.
With -frame <n>: run <n> NTSC frames, then capture a screenshot via AESP.
EOF
      exit 0 ;;
    -*)
      echo "error: unknown option: $1" >&2; exit 3 ;;
    *)
      if [[ -z "$XEX" ]]; then XEX="$1"; else
        echo "error: extra positional argument: $1" >&2; exit 3
      fi
      shift ;;
  esac
done

if [[ -z "$XEX" ]]; then
  echo "usage: $(basename "$0") <program.xex> [-frame <n>] [-o <screenshot.png>]" >&2
  exit 3
fi
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
# 4.  Launch SBCL on the runner.
# ---------------------------------------------------------------------------
RUNNER="$PROJECT_DIR/scripts/runner.lisp"
CAPTURE="$PROJECT_DIR/scripts/capture-screenshot.py"

if [[ -z "$FRAME_COUNT" ]]; then
  # Default: step until BRK / budget.  --script auto-quits on EOF.
  exec "$SBCL_BIN" --script "$RUNNER" \
    "$XEX" \
    --max-steps "$MAX_STEPS" \
    "${ROM_ARGS[@]}"
fi

if ! [[ "$FRAME_COUNT" =~ ^[0-9]+$ ]] || [[ "$FRAME_COUNT" -lt 1 ]]; then
  echo "error: -frame must be a positive integer, got: $FRAME_COUNT" >&2
  exit 3
fi

# --frames mode: launch the runner in the background, wait for it to print
# the bound AESP ports and READY, then capture a screenshot and tear down.
RUNNER_LOG="$(mktemp -t atari-run.XXXXXX)"

cleanup() {
  if kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  rm -f "$RUNNER_LOG"
}
trap cleanup EXIT

"$SBCL_BIN" --script "$RUNNER" \
  "$XEX" \
  --max-steps "$MAX_STEPS" \
  --frames "$FRAME_COUNT" \
  "${ROM_ARGS[@]}" >"$RUNNER_LOG" 2>&1 &
RUNNER_PID=$!

# Wait for the runner to bind the video port and reach READY.
VIDEO_PORT=""
DEADLINE=$(( $(date +%s) + 60 ))
while true; do
  if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
    echo "error: runner exited before becoming ready. log:" >&2
    cat "$RUNNER_LOG" >&2
    exit 1
  fi
  if [[ -z "$VIDEO_PORT" ]]; then
    VIDEO_PORT="$(grep -m1 '^AESP_VIDEO ' "$RUNNER_LOG" 2>/dev/null | awk '{print $2}' || true)"
  fi
  if [[ -n "$VIDEO_PORT" ]] && grep -q '^READY ' "$RUNNER_LOG" 2>/dev/null; then
    break
  fi
  if [[ $(date +%s) -ge $DEADLINE ]]; then
    echo "error: timed out waiting for runner to become ready. log:" >&2
    cat "$RUNNER_LOG" >&2
    cleanup
    exit 1
  fi
  sleep 0.2
done

echo "runner ready (video port $VIDEO_PORT) after $FRAME_COUNT frames; capturing screenshot..."

python3 "$CAPTURE" \
  -p "$VIDEO_PORT" \
  --no-control \
  -o "$SCREENSHOT_OUT"

echo "screenshot: $SCREENSHOT_OUT"
cleanup
