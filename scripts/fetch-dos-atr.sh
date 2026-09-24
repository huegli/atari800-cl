#!/usr/bin/env bash
# Downloads a DOS 2.5 ATR disk image into roms/ (as dos25.atr, the first
# filename tests/test-machine.lisp's *DOS-ATR-CANDIDATES* looks for) so the
# Phase 25 acceptance test REAL-OS-ROM-BOOTS-DOS-MENU-OVER-SERIAL-WIRE
# stops skipping: with the real OS ROM and a DOS 2.5 disk mounted on
# drive 1, a cold boot must load DOS.SYS and DUP.SYS over the emulated
# SIO serial wire and put the DUP menu on screen.
#
# roms/ is gitignored, so this is per-machine setup, not a vendored
# commit.  Source: the Internet Archive's Atari 8-bit Software Library
# item a8b_DOS_v2.5_1984_Atari -- the unmodified 1984 Atari DOS 2.5 disk
# (90 KiB single-density, the image atari800/Altirra also boot).
#
# The test also accepts $ATARI800_CL_DOS_ATR pointing at any DOS 2.5
# image you already have; this script is just the no-thought default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/roms/dos25.atr"
URL="https://archive.org/download/a8b_DOS_v2.5_1984_Atari/DOS_v2.5_1984_Atari.atr"

if [ -e "$DEST" ]; then
  echo "already present: $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$WORK/dos25.atr"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$URL" -O "$WORK/dos25.atr"
else
  echo "error: neither curl nor wget found on PATH" >&2
  exit 127
fi

# Sanity-check the download: an ATR starts with the little-endian magic
# word $0296 (bytes $96 $02; src/hostdev.lisp's +ATR-MAGIC+) and must
# comfortably hold this disk's 720+ sectors.
MAGIC="$(head -c 2 "$WORK/dos25.atr" | od -An -tx1 | tr -d ' \n')"
SIZE="$(wc -c < "$WORK/dos25.atr" | tr -d ' ')"
if [ "$MAGIC" != '9602' ] || [ "$SIZE" -lt 90000 ]; then
  echo "error: downloaded file does not look like a DOS 2.5 ATR" \
       "(magic '${MAGIC}', ${SIZE} bytes)" >&2
  echo "error: the archive.org item layout may have changed upstream --" \
       "inspect $URL" >&2
  exit 1
fi

mkdir -p "$ROOT/roms"
mv "$WORK/dos25.atr" "$DEST"

echo "downloaded $DEST (${SIZE} bytes)"
echo
echo "The DOS-menu serial-boot test will now run (it was skipping before):"
echo "  ./scripts/test-sbcl.sh"