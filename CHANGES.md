# Changes

A flat log of what each build phase delivered, in commit order.
For deeper detail see `git log` on the corresponding feature branch.

## ROADMAP Phase 13 -- POKEY keyboard IRQ: the OS editor now sees keystrokes

The machine booted to BASIC's `Ready` but could not be typed at: AESP's
`KEY_DOWN` already reached `INPUT-SET-KEY`, making `KBCODE` readable, but
the XL OS reads `KBCODE` from an interrupt handler dispatched off IRQEN
bit 6, and POKEY had no such source. `+IRQ-OTHER-KEY+` (`$40`) and
`+IRQ-BREAK-KEY+` (`$80`) are confirmed straight from `TIRQ` in
`Atari_XL_OS_Rev.2.asm` (`.byte $40 ;1 - keyboard IRQ`, `.byte $80 ;0 -
BREAK key IRQ`), not just taken from the plan.

`src/input.lisp` adds two one-shot flags to `INPUT-STATE`,
`KEY-IRQ-PENDING` / `BREAK-IRQ-PENDING`, armed under its existing lock by
`INPUT-SET-KEY` on a press and by the new `INPUT-SET-BREAK`, and drained
by two new getters `INPUT-CONSUME-KEY-IRQ` / `-BREAK-IRQ`. BREAK gets its
own setter rather than reusing `INPUT-SET-KEY`, because on real hardware
it is a dedicated physical switch outside the 64-key scan matrix and does
not touch KBCODE.

`src/pokey.lisp` claims `PENDING` bit 2 (`+POKEY-PENDING-KEY+`, reserved
by ROADMAP Phase 22), maintained by `ATTACH-POKEY-INPUT` exactly like the
audio bit: set when an `INPUT-STATE` is attached, cleared on detach,
preserved across `RESET-POKEY`. This deliberately does not mean "a key
event is pending" the way the ROADMAP draft described -- `INPUT-SET-KEY`
runs on socket reader threads, and having it write `PENDING` directly
would race the emulator thread's own clears of bits 0/1 (a lost-update:
whichever write lands last erases the other's effect, with no lock
protecting `PENDING` itself). Instead the bit means "input is attached,"
so `POKEY-TICK` / `POKEY-ADVANCE` drain the two `INPUT-STATE` flags
(`%POKEY-SERVICE-KEY-IRQS`) every advance while it is set -- taking
`INPUT-STATE`'s lock there is safe because that only happens in real
interactive use, never in any benchmark workload (none attach input), so
the new code costs nothing in the workloads that get measured.

