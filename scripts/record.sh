#!/usr/bin/env bash
# record.sh — One command from a MADS source (or XEX) to a watchable mp4.
#
# Usage:
#   record.sh <file.asm|file.xex> [-frames N] [-o out.mp4] [--keep]
#   record.sh --selftest
#
# What it does:
#   1. If given a .asm, assembles it with scripts/mads-build.sh.
#   2. Starts the emulator with its AESP servers on ephemeral ports, the
#      same way scripts/atari-run.sh does (scripts/runner.lisp --frames).
#   3. Captures N frames of video (scripts/capture-video.py) and the
#      matching N frames of audio (scripts/capture-audio.py) concurrently.
#   4. Muxes them with ffmpeg at 59.92 fps into <out>.
#
# Without ffmpeg the PNG sequence and the WAV are left in place and the
# assemble command is printed, so nothing is lost.
#
# A/V sync: the video and audio ports are pushed from the same post-frame
# hook, so the Nth AUDIO_PCM belongs to the Nth FRAME_RAW.  The two
# capture processes connect a moment apart, though, and audio synthesis
# only attaches at the end of the frame during which the audio client
# connects — expect the streams to be offset by a frame or two (~30 ms),
# which is inaudible for demo capture but not sample-exact.
#
# Acceptance (manual, per ROADMAP.md Phase 11):
#   ./scripts/record.sh asm/edvent02_rasterbars.asm -frames 300 -o /tmp/rb.mp4
#   -> a ~5-second video of animated raster bars.
# Automated smoke:  ./scripts/record.sh --selftest
#   -> 10 frames from the raster-bars demo: >= 10 images and a WAV of
#      >= 7460 samples (10 frames x 746).
#
# Exit: 0 success, 1 runtime failure, 3 bad arguments.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SBCL_BIN="${SBCL_BIN:-sbcl}"
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
ROMS_DIR="${ROMS_DIR:-}"
MAX_STEPS="${MAX_STEPS:-20000000}"
NTSC_FPS="59.92"

# shellcheck disable=SC1091
[[ -f "$PROJECT_DIR/.env" ]] && source "$PROJECT_DIR/.env"

# ---------------------------------------------------------------------------
# 1.  Arguments.
# ---------------------------------------------------------------------------
FRAME_COUNT=300
OUT="recording.mp4"
INPUT=""
KEEP=0
SELFTEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -frames|--frames)
      [[ $# -ge 2 ]] || { echo "error: -frames requires a value" >&2; exit 3; }
      FRAME_COUNT="$2"; shift 2 ;;
    -o|--out)
      [[ $# -ge 2 ]] || { echo "error: -o requires a value" >&2; exit 3; }
      OUT="$2"; shift 2 ;;
    --keep)
      KEEP=1; shift ;;
    --selftest)
      SELFTEST=1; shift ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      echo "error: unknown option: $1" >&2; exit 3 ;;
    *)
      if [[ -z "$INPUT" ]]; then INPUT="$1"; else
        echo "error: extra positional argument: $1" >&2; exit 3
      fi
      shift ;;
  esac
done

if [[ "$SELFTEST" -eq 1 ]]; then
  INPUT="${INPUT:-$PROJECT_DIR/asm/edvent02_rasterbars.asm}"
  FRAME_COUNT=10
  OUT="${OUT:-selftest.mp4}"
  KEEP=1
fi

if [[ -z "$INPUT" ]]; then
  echo "usage: $(basename "$0") <file.asm|file.xex> [-frames N] [-o out.mp4]" >&2
  exit 3
fi
if [[ ! -f "$INPUT" ]]; then
  echo "error: input file not found: $INPUT" >&2
  exit 3
fi
if ! [[ "$FRAME_COUNT" =~ ^[0-9]+$ ]] || [[ "$FRAME_COUNT" -lt 1 ]]; then
  echo "error: -frames must be a positive integer, got: $FRAME_COUNT" >&2
  exit 3
fi

INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"

# ---------------------------------------------------------------------------
# 2.  Assemble if we were handed a source file.
# ---------------------------------------------------------------------------
case "$INPUT" in
  *.asm|*.s|*.a65)
    echo "==> assembling $INPUT"
    "$SCRIPT_DIR/mads-build.sh" "$INPUT"
    XEX="$(dirname "$INPUT")/build/$(basename "${INPUT%.*}").xex"
    [[ -f "$XEX" ]] || { echo "error: build produced no XEX: $XEX" >&2; exit 1; }
    ;;
  *)
    XEX="$INPUT" ;;
