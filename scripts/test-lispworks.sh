#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LW_CONSOLE="${LW_CONSOLE:-lw-console}"

if ! command -v "$LW_CONSOLE" >/dev/null 2>&1; then
  echo "error: LispWorks console not found: $LW_CONSOLE" >&2
  echo "Set LW_CONSOLE to the LispWorks console executable if it is not on PATH." >&2
  exit 127
fi

"$LW_CONSOLE" -build "$ROOT/scripts/test-lispworks.lisp"
