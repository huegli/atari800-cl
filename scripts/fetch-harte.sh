#!/usr/bin/env bash
# Fetches the Tom Harte / SingleStepTests 6502 vectors that
# tests/test-harte.lisp uses, into a gitignored directory -- so getting
# the harness's data is one command instead of a README paragraph
# (ROADMAP.md Phase 14).
#
# Source: the SingleStepTests/65x02 GitHub repository, directory
# 6502/v1/ (one <hex>.json file per opcode, main branch). That directory
# alone is ~1 GB, and its git HISTORY is bigger still, so this fetches
# each file directly over HTTPS (raw.githubusercontent.com) rather than
# `git clone`ing the repository -- no .git overhead, and it degrades
# gracefully to a partial set if interrupted (tests/test-harte.lisp
# already tests whichever <hex>.json files it finds).
#
# Usage:
#   ./scripts/fetch-harte.sh                 # all 256 opcode files (~1 GB)
#   ./scripts/fetch-harte.sh --subset        # curated 8-file gate (~30 MB)
#   ./scripts/fetch-harte.sh --subset 4      # first 4 of the curated list
#   ./scripts/fetch-harte.sh --dir PATH      # fetch into PATH instead of
#                                             #   the default below
#
# Prefer --subset for a pre-commit sanity check; the full fetch is for
# a session that intends to run ATARI800_CL_STRICT=1 or otherwise wants
# the whole ratchet. Files already present (nonzero size) are left
# alone, so a --subset fetch followed later by a bare fetch only pulls
# what's missing, and a repeated run after an interruption resumes
# rather than re-downloading everything.
#
# Either way, on success the LAST LINE on stdout is
# `export ATARI800_CL_HARTE_TESTS=...`; everything else (progress,
# warnings) goes to stderr, so:
#   eval "$(./scripts/fetch-harte.sh --subset)"
# fetches and exports the variable in one step, or copy the printed
# line yourself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/.cache/harte"
BASE_URL="https://raw.githubusercontent.com/SingleStepTests/65x02/main/6502/v1"

# Curated subset (ROADMAP.md Phase 14 item 2): opcodes chosen to cover
# addressing-mode diversity (indirect, indirect-indexed, absolute,
# absolute-indexed, immediate; read-modify-write) and every illegal-
# opcode family this project's Harte triage has ever named -- in fact
# every opcode where the Tom Harte vectors found a real bug during
# ROADMAP.md Phase 12 (9c, 6b, 20), listed first so a smaller --subset N
# keeps the highest-value regression coverage. Ordered, highest
# priority first:
SUBSET_OPCODES=(
  9c  # SHY abs,X -- unstable-store family; Phase 12 found the page-cross
      #   address-corruption bug here
  6b  # ARR #imm -- Phase 12 found the missing decimal-mode fixup here
  20  # JSR abs -- Phase 12 found the push-before-high-byte-read order bug
  8b  # XAA #imm -- magic-constant illegal family
  ab  # LAX #imm -- magic-constant illegal family (dual load+transfer)
  6c  # JMP (ind) -- indirect addressing, the famous page-wrap quirk
  7e  # ROR abs,X -- read-modify-write + absolute-indexed (dummy read)
  b1  # LDA (zp),Y -- indirect-indexed addressing (page-cross)
)

usage() {
  echo "usage: $0 [--subset [N]] [--dir PATH]" >&2
  exit 2
}

SUBSET=0
SUBSET_N="${#SUBSET_OPCODES[@]}"
while [ $# -gt 0 ]; do
  case "$1" in
    --subset)
      SUBSET=1
      if [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
        SUBSET_N="$2"; shift
      fi
      ;;
    --dir)
      shift; [ $# -gt 0 ] || usage
      DEST="$1" ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

if [ "$SUBSET" -eq 1 ] && [ "$SUBSET_N" -gt "${#SUBSET_OPCODES[@]}" ]; then
  echo "note: --subset $SUBSET_N exceeds the curated list of ${#SUBSET_OPCODES[@]};" >&2
  echo "note: capping at ${#SUBSET_OPCODES[@]} -- use a bare fetch (no --subset) for all 256." >&2
  SUBSET_N="${#SUBSET_OPCODES[@]}"
fi

if command -v curl >/dev/null 2>&1; then
  FETCH() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  FETCH() { wget -q "$1" -O "$2"; }
else
  echo "error: neither curl nor wget found on PATH" >&2
  exit 127
fi

mkdir -p "$DEST"

if [ "$SUBSET" -eq 1 ]; then
  OPCODES=("${SUBSET_OPCODES[@]:0:$SUBSET_N}")
  echo "fetching curated subset: ${OPCODES[*]} (${#OPCODES[@]} files, ~$((${#OPCODES[@]} * 4)) MB)" >&2
else
  OPCODES=()
  for i in $(seq 0 255); do
    OPCODES+=("$(printf '%02x' "$i")")
  done
  echo "fetching all 256 opcode files (~1 GB) -- this takes a while" >&2
fi

FAILED=0
PRESENT=0
for hex in "${OPCODES[@]}"; do
  dest="$DEST/$hex.json"
  if [ -s "$dest" ]; then
    echo "  already present: $hex.json" >&2
    PRESENT=$((PRESENT + 1))
    continue
  fi
  if FETCH "$BASE_URL/$hex.json" "$dest.tmp"; then
    mv "$dest.tmp" "$dest"
    echo "  fetched: $hex.json" >&2
    PRESENT=$((PRESENT + 1))
  else
    rm -f "$dest.tmp"
    echo "  FAILED: $hex.json" >&2
    FAILED=1
  fi
done

echo >&2
echo "$PRESENT/${#OPCODES[@]} requested files present in $DEST" >&2
if [ "$FAILED" -eq 1 ]; then
  echo "warning: one or more files failed to fetch; re-run to retry (already-fetched files are skipped)" >&2
fi
echo >&2
echo "export ATARI800_CL_HARTE_TESTS=$DEST"
