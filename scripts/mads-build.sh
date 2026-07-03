#!/usr/bin/env bash
# mads-build.sh — Build a MADS assembler source file and, on error/warning,
# jump the active BBEdit window to the first offending line.
#
# Usage:   mads-build.sh path/to/source.asm
# Exit:    0 on clean build, 2 on MADS errors, 3 on bad arguments.
#
# Reads .env from the project root (one level up from this script) if present.

set -eu -o pipefail

# ---------------------------------------------------------------------------
# 1.  Locate project root and source .env.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults (overridable by .env).
MADS_BIN="${MADS_BIN:-mads}"
MAX_STEPS="${MAX_STEPS:-20000000}"

# shellcheck disable=SC1091
[[ -f "$PROJECT_DIR/.env" ]] && source "$PROJECT_DIR/.env"

# ---------------------------------------------------------------------------
# 2.  Validate arguments.
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "usage: $(basename "$0") <source.asm>" >&2
  exit 3
fi

SRC="$1"
if [[ ! -f "$SRC" ]]; then
  echo "error: source file not found: $SRC" >&2
  exit 3
fi

# Resolve to an absolute path so MADS -p produces absolute paths in errors,
# and so BBEdit's "open" can find the file regardless of CWD.
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
SRC_DIR="$(dirname "$SRC")"
SRC_STEM="$(basename "${SRC%.*}")"

# ---------------------------------------------------------------------------
# 3.  Prepare build directory next to the source.
# ---------------------------------------------------------------------------
BUILD_DIR="$SRC_DIR/build"
mkdir -p "$BUILD_DIR"

XEX="$BUILD_DIR/${SRC_STEM}.xex"
LST="$BUILD_DIR/${SRC_STEM}.lst"
LAB="$BUILD_DIR/${SRC_STEM}.lab"
RAW="$BUILD_DIR/${SRC_STEM}.mads.out"   # raw MADS stdout+stderr
NORM="$BUILD_DIR/${SRC_STEM}.errors.txt" # normalized file:line: message form

rm -f "$XEX" "$LST" "$LAB" "$RAW" "$NORM"

# ---------------------------------------------------------------------------
# 4.  Run MADS.  -p gives absolute paths in error lines; -l writes a listing;
#     -t writes the label table.  We capture both stdout and stderr.
# ---------------------------------------------------------------------------
echo "==> $MADS_BIN -p -l:$LST -t:$LAB -o:$XEX $SRC"
set +e
"$MADS_BIN" -p "-l:$LST" "-t:$LAB" "-o:$XEX" "$SRC" >"$RAW" 2>&1
MADS_RC=$?
set -e

# Echo the raw output so BBEdit's Shell Worksheet shows it verbatim.
cat "$RAW"

# ---------------------------------------------------------------------------
# 5.  Normalize MADS' "<path> (<line>) ERROR/WARNING: msg" into the canonical
#     "<path>:<line>: <severity>: msg" format that BBEdit (and most editors)
#     understand for click-to-jump.
#
#     We also tolerate the legacy quoted-path form  '<path>' (<line>) ...
# ---------------------------------------------------------------------------
# MADS prints diagnostics as:
#     <path> (<line>) ERROR: <msg>
#     <path> (<line>) WARNING: <msg>
# Older / Code-Genie variants wrap the path in single quotes.  We use sed
# with extended regex (-E) — portable across GNU and BSD/macOS — to lift
# those into the canonical `path:line: severity: msg` form that BBEdit and
# the *nix click-to-jump convention expect.  Anything containing
# ERROR/WARNING that we can't parse is echoed with an `(unparsed)` prefix
# so nothing is silently dropped.
# We parse the diagnostics in awk, which is portable across BSD/macOS awk
# and GNU awk and avoids the sed-delimiter / quoting pitfalls that come
# from MADS paths containing arbitrary characters.
awk '
  # State: SQ is a literal apostrophe so we can use it inside the regex
  # without fighting the surrounding awk single-quote.
  BEGIN { SQ = sprintf("%c", 39); }

  {
    line = $0;

    # 1. Strip an optional leading apostrophe (Code-Genie variant).
    sub("^[[:space:]]*" SQ "?", "", line);

    # 2. Match  <path><whitespace>(LINENO)<whitespace>(ERROR|WARNING):? <msg>
    #    Anchor the trailing apostrophe (if any) just before the line
    #    number to recognise the quoted variant cleanly.
    if (match(line, "^[^(]+[(][0-9]+[)][[:space:]]*(ERROR|WARNING)")) {
      head = substr(line, 1, RLENGTH);          # path<opt-sq> (LINE) SEV
      tail = substr(line, RLENGTH + 1);          # ": msg" or " msg"
      sub("^[[:space:]]*:?[[:space:]]*", "", tail);

      # Pull LINE out of head.
      if (!match(head, "[(][0-9]+[)]")) next;
      lineno = substr(head, RSTART + 1, RLENGTH - 2);

      # SEV is the trailing token in head.
      if (!match(head, "(ERROR|WARNING)$")) next;
      sev = tolower(substr(head, RSTART, RLENGTH));

      # PATH is everything before " (LINE) SEV".
      path = head;
      sub("[[:space:]]*" SQ "?[[:space:]]*[(][0-9]+[)][[:space:]]*(ERROR|WARNING)$", "", path);

      printf("%s:%s: %s: %s\n", path, lineno, sev, tail);
      next;
    }

    # Anything mentioning ERROR or WARNING that we could not parse is
    # surfaced so we never silently drop diagnostics.
    if ($0 ~ /(ERROR|WARNING)/) {
      printf("  (unparsed) %s\n", $0);
    }
  }
' "$RAW" > "$NORM" || true

if [[ -s "$NORM" ]]; then
  echo
  echo "---- normalized diagnostics ($NORM) ----"
  cat "$NORM"
fi

# ---------------------------------------------------------------------------
# 6.  If there is at least one diagnostic, jump BBEdit to the first ERROR
#     (preferred) or the first WARNING.  Uses AppleScript so the existing
#     document is reused if it is already open.
# ---------------------------------------------------------------------------
jump_to_diagnostic () {
  local sev="$1"
  local line
  # First "error" line wins; if none, fall back to first "warning".
  line="$(awk -F: -v sev=": $sev:" '$0 ~ sev { print; exit }' "$NORM" || true)"
  [[ -z "$line" ]] && return 1

  # Split  /abs/path/file.asm:LINE: severity: msg
  local file ln
  file="${line%%:*}"
  ln="$(echo "$line" | awk -F: '{print $2}')"

  # Prefer the `bbedit` CLI if it exists; fall back to AppleScript.
  if command -v bbedit >/dev/null 2>&1; then
    bbedit "+$ln" "$file"
  else
    /usr/bin/osascript <<APPLESCRIPT
tell application "BBEdit"
  activate
  open POSIX file "$file"
  tell text of front text document
    select (line $ln)
  end tell
end tell
APPLESCRIPT
  fi
  return 0
}

if [[ -s "$NORM" ]]; then
  jump_to_diagnostic error || jump_to_diagnostic warning || true
fi

# ---------------------------------------------------------------------------
# 7.  Exit with the MADS return code.  MADS uses:
#       0 = no errors    2 = error    3 = bad parameters
# ---------------------------------------------------------------------------
if [[ $MADS_RC -eq 0 && -f "$XEX" ]]; then
  echo
  echo "==> built: $XEX"
fi

exit "$MADS_RC"