esac

# ---------------------------------------------------------------------------
# 3.  Work directory for the intermediate PNG sequence + WAV.
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d -t atari-record.XXXXXX)"
FRAMES_DIR="$WORK_DIR/frames"
WAV="$WORK_DIR/audio.wav"
RUNNER_LOG="$WORK_DIR/runner.log"
RUNNER_PID=""

cleanup() {
  if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  if [[ "$KEEP" -eq 0 ]]; then
    rm -rf "$WORK_DIR"
  else
    echo "==> intermediates kept in $WORK_DIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 4.  Launch the emulator + AESP servers (same mechanism as atari-run.sh).
#     --frames 1 gets us past cold reset quickly; the runner then keeps
#     pumping frames at ~60 fps until we kill it, which is what the two
#     capture clients consume.
# ---------------------------------------------------------------------------
ROM_ARGS=()
if [[ -n "$ROMS_DIR" ]]; then
  [[ -f "$ROMS_DIR/atariosxl.rom" ]] && ROM_ARGS+=("--os-rom"    "$ROMS_DIR/atariosxl.rom")
  [[ -f "$ROMS_DIR/ataribas.rom"  ]] && ROM_ARGS+=("--basic-rom" "$ROMS_DIR/ataribas.rom")
fi

echo "==> starting emulator on $XEX"
"$SBCL_BIN" --script "$PROJECT_DIR/scripts/runner.lisp" \
  "$XEX" \
  --max-steps "$MAX_STEPS" \
  --frames 1 \
  "${ROM_ARGS[@]}" >"$RUNNER_LOG" 2>&1 &
RUNNER_PID=$!

VIDEO_PORT=""
AUDIO_PORT=""
CONTROL_PORT=""
DEADLINE=$(( $(date +%s) + 60 ))
while true; do
  if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
    echo "error: runner exited before becoming ready. log:" >&2
    cat "$RUNNER_LOG" >&2
    exit 1
  fi
  [[ -z "$CONTROL_PORT" ]] && CONTROL_PORT="$(grep -m1 '^AESP_CONTROL ' "$RUNNER_LOG" 2>/dev/null | awk '{print $2}' || true)"
  [[ -z "$VIDEO_PORT"   ]] && VIDEO_PORT="$(grep -m1 '^AESP_VIDEO ' "$RUNNER_LOG" 2>/dev/null | awk '{print $2}' || true)"
  [[ -z "$AUDIO_PORT"   ]] && AUDIO_PORT="$(grep -m1 '^AESP_AUDIO ' "$RUNNER_LOG" 2>/dev/null | awk '{print $2}' || true)"
  if [[ -n "$VIDEO_PORT" && -n "$AUDIO_PORT" ]] && grep -q '^READY ' "$RUNNER_LOG" 2>/dev/null; then
    break
  fi
  if [[ $(date +%s) -ge $DEADLINE ]]; then
    echo "error: timed out waiting for runner to become ready. log:" >&2
    cat "$RUNNER_LOG" >&2
    exit 1
  fi
  sleep 0.2
done

echo "==> runner ready (control $CONTROL_PORT, video $VIDEO_PORT, audio $AUDIO_PORT)"

# ---------------------------------------------------------------------------
# 5.  Capture video and audio concurrently.
# ---------------------------------------------------------------------------
CAPTURE_TIMEOUT=$(( 30 + FRAME_COUNT / 10 ))

echo "==> capturing $FRAME_COUNT frames"
python3 "$SCRIPT_DIR/capture-audio.py" \
  -p "$AUDIO_PORT" --control-port "$CONTROL_PORT" \
  --frames "$FRAME_COUNT" --timeout "$CAPTURE_TIMEOUT" \
  -o "$WAV" >"$WORK_DIR/audio.log" 2>&1 &
AUDIO_PID=$!

VIDEO_OUT="$(python3 "$SCRIPT_DIR/capture-video.py" \
  -p "$VIDEO_PORT" --control-port "$CONTROL_PORT" \
  --frames "$FRAME_COUNT" --timeout "$CAPTURE_TIMEOUT" \
  -d "$FRAMES_DIR")" || {
    echo "error: video capture failed" >&2
    wait "$AUDIO_PID" 2>/dev/null || true
    cat "$WORK_DIR/audio.log" >&2 || true
    exit 1
  }

AUDIO_RC=0
wait "$AUDIO_PID" || AUDIO_RC=$?
if [[ "$AUDIO_RC" -ne 0 ]]; then
  echo "warning: audio capture failed (rc=$AUDIO_RC); recording video only" >&2
  cat "$WORK_DIR/audio.log" >&2 || true
  rm -f "$WAV"
fi

# capture-video.py prints: VIDEO_CAPTURE dir=... pattern=frame%05d.png frames=N first=M
PATTERN="$(printf '%s\n' "$VIDEO_OUT" | awk '/^VIDEO_CAPTURE /{for(i=1;i<=NF;i++) if ($i ~ /^pattern=/) {sub(/^pattern=/,"",$i); print $i}}')"
FRAMES_WRITTEN="$(printf '%s\n' "$VIDEO_OUT" | awk '/^VIDEO_CAPTURE /{for(i=1;i<=NF;i++) if ($i ~ /^frames=/) {sub(/^frames=/,"",$i); print $i}}')"
[[ -n "$PATTERN" ]] || { echo "error: could not parse capture-video output: $VIDEO_OUT" >&2; exit 1; }
echo "==> captured $FRAMES_WRITTEN frames ($FRAMES_DIR/$PATTERN)"

# The emulator has no more work to do; stop it before muxing.
kill "$RUNNER_PID" 2>/dev/null || true
wait "$RUNNER_PID" 2>/dev/null || true
RUNNER_PID=""

# ---------------------------------------------------------------------------
# 6.  Self-test mode stops here with its assertions.
# ---------------------------------------------------------------------------
if [[ "$SELFTEST" -eq 1 ]]; then
  IMAGE_COUNT="$(find "$FRAMES_DIR" -type f \( -name '*.png' -o -name '*.ppm' \) | wc -l | tr -d ' ')"
  if [[ "$IMAGE_COUNT" -lt "$FRAME_COUNT" ]]; then
    echo "SELFTEST FAIL: expected >= $FRAME_COUNT images, got $IMAGE_COUNT" >&2
    exit 1
  fi
  SAMPLES=0
  if [[ -f "$WAV" ]]; then
    SAMPLES="$(python3 -c "import wave,sys; w=wave.open(sys.argv[1]); print(w.getnframes())" "$WAV")"
  fi
  MIN_SAMPLES=$(( FRAME_COUNT * 746 ))
  if [[ "$SAMPLES" -lt "$MIN_SAMPLES" ]]; then
    echo "SELFTEST FAIL: expected >= $MIN_SAMPLES samples, got $SAMPLES" >&2
    exit 1
  fi
  echo "SELFTEST PASS: $IMAGE_COUNT images, $SAMPLES samples"
  exit 0
fi

# ---------------------------------------------------------------------------
# 7.  Mux with ffmpeg (or leave the pieces and print the command).
# ---------------------------------------------------------------------------
if ! command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
  KEEP=1
  echo "warning: $FFMPEG_BIN not found; leaving the frame sequence and WAV in place." >&2
  echo "assemble them with:" >&2
  echo "  $FFMPEG_BIN -framerate $NTSC_FPS -i $FRAMES_DIR/$PATTERN -i $WAV \\" >&2
  echo "    -c:v libx264 -pix_fmt yuv420p -c:a aac $OUT" >&2
  exit 0
fi

echo "==> muxing with $FFMPEG_BIN"
FFMPEG_ARGS=(-y -framerate "$NTSC_FPS" -i "$FRAMES_DIR/$PATTERN")
[[ -f "$WAV" ]] && FFMPEG_ARGS+=(-i "$WAV" -c:a aac)
FFMPEG_ARGS+=(-c:v libx264 -pix_fmt yuv420p "$OUT")

if ! "$FFMPEG_BIN" "${FFMPEG_ARGS[@]}" >"$WORK_DIR/ffmpeg.log" 2>&1; then
  echo "error: ffmpeg failed; log:" >&2
  tail -30 "$WORK_DIR/ffmpeg.log" >&2
  KEEP=1
  exit 1
fi

echo "==> wrote $OUT ($FRAMES_WRITTEN frames at $NTSC_FPS fps)"
