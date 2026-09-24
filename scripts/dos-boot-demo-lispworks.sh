#!/usr/bin/env bash
# LispWorks counterpart to
#   sbcl --script scripts/dos-boot-demo.lisp [path/to/dos25.atr]
#
# Boots DOS 2.5 over the emulated SIO serial wire and serves the menu to
# a screenshot client (Phase 25 visual verification).  Prints the same
# AESP_CONTROL / AESP_VIDEO / AESP_AUDIO and MENU status lines the SBCL
# demo prints, so the same capture command works against either:
#
#   ./scripts/dos-boot-demo-lispworks.sh &
#   ./scripts/capture-screenshot.py -p <video-port> -o dos-menu.png
#
# An ATR path given here is exported as $ATARI800_CL_DOS_ATR rather than
# passed positionally: `lw-console -build` owns the command line, so the
# demo cannot see a positional argument under LispWorks.  Without one it
# falls back to $ATARI800_CL_DOS_ATR or the roms/ defaults, exactly as
# the SBCL demo does.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LW_CONSOLE="${LW_CONSOLE:-lw-console}"

if ! command -v "$LW_CONSOLE" >/dev/null 2>&1; then
  echo "error: LispWorks console not found: $LW_CONSOLE" >&2
  echo "Set LW_CONSOLE to the LispWorks console executable if it is not on PATH." >&2
  exit 127
fi

if [ "$#" -gt 1 ]; then
  echo "usage: $(basename "$0") [path/to/dos25.atr]" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  if [ ! -f "$1" ]; then
    echo "error: ATR not found: $1" >&2
    exit 2
  fi
  ATARI800_CL_DOS_ATR="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  export ATARI800_CL_DOS_ATR
fi

exec "$LW_CONSOLE" -build "$REPO_ROOT/scripts/dos-boot-demo-lispworks.lisp"
