#!/usr/bin/env bash
# run-edvent02-lispworks.sh -- Launch the real LispWorks IDE (not lw-console)
# and, inside it, build an a800 machine against the minimal-xl OS, assemble
# and load asm/edvent02.asm, and start the AESP + CLI servers.  Once the
# machine reports ready, grab a screenshot and print how to point the Attic
# GUI/CLI at the running servers.
#
# All of the actual bring-up work happens inside LispWorks; see
# scripts/run-edvent02-lispworks.lisp, which is loaded via `-init`.
#
# Usage:  scripts/run-edvent02-lispworks.sh
#
# Override LISPWORKS_APP to point at a different LispWorks executable (the
# binary inside <App>.app/Contents/MacOS/, not the .app bundle itself).
# Override ATTIC_DIR to point at a different checkout of
# https://github.com/huegli/attic (defaults to the same checkout
# scripts/compare-attic-protocols.sh uses).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_FILE="$REPO_ROOT/scripts/run-edvent02-lispworks.lisp"

LISPWORKS_APP="${LISPWORKS_APP:-/Applications/LispWorks 8.1 (64-bit)/LispWorks (64-bit).app/Contents/MacOS/lispworks-8-1-0-macos64-universal}"
ATTIC_DIR="${ATTIC_DIR:-/Users/nikolai/Source/Repos/GitHub/huegli/attic}"

if [[ ! -x "$LISPWORKS_APP" ]]; then
  echo "error: LispWorks IDE executable not found or not executable: $LISPWORKS_APP" >&2
  echo "Set LISPWORKS_APP to the executable inside <LispWorks App>.app/Contents/MacOS/." >&2
  exit 127
fi

if [[ ! -f "$INIT_FILE" ]]; then
  echo "error: init file not found: $INIT_FILE" >&2
  exit 1
fi

if ! command -v mads >/dev/null 2>&1; then
  echo "warning: mads not found on PATH; asm/edvent02.asm assembly will fail" \
       "inside the IDE unless MADS_BIN is set for scripts/mads-build.sh." >&2
fi

# ---------------------------------------------------------------------------
# A prior run of this exact script left a LispWorks process bound to the
# AESP/CLI ports it would fail to re-bind: `-init "$INIT_FILE"` is a
# specific enough command-line match to only ever catch instances THIS
# script launched, so cleaning them up before starting a fresh one is safe
# and is what re-running this script means.
# ---------------------------------------------------------------------------
STALE_PIDS="$(pgrep -f -- "-init $INIT_FILE" 2>/dev/null || true)"
if [[ -n "$STALE_PIDS" ]]; then
  echo "Stopping a previous run of this script (pid(s): $STALE_PIDS)..."
  # shellcheck disable=SC2086
  kill $STALE_PIDS 2>/dev/null || true
  DEADLINE=$(( $(date +%s) + 10 ))
  while [[ $(date +%s) -lt $DEADLINE ]]; do
    STILL="$(pgrep -f -- "-init $INIT_FILE" 2>/dev/null || true)"
    [[ -z "$STILL" ]] && break
    sleep 0.5
  done
  STILL="$(pgrep -f -- "-init $INIT_FILE" 2>/dev/null || true)"
  if [[ -n "$STILL" ]]; then
    echo "warning: still running after SIGTERM (pid(s): $STILL); force-killing" >&2
    # shellcheck disable=SC2086
    kill -9 $STILL 2>/dev/null || true
    sleep 0.5
  fi
fi

LOG_FILE="$(mktemp -t edvent02-lispworks.XXXXXX)"

echo "Launching LispWorks IDE (log: $LOG_FILE)..."
# Invoke the app's binary directly (bypassing `open -a`/LaunchServices) so
# this always starts a fresh, distinct process with our -init file, even if
# another LispWorks IDE instance is already running.
nohup "$LISPWORKS_APP" -init "$INIT_FILE" >"$LOG_FILE" 2>&1 &
PID=$!

