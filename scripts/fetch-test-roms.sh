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
#
# The URL tracks the repo's master branch (a moving target), so the
# download is verified against the pinned sha256 below -- the hash of
# the binary this project's tests and benchmarks were validated with.
# If upstream rebuilds the binary the mismatch is reported and the
# download is discarded; update EXPECTED_SHA256 here after verifying
# the new build passes the suite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROMS_DIR="$ROOT/roms"
DEST="$ROMS_DIR/6502_functional_test.bin"
URL="https://raw.githubusercontent.com/Klaus2m5/6502_65C02_functional_tests/master/bin_files/6502_functional_test.bin"
EXPECTED_SHA256="fa12bfc761e6f9057e4cc01a665a7b800ff01ae91f598af1e39a1201d01953fd"

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if [ -f "$DEST" ]; then
  ACTUAL="$(checksum "$DEST")"
  echo "already present: $DEST"
  echo "checksum: $ACTUAL"
  if [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
    echo "warning: checksum differs from the pinned $EXPECTED_SHA256" >&2
    echo "warning: (a custom or newer build -- the suite may still pass)" >&2
  fi
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

ACTUAL="$(checksum "$DEST")"
if [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
  echo "error: downloaded file's sha256 $ACTUAL" >&2
  echo "error: does not match the pinned  $EXPECTED_SHA256" >&2
  echo "error: discarding the download; see the header comment" >&2
  rm -f "$DEST"
  exit 1
fi

echo "downloaded: $DEST"
echo "checksum: $ACTUAL (matches pinned)"
echo "size: $(wc -c < "$DEST") bytes (expect 65536)"
echo
echo "Full run is slow (max-instructions ~200M); expect a couple of"
echo "minutes on SBCL and longer on LispWorks. See tests/test-cpu.lisp."