`tests/test-machine.lisp` adds the real acceptance test: boot to `READY`,
type the POKEY key codes for `PRINT 2+2` and RETURN through an attached
`INPUT-STATE`, and assert `4` lands in screen memory once BASIC evaluates
the line. The key codes are read directly from the real OS's own TCKD
table (`Atari_XL_OS_Rev.2.asm`: "Entry n is the ATASCII equivalent of key
code n") and were verified empirically against the real ROM before being
committed to the test.

One correction to the original plan, caught by checking the real OS
source rather than trusting the draft (ROADMAP.md rule 9): the plan
claimed SKSTAT bit 2 was "shift held" and bit 3 "a key is down."
`minimal-xl`'s own documented VBI debounce logic ("the VBI counts it down
while SKSTAT bit 2 shows the key held") confirms the *existing*
bit-2-is-keydown implementation was already correct, so
`input-pokey-skstat` was left unchanged.

Verified on both implementations, lenient and strict
(`ATARI800_CL_STRICT=1`): 2106 checks (SBCL) / 2124 (LispWorks), 0 fail,
exit 0 lenient; strict fails only the genuinely-absent Harte vectors on
this machine, exit 1 as expected, with the new typing test itself passing
under strict on both. Not freshly benchmarked: the design makes the new
code provably zero-cost in every measured workload (gated behind a bit no
bench workload ever sets); a live `bench-ab.sh` attempt was abandoned
when the host's load average hit 74 from unrelated activity.

## ROADMAP Phase 22 -- POKEY pending-work bitmask

The serial transmitter and audio synthesis each added their own
per-advance branch test to `POKEY-TICK` / `POKEY-ADVANCE` (a separate
slot read for `SERIAL-OUT-CYCLES`, another for `AUDIO`), each measured
and accepted individually, and Phases 13 (keyboard IRQ) and 16a (SIO
receive) were each about to add a third and fourth of the same shape.

`src/pokey.lisp` adds a `PENDING` fixnum: bit 0 tracks the transmitter
(set when a byte starts shifting in `%SEROUT-WRITE`, cleared when the
shift register empties with nothing queued in `%SERIAL-OUT-ADVANCE`),
bit 1 tracks whether an `AUDIO-UNIT` is attached (maintained by
`ATTACH-AUDIO` in `src/audio.lisp`), and bits 2-3 are reserved for
Phases 13 and 16a. `POKEY-TICK` / `POKEY-ADVANCE` read `PENDING` once;
when it is zero the timer chain runs with no further slot reads at all,
and when nonzero each feature's check is a `LOGTEST` against the
already-loaded local rather than an independent read. `RESET-POKEY`
clears bits 0/2/3 but preserves bit 1 (audio attachment is an
emulator-level facade, not a chip register, and survives a chip reset).

`POKEY-TICK-VS-ADVANCE-EQUIVALENCE` (`tests/test-pokey.lisp`) now runs
its scripted 50,000-cycle comparison under all four `PENDING` states
(neither bit, audio only, serial only, both), not just the all-zero
case the original test covered, via a new `%RUN-POKEY-EQUIVALENCE`
helper -- the serial run starts one byte before cycle 0 and lets it
finish mid-run, exercising the bit clearing again as well as setting.

Measured with the new `scripts/bench-ab.sh` (an interleaved-run A/B
harness, promoted from prose in `PERFORMANCE_LOG.md` to a command)
against the pre-phase commit: nothing regressed on either
implementation. Two clean improvements -- LispWorks `nop` +8.5% (the
maximum possible `PENDING`-check density) and SBCL `audio` +8.9% (the
cold path getting cheaper: one `LOGTEST` instead of two independent
slot reads) -- the rest positive but not clean at this sample size. See
`PERFORMANCE_LOG.md` for the full tables.

## AESP video push: fix FRAME_RAW to match the Attic protocol spec

The AESP video-port push had drifted from the Attic project's
`docs/PROTOCOL.md` on three points at once: it used message type `0x65`
("VIDEO_FRAME") where the spec defines `FRAME_RAW` at `0x60`; it sent the
renderer's native 24-bit RGB pixel data where the spec requires BGRA8888;
and it prefixed the payload with a 4-byte frame number the spec doesn't
have. A real Attic client (AtticGUI) connecting to an atari800-cl server
therefore failed immediately with "Unknown message type: 0x65" -- this
project's own `tools/protocol-comparison/protocol_spec.py` already had
the correct values (`FRAME_RAW: 0x60`), so the drift was isolated to
`src/aesp.lisp`'s implementation, not a spec ambiguity.

`src/aesp.lisp` now sends `+aesp-frame-raw+` (`0x60`) with a `%rgb24->bgra32`
conversion of the framebuffer applied at the push boundary only -- the
renderer's internal representation is untouched, so nothing outside
`%push-video-frame` needed to change. `%frame-config-payload`'s byte 4 now
reports `4` (bytes per pixel) instead of `24` (bits), matching
`FRAME_CONFIG`'s spec'd `bytes-per-pixel` field and what `FRAME_RAW` now
actually sends. `scripts/aesp_client.py` and the `capture-*.py` tools were
updated to match: `read_video_frame` returns the raw BGRA payload (no more
frame-number unpacking), and `write_image`/`write_png`/`write_ppm` convert
BGRA to RGB before writing, so screenshot/video output is unchanged
(3-byte RGB PNG/PPM) even though the wire format is now BGRA. Both
`atari800-cl` and Attic (`AtticGUI`) can now display the same running
emulator's frames.

Verified on this machine: 2080 pass, 1 skip (Tom Harte, no checkout
here), 0 fail, both SBCL and LispWorks.

## ROADMAP Phase 21 -- Strict test gate + skip census

Three tests skip gracefully when an asset they need is absent (the Klaus
functional-test binary, the Tom Harte vectors, the real OS/BASIC ROM
images) -- correct for a checkout that has never had the asset, but on a
machine that is supposed to have it (`CLAUDE.md`/`ROADMAP.md` rule 8) a
silent skip can hide a real regression. It did: the PIA register-map and
missing-serial-transmitter bugs that once made the emulator unable to
boot the real OS survived twelve green suite runs, because the one test
that would have caught it was in a skip-tolerant posture the whole time.

`tests/test-helpers.lisp` adds `%SKIP-OR-FAIL`: skips exactly as `SKIP`
would, unless `$ATARI800_CL_STRICT` is set to a non-empty value, in which
case the same reason becomes a failure instead. The Klaus test
(`tests/test-cpu.lisp`), the Tom Harte harness (`tests/test-harte.lisp`,
both skip sites), and the two real-ROM boot tests
(`tests/test-machine.lisp`) now use it. A self-test
(`SKIP-OR-FAIL-RESPECTS-STRICT-MODE` in `tests/test-compat.lisp`) exercises
both branches against two standalone probe tests via a test-only dynamic
override (`*STRICT-MODE-OVERRIDE*`), so it never has to touch the process
environment or a real asset.

`tests/test-suite.lisp`'s `RUN-TESTS` (now what both `scripts/test-sbcl.sh`
and `scripts/test-lispworks.lisp` call, in place of a bare `fiveam:run!`)
prints a "Skip census" after FiveAM's own report: one `SKIPPED: <test>
(<reason>)` line per skipped check, or `(none)`, so a skip that matters is
always grep-able and never buried in scrollback.

Verified on this machine (which has the Klaus binary and both ROM images,
but not a Harte checkout): lenient runs are unchanged (2081 checks, 1
skip, exit 0, both implementations); `ATARI800_CL_STRICT=1` runs execute
Klaus and both real-ROM tests for real (they pass) and fail only on Harte,
whose vectors are genuinely absent here (2063 checks, 0 skip, 1 fail, exit
1, both implementations) -- exactly the intended behavior.

## ROADMAP Phase 12 -- Tom Harte ProcessorTests harness (3 CPU bugs found)

`tests/test-harte.lisp` runs the SingleStepTests/65x02 vectors: per-opcode
JSON cases carrying full before/after CPU + memory state and a
cycle-by-cycle bus trace.  The data is ~1 GB and deliberately not
vendored -- point `ATARI800_CL_HARTE_TESTS` at a checkout's `6502/v1`
directory and the harness tests whatever `<hex>.json` files it finds;
without it the test SKIPs, like the Klaus functional test.  Depth is 500
cases per opcode, `ATARI800_CL_HARTE_FULL=1` for all 10,000.  `shasht` is
a new **tests-only** dependency; the runtime system stays as light as it
was.

Files are parsed incrementally -- consume the opening bracket, read one
case at a time -- rather than with a single `read-json` per file.  Parsing
a whole 3-5 MB file materialises all 10,000 cases at once and exhausts a
default 1 GB SBCL heap partway through a 256-opcode run.

**Three real bugs, all fixed, each with a regression test naming the
failing case id:**

- **Unstable stores didn't corrupt the address on a page cross.**
  SHA/SHX/SHY/TAS AND the stored byte with `high(base)+1`; when the index
  carries into the high byte, that same value is driven onto the address
  bus, so the write lands at `(low(base+index) | value<<8)`.
  `src/illegal.lisp` documented *not* modelling this; 849 of the first 955
  page-crossing `$9C` cases disagreed.  Now modelled in
  `%UNSTABLE-STORE-ADDRESS` -- it is deterministic, only the ANDed value is
  chip-dependent.
- **ARR (`$6B`) ignored decimal mode.**  With D set, the ADC-style nibble
  fixup runs on top of the shift and changes both A and C, with N taken
  from the rotated-in carry and V/Z from the pre-fixup value.  132 of the
  first 500 cases failed.
- **JSR read its high operand byte before pushing.**  The NMOS sequence is
  read-low, push, read-high, which only shows when the push overwrites the
  JSR's own operand -- one case in 2,560,000.

XAA (`$8B`) and LAX #imm (`$AB`) now compute through `(A | $EE)`.  The
magic constant genuinely varies on hardware, but `$EE` is what the vectors
encode (uniquely determined over thousands of cases) and what mainstream
emulators model, so adopting it beats carrying a permanent skip.

Result: **all 256 opcodes pass at full depth -- 2,560,000 cases, zero
failures, and the skip list is empty** on both implementations.  Suite:
2058 checks + 1 skip (the Harte test itself, with no data present); 2315
with the vectors attached.  Interleaved benchmarks show the CPU changes
are performance-neutral (SBCL `nop` -1.6%, `klaus` +0.8%, both inside
run-to-run spread).

## ROADMAP Phase 11 -- A/V recording tooling (`.asm` -> `.mp4`)

`scripts/record.sh <file.asm|file.xex> [-frames N] [-o out.mp4]`
assembles (when handed a source), starts the emulator and its AESP
servers the way `atari-run.sh` does, captures video and audio
concurrently, and muxes them with ffmpeg at 59.92 fps.  `--keep` leaves
the intermediates, `--selftest` runs the 10-frame smoke case and asserts
on it, and without ffmpeg the frame sequence and WAV are left in place
with the assemble command printed.

`scripts/capture-video.py` is new: N frames into `frame00001.png`, ... --
the numbering ffmpeg's `-i frame%05d.png` wants -- falling back to PPM
without Pillow.  The protocol codec, the two subscribe exchanges and the
image writers moved into `scripts/aesp_client.py`, which all three
capture scripts now import instead of carrying their own copies;
`capture-screenshot.py` and `capture-audio.py` shrank accordingly and
their CLIs are unchanged.

One emulator-side change: `scripts/runner.lisp` prints `AESP_AUDIO`
alongside `AESP_CONTROL` / `AESP_VIDEO`.  The three ports are bound from
ephemeral ports and are not necessarily adjacent, so a recorder cannot
infer the audio port from the video one.

Acceptance (ROADMAP.md Phase 11 item 3): 300 frames of
`asm/edvent02_rasterbars.asm` produce a 5.006 s, 384x240, 300-frame
h264 + AAC mp4 with the raster bars visible.  Sync caveat, documented in
the script header and the README: video and audio pair 1:1 on the wire,
but the two capture processes connect a moment apart, so the streams can
sit a frame or two (~30 ms) apart.

## POKEY serial output interrupts -- the XL OS now boots through to BASIC

With the PIA fixed the OS booted but then parked forever at `$E9E4`, the
SIO send loop: `LDA BRKKEY / BEQ exit / LDA XMTDON / BEQ loop`.  It had
written the first byte of its command frame to `SEROUT` and was waiting
for its own serial-output IRQ handler to set `XMTDON` ($3A) -- an
interrupt POKEY never raised, because the serial side was a stub.

Two things were wrong.  **The IRQEN bit map**: timer 4 was `$08`, but the
XL OS's own interrupt dispatch table (`TIRQ` in
`minimal-xl/Atari_XL_OS_Rev.2.asm`) assigns `$04` to timer 4 and `$08` /
`$10` to the two serial-output interrupts -- which is exactly the pair the
OS clears with `AND #$E7` after a transfer.  `+IRQ-TIMER4+` is now `$04`.
**And the transmitter did not exist**: SEROUT was a no-op.

