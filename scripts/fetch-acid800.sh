#!/usr/bin/env bash
# Downloads Avery Lee's Acid800 test suite (the emulator-accuracy ratchet
# for ANTIC/CPU behavior an emulator's own tests can't check, since they'd
# just assert the implementation back at itself) and unpacks the CPU and
# ANTIC standalone tests into roms/acid800/ (ROADMAP.md Phase 24).
#
# roms/ is gitignored, so this is per-machine setup, not a vendored
# commit of the suite. Source: virtualdub.org (Avery Lee, the Altirra and
# Acid800 author's own site) -- MIT licensed per the suite's own
# README.html. The archive is a small (~216 KB) 7z file; this script
# downloads it, extracts the whole thing (it decompresses to ~12 MB,
# trivial), and copies out only the 7 cpu_*.xex/.lab and 13 antic_*.xex/
# .lab standalone tests -- Phase 24's scope -- discarding the rest
# (Acid5200/AcidSAP variants, the full-suite .atr, and the gtia_*/
# pokey_*/pia_*/mmu_*/mod_* standalone tests, which are out of scope for
# now). Each standalone .xex runs one test and stops; see
# tests/test-machine.lisp's ACID800-* tests for how they're driven.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/roms/acid800"
URL="https://www.virtualdub.org/downloads/Acid800-0.8.7z"
STANDALONE_SUBDIR="out/release/Acid800/standalone"

SEVENZ=""
for candidate in 7zz 7z 7za; do
  if command -v "$candidate" >/dev/null 2>&1; then
    SEVENZ="$candidate"
    break
  fi
done
if [ -z "$SEVENZ" ]; then
  echo "error: no 7z extractor found on PATH (looked for 7zz, 7z, 7za)" >&2
  echo "error: install one, e.g. 'brew install sevenzip' or 'apt install p7zip-full'" >&2
  exit 127
fi

if [ -d "$DEST" ] && [ -n "$(find "$DEST" -maxdepth 1 -name '*.xex' -print -quit 2>/dev/null)" ]; then
  echo "already present: $DEST ($(find "$DEST" -maxdepth 1 -name '*.xex' | wc -l | tr -d ' ') .xex files)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARCHIVE="$WORK/acid800.7z"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$ARCHIVE"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$URL" -O "$ARCHIVE"
else
  echo "error: neither curl nor wget found on PATH" >&2
  exit 127
fi

"$SEVENZ" x -y -o"$WORK/extracted" "$ARCHIVE" >/dev/null

SRC="$WORK/extracted/$STANDALONE_SUBDIR"
if [ ! -d "$SRC" ]; then
  echo "error: expected directory not found in archive: $STANDALONE_SUBDIR" >&2
  echo "error: the archive layout may have changed upstream -- inspect $WORK/extracted" >&2
  exit 1
fi

mkdir -p "$DEST"
COUNT=0
for prefix in cpu antic; do
  for f in "$SRC/${prefix}_"*.xex; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .xex)"
    cp "$f" "$DEST/$base.xex"
    [ -e "$SRC/$base.lab" ] && cp "$SRC/$base.lab" "$DEST/$base.lab"
    COUNT=$((COUNT + 1))
  done
done

echo "extracted $COUNT standalone tests into $DEST:"
find "$DEST" -maxdepth 1 -name '*.xex' | xargs -n1 basename | sort | sed 's/^/  /'
echo
echo "License: MIT (Copyright 2010 Avery Lee -- see the suite's own"
echo "README.html, not re-fetched here; https://virtualdub.org/altirra.html)."