echo "LispWorks IDE starting (pid $PID)."
echo "It will build the machine, assemble + load asm/edvent02.asm against"
echo "the minimal-xl OS, and start the AESP (127.0.0.1:47800-47802) and CLI"
echo "servers automatically once the IDE finishes loading."
echo "Watch progress with:  tail -f \"$LOG_FILE\""

# ---------------------------------------------------------------------------
# Wait for the machine + servers to come up, then capture a screenshot and
# print how to point Attic's GUI/CLI at the running servers.
#
# This polls the CLI socket directly with a real PING instead of grepping
# the log for the Lisp side's EDVENT02_READY line: LispWorks' redirected
# stdout under `nohup ... &` does not reliably flush that final line to
# the log file by the time bring-up has actually finished (observed: the
# machine is already serving PING/pong on both AESP and CLI while the log
# is still sitting on an earlier line) -- so grepping it can report a false
# timeout even though the machine is fine.  START-CLI-SOCKET names its
# socket /tmp/atari800-cl-<pid>.sock from the OS process id (see
# CURRENT-PROCESS-ID in src/compat.lisp), which is exactly $PID here since
# we launched the LispWorks binary directly -- so the path is known
# up front, and a successful PING is the least ambiguous readiness signal
# there is: the CLI server can't answer it before the machine is built.
# ---------------------------------------------------------------------------
CLI_SOCKET="/tmp/atari800-cl-$PID.sock"

echo
echo "Waiting for the machine + servers to come up (IDE cold-start can take"
echo "a minute or two)..."

DEADLINE=$(( $(date +%s) + 180 ))
STATUS=""
while true; do
  if [[ -S "$CLI_SOCKET" ]] && printf 'CMD:ping\n' | nc -U -w 2 "$CLI_SOCKET" 2>/dev/null | grep -q '^OK:pong$'; then
    STATUS="ready"
    break
  fi
  if grep -q '^fatal: edvent02 bring-up failed' "$LOG_FILE" 2>/dev/null; then
    STATUS="failed"
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "error: LispWorks exited before the machine came up; see $LOG_FILE" >&2
    exit 1
  fi
  if [[ $(date +%s) -ge $DEADLINE ]]; then
    echo "error: timed out waiting for the machine to come up; see $LOG_FILE" >&2
    exit 1
  fi
  sleep 1
done

if [[ "$STATUS" == "failed" ]]; then
  echo "error: edvent02 bring-up failed inside the IDE; see $LOG_FILE" >&2
  grep '^fatal:' "$LOG_FILE" >&2 || true
  exit 1
fi

SCREENSHOT="$REPO_ROOT/asm/build/edvent02.png"
echo "Machine is up; capturing a screenshot to $SCREENSHOT..."
if command -v python3 >/dev/null 2>&1; then
  if python3 "$REPO_ROOT/scripts/capture-screenshot.py" -o "$SCREENSHOT"; then
    echo "screenshot: $SCREENSHOT"
  else
    echo "warning: screenshot capture failed (server may still be starting" \
         "its AESP listeners); see output above" >&2
  fi
else
  echo "warning: python3 not found on PATH; skipping screenshot" >&2
fi

echo
echo "=== EdVenture video 2 is running ==="
echo "AESP:  127.0.0.1:47800 (control) / 47801 (video) / 47802 (audio)"
echo "CLI:   ${CLI_SOCKET:-<not found in log; see $LOG_FILE>}"
echo
echo "View it with the Attic GUI (auto-connects to localhost:47800-47802):"
echo "  (cd \"$ATTIC_DIR\" && swift run AtticGUI)"
echo
echo "Drive it from the Attic CLI REPL over the same CLI socket:"
echo "  (cd \"$ATTIC_DIR\" && swift run attic --socket \"$CLI_SOCKET\")"
if [[ ! -d "$ATTIC_DIR" ]]; then
  echo
  echo "warning: ATTIC_DIR not found: $ATTIC_DIR" >&2
  echo "Set ATTIC_DIR to your checkout of https://github.com/huegli/attic." >&2
fi
