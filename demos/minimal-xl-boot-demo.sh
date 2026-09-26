#!/usr/bin/env bash
# Unified entry point for the minimal-xl OS boot demo: dispatches to
# demos/minimal-xl-boot-demo.lisp (SBCL, --impl sbcl, the default) or its
# LispWorks counterpart demos/minimal-xl-boot-demo-lispworks.lisp
# (--impl lispworks).  Both boot the minimal-xl/ submodule's stripped-
# down XL OS -- no copyrighted ROM dump needed -- and serve its boot-
# banner screen to a screenshot client:
#
#   git submodule update --init minimal-xl   # once, if empty
#   ./demos/minimal-xl-boot-demo.sh [--impl sbcl|lispworks] [path/to/minimal_os.rom]
#   ./scripts/capture-screenshot.py -p <video-port> -o minimal-xl-banner.png
#
# The ROM path falls back to $ATARI800_CL_MINIMAL_XL_ROM, then
# minimal-xl/minimal_os.rom, if omitted here.  Under --impl lispworks,
# `lw-console -build` owns the command line, so the path is passed
# through $ATARI800_CL_MINIMAL_XL_ROM instead of positionally -- the
# demo already checks that env var as a fallback, so this is
# transparent to the caller.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMPL="sbcl"

usage() {
  echo "usage: $(basename "$0") [--impl sbcl|lispworks] [path/to/minimal_os.rom]" >&2
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
ROM="${1:-}"

case "$IMPL" in
  sbcl)
    if [ -n "$ROM" ]; then
      exec sbcl --script "$REPO_ROOT/demos/minimal-xl-boot-demo.lisp" "$ROM"
    else
      exec sbcl --script "$REPO_ROOT/demos/minimal-xl-boot-demo.lisp"
    fi
    ;;
  lispworks)
    LW_CONSOLE="${LW_CONSOLE:-lw-console}"
    if ! command -v "$LW_CONSOLE" >/dev/null 2>&1; then
      echo "error: LispWorks console not found: $LW_CONSOLE" >&2
      echo "Set LW_CONSOLE to the LispWorks console executable if it is not on PATH." >&2
      exit 127
    fi
    if [ -n "$ROM" ]; then
      if [ ! -f "$ROM" ]; then
        echo "error: ROM not found: $ROM" >&2
        exit 2
      fi
      ATARI800_CL_MINIMAL_XL_ROM="$(cd "$(dirname "$ROM")" && pwd)/$(basename "$ROM")"
      export ATARI800_CL_MINIMAL_XL_ROM
    fi
    exec "$LW_CONSOLE" -build "$REPO_ROOT/demos/minimal-xl-boot-demo-lispworks.lisp"
    ;;
  *)
    echo "error: unknown --impl '$IMPL' (expected sbcl or lispworks)" >&2
    exit 2
    ;;
esac
