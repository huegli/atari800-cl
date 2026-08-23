#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ROADMAP.md Phase 26 / src/compat.lisp FAST-AREF: SBCL is always fully
# checked (ATARI800_CL_CHECKED_AREF only changes LispWorks's expansion), so
# this separate cache directory is for symmetry with test-lispworks.lisp
# rather than a behavioral necessity here.
if [ -n "${ATARI800_CL_CHECKED_AREF:-}" ]; then
  CACHE="$ROOT/.cache/fasls-checked"
else
  CACHE="$ROOT/.cache/fasls"
fi
QL_SOFTWARE="${QUICKLISP_SOFTWARE:-$HOME/quicklisp/dists/quicklisp/software}"

if ! command -v sbcl >/dev/null 2>&1; then
  echo "error: sbcl not found on PATH" >&2
  exit 127
fi

if [ ! -d "$QL_SOFTWARE" ]; then
  echo "error: Quicklisp software tree not found: $QL_SOFTWARE" >&2
  echo "Set QUICKLISP_SOFTWARE to the directory containing installed .asd dependencies." >&2
  exit 2
fi

mkdir -p "$CACHE"

ROOT_PATH="$ROOT/"
QL_PATH="$QL_SOFTWARE/"
CACHE_PATH="$CACHE/"

sbcl --noinform --no-userinit --non-interactive \
  --eval "(require :asdf)" \
  --eval "(asdf:initialize-output-translations '(:output-translations (t (#P\"$CACHE_PATH\" :implementation)) :ignore-inherited-configuration))" \
  --eval "(asdf:initialize-source-registry '(:source-registry (:tree #P\"$ROOT_PATH\") (:tree #P\"$QL_PATH\") :ignore-inherited-configuration))" \
  --eval "(asdf:load-system :atari800-cl/tests)" \
  --eval "(uiop:quit (if (uiop:symbol-call :atari800-cl/tests :run-tests) 0 1))"