POKEY now models the double-buffered transmitter: a `SEROUT` write starts
the byte (or queues it behind one already shifting), SEROR (`$10`) fires
when the holding register empties and the next byte is wanted, SEROC
(`$08`) when the last byte has shifted out.  Byte duration comes from the
channel-4 timer -- 20 half-bits of (reload+1)*divisor cycles, which at the
OS's SIO setup (AUDCTL `$28`, AUDF3/4 = `$0028`) works out to 19,047 baud
against a nominal 19200.  SKCTL bit 5 gates it: writes in a non-transmit
mode only latch.

Not modelled: the serial line itself.  No bits leave the chip, nothing is
received, SKSTAT stays the `$FF` stub.  That is enough for the OS to
finish sending its command frame, get no answer, time out through its VBI
countdown timers, and fall through to BASIC -- which is what a real 800 XL
with no drive attached does.  Booting `ATARIXL.ROM` + `ATARIBAS.ROM` now
reaches the BASIC prompt (`Altirra 8K BASIC 1.59 / Ready` on the dumps
used here) in about 1,100 frames.

Hot-path cost measured and logged in `PERFORMANCE_LOG.md`: -1.2% (SBCL
`nop`) to -4.8% (LispWorks `irq`), and within noise on the mixed
workloads.  A first implementation that clocked the transmitter from
inside `%EXPIRE-CHANNEL` cost 4-9% and was rejected; the log records why.

New tests: five POKEY serial tests, plus two real-ROM boot tests in
`tests/test-machine.lisp` -- one asserting the OS gets far enough to
program ANTIC, one asserting BASIC's prompt reaches screen memory.  Both
skip when no ROM images are present, like the Klaus test, so a checkout
without dumps still runs green.  2047 checks on SBCL and LispWorks.

## PIA register map fix -- the XL OS now boots

The PIA decoded `addr & 3` as PORTA / DDRA / **PORTB** / DDRB.  On a real
6520 only the first address pair is a port: `$D300` is PORTA *or* DDRA
and `$D301` is PORTB *or* DDRB, each selected by bit 2 of its control
register, and `$D302` / `$D303` are those control registers (PACTL /
PBCTL) -- which the model did not have at all.

The consequence was fatal to booting.  The XL OS's PIA init at `$EF91`
does `LDX #$38 / STX $D302` to select DDRA before programming it; taken
as a PORTB write, `$38` (bit 0 clear = OS ROM off) went straight into
`MMU-WRITE-PORTB` and unmapped the OS ROM out from under the running
boot code.  The next fetch read `$00` from RAM, i.e. `BRK`, and the
machine sat in a `BRK` loop for the rest of time: ANTIC was never
programmed, so every rendered frame was background color 0 and every
AESP `VIDEO_FRAME` (and `capture-screenshot.py` PNG) came out black.

`PIA` now carries `PACTL` / `PBCTL` slots (cleared by `RESET-PIA`, so a
just-reset chip sees the DDRs at `$D300`/`$D301` exactly like hardware);
`PIA-READ` / `PIA-WRITE` honour the bit-2 select; control-register writes
mask off bits 6-7, the read-only CA/CB interrupt flags.  Only a real
PORTB write reaches the MMU -- a DDRB write no longer does.  Not modelled:
pin-level readback of input-configured PORTB bits (the port read returns
the output latch), and the CA/CB peripheral-control lines including
PACTL bit 3 (cassette motor) and PBCTL bit 3 (SIO command).

With the fix the XL OS gets through PIA init, sets `DMACTL=$22`,
`NMIEN=$40` and a display list at `$9C20`, and the renderer produces a
real frame.  Tests updated for the corrected map (`test-pia.lisp`,
`test-mmu.lisp`, `test-regressions.lisp`), including a regression that
replays the OS's `$38`/`$3C` init dance and asserts the OS ROM stays
mapped.  2018 checks green on SBCL and LispWorks.

## ROADMAP Phase 10 -- AESP audio streaming + WAV capture

The synthesised PCM from Phase 9 now leaves the process.

**Message type.**  ROADMAP.md offered `#x85` as a fallback "if the
protocol defines no audio-frame type" -- it does: `AUDIO_PCM` = `0x80`
in `tools/protocol-comparison/protocol_spec.py`'s `AESP_MESSAGES`
table, so that is what `+AESP-AUDIO-PCM+` uses.  Payload is raw mono
unsigned-8 samples with no prefix, so the payload length IS the sample
count (746-747 per frame).  Pushed from the same post-frame hook as
VIDEO_FRAME, so the Nth AUDIO_PCM and the Nth VIDEO_FRAME describe the
same frame -- the 1:1 pairing Phase 11's muxing will rely on.

**AUDIO_CONFIG** now declares the synthesiser's real rate, 44,744 Hz
(`$0000AEC8`), instead of the 44,100 it claimed before there were any
samples to describe.  Wire layout is unchanged.

**Attachment lifecycle.**  Audio-port connections are tracked in a new
`AUDIO-CLIENTS` list; synthesis is attached while at least one is
connected and detached when the last leaves, so a machine nobody is
listening to does not pay for it.  This deviates from the plan's
"attach on first subscribe, guard with the server lock": acceptor and
reader threads must never touch the machine directly (that is what the
command mailbox is for), and a MACHINE-SUBMIT from an acceptor would
deadlock whenever no run loop is draining.  Instead the post-frame
hook -- already on the emulator thread -- reconciles the attachment each
frame.  Race-free and lock-free; the cost is that synthesis switches on
at the end of the frame during which the first client connects, so that
client's first push arrives one frame later.  `STOP-AESP-SERVER`
detaches too, since nothing would drain the buffer afterwards.

**`scripts/capture-audio.py`** subscribes on the control port for
AUDIO_CONFIG, collects N frames of AUDIO_PCM, and writes a WAV through
Python's `wave` module.  Verified end to end against a real server
voicing two POKEY channels.

