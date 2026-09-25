#!/usr/bin/env bash
# Unified entry point for the EdVenture demo: dispatches to
# scripts/edventure-demo.lisp (SBCL, --impl sbcl, the default) or its
# LispWorks counterpart scripts/edventure-demo-lispworks.lisp
# (--impl lispworks).  Both boot the same EdVenture branch over the
# emulated SIO serial wire and serve the result to a screenshot client:
#
#   ./scripts/edventure-demo.sh [--impl sbcl|lispworks] [branch] &
#   ./scripts/capture-screenshot.py -p <video-port> -o edventure.png
#
# BRANCH defaults to episode_29_work inside the demo itself (see its
# header) if omitted here.  Under --impl lispworks, `lw-console -build`
# owns the command line, so BRANCH is passed through
# $ATARI800_CL_EDVENTURE_BRANCH instead of positionally -- the demo
# already checks that env var as a fallback, so this is transparent to
# the caller.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMPL="sbcl"

usage() {
  echo "usage: $(basename "$0") [--impl sbcl|lispworks] [branch]" >&2
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
BRANCH="${1:-}"

case "$IMPL" in
  sbcl)
    if [ -n "$BRANCH" ]; then
      exec sbcl --script "$REPO_ROOT/scripts/edventure-demo.lisp" "$BRANCH"
    else
      exec sbcl --script "$REPO_ROOT/scripts/edventure-demo.lisp"
    fi
    ;;
  lispworks)
    LW_CONSOLE="${LW_CONSOLE:-lw-console}"
    if ! command -v "$LW_CONSOLE" >/dev/null 2>&1; then
      echo "error: LispWorks console not found: $LW_CONSOLE" >&2
      echo "Set LW_CONSOLE to the LispWorks console executable if it is not on PATH." >&2
      exit 127
    fi
    if [ -n "$BRANCH" ]; then
      export ATARI800_CL_EDVENTURE_BRANCH="$BRANCH"
    fi
    exec "$LW_CONSOLE" -build "$REPO_ROOT/scripts/edventure-demo-lispworks.lisp"
    ;;
  *)
    echo "error: unknown --impl '$IMPL' (expected sbcl or lispworks)" >&2
    exit 2
    ;;
esac
