#!/usr/bin/env bash
# Downloads the prebuilt Klaus Dormann 6502 functional-test binary into
# roms/, where tests/test-cpu.lisp looks for it (or set
# ATARI800_CL_FUNCTIONAL_TEST to point elsewhere -- see that file).
#
# roms/ is gitignored, so this is per-machine setup, not a vendored
# commit of the binary. Source: the Klaus2m5/6502_65C02_functional_tests
# GitHub repository (MIT-ish "do what you want" license per that repo's
# README -- verify there if redistribution terms matter to you), file
# bin_files/6502_functional_test.bin on its default branch, which is
# already built with the config this project's test expects:
# org=0000, load_data_direct=1, 64 KiB image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROMS_DIR="$ROOT/roms"
DEST="$ROMS_DIR/6502_functional_test.bin"
URL="https://raw.githubusercontent.com/Klaus2m5/6502_65C02_functional_tests/master/bin_files/6502_functional_test.bin"

if [ -f "$DEST" ]; then
  echo "already present: $DEST"
  echo "checksum: $(shasum -a 256 "$DEST" | awk '{print $1}')"
  exit 0
fi

mkdir -p "$ROMS_DIR"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$DEST"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$URL" -O "$DEST"
else
  echo "error: neither curl nor wget found on PATH" >&2
  exit 127
fi

echo "downloaded: $DEST"
echo "checksum: $(shasum -a 256 "$DEST" | awk '{print $1}')"
echo "size: $(wc -c < "$DEST") bytes (expect 65536)"
echo
echo "Full run is slow (max-instructions ~200M); expect a couple of"
echo "minutes on SBCL and longer on LispWorks. See tests/test-cpu.lisp."
