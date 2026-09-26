#!/usr/bin/env bash
# Unified entry point for the DOS 2.5 boot demo: dispatches to
# demos/dos-boot-demo.lisp (SBCL, --impl sbcl, the default) or its
# LispWorks counterpart demos/dos-boot-demo-lispworks.lisp (--impl
# lispworks).  Both boot DOS 2.5 over the emulated SIO serial wire and
# serve the menu to a screenshot client:
#
#   ./demos/dos-boot-demo.sh [--impl sbcl|lispworks] [path/to/dos25.atr]
#   ./scripts/capture-screenshot.py -p <video-port> -o dos-menu.png
#
# ATR falls back to $ATARI800_CL_DOS_ATR, then the roms/ defaults, if
# omitted here.  Under --impl lispworks, `lw-console -build` owns the
# command line, so the path is passed through $ATARI800_CL_DOS_ATR
# instead of positionally -- the demo already checks that env var as a
# fallback, so this is transparent to the caller.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMPL="sbcl"

usage() {
  echo "usage: $(basename "$0") [--impl sbcl|lispworks] [path/to/dos25.atr]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --impl)
      [ "$#" -ge 2 ] || usage
      IMPL="$2"
      shift 2
      ;;
    --impl=*)
      IMPL="${1#--impl=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -le 1 ] || usage
ATR="${1:-}"

case "$IMPL" in
  sbcl)
    if [ -n "$ATR" ]; then
      exec sbcl --script "$REPO_ROOT/demos/dos-boot-demo.lisp" "$ATR"
    else
      exec sbcl --script "$REPO_ROOT/demos/dos-boot-demo.lisp"
    fi
    ;;
  lispworks)
    LW_CONSOLE="${LW_CONSOLE:-lw-console}"
    if ! command -v "$LW_CONSOLE" >/dev/null 2>&1; then
      echo "error: LispWorks console not found: $LW_CONSOLE" >&2
      echo "Set LW_CONSOLE to the LispWorks console executable if it is not on PATH." >&2
      exit 127
    fi
    if [ -n "$ATR" ]; then
      if [ ! -f "$ATR" ]; then
        echo "error: ATR not found: $ATR" >&2
        exit 2
      fi
      ATARI800_CL_DOS_ATR="$(cd "$(dirname "$ATR")" && pwd)/$(basename "$ATR")"
      export ATARI800_CL_DOS_ATR
    fi
    exec "$LW_CONSOLE" -build "$REPO_ROOT/demos/dos-boot-demo-lispworks.lisp"
    ;;
  *)
    echo "error: unknown --impl '$IMPL' (expected sbcl or lispworks)" >&2
    exit 2
    ;;
esac
