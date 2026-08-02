#!/usr/bin/env bash
# scripts/bench-sbcl.sh --- SBCL frame-rate benchmark runner.
#
# Mirrors scripts/test-sbcl.sh (same sandbox/ASDF/source-registry
# handling) but loads :atari800-cl and runs scripts/bench.lisp instead
# of the test suite.  Exit 0 on completion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/.cache/fasls"
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
BENCH_LISP="$ROOT/scripts/bench.lisp"

sbcl --noinform --no-userinit --non-interactive \
  --eval "(require :asdf)" \
  --eval "(asdf:initialize-output-translations '(:output-translations (t (#P\"$CACHE_PATH\" :implementation)) :ignore-inherited-configuration))" \
  --eval "(asdf:initialize-source-registry '(:source-registry (:tree #P\"$ROOT_PATH\") (:tree #P\"$QL_PATH\") :ignore-inherited-configuration))" \
  --eval "(asdf:load-system :atari800-cl)" \
  --eval "(load \"$BENCH_LISP\")" \
  --eval "(atari800-cl.bench:run-benchmarks)"
