#!/usr/bin/env bash
# scripts/bench-ab.sh --- interleaved A/B benchmark against a baseline.
#
# Codifies the methodology PERFORMANCE_LOG.md's Phase 9 and Phase 12
# notes arrived at by hand: absolute fps numbers drift between sessions
# (background load, thermal state), so before/after runs taken in
# separate blocks are not comparable.  This script builds the baseline
# ref in a git worktree and ALTERNATES runs -- B A B A ... -- so drift
# hits both sides equally, then reports paired deltas and whether the
# runs separate cleanly (every A run on one side of every B run).
#
# Usage:
#   ./scripts/bench-ab.sh <baseline-ref> [-impl sbcl|lispworks|both]
#                         [-pairs N]
#
#   <baseline-ref>  commit/tag to compare against (usually the
#                   pre-phase commit).  Built once into a worktree at
#                   .cache/bench-ab/<sha>/ and reused on later runs;
#                   remove with: git worktree remove .cache/bench-ab/<sha>
#   -impl           implementation(s) to run (default: both)
#   -pairs N        number of B/A pairs per implementation (default: 3)
#
# The working tree is measured AS IS, uncommitted changes included.
# Each side compiles into its own repo-local .cache/fasls (the bench
# scripts already redirect ASDF output), so the builds never collide.
#
# Output: per implementation, a Markdown table (workload, baseline mean
# fps, working-tree mean fps, delta %, separation) ready to paste into
# PERFORMANCE_LOG.md.  Separation is CLEAN when every A run fell on one
# side of every B run -- the sign test; treat MIXED deltas as noise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "usage: $0 <baseline-ref> [-impl sbcl|lispworks|both] [-pairs N]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
BASELINE_REF="$1"; shift

IMPLS="sbcl lispworks"
PAIRS=3
while [ $# -gt 0 ]; do
  case "$1" in
    -impl)
      shift; [ $# -gt 0 ] || usage
      case "$1" in
        both)            IMPLS="sbcl lispworks" ;;
        sbcl|lispworks)  IMPLS="$1" ;;
        *) echo "error: -impl must be sbcl, lispworks, or both" >&2; exit 2 ;;
      esac ;;
    -pairs)
      shift; [ $# -gt 0 ] || usage
      case "$1" in
        ''|*[!0-9]*) echo "error: -pairs takes a positive integer" >&2; exit 2 ;;
        *) PAIRS="$1" ;;
      esac ;;
    *) usage ;;
  esac
  shift
done

SHA="$(git -C "$ROOT" rev-parse --short "$BASELINE_REF")" \
  || { echo "error: cannot resolve ref: $BASELINE_REF" >&2; exit 1; }
WT="$ROOT/.cache/bench-ab/$SHA"

# Load warning: interleaving cancels drift but a busy machine still
# widens the spread -- better to know before burning six LispWorks runs.
NCPU="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )"
LOAD1="$(uptime | sed -E 's/.*load averages?:? *//; s/,/ /g' | awk '{print $1}')"
awk -v l="$LOAD1" -v n="$NCPU" 'BEGIN {
  if (l + 0 > n / 2)
    printf "WARNING: load average %.2f on %d CPUs -- expect noisy results\n", l, n
}' >&2

# Baseline worktree: created once, keyed by sha, reused thereafter.
if [ ! -d "$WT" ]; then
  echo "bench-ab: creating baseline worktree $WT ($SHA)" >&2
  git -C "$ROOT" worktree add --detach "$WT" "$SHA" >&2
fi
for IMPL in $IMPLS; do
  if [ ! -x "$WT/scripts/bench-$IMPL.sh" ]; then
    echo "error: baseline $SHA has no executable scripts/bench-$IMPL.sh" >&2
    exit 1
  fi
done

RESULTS="$(mktemp "${TMPDIR:-/tmp}/bench-ab.XXXXXX")"
trap 'rm -f "$RESULTS"' EXIT

# One benchmark run.  BENCH lines look like
#   BENCH nop frames=600 seconds= 0.171 fps= 3500.02 realtime-x=58.412
# and ~8,2F padding can split "fps=" and the number into two tokens,
# so match against the whole line rather than a field.
run_side() { # side(A|B) dir impl pair
  local SIDE="$1" DIR="$2" IMPL="$3" PAIR="$4" LABEL
  [ "$SIDE" = A ] && LABEL="working tree" || LABEL="$SHA"
  echo "== bench-ab: $IMPL pair $PAIR/$PAIRS side $SIDE ($LABEL)" >&2
  ( cd "$DIR" && "./scripts/bench-$IMPL.sh" ) \
    | tee /dev/stderr \
    | awk -v impl="$IMPL" -v side="$SIDE" -v pair="$PAIR" '
        $1 == "BENCH" && match($0, /fps= *[0-9]+\.?[0-9]*/) {
          fps = substr($0, RSTART, RLENGTH)
          sub(/fps= */, "", fps)
          print impl, side, pair, $2, fps
        }' >> "$RESULTS"
}

for IMPL in $IMPLS; do
  PAIR=1
  while [ "$PAIR" -le "$PAIRS" ]; do
    run_side B "$WT"   "$IMPL" "$PAIR"
    run_side A "$ROOT" "$IMPL" "$PAIR"
    PAIR=$((PAIR + 1))
  done
done

echo >&2
echo "== bench-ab: summary (paste the tables into PERFORMANCE_LOG.md)" >&2

python3 - "$SHA" "$RESULTS" <<'EOF'
import sys
from collections import OrderedDict

sha, path = sys.argv[1], sys.argv[2]

# impl -> workload -> {"A": [fps...], "B": [fps...]}, insertion-ordered
runs = OrderedDict()
with open(path) as f:
    for line in f:
        impl, side, pair, workload, fps = line.split()
        impl_d = runs.setdefault(impl, OrderedDict())
        sides = impl_d.setdefault(workload, {"A": [], "B": []})
        sides[side].append(float(fps))

if not runs:
    sys.exit("bench-ab: no BENCH lines captured -- did the runs fail?")

for impl, workloads in runs.items():
    npairs = max(len(s["B"]) for s in workloads.values())
    print()
    print(f"### bench-ab: {impl} -- baseline {sha} (B) vs working tree (A), "
          f"{npairs} interleaved pairs")
    print()
    print(f"| workload | {sha} fps (B) | working tree (A) | delta | separation |")
    print("|----------|---------------|------------------|-------|------------|")
    for wl, sides in workloads.items():
        a, b = sides["A"], sides["B"]
        if not b:
            print(f"| {wl} | -- | {sum(a)/len(a):8.2f} | new workload | -- |")
            continue
        if not a:
            print(f"| {wl} | {sum(b)/len(b):8.2f} | -- | workload absent | -- |")
            continue
        mean_a, mean_b = sum(a) / len(a), sum(b) / len(b)
        delta = (mean_a - mean_b) / mean_b * 100.0
        clean = max(a) < min(b) or min(a) > max(b)
        sep = "CLEAN" if clean else "MIXED (noise)"
        print(f"| {wl} | {mean_b:8.2f} | {mean_a:8.2f} | {delta:+.1f}% | {sep} |")
    print()
    print("(means of interleaved runs; CLEAN = every A run fell on one side "
          "of every B run)")
EOF