Tests: AUDIO_PCM codec roundtrip (including that the code is the
protocol's 0x80 and that payload length equals sample count), the
corrected AUDIO_CONFIG payload, and three live-server tests -- PCM
arrives with a frame's worth of samples, no unit is attached without a
subscriber, and the unit is detached once the last client leaves.

## ROADMAP Phase 9 -- POKEY audio synthesis core

New `src/audio.lisp` / `atari800-cl.audio`, loaded between `pokey` and
`irq`, turns POKEY register state into mono 8-bit PCM at 44,744 Hz (one
sample every 40 CPU cycles -> 746-747 samples per NTSC frame).

**Synthesis.**  Each channel has a one-bit output flip-flop clocked by
its timer's underflow.  AUDC bits 7-5 decide what the clock does,
gated through polynomial counters free-running at 1.79 MHz: bit 7
bypasses the 5-bit gate poly, bit 5 toggles the flip-flop (square
wave), bit 6 loads it from poly4, otherwise it loads from poly17 (or
poly9 when AUDCTL bit 7 selects the short poly) -- the eight documented
distortions.  AUDC bit 4 (volume-only) bypasses the flip-flop and emits
the volume as DC.  Mixing: each channel deflects the level by +/-volume,
doubled and centred on 128.

**Poly tables** are built at load time from POKEY's own `STEP-LFSR` and
tap constants, which Phase 9 factored out of the RANDOM register's two
steppers -- so the audio distortion polys and the RNG polys cannot drift
apart.  The 4- and 5-bit taps are new and their maximal-length property
is pinned by test, as the 9/17-bit ones already were.

**Wiring.**  POKEY gains an `AUDIO` slot plus two function slots that
`ATTACH-AUDIO` fills in, so POKEY never names the audio package (the
same closure discipline the bus uses for the chips).  A cycle run
elapses in the audio unit BEFORE the expiries at its end are processed,
which is what makes `pokey-tick` and `pokey-advance` produce identical
audio.  A linked 16-bit pair is voiced by its HIGH channel's AUDC -- the
same channel that owns its IRQ.

**Facade.**  `a800:machine-attach-audio` (fresh unit by default, NIL to
detach) and `a800:machine-audio-drain` (fresh sample vector, empties
the buffer), plus `a800:+audio-sample-rate+`.

Out of scope, documented in the file header rather than approximated:
AUDCTL's two high-pass filters (bits 1-2), two-tone serial mode, and
real POKEY's non-linear mixer/volume curve.

New `audio` bench workload (all four channels voiced, two on the
1.79 MHz clock, draining per frame) measures the synthesis path; every
other workload runs with audio detached, so the row pair shows both
that the no-audio path stays free and what synthesis costs.  See
`PERFORMANCE_LOG.md`.

Suite: 1983 checks green on both implementations.

## ROADMAP Phase 8 -- POKEY timer fidelity

MISC_IMPROVEMENTS_PLAN.md item 5.  Two divergences from hardware, both
in the timer period model, fixed together because they change what the
existing timer tests mean.

**Reload offsets.**  The period was AUDF+1 in every configuration; on
hardware POKEY's counter reload costs extra cycles at the fast clock:

| clock                    | period                              |
|--------------------------|-------------------------------------|
| 1.79 MHz, unlinked       | AUDF + 4 CPU cycles                 |
| 1.79 MHz, 16-bit linked  | 256*AUDF_hi + AUDF_lo + 7 cycles    |
| 64 kHz / 15 kHz          | AUDF + 1 of the *divided* clock     |

`%TIMER-RELOAD-VALUE` is now the single source of the countdown reload,
used by both underflow and STIMER.  The figures come from the plan
(quoting the Altirra Hardware Reference), which flags them **CONFIRM**;
no independent source was available here, so they are implemented as
stated and the flag is carried into `src/pokey.lisp`'s header.

**Linked 16-bit channels.**  AUDCTL bit 4 joins channels 1+2 and bit 3
joins 3+4.  A linked pair is ONE 16-bit counter clocked by the low
channel's clock select -- the low byte borrows from the high byte rather
than reloading independently, so the period is `256*hi + lo + offset`,
not the product of two independent periods.  The pair's whole countdown
lives in the low channel's slot; the high channel's own divided clock
drives nothing while linked, and the pair's IRQ comes from the HIGH
channel's IRQEN bit (timer 2 for 1+2, timer 4 for 3+4).

Tests that changed meaning are renamed and re-derived with citations:
`pokey-timer1-fires-irq-after-audf1+1-ticks` ->
`...-audf1+4-ticks`, plus the AUDF=0-at-1.79 MHz tick counts in three
IRQ-line regression tests and a comment in the machine suite.  New
tests cover the fast-clock STIMER offset, both linked pairs' periods
and IRQ sources, a linked pair on the divided clock (no fast offset),
and unchanged independent behaviour when the link bits are clear.  The
`pokey-tick`/`pokey-advance` equivalence script gains four linked-mode
phases (fast pair, the same pair moved to 64 kHz, the 3+4 pair, then
unlinking), so the batched advance is pinned against the per-cycle loop
through every new path.

Suite: 1946 checks green on both implementations.  The `irq` bench
workload uses the 64 kHz clock, whose period is unchanged, so benchmark
numbers are unaffected.

## ROADMAP Phase 7 -- GTIA color modes 9/10/11

PRIOR bits 6-7 now reinterpret an ANTIC mode-F fetch: the same 40 bytes
become 80 four-bit nibbles, each one wide pixel (4 output columns at
this renderer's 320-column playfield scale).  `%RENDER-GTIA-MODE`
implements the three modes:

- **Mode 9** (PRIOR $40): nibble replaces COLBK's luminance bits,
  keeping its hue -- `(COLBK & $F0) | nibble`.
- **Mode 10** (PRIOR $80): nibble selects a color register, 0-3 ->
  COLPM0-3, 4-7 -> COLPF0-3, 8 -> COLBK.  Those nine registers are
  contiguous in the write window ($12-$1A), so the nibble indexes them
  directly -- the same decode the hardware does.  Nibbles 9-15 clamp to
  COLBK (**CONFIRM** pending against Altirra/atari800).
- **Mode 11** (PRIOR $C0): nibble supplies the hue, COLBK the
  luminance -- `(nibble << 4) | (COLBK & $0F)`.  Nibble 0 is hue 0 at
  COLBK's luminance, which is why mode 11 cannot display black unless
  COLBK's luminance is 0 (pinned by a test).

The mode is read per scanline, so a DLI rewriting PRIOR switches modes
mid-frame; a test renders two rows under different PRIOR values to pin
that.  GTIA bits set on a non-F ANTIC mode render that mode normally
(hardware emits garbage there; not modelled).  GTIA-mode pixels carry
mode F's PF2 source tag for Phase 6b priority arbitration -- mode 10's
COLPM0-3 selections do not carry player priority as they would on
hardware (documented).

Known limitation, newly pinned by `GTIA-MODE-9-LUMINANCE-PAIRS-COLLAPSE`:
this project's palette is 128 entries indexed by `(color >> 1)`, so
mode 9's 16 nibble values collapse to 8 luminances in pairs.  The color
bytes produced are hardware-correct; widening the palette to 256
entries is the only change needed to recover all 16 shades.

## ROADMAP Phase 6 -- P/M DMA, full GTIA priority, GTIA cleanups

Three commits.

**6a -- ANTIC fetches P/M graphics into GTIA.**  Previously ANTIC stole
P/M DMA cycles but never fetched data; GRAF registers only changed when
software poked them.  `%FETCH-PM-GRAPHICS` now reads one byte per
enabled object per scanline (8-247) from P/M RAM and delivers it
through ANTIC's new `PM-WRITE-FN` closure slot, which
`MAKE-ATARI-MACHINE` wires into GTIA's GRAFP0-3/GRAFM gated on GRACTL
(players bit 1, missiles bit 0) -- DMACTL causes the fetch and the
cycle steal, GRACTL decides whether GTIA latches the bytes.
Single-line addressing: base = (PMBASE & $F8) << 8, missiles at
+$300+scanline, player p at +$400+$100p+scanline; double-line: base =
(PMBASE & $FC) << 8 (1K boundary -- the ROADMAP's from-memory formula
said $F8 for both), missiles at +$180+(scanline>>1), player p at
+$200+$80p+(scanline>>1).  VDELAY is out of scope (documented).

**6b -- Full PRIOR priority, fifth player, multicolor players.**  The
playfield renderers now record a per-column source tag (BAK/PF0-3)
into a GTIA-owned `PF-TAG-ROW` scratch (only on rows with active P/M
objects), and `%RENDER-PM-LAYER` arbitrates each covered column's
highest-priority player channel against that tag using the four PRIOR
bit 0-3 orderings (`+PM-BEATS-PF-MASKS+`).  Missile m has player m's
priority and color; PRIOR bit 4 instead renders all missiles as
playfield 3 (COLPF3 + PF3 tag -- the atari800 fifth-player model);
PRIOR bit 5 ORs COLPM0|COLPM1 / COLPM2|COLPM3 on overlap.  Zero or
multiple select bits fall back to bit-0 / lowest-bit behaviour (real
GTIA color-merges conflicts -- documented simplification).  Bits 6-7
(GTIA modes) are Phase 7.

**6c -- GTIA cleanups** (MISC_IMPROVEMENTS_PLAN items 6 + 7).  The PAL
register ($D014) now reads $0F on NTSC (atari800 gtia.c encoding; bits
1-3 all-ones = NTSC).  The old value of 1 answered "PAL" to the
documented AND #$0E region probe.  The read-side reset defaults are
deduped into one `%INIT-READ-REGS` shared by construction and
`RESET-GTIA`.

Suite grows to 1906 checks, green on both implementations.

## Renderer: per-character color-pair hoisting in char modes

After the P/M fix, glyph rendering was the display frame's dominant
term (71% SBCL / 60% LispWorks): `%render-char-mode` dispatched on the
ANTIC mode and did three palette lookups (via `%write-rgb`) for every
one of 61,440 glyph pixels per frame.  A character row only ever has
two colors -- glyph-on and glyph-off, both fixed per character -- so
both RGB triples are now resolved once per character (six palette
lookups instead of 24-48) and the inner 8-bit loop just stores bytes.
New tests pin the previously-untested attribute paths (mode-2 inverse
and alternate video, mode-6 wide chars + color select from the char's
top bits) before the rewrite.

Measured (display, mean of 3): SBCL 1124.8 -> 1931.6 fps (+72%; 3.68x
vs. the 525.5 before this optimization pass), LispWorks 255.2 -> 332.0
fps (+30%; 4.97x vs. 66.7, now ~5.5x realtime). Suite 1853/1853 green
on both implementations.

## Renderer: span-based P/M compositing + border-only background fill

A decomposition of the new `display` bench workload showed P/M
compositing eating 52% (SBCL) / 67% (LispWorks) of a display frame's
entire cost WITH NO P/M OBJECTS ENABLED: `%render-pm-layer` made a
non-inlined `%pm-pixel-color` call for every one of 384x240 = 92,160
pixels per frame, each re-reading all 8 objects' loop-invariant
HPOS/SIZE/GRAF registers.

- `%render-pm-layer` rewritten span-based: each enabled object paints
  its own <= 32-column span, lowest-priority first (M3..M0, P3..P0), so
  the highest-priority color lands on top -- bit-for-bit the same output
  as the per-pixel arbitration (new tests pin overlap priority, player
  sizing, missile geometry/colors, and edge clipping). A row with all
  GRAF registers zero exits after five register reads.
- `render-scanline` floods only the two 32-column borders when a
  playfield renderer will cover the 320 active columns anyway (the full
  384-pixel flood was overwritten immediately on every playfield line).
- `src/renderer.lisp` now carries the same explicit hot-path
  `(declaim (optimize (speed 3) (safety 1) (debug 1)))` as the other
  hot files instead of relying on the policy leaking from earlier
  files in the serial build (~8% on LispWorks when recompiled alone).

Measured (display workload, mean of 3): SBCL 525.5 -> 1124.8 fps
(2.14x), LispWorks 66.7 -> 255.2 fps (3.82x, from ~1.1x realtime to
~4.3x). nop/irq/klaus unchanged within session noise. Suite 1842/1842
green on both implementations.

## Phases 1-5 review fixes (3) -- display bench workload + misc hardening

Closes out the remaining recommendations from the Phases 1-5 review:

- `scripts/bench.lisp`: new `display` workload -- the NOP sled with a
  24-line mode-2 display list fetched by ANTIC (DMACTL $22) and the
  pixel renderer attached through the scanline callback, exactly as
  the AESP server wires it. Until now no bench workload ever enabled
  DMACTL, so the DMA-active steal accounting + per-line render path
  (what display programs and A/V capture actually run) was unmeasured.
  In the default workload list; both bench scripts pick it up.
- `scripts/fetch-test-roms.sh`: the download is now verified against a
  pinned sha256 (the binary the suite was validated with) instead of
  merely echoing a checksum; a mismatched download is discarded, a
  mismatched pre-existing file gets a warning.
- `tests/test-compat.lisp`: `chmod-file-actually-changes-mode` verifies
  CHMOD-FILE really changes permission bits (write-denied at #o400,
  allowed again at #o600) -- the LispWorks FLI chmod(2) binding from
  ROADMAP Phase 1 previously had no effect-level test.
- `CLAUDE.md` benchmarking section now documents all four workloads
  (`klaus` had never been added, `display` is new).

## Phases 1-5 review fixes (2) -- WSYNC stall edge cases

Two scheduler-level WSYNC defects found in the Phases 1-5 review:

- The stall clamp in `%RUN-CLOCKS` was `(setf cpu-budget 0)`, which
  FORGAVE a negative budget: when the `STA WSYNC` instruction itself
  overshot the line's remaining budget (it can enter with 2-3 cycles
  left and costs 4+), the borrowed cycles were erased and the CPU got
  them free on the next line. Now `(setf cpu-budget (min cpu-budget 0))`
  -- surplus still cannot leak past the stall, but a deficit carries.
  Regression test pins the exact two-line cycle ledger (209, not 211).
- A WSYNC flag armed OUTSIDE the scheduler (a debugger poke of $D40A,
  or `MACHINE-TRACE-STEP` executing a store) used to stall the first
  line of the next `%RUN-CLOCKS` call. The flag is now consumed on
  entry: out-of-band writes have no scanline context to stall against.
  Regression test covers the bus-poke case.
- Also: the `DEC WSYNC` NMOS double-write out-of-scope note ROADMAP
  Phase 3 asked for is now actually in `src/antic.lisp`, and
  `ANTIC-BEGIN-SCANLINE`'s docstring lists the full steal components
  (it still described the pre-Phase-5 refresh + P/M only lump).

## Phases 1-5 review fixes (1) -- map-mode geometry + DMA table corrected to hardware

Reverses the ROADMAP Phase 5 deviation, which ran the wrong way: the
SCANLINE_ACCURACY_PLAN.md byte table was RIGHT (pixel width x bpp / 8
per mode, per the Altirra Hardware Reference), and the RENDERER's
map-mode geometry was the divergent component the steal tables then
inherited.

- `BYTES-PER-SCREEN-ROW` (`src/antic.lisp`, now exported) is the single
  hardware byte table: modes 2-5 -> 40, 6-7 -> 20, 8-9 -> 10, A-C -> 20,
  D-F -> 40. `PLAYFIELD-DMA-CYCLES`, the renderer, and the end-of-line
  screen-pointer advance all derive from it and can no longer disagree.
- Map modes (8-F) now fetch screen bytes on the FIRST scanline of a
  mode line only -- ANTIC line-buffers them and replays the buffer on
  the remaining scanlines (0 steal), matching hardware. Previously
  every scanline was charged AND the screen pointer advanced every
  scanline, so a mode-8 mode line consumed 320 bytes instead of 10.
- `%RENDER-BITMAP-MODE` (`src/renderer.lisp`) rewritten to hardware
  geometry: mode 8 = 10 bytes 2bpp (40 px x 8 columns), 9 = 10 bytes
  1bpp, A = 20 bytes 2bpp, D/E = 40 bytes 2bpp (previously e.g. mode 8
  was drawn as 40 bytes of 1bpp and mode E stopped at 20 bytes). 1bpp
  map pixels now use COLPF0 (modes 9/B/C; B/C previously used COLPF2).
  Mode F's simplified artifact-free output is unchanged (GTIA-mode
  work, ROADMAP Phase 7).
- New renderer tests pin modes 8/9/E geometry and registers; a new
  end-to-end test renders a full mode-2 frame through the machine
  scheduler with DMA stealing active (the render test ROADMAP Phase 5
  listed but never landed); an ANTIC test pins the line-buffer
  behaviour (render pointer constant across a mode-8 line, screen
  pointer +10 after it).
- `src/antic.lisp`'s header no longer claims real ANTIC packs fetches
  "2 bytes per DMA slot" (it doesn't; one byte per slot, and the char
  mode counts always did match hardware). ROADMAP.md and
  SCANLINE_ACCURACY_PLAN.md status headers corrected -- they asserted
  the plan table "turned out to be wrong", which was false.

Suite: 1832/1832 checks green on both SBCL and LispWorks.

## ROADMAP Phase 5 -- playfield DMA steal + DL fetch accounting

SCANLINE_ACCURACY_PLAN.md Phase 3: the largest remaining timing error
in `%RUN-CLOCKS`'s per-line steal was that only DRAM refresh (9) and
P/M DMA (0-5) were charged, ignoring the ~20-96 cycles/line real
character and bitmap modes steal for their own data.

- New `PLAYFIELD-DMA-CYCLES (mode-byte dmactl first-line-p)` in
  `src/antic.lisp`: character modes (2-7) charge NAME+FONT bytes on
  the first scanline of a mode line and FONT-only on later scanlines;
  bitmap modes (8-F) charge a fresh row every scanline (matching
  `%RENDER-BITMAP-MODE`'s own per-scanline re-fetch). Byte-per-line
  counts are cross-checked against this project's own tested renderer
  code, not recalled independently -- they diverge from
  SCANLINE_ACCURACY_PLAN.md's original from-memory table for modes
  8-14, which the renderer's implementation contradicts (see the
  function's docstring for the full reasoning).
- `process-dl-instruction` now returns the number of DL bytes it
  consumed (1 for a plain mode byte, +2 for an LMS address, +2 for a
  JMP/JVB address); `%begin-scanline-events` charges that count plus
  `PLAYFIELD-DMA-CYCLES` (gated on `%DISPLAY-ACTIVE-P`, since
  `CURRENT-MODE` can hold a leftover value outside the active region)
  into the line's total steal, on top of the existing refresh + P/M
  DMA.
- New frame-level regression test builds a 24-line mode-2 display list
  + JVB, runs one frame, and checks that CPU cycles consumed match a
  scanline-by-scanline expected-steal computation built from the same
  functions the scheduler uses (a conservation check, not a hand-typed
  magic number) -- pins the whole model end to end.

Suite: 1784/1784 checks green on both SBCL and LispWorks. Benchmarked:
no measurable change on the standard bench workloads (none of them
enable DMACTL, so the new accounting never runs beyond its early-exit
guards) -- see `PERFORMANCE_LOG.md`.

## ROADMAP Phase 4 -- raster-bars demo + rendered acceptance test

The EdVenture payoff for Phase 3's WSYNC: `asm/edvent02_rasterbars.asm`
is a minimal MADS demo that waits for the top of the display then
loops `STA WSYNC` / `STA COLBK` / advance-hue for 64 lines every frame,
producing 64 distinct horizontal color bands (visually confirmed via
`scripts/mads-build.sh` + `scripts/atari-run.sh` screenshot capture).

Added a machine-level regression test
(`wsync-raster-bars-render-as-distinct-rows`) that pokes the same
WSYNC/COLBK loop into a synthetic-ROM machine, wires
`ATARI-MACHINE-SCANLINE-FN` to `RENDER-SCANLINE` exactly as the AESP
server does, and asserts a run of >= 32 consecutive rendered rows with
strictly different background colors -- pinning WSYNC, the scanline
callback's firing point, and per-line register latching together
end-to-end through the real renderer.

Suite: 1720/1720 checks green on both SBCL and LispWorks.

## ROADMAP Phase 3 -- WSYNC ($D40A)

SCANLINE_ACCURACY_PLAN.md Phase 2: `STA WSYNC` now halts the CPU for
the rest of the current scanline, the single most important register
for scanline-accurate software (every DLI handler starts with it).

- `src/antic.lisp`: new `WSYNC-PENDING` struct slot, armed by
  `ANTIC-WRITE`'s `$D40A` case, read-and-cleared by the new
  `ANTIC-CONSUME-WSYNC`. Scheduler-only -- the per-cycle `ANTIC-TICK`
  reference path never calls it, so WSYNC has no effect there.
- `src/machine.lisp` `%RUN-CLOCKS`: after every instruction, checks
  `ANTIC-CONSUME-WSYNC` and, if armed, clamps `CPU-BUDGET` to 0 and
  ends the line's instruction loop. POKEY still advances through the
  skipped remainder via the existing per-line top-up step. First cut:
  stalls to end-of-line rather than the hardware-accurate cycle 105
  (that refinement is SCANLINE_ACCURACY_PLAN.md's stretch Phase 4).
- Back-to-back `STA WSYNC` correctly stalls a full extra scanline
  (verified by a dedicated regression test), matching real hardware.

Suite: 1719/1719 checks green on both SBCL and LispWorks (11 new
checks: 3 unit tests + 2 machine-level regression tests, one with
multiple assertions). Benchmarked: the per-instruction check is
effectively free (+/-0.4-1.2%, within run-to-run noise) -- see
`PERFORMANCE_LOG.md`.

## ROADMAP Phase 2 -- rename color clocks to CPU cycles

SCANLINE_ACCURACY_PLAN.md's previously-skipped Phase 0. The 114-unit
ANTIC and the machine scheduler use per scanline is CPU cycles, not
color clocks (a real NTSC line is 228 color clocks at twice the CPU
rate; hardware references quote cycle positions 0-113). Renamed
`+color-clocks-per-scanline+` -> `+cpu-cycles-per-scanline+` and the
`antic` struct slot/accessor `color-clock`/`antic-color-clock` ->
`line-cycle`/`antic-line-cycle` throughout `src/` and `tests/`, and
reworded the surrounding comments/docstrings. Pure rename -- no
behaviour change.

Suite: 1708/1708 checks green on both SBCL and LispWorks (unchanged
count, confirming no behaviour change).

## ROADMAP Phase 1 -- cheap hardening batch

Four independent fixes from `MISC_IMPROVEMENTS_PLAN.md`:

- **Opcode-table reload robustness** (item 1) -- `*OPCODE-TABLE*` and
  `*OPCODE-MNEMONIC-TABLE*` are now load-time `DEFVAR`s in `cpu.lisp`;
  `DEFOPCODE` writes directly into them instead of through a temporary
  `*OPCODE-TABLE-BUILDER*` bulk-installed at end of file. Reloading
  `cpu-opcodes.lisp` alone in a live image no longer silently drops
  `illegal.lisp`'s 105 handlers.
- **Reset flag consistency** (item 2) -- `machine-cold-reset` now sets
  P to `#x24` (U=1, I=1), matching `reset-cpu`; it previously set
  `#x34`, disagreeing about the phantom B bit (not a real register bit
  outside a pushed stack copy).
- **LispWorks `chmod-file` via FLI** (item 8) -- replaced the
  `/bin/chmod` shell-out with a direct `fli:define-foreign-function`
  binding to `chmod(2)`, following the existing `%getpid` pattern.
- **`scripts/fetch-test-roms.sh`** (item 3) -- downloads the prebuilt
  Klaus Dormann functional-test binary into `roms/` (gitignored,
  no-ops if already present), unblocking that test without a manual
  build step.

Suite: 1708/1708 checks green on both SBCL and LispWorks.

## Branch consolidation -- everything back on main

The `atari800-cl-perf-ph3-scanline` (performance + scanline scheduler)
and `pixel-renderer` feature branches were merged into `main` and
deleted, along with their worktrees.  The one real integration point:
the renderer's per-line bookkeeping (screen-pointer snapshot at line
start, screen-pointer/scan-y advancement at line end) moved into the
shared `%BEGIN-SCANLINE-EVENTS` / `%END-SCANLINE-EVENTS` helpers, so
both the per-cycle `ANTIC-TICK` reference path and the scanline-granular
scheduler carry rendering support, and the machine's per-scanline render
callback now fires right after `ANTIC-END-SCANLINE` closes each full
line.  Combined-tree benchmarks logged in `PERFORMANCE_LOG.md` (2-6%
below the renderer-less scheduler rows; the scheduler's gains dwarf it).
The `minimal-xl` submodule was bumped to `phase-1-bringup`: the minimal
OS now assembles to a loadable XEX (`OPT h+`, `run RESET`) and gained
`run.sh`, a one-shot assemble/run/screenshot script.

Suite: 1450/1450 checks green on both SBCL and LispWorks.

## Pixel renderer + AESP video frames + screenshot capture

- `src/renderer.lisp` -- `:atari800-cl.renderer`: converts ANTIC
  display-list state + GTIA registers into a 384x240 24-bit RGB
  framebuffer, one scanline at a time (background flood, 320-pixel
  playfield for modes 2-F, player/missile compositing with PRIOR
  priority arbitration, NTSC hue/luminance palette).
- ANTIC gained the renderer's screen-data plumbing: LMS addresses are
  latched into `SCREEN-DATA-PTR`, snapshotted per line for the
  renderer, and advanced per scanline (bitmap modes) or per character
  row (character modes) with a `SCAN-Y` row counter.
- `atari-machine` gained `SCANLINE-FN` / `POST-FRAME-FN` callback
  slots; the AESP server uses them to render into its framebuffer and
  push completed frames to video subscribers as `VIDEO_FRAME` (0x65)
  messages after `FRAME_CONFIG`.
- `scripts/capture-screenshot.py` subscribes to the AESP video port
  and saves a frame as PNG (PPM fallback without Pillow);
  `scripts/atari-run.sh` wires it into the XEX run workflow.
- `minimal-xl/` added as a git submodule: a minimal XL OS used for
  emulator bring-up against real display output.

## MADS assembly toolchain

- `asm/hello.asm`, `asm/edvent01.asm` -- example 6502 programs in MADS
  syntax.
- `scripts/mads-build.sh` / `scripts/mads-run.sh` -- assemble MADS
  sources to XEX and run them in the emulator.
- `scripts/runner.lisp` + `scripts/xex-loader.lisp` -- load a XEX into
  machine RAM segment-by-segment and run it for N frames from the
  shell (`scripts/atari-run.sh`).

## Scanline-granular scheduler (SCANLINE_ACCURACY_PLAN Phase 1)

- `%RUN-CLOCKS` restructured from per-clock to per-scanline: ~260
  `ANTIC`/`POKEY` calls per frame instead of ~60,000.
  `ANTIC-BEGIN-SCANLINE` fires the line's events (VBI/DLI, DL fetch)
  and reports stolen cycles; the CPU executes whole instructions
  against the line's remaining budget with `POKEY-ADVANCE` alongside;
  `ANTIC-END-SCANLINE` closes the line.  `ANTIC-TICK` remains as the
  single-cycle reference path, built on the same shared event helpers.
- Accuracy correction included: the old loop granted the CPU 113
  cycles/line regardless of the real steal; the scheduler charges the
  full per-line steal (105 cycles/line at the default 9-cycle refresh
  + P/M steal).
- Result (vs. Phase 3, mean of 3): SBCL klaus 1954 -> 3381 fps;
  LispWorks irq 626 -> 1607 fps.  Full rows in `PERFORMANCE_LOG.md`.

## Performance Phases 1-3 (PERFORMANCE_PLAN)

- **Phase 1** -- `(optimize (speed 3) (safety 1) (debug 1))` + `ftype`
  declarations on the hot path (bus, CPU, chips).  LispWorks nop
  250 -> 653 fps; SBCL nop 1961 -> 2339 fps.
- **Phase 2** -- page-dispatch table for `BUS-READ`/`BUS-WRITE`:
  implemented, measured, **rejected** (LispWorks regressed up to
  5.6%; the COND chain already short-circuits cheaply).  Not merged;
  details in `PERFORMANCE_LOG.md`.
- **Phase 3** -- POKEY batched advance: `POKEY-ADVANCE` skips ahead to
  the next timer-expiry event and the 17/9-bit RNG shifts lazily on
  RANDOM reads; `POKEY-TICK` keeps a flat per-cycle loop (the
  batching bookkeeping costs more than it saves at N = 1), with a
  50,000-cycle equivalence test pinning the two paths together.
- Klaus Dormann functional test added as a `klaus` benchmark workload.

## Frame-rate benchmark harness (PERFORMANCE_PLAN Phase 0)

- `scripts/bench.lisp` -- portable `:atari800-cl.bench` package building
  the machine with an inlined synthetic OS ROM (no real ROM images
  needed).  Two workloads: `nop` (a NOP sled that loops back via a JMP
  placed below the vector region) and `irq` (a busy loop that arms POKEY
  timer 1, enables IRQs, and fields a bare-`RTI` handler).  Runs 60
  warm-up + 600 timed frames and prints one
  `BENCH <workload> frames=600 seconds=... fps=... realtime-x=...` line per
  workload.  Tune via `*warmup-frames*` / `*measured-frames*`.
- `scripts/bench-sbcl.sh` / `scripts/bench-lispworks.sh` (+ the
  `-lispworks.lisp` driver) mirror the test runners' sandbox/ASDF/
  `mp:initialize-multiprocessing` handling.  Exit 0 on completion.
- `PERFORMANCE_LOG.md` records the baseline from both implementations;
  every optimization commit must add before/after rows.
- `CLAUDE.md` gained a "Benchmarking" section pointing at the scripts
  and stating the log-update rule.

Suite untouched; harness runs clean on both SBCL and LispWorks.

## AESP + CLI protocol servers

External GUI/CLI/web clients can now drive the headless emulator over two
socket protocols (compatible with the Attic project's `PROTOCOL.md`).
Built in stages (see `AI-Docs/AESP-CLI-Implementation-Stages.md`):

- **Foundation** -- `usocket` + `flexi-streams` re-added; `compat.lisp`
  gained process-id / chmod / file-delete and Unix-domain socket helpers
  (`sb-bsd-sockets` on SBCL, an FLI `AF_UNIX` wrapper on LispWorks, since
  usocket has no local-socket support), plus condition-variable and
  thread-lifecycle wrappers.
- **Host input** -- `atari800-cl.input`: a mutex-guarded input-state for
  joystick/console/paddle/keyboard, delegated to from PIA/GTIA/POKEY reads
  when attached.
- **Concurrency core** -- `atari-machine` gained a command mailbox, a
  background `machine-run-loop` (+ `start-machine`/`stop-machine`), and
  `machine-submit` so non-emulator threads mutate the machine safely.
  `machine-run-frame` was refactored over a new `%run-clocks` helper
  (correctness-neutral).
- **AESP** (`atari800-cl.aesp`) -- 8-byte big-endian binary protocol
  (magic `0xAE50`); pure codec + a 3-port (control/video/audio) TCP
  server covering ping/pause/resume/reset/status/info, input events, and
  video/audio subscribe->config.
- **CLI** (`atari800-cl.cli-socket`) -- `CMD:<verb>` -> `OK:`/`ERR:` text
  protocol over a Unix socket: ping/version/pause/resume/step/reset/
  status/read/write/fill/registers/quit.
- **Facade** -- `a800:start-machine`/`stop-machine`,
  `start-aesp-server`/`stop-aesp-server`, `start-cli-socket`/
  `stop-cli-socket`.

Suite grew from 1254 to 1398 checks, green on both SBCL and LispWorks.

## Public facade now drives the full machine; legacy emulator removed

- The `:atari800-cl` (`a800`) facade was rewired from the bare
  CPU+memory `atari800-cl.emulator` bundle to the full
  `atari800-cl.machine:atari-machine` (CPU + bus + MMU + PIA + ANTIC +
  GTIA + POKEY). New `RUN-FRAME` / `MACHINE-FRAME-COUNT` entry points.
- With nothing left referencing it, the `atari800-cl.emulator` package
  was deleted: removed `src/emulator.lisp`, its `defpackage`, the ASDF
  component, and the test package's `:use` of it.

## Removed the headless IPC layer

- Deleted `src/ipc.lisp`, `tests/test-ipc.lisp`, the `atari800-cl.ipc`
  package, and the now-unused `usocket` / `flexi-streams` dependencies.
  The Unix-domain-socket streamer added in Phase 12 (below) is gone;
  a downstream renderer should instead drive `MACHINE-RUN-FRAME` and
  read the program-visible chip state directly after each frame.

## Phase 14 -- Repository handoff (Prompt 14)

- Comprehensive README rewrite: project status, dependency table with
  versions, SBCL + LispWorks setup with SLIME/Sly, full-suite
  invocation per platform, ROM acquisition + boot-toward-BASIC walk-through,
  IPC wire protocol, and a "Known limitations" section that names
  every area still stubbed.
- This file (`CHANGES.md`) -- phase-level changelog.
- Docstring audit and type declarations on the hot paths.

## Phase 13 -- Test harness audit + CI commands (Prompt 13)

- New `tests/test-helpers.lisp`: shared `%POKE` (NOTINLINE),
  `%MAKE-SYNTHETIC-OS-ROM`, `%MAKE-SYNTHETIC-BASIC-ROM`,
  `MAKE-TEST-MACHINE`, `WITH-CPU-STATE` macro.
- New `tests/test-regressions.lisp` with 5 pinned-bug tests:
  high-address `BUS-PEEK-RAM`, KIL-in-frame doesn't crash, no I/O leak
  to RAM, DLI fires once per mode-line, PORTB write flips bank mapping
  immediately.
- README CI section with SBCL + LispWorks one-liners that propagate
  test-failure exit codes.
- Total checks at end of phase: **1263 / 1263 pass**.

## Phase 12 -- Headless IPC layer (Prompt 12)

- `src/ipc.lisp` adds an *optional* Unix-domain-socket server that
  spawns a `bordeaux-threads` background thread, accepts one client,
  and pushes a 56-byte wire frame after every `MACHINE-RUN-FRAME`.
- Wire protocol: 4-byte magic `"A8XL"`, u32 frame number, u16
  scanline, 6 reserved bytes, 32 bytes of GTIA write registers, 8
  bytes of POKEY AUDF/AUDC. README documents byte offsets.
- Test coverage includes a real loopback exchange (client connects,
  receives a frame, decodes the header) plus thread-lifecycle tests.

## Phase 11 -- ROM loading + boot-toward-BASIC instrumentation (Prompt 11)

- `MACHINE-COLD-RESET` accepts byte arrays or file paths for OS + BASIC.
- New REPL helpers: `MACHINE-TRACE-STEP` (returns N execution
  snapshots with mnemonic strings), `MACHINE-PORTB-STATE`,
  `MACHINE-SCANLINE`, `MACHINE-PENDING-INTERRUPTS`.
- `*OPCODE-MNEMONIC-TABLE*` populated alongside `*OPCODE-TABLE*` by
  `DEFOPCODE` so tracing decodes opcodes without a separate disassembler.
- README "Running toward BASIC" walk-through plus a ROM-image table
  with sizes and md5 hashes.

## Phase 10 -- IRQ routing + machine scheduler (Prompt 10)

- `src/irq.lisp`: `CHECK-AND-DISPATCH-NMI` / `CHECK-AND-DISPATCH-IRQ`
  wrappers around the newly-exported `SERVICE-NMI` / `SERVICE-IRQ`.
- `src/machine.lisp`: `ATARI-MACHINE` defstruct owning every chip,
  `MAKE-ATARI-MACHINE` wires all chip dispatch closures into the bus
  and points the CPU's bus hooks at the bus.
- `MACHINE-RUN-FRAME` pumps 29,868 NTSC color clocks, services
  interrupts on every clock, runs the CPU when budget allows, and
  catches `ILLEGAL-OPCODE` on KIL so the frame loop never dies.
- The legacy `atari800-cl.emulator` package stays in place for
  backward-compat.

## Phase 9 -- POKEY (Prompt 9)

- Timer model with per-channel divider (28-cycle 64 kHz default,
  114-cycle 15 kHz, 1-cycle 1.79 MHz for channels 1 and 3).
- IRQEN/IRQST latches with active-low semantics; writing IRQEN
  restores ack'd bits.
- Two LFSRs (17-bit and 9-bit) clocked every `POKEY-TICK`;
  `POKEY-RANDOM` picks one based on AUDCTL bit 7.
- Stub I/O for paddles, ALLPOT, SKSTAT, serial.

## Phase 8 -- GTIA (Prompt 8)

- Split write/read register windows at `$D000-$D0FF`.
- Cold-reset defaults: TRIG0-3 = 1, PAL = 1 (NTSC), CONSOL = 7.
- `GTIA-RECORD-COLLISION` takes keyword identifiers and OR's the
  correct bit into the correct collision register, including the
  symmetric P{a}P / P{b}P latching for player-player collisions.
- `HITCLR` clears the 16-byte collision area only; triggers / PAL /
  CONSOL stay intact.

## Phase 7 -- ANTIC (Prompt 7)

- Scanline-oriented engine: 262 lines x 114 color clocks (NTSC).
- DRAM refresh (9 cyc / line) + P/M DMA (+1 missile, +4 player)
  lumped at color-clock 0 of each scanline.
- Display-list parsing: mode 0 (N+1 blank lines), mode 1 (JMP / JVB),
  modes 2-F with per-mode scanline counts, LMS modifier (bit 6), DLI
  bit (bit 7) gated by NMIEN bit 7.
- VBI at scanline 248 (NMIEN bit 6).

## Phase 6 -- PIA (Prompt 6)

- 6520 PIA shadow with PORTA / DDRA / PORTB / DDRB at `$D300-$D303`,
  (register map corrected later -- see "PIA register map fix" above;
  `$D302`/`$D303` are really PACTL/PBCTL,)
  mirrored across the page by `(addr & $03)`.
- PORTB write propagates to `MMU-WRITE-PORTB` for immediate
  bank-switching.

## Phase 5 -- Bus + MMU (Prompt 5)

- `atari800-cl.mmu`: PORTB shadow + `os-rom-mapped-p`,
  `basic-rom-mapped-p`, `selftest-mapped-p` predicates.
- `atari800-cl.bus`: 64 KiB RAM + ROM overlays + per-chip dispatch
  closure slots.  ROM reads dispatch through the MMU; I/O writes
  reach chips via attached closures and NEVER leak to RAM.
- `BUS-PEEK-RAM` / `BUS-POKE-RAM` (NOTINLINE) escape the SBCL/arm64
  large-constant-offset codegen bug.

## Phase 4 -- Illegal opcodes (Prompt 4)

- 105 NMOS-specific undocumented opcodes: compound RMW (SLO, RLA,
  SRE, RRA, DCP, ISC), LAX, SAX, ANC, ALR, ARR, XAA (unstable), AXS,
  LAS, TAS / AHX / SHX / SHY (unstable stores), SBC duplicate, 27
  multi-byte / extra NOPs, 12 KIL/JAM/STP halt opcodes.
- `documented-opcodes` filters them against `*illegal-opcode-list*`
  so the legacy "151 documented" count stays accurate.

## Phases 1-3 -- Scaffold / CPU / Documented opcodes

Bootstrap commits (pre-Prompt-5).  Repository layout, compat layer,
flat memory model, 6502 register file, addressing-mode helpers, all
151 documented opcodes via the `DEFOPCODE` macro family, Klaus
Dormann 6502 functional-test fixture.

See `AI-Docs/AI-Prompts.md` for the per-phase prompt text.
