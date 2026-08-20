# Roadmap -- EdVenture-first accuracy, rendering, and audio

> **Status (2026-08-02): Phases 1-5 done and committed to main** (suite
> green on both implementations throughout; benchmarked at each
> hot-path phase -- see `PERFORMANCE_LOG.md`). **Post-phase correction
> (2026-08-02):** Phase 5 originally rejected `SCANLINE_ACCURACY_PLAN.md`'s
> map-mode (8-14) byte table in favor of this project's own renderer --
> that call was backwards. The plan's table matched real hardware
> (each mode's pixel width x bits per pixel / 8); it was the RENDERER
> whose map-mode geometry was wrong (mode 8 drawn as 40 bytes of 1bpp
> instead of 10 bytes of 2bpp, mode E as 20 bytes instead of 40, etc.).
> A follow-up commit restored the hardware byte counts, fixed the
> renderer's map-mode geometry/colors to match, and made map modes
> fetch on the first scanline of a mode line only (ANTIC line-buffers
> them), per the Altirra Hardware Reference.
>
> **Phase 6 done (2026-08-02)**, three commits as planned: ANTIC P/M
> DMA into GTIA (double-line PMBASE masks #xFC, not this document's
> #xF8 -- 1K boundary per the Altirra HRM), full PRIOR priority via
> GTIA-owned playfield source tags (fifth player = missiles rendered
> as playfield 3, the atari800 model; multicolor OR; the priority
> orderings below still carry their CONFIRM flag), and the GTIA
> cleanups (PAL register now the $0F NTSC pattern; reset defaults
> deduped).
>
> **Phase 7 done (2026-08-03)**: GTIA color modes 9/10/11 render over
> ANTIC mode F, selected per scanline from PRIOR bits 6-7. Mode 10's
> nibbles 9-15 (clamped to COLBK) keep this document's CONFIRM flag.
> One limitation newly pinned by test: the 128-entry palette collapses
> mode 9's 16 luminances into 8 pairs -- the color bytes are
> hardware-correct, so a 256-entry palette would recover them.
>
> **Phase 8 done (2026-08-03)**: POKEY reload offsets (AUDF+4 at
> 1.79 MHz, +7 for linked pairs, AUDF+1 on the divided clocks) and
> linked 16-bit channels with the IRQ taken from the high channel.
> The period figures keep their CONFIRM flag -- implemented as this
> plan states them, recorded in `src/pokey.lisp`'s header.
> Phase 9 (POKEY audio synthesis) is next, and its frequencies now
> come out right the first time.
>
> **Phase 9 done (2026-08-03)**: `src/audio.lisp` synthesises four
> POKEY channels (poly4/5/9/17 distortion + volume-only mode) into
> mono 8-bit PCM at 44,744 Hz, attached on demand through function
> slots on the POKEY struct. Detached machines pay one slot read and
> branch per POKEY advance -- measured at ~4% on the `nop` workload
> (the maximum possible advance density: one advance per 2-cycle
> instruction) and within noise everywhere else, via an interleaved
> A/B against the pre-phase commit; see `PERFORMANCE_LOG.md`.
> **Phase 10 done (2026-08-03)**: AUDIO_PCM streams over the AESP audio
> port and `scripts/capture-audio.py` writes WAVs. Two deviations, both
> deliberate: the message code is the protocol's own `0x80` (this
> document's `#x85` was explicitly a fallback for "if the protocol
> defines none" -- `tools/protocol-comparison/protocol_spec.py` defines
> `AUDIO_PCM` = `0x80`), and the attach/detach decision is made by the
> post-frame hook on the emulator thread rather than in the
> subscribe path under the server lock, because acceptor threads must
> not touch the machine. Phase 11 (A/V recording tooling) is next.
>
> **Phase 11 done (2026-08-07)**: `scripts/record.sh` takes a `.asm` or
> `.xex` to an mp4 in one command; `scripts/capture-video.py` writes the
> numbered frame sequence and `scripts/aesp_client.py` now holds the
> protocol codec all three capture scripts share. `scripts/runner.lisp`
> also prints `AESP_AUDIO` -- the three ports are ephemeral and not
> adjacent, so recording needs it stated. Acceptance met: 300 frames of
> `asm/edvent02_rasterbars.asm` -> a 5.0 s 384x240 h264+AAC file;
> `--selftest` covers the 10-frame smoke case. Phase 12 (Tom Harte
> ProcessorTests harness) is next.
>
> **Phase 12 done (2026-08-07)**: `tests/test-harte.lisp` runs the
> SingleStepTests/65x02 vectors, env-gated on `ATARI800_CL_HARTE_TESTS`
> and skipping without them. It found three real CPU bugs, all fixed
> with regressions in `tests/test-regressions.lisp`: the unstable stores
> did not corrupt the destination address on a page cross, ARR ignored
> decimal mode, and JSR read its high operand byte before pushing rather
> than after (one case in 2.56M). XAA / LAX #imm now use the `$EE` magic
> constant the vectors encode, so the skip list stays EMPTY: all 256
> opcodes pass at full depth -- 2,560,000 cases, zero failures, on both
> implementations. That closes the original twelve-phase plan.
>
> **Next tranche added (2026-08-07): Phases 13-20.** With the EdVenture
> workflow shipped end to end (assemble -> boot -> capture -> mp4) and
> the CPU pinned by the Harte vectors, the emulator's remaining gaps are
> no longer about video content: the machine boots to BASIC but cannot
> be typed at, has no disk, and its bus-level timing is unverified.
> Phases 13-20 are ordered payoff-for-effort, not by theme; 13 is the
> recommended start (small, and it makes the machine interactive), 14
> and 15 are cheap hygiene, 16 is the next substantial feature.
>
> **Amended (2026-08-07) after a critique of the Phases 1-12 execution.**
> Ground rule 2 gains a strict gate (env-gated skips become failures on
> the machine that has the assets), rule 3 now prescribes
> `scripts/bench-ab.sh` (the interleaved A/B method that survived
> session drift, promoted from prose in `PERFORMANCE_LOG.md` to a
> command), and a new rule 9 makes the post-phase review and the
> cycle-ledger tests mandatory. Four phases appended: 21 (strict test
> gate + skip census), 22 (POKEY pending-work bitmask -- land BEFORE 13
> and 16a so their hooks join it), 23 (CONFIRM retirement), 24 (Acid800
> gate -- run before 17). Recommended order is now 21, 22, 13, 14/15/23,
> 24, 16, 17, then the rest as listed.
>
> **Phase 21 done (2026-08-11)**: `%SKIP-OR-FAIL` (`tests/test-helpers.lisp`)
> replaces the bare `SKIP` calls in the Klaus, Harte, and real-ROM boot
> tests; `$ATARI800_CL_STRICT=1` turns those skips into failures. Verified
> on this machine (Klaus binary and both ROM images present, no Harte
> checkout): lenient runs unchanged, strict runs execute and pass Klaus
> and both boot tests for real and fail only on the genuinely-absent Harte
> vectors, on both implementations. `RUN-TESTS` (`tests/test-suite.lisp`,
> now what both test scripts call) also prints a grep-able skip census
> after every run.
>
> **Phase 22 done (2026-08-14)**: `src/pokey.lisp` gains a `PENDING`
> fixnum consolidating the serial-transmitter and audio-attached checks
> (previously two independent slot reads on every `POKEY-TICK` /
> `POKEY-ADVANCE` call) into one slot read plus cheap `LOGTEST`s; bits 2
> and 3 are reserved for Phase 13's key-pending and Phase 16a's
> serial-rx. `POKEY-TICK-VS-ADVANCE-EQUIVALENCE` now runs the scripted
> 50,000-cycle comparison under all four bit combinations (neither,
> audio, serial, both), not just the all-zero case. Measured with the
> new `scripts/bench-ab.sh` against the pre-phase commit (rule 3):
> nothing regressed on either implementation; two clean improvements
> (LispWorks `nop` +8.5%, SBCL `audio` +8.9%), the rest positive but
> noisy at this sample size -- see `PERFORMANCE_LOG.md`.
>
> **Phase 13 done (2026-08-19)**: keyboard/BREAK IRQs claim `PENDING`
> bit 2 (`+POKEY-PENDING-KEY+`), set/cleared by `ATTACH-POKEY-INPUT`
> exactly like the audio bit -- a deliberate deviation from this
> document's literal "flag set through the input plumbing" wording (see
> the +POKEY-PENDING-KEY+ comment in `src/pokey.lisp`): having
> `INPUT-SET-KEY` write the bit directly would race the emulator
> thread's own clears of bits 0/1, a lost-update with no lock to stop
> it. The bit instead just gates whether `INPUT` is attached; the actual
> per-keystroke event lives in two new one-shot flags inside
> `INPUT-STATE`'s own lock (`INPUT-CONSUME-KEY-IRQ` /
> `-BREAK-IRQ`), drained every advance while attached -- safe because
> that only happens in real interactive use, never in a bench workload.
> `+IRQ-OTHER-KEY+` (`$40`) / `+IRQ-BREAK-KEY+` (`$80`) were confirmed by
> reading `TIRQ` in `Atari_XL_OS_Rev.2.asm` directly, not just taken
> from the plan; the plan's SKSTAT bit2/bit3 claim was checked the same
> way and turned out to be wrong -- the existing bit2-only
> implementation already matched the real OS's own VBI debounce logic
> (per `minimal-xl`'s documented phase 4), so `input-pokey-skstat` was
> left unchanged. The acceptance test (`REAL-OS-BOOTS-AND-TYPES-PRINT-2-
> PLUS-2`) types real POKEY key codes -- read from the OS's own TCKD
> table, verified empirically against the real ROM -- through an
> attached `INPUT-STATE` after booting to `READY`, and asserts `4`
> lands in screen memory once BASIC evaluates `PRINT 2+2`. Not
> benchmarked fresh: the new code path is strictly inside `PENDING`'s
> nonzero branch, gated by a bit no bench workload ever sets, so it is
> provably zero-cost in every measured workload by construction: a live
> `bench-ab.sh` attempt was abandoned when the host's load average hit
> 74 from unrelated activity. Phase 14 (`fetch-harte.sh`) is next per
> the recommended order, alongside 15/23.

A complete, ordered execution plan covering the four open work streams:
scanline accuracy (WSYNC, DMA stealing), renderer fidelity (P/M DMA,
priority, GTIA modes), POKEY audio synthesis + streaming, and the
miscellaneous hardening items. Ordered for the **EdVenture video
workflow**: the near-term goal is producing assembly-programming video
content, so phases that unlock visible/audible demo material (raster
effects, correct visuals, sound, A/V capture) come before pure
correctness ratchets.

This plan is written to be executed phase-by-phase by an AI coding
agent without further design input. Each phase states its goal, exact
steps, tests, verification commands, and commit message. Where a
hardware number is marked **CONFIRM**, cross-check it against the
Altirra Hardware Reference Manual or the atari800 emulator source if
possible; if you cannot verify it, implement the value as stated here
and say so in the commit message.

## Ground rules (apply to every phase)

1. Read `CLAUDE.md` first. Key constraints: no reader conditionals
   outside `src/compat.lisp`; `defstruct` over `defclass`; verbose
   docstrings on exported symbols; the `.asd` is `:serial t` so file
   order matters.
2. After every phase run BOTH `./scripts/test-sbcl.sh` and
   `./scripts/test-lispworks.sh`. Both must exit 0 before committing.
   The suite currently passes 2058 checks plus 1 skip on both (the skip
   is the Harte test with no vector data present; 2315 checks with it).
   Once Phase 21 lands, also run `ATARI800_CL_STRICT=1
   ./scripts/test-sbcl.sh` on this machine: strict mode turns the
   env-gated skips (Klaus, Harte, real-ROM boot, later the ATR boot and
   typing tests) into failures, so a phase cannot go green while the
   tests that need local assets silently skip. Sandbox and CI runs stay
   lenient; the strict run is the done-gate on the machine that rule 8
   says has the ROMs.
3. **Benchmark rule**: any phase touching the hot path
   (`src/machine.lisp` `%run-clocks`, `src/antic.lisp` scanline events,
   `src/pokey.lisp` tick/advance, `src/renderer.lisp` per-line work)
   must measure with `./scripts/bench-ab.sh <pre-phase-ref>`, which
   builds the baseline in a git worktree and INTERLEAVES baseline and
   working-tree runs (B-A-B-A) so session drift hits both sides
   equally, then add its paired-delta table plus a short note to
   `PERFORMANCE_LOG.md`. Treat a delta as real only when the runs
   separate cleanly (every A run on one side of every B run -- the
   script reports CLEAN/MIXED per workload); absolute fps values are
   comparable only within one bench-ab session, so do not extend the
   longitudinal table at the top of the log. (The old
   three-runs-before/three-after method is retired: session drift
   defeated it twice -- see the log's Phase 9 and Phase 12 notes.)
   Phases 3, 5, 6, and 9 were the original tranche's hot-path phases;
   of the open work, 18 and 22 are.
4. Each phase gets a `CHANGES.md` entry at the TOP of the file (the log
   is newest-first) and updates the status header of whichever plan
   document it advances (`SCANLINE_ACCURACY_PLAN.md`,
   `MISC_IMPROVEMENTS_PLAN.md`, this file).
5. Commit per phase (or per sub-item where a phase lists multiple
   commits) directly on `main` with the stated commit message. Never
   push unless the user asks.
6. New timing/rendering behaviour gets a FiveAM test in the matching
   `tests/test-*.lisp` child suite; concrete bug fixes also get a
   regression test in `tests/test-regressions.lisp`.
7. If a Lisp file fails to compile with an unmatched-parenthesis style
   error, diagnose with a paren-counting script (walk the file counting
   depth per top-level form) BEFORE re-running the full suite -- do not
   guess-and-rerun.
8. ROM images live in `roms/` (gitignored). `ATARIXL.ROM`,
   `ATARIBAS.ROM`, and `6502_functional_test.bin` are already present
   on this machine.
9. **Review rule**: after the suite is green and before a phase is
   declared done, review the phase's full diff against hardware
   references and first principles -- the plan text is itself under
   review, not the standard to review against. A plan sentence that
   asserts emulator-bookkeeping semantics ("clamping to 0 is
   deliberate", "X cannot happen here") is a claim with the same
   standing as a CONFIRM-flagged hardware number: verify it or pin it
   with a test before trusting it. Any phase touching `%run-clocks` or
   cycle accounting must include at least one ledger test asserting an
   exact cycle total over a multi-line window, computed on paper, not
   recorded from a run of the code. (Precedent: the Phases 1-5 review
   caught the WSYNC clamp forgiving a budget deficit -- commit 21e6749
   -- after this plan had specified that clamp as deliberate.)

## Phase overview and dependencies

| Phase | Title                                        | Depends on | Hot path | Status |
|-------|----------------------------------------------|------------|----------|--------|
| 1     | Cheap hardening batch (4 small commits)      | --          | no       | done   |
| 2     | Rename: color clocks -> CPU cycles            | --          | no       | done   |
| 3     | WSYNC ($D40A)                                | 2          | yes      | done   |
| 4     | Raster-bars demo + rendered acceptance test  | 3          | no       | done   |
| 5     | Playfield DMA steal tables                   | 3          | yes      | done   |
| 6     | P/M DMA, full priority, GTIA cleanups        | --          | yes      | done   |
| 7     | GTIA modes 9/10/11                           | 6          | no       | done   |
| 8     | POKEY timer fidelity                         | --          | no       | done   |
| 9     | POKEY audio synthesis core                   | 8          | yes      | done   |
| 10    | AESP audio streaming + WAV capture           | 9          | no       | done   |
| 11    | A/V recording tooling (`record.sh` -> mp4)    | 4, 10      | no       | done   |
| 12    | Tom Harte ProcessorTests harness             | --          | no       | done   |
| 13    | POKEY keyboard IRQ (typing into BASIC)       | 22         | no       | done   |
| 14    | `fetch-harte.sh` + fast subset gate          | 12         | no       | open   |
| 15    | Documentation drift sweep (misc item 9)      | --          | no       | open   |
| 16    | SIO receive path + virtual disk (ATR)        | 13, 22     | no       | open   |
| 17    | Harte bus-trace comparison                   | 12         | no       | open   |
| 18    | LispWorks profiling pass                     | --          | yes      | open   |
| 19    | 256-entry palette (GTIA mode 9 luminances)   | 7          | no       | open   |
| 20    | ANTIC display-list latch note (misc item 10) | --          | no       | open   |
| 21    | Strict test gate + skip census               | --          | no       | done   |
| 22    | POKEY pending-work bitmask                   | --          | yes      | done   |
| 23    | CONFIRM retirement pass                      | --          | no       | open   |
| 24    | Acid800 gate (CPU + ANTIC subsets)           | 21         | no       | open   |

Phases 6/7/8 are independent of 3/5 and can be reordered if blocked.
Phase 12 is independent of everything and can run any time; it is last
of the original tranche only because it produces no video-visible
payoff.

Of the 13-20 tranche, only 16 depends on another new phase (13 gives
it the interrupt plumbing and a way to drive DOS once it boots). 17 is
what turns SCANLINE_ACCURACY_PLAN.md's stretch Phase 5 from guesswork
into a checkable target, so run it before attempting those quirks.

The 21-24 amendments adjust the recommended order: 21 first (it makes
the real-ROM tests un-skippable on this machine before the phases that
lean on them), 22 before 13 and 16a (their per-advance POKEY hooks
join the bitmask instead of adding two more branch tests to the hot
path -- the Phases 1-12 pattern was one such test per feature, each
individually measured and shrugged at), 24 before 17 (Acid800's ANTIC
subset is the first external check the Phase 5 steal tables and Phase
3 WSYNC have ever faced; 17 deepens the CPU's already-strongest
evidence), and 23 alongside 14/15 as hygiene.

---

## Phase 1 -- Cheap hardening batch

Four small, independent fixes from `MISC_IMPROVEMENTS_PLAN.md` (its
items 1, 2, 8, 3). One commit each, in this order. Full step-by-step
detail lives in that plan -- follow it exactly; summary:

1. **Opcode-table reload robustness** (misc item 1): eliminate
   `*opcode-table-builder*` (`src/cpu-opcodes.lisp:252`); make
   `*opcode-table*` and `*opcode-mnemonic-table*` load-time `defvar`s
   in `src/cpu.lisp`; `DEFOPCODE` writes `(setf (svref *opcode-table*
   op) ...)` directly. Test: all 256 slots non-NIL after load; 151
   documented + 105 illegal via the existing introspection functions.
   Commit: "Install opcodes directly into *OPCODE-TABLE*; drop the builder".
2. **Reset flag consistency** (misc item 2): `machine-cold-reset` sets
   P to `#x34`; change to `#x24` to match `reset-cpu` (B is not a real
   register bit). Grep `#x34` in `tests/` and update. Test: flags equal
   `#x24` after both reset paths.
   Commit: "Cold reset sets P to #x24, matching RESET-CPU".
3. **LispWorks `chmod-file` via FLI** (misc item 8): replace the
   `/bin/chmod` shell-out in `src/compat.lisp` with an
   `fli:define-foreign-function` following the existing `%getpid` /
   socket FLI style in the same file. Test in `tests/test-compat.lisp`.
   Commit: "compat: chmod-file via FLI on LispWorks".
4. **`scripts/fetch-test-roms.sh`** (misc item 3): download
   `bin_files/6502_functional_test.bin` from the
   Klaus2m5/6502_65C02_functional_tests GitHub repo into `roms/`
   (skip with a message if already present), echo a checksum, note the
   license. Document in `CLAUDE.md`'s test section.
   Commit: "Add fetch-test-roms.sh for the Klaus functional test binary".

Done when: suite green on both implementations after each commit; four
commits on main; `MISC_IMPROVEMENTS_PLAN.md` gets a status header
(like the other plans') marking items 1, 2, 3, 8 done.

---

## Phase 2 -- Rename: color clocks -> CPU cycles

`SCANLINE_ACCURACY_PLAN.md` Phase 0, previously skipped. The 114-unit
the code calls "color clocks" is actually CPU cycles (a real NTSC line
is 228 color clocks = 114 CPU cycles); hardware docs quote CPU cycle
numbers 0-113, and Phases 3-5 will start using them.

1. Rename `+color-clocks-per-scanline+` -> `+cpu-cycles-per-scanline+`
   (defined in `src/antic.lisp`, exported via `src/package.lisp`).
   Grep for every use: `src/antic.lisp`, `src/machine.lisp` (the
   `%run-clocks` line loop), `tests/test-antic.lisp`,
   `tests/test-regressions.lisp`, possibly `src/renderer.lisp` and
   `scripts/bench.lisp`.
2. Rename the `antic` struct slot `color-clock` -> `line-cycle`
   (accessor `antic-color-clock` -> `antic-line-cycle`; update
   `src/package.lisp` exports and all callers -- note `antic-tick` and
   its callers/tests use it).
3. Sweep comments/docstrings in `antic.lisp`, `machine.lisp`,
   `main.lisp` that say "color clock" for the 114-unit; reword as
   "CPU cycles (114 per line; a real line is 228 color clocks at twice
   the CPU rate)". Keep `+clocks-per-frame+` = 29,868 but fix its
   docstring.
4. Update the stale wording in `CLAUDE.md` and `README.md` ("29,868
   NTSC color clocks" -> "29,868 CPU clock cycles").

Pure rename: no behaviour change, no benchmark needed. Suite must be
green untouched (check counts stay 1450/1450).
Commit: "Rename ANTIC's line unit from color clocks to CPU cycles".
Update `SCANLINE_ACCURACY_PLAN.md` status header: Phase 0 done.

---

## Phase 3 -- WSYNC ($D40A)  [hot path -> benchmark]

`SCANLINE_ACCURACY_PLAN.md` Phase 2, adapted to the merged scanline
scheduler. The single most important register for raster effects;
every DLI handler starts with `STA WSYNC`. Semantics: a write halts
the CPU until cycle 105 of the current line; THIS phase stalls to
end-of-line (the 105-cycle refinement belongs to the plan's Phase 4).

1. `src/antic.lisp`: add struct slot `wsync-pending` (boolean,
   default NIL). In `ANTIC-WRITE`, add a `+reg-wsync+` case ($0A,
   mirrored across $D4xx -- the offset constant already exists) that
   sets it. Add and export `ANTIC-CONSUME-WSYNC (antic)` --
   read-and-clear, returns the old value. Clear the slot in
   `reset-antic`.
2. `src/machine.lisp` `%run-clocks`: inside the per-line instruction
   loop, after each successful `step-cpu` (and its `pokey-advance`),
   check `(antic-consume-wsync antic)`; if true, `(setf cpu-budget 0)`
   and terminate the inner instruction loop for this line. The
   existing "top POKEY up to exactly this line's cycle count" step
   already advances POKEY through the stalled remainder -- verify that
   and say so in a comment. Clamping `cpu-budget` to 0 (not merely
   subtracting) is deliberate: real WSYNC freezes the CPU regardless
   of any budget surplus carried from previous lines; do not let
   surplus leak past the stall. Document in the `%run-clocks`
   docstring.
3. Note in a comment: WSYNC via read-modify-write instructions
   (`DEC WSYNC` double-write) is out of scope until the NMOS bus-quirk
   phase; `antic-tick` (the per-cycle reference path) does NOT consume
   WSYNC -- scheduler-only behaviour, documented at
   `antic-consume-wsync`.

Tests (`tests/test-antic.lisp` unit + `tests/test-regressions.lisp`
machine-level):
- Unit: `antic-write` to $D40A sets the flag; `antic-consume-wsync`
  returns T then NIL; `reset-antic` clears it.
- Machine-level (use `%make-synthetic-os-rom` + `%poke` from
  `tests/test-helpers.lisp`): reset code `STA $D40A` then `STA $00`
  (bytes `8D 0A D4  85 00`, with A pre-loaded non-zero via `LDA #$xx`
  first). Run exactly one scanline via `%run-clocks` (114 cycles);
  assert RAM $00 unchanged (CPU stalled after the WSYNC store). Run
  one more line; assert the marker was written.
- Back-to-back `STA WSYNC / STA WSYNC`: the second stalls to the NEXT
  line's end (assert a following marker write lands only after the
  second extra line).

Benchmark before/after (rule 3); expect ~ neutral (one flag check per
instruction). Log rows + note in `PERFORMANCE_LOG.md`.
Commit: "Implement WSYNC: CPU stalls to end of scanline".
Update `SCANLINE_ACCURACY_PLAN.md` status: Phase 2 done.

---

## Phase 4 -- Raster-bars demo + rendered acceptance test

The EdVenture payoff for Phase 3: a classic WSYNC raster-color demo,
verified end-to-end through the real renderer, providing camera-ready
material and pinning WSYNC + per-line rendering together.

1. `asm/edvent02_rasterbars.asm` (MADS syntax; follow
   `asm/hello.asm` / `asm/edvent01.asm` house style and the XEX
   conventions used there). Program outline (self-contained, no OS
   calls -- the XEX runner loads it and jumps to its run address):
   - Disable IRQs (`SEI`), set up a display list of blank lines +
     ~100 mode-2 or blank lines + JVB in low RAM; point DLISTL/H
     ($D402/3) at it; DMACTL ($D400) = $22.
   - Main loop: wait for VCOUNT ($D40B) to reach the top of the active
     region, then a tight loop of ~64 iterations: `STA $D40A` (WSYNC),
     write an incrementing color value to COLBK ($D01A), `INC` the
     value (adding 16 per line cycles the hue), repeat. Then loop
     forever.
2. Build + run + capture:
   `./scripts/mads-build.sh asm/edvent02_rasterbars.asm` then
   `./scripts/atari-run.sh <xex> -frames 30 -o /tmp/rasterbars.png`
   (check the scripts' actual flag spellings first -- see their usage
   headers). The PNG must show horizontal color bands.
3. Automated acceptance (this is the committed test, the PNG check is
   manual): add a regression test that pokes an equivalent machine-code
   loop into RAM via `%poke` (WSYNC + COLBK increment per line), runs
   one frame with a framebuffer attached (see
   `tests/test-renderer.lisp` for how the renderer tests construct
   machine + framebuffer), and asserts >= 32 consecutive active rows
   whose row-color (sample pixel x=0, the border/background column)
   differs from the previous row's. This fails if WSYNC stops
   stalling, if the render callback fires at the wrong time, or if
   per-line register latching breaks.
4. Add a short "Raster effects" example paragraph to `README.md`
   pointing at the asm file and the run command.

Commit: "Add WSYNC raster-bars demo and rendered acceptance test".

---

## Phase 5 -- Playfield DMA steal tables  [hot path -> benchmark]

`SCANLINE_ACCURACY_PLAN.md` Phase 3, verbatim -- follow that plan
section's five numbered steps, its bytes-per-line table, its test
list, and its guard rails. Summary of what lands:

- `PLAYFIELD-DMA-CYCLES (mode-byte dmactl first-line-p)` pure function
  + data tables in `src/antic.lisp` (narrow/normal/wide from DMACTL
  bits 0-1; text modes fetch names on the first line of a mode line
  and font bytes every line; map modes fetch data on the first line
  only -- table values marked CONFIRM in the plan).
- DL instruction fetch cost charged (1 cycle + 2 for LMS operand + 2
  for JMP/JVB operand) -- `process-dl-instruction` already knows the
  byte count.
- Wired into `%begin-scanline-events` so BOTH the scheduler and
  `antic-tick` see identical steals; steal clamped/asserted < 114.
- The frame-budget regression test from the plan (24 mode-2 lines +
  JVB, DMACTL $22, assert total CPU cycles in the computed band) --
  this pins the whole model.

Extra care (post-renderer): the renderer's screen-pointer advancement
in `%end-scanline-events` and this phase's fetch accounting both key
off mode/first-line state -- keep them consistent; add one test that a
24-line mode-2 frame still renders the same pixels after this phase
(render a frame before/after is not possible in one test -- instead
assert the renderer test suite is untouched and add a
mode-2-with-DMA-steal render test).

Klaus workload note: heavier steal per line means fewer CPU cycles per
frame; the `klaus` bench workload's frame count may need adjusting
(see the `PERFORMANCE_LOG.md` scanline-scheduler note for precedent --
same total instruction count, more frames). Update `scripts/bench.lisp`
if the Klaus run stops PASSing purely due to frame count.

Benchmark + log (expect a further "speedup" that is really the CPU
getting fewer cycles/frame -- note it as the scheduler note did).
Commit: "Model ANTIC playfield and display-list DMA cycle stealing".
Update `SCANLINE_ACCURACY_PLAN.md` status: Phase 3 done.

---

## Phase 6 -- P/M DMA, full GTIA priority, GTIA cleanups  [hot path -> benchmark]

Makes player/missile graphics work the way real programs use them
(ANTIC-fetched, not just poked GRAF registers) and finishes the
priority model. Three commits.

**6a -- ANTIC -> GTIA P/M DMA data path.**
Currently ANTIC accounts P/M DMA *cycles* but never fetches the data;
the renderer reads only the GRAFP/GRAFM registers the program poked.
Real hardware: when DMACTL ($D400) bit 3 (players) / bit 2 (missiles)
is set AND GRACTL ($D01D) bit 1 (players) / bit 0 (missiles) enables
receive, ANTIC fetches one byte per object per line and delivers it to
GTIA's GRAF registers.
1. Addressing (**CONFIRM** against Altirra/atari800): base =
   `(ash (logand pmbase #xF8) 8)` from PMBASE ($D407). DMACTL bit 4
   selects resolution: single-line (bit 4 = 1): missiles at
   base+768+scanline, player p at base+1024+256*p+scanline;
   double-line (bit 4 = 0): missiles at base+384+(scanline>>1),
   player p at base+512+128*p+(scanline>>1). Mask addresses to 16
   bits.
2. Implement `%fetch-pm-graphics (antic)` in `src/antic.lisp`, called
   from `%begin-scanline-events` during the active region when the
   DMACTL bits are set; it needs the GTIA -- chips don't reference each
   other's packages (see `CLAUDE.md` bus design), so follow the
   existing closure pattern: give ANTIC a `pm-write-fn` function slot
   that `machine.lisp` wires to a closure storing into the GTIA's
   write-register array (GRAFP0-3 offsets $0D-$10, GRAFM $11), gated
   on GRACTL bits inside the closure. Wire it in `make-atari-machine`.
3. Tests (`tests/test-antic.lisp` + `tests/test-gtia.lisp`): poke a
   recognizable byte pattern into P/M RAM, enable DMACTL+GRACTL, run
   `antic-begin-scanline` on a known scanline, assert the GRAF
   registers; assert no delivery when GRACTL is clear (cycles still
   stolen -- that's DMACTL's job); double-line uses scanline>>1.
Commit: "ANTIC fetches P/M graphics into GTIA when DMA is enabled".

**6b -- Full P/M <-> playfield priority.**
Replace `%render-pm-layer`'s simplification (`src/renderer.lisp:348`,
which skips P/M entirely when PRIOR bit 1 is set). Implement PRIOR
($D01B / GTIA write offset $1B... use the existing `+w-prior+`
constant) properly:
1. Priority select bits 0-3 (exactly one normally set -- **CONFIRM**
   the four orderings against Altirra/atari800 `gtia.c`; the standard
   table, top priority first:
   - PRIOR bit 0: P0 P1 P2 P3 PF0 PF1 PF2 PF3 BAK
   - PRIOR bit 1: P0 P1 PF0 PF1 PF2 PF3 P2 P3 BAK
   - PRIOR bit 2: PF0 PF1 PF2 PF3 P0 P1 P2 P3 BAK
   - PRIOR bit 3: PF0 PF1 P0 P1 P2 P3 PF2 PF3 BAK).
   The renderer must therefore know WHICH playfield register produced
   each pixel, not just its color: have the playfield renderers
   (`%render-char-mode`, `%render-bitmap-mode`) also fill a per-row
   scratch array of source tags (BAK/PF0-3), stored in a new slot on
   the framebuffer-owning struct or passed down from
   `render-scanline`; then `%render-pm-layer` arbitrates per pixel.
2. Bit 4: fifth player -- the four missiles combine into one "player"
   colored COLPF3 instead of their player's color.
3. Bit 5: multicolor players -- overlapping P0/P1 (and P2/P3) OR their
   color registers.
4. Bits 6-7 (GTIA modes) are Phase 7; leave a `;; Phase 7` comment.
5. Tests (`tests/test-renderer.lisp`): one test per priority ordering
   (poke a player over a playfield pixel, assert which color wins);
   fifth-player; multicolor OR.
Commit: "Renderer: full PRIOR priority, fifth player, multicolor players".

**6c -- GTIA register cleanups** (misc items 6 + 7): verify the PAL
register value against atari800 `gtia.c` (`$0F`-pattern for NTSC --
**CONFIRM**); dedupe `%make-gtia-read-regs` / `reset-gtia` defaults
into one `%init-read-regs` helper; test the documented NTSC value.
Commit: "GTIA: correct PAL register encoding; dedupe reset defaults".

Benchmark after 6a (per-line fetch work) + log.
Update `MISC_IMPROVEMENTS_PLAN.md` status: items 6, 7 done.

---

## Phase 7 -- GTIA modes 9/10/11

The GTIA color modes (16 luminances / 9 colors / 16 hues), selected by
PRIOR bits 6-7 on top of an ANTIC mode F fetch. Used by many demos and
paint programs; visually striking -> good video material.

1. In `render-scanline` (`src/renderer.lisp`), read PRIOR bits 6-7:
   0 = normal, 1 = mode 9, 2 = mode 10, 3 = mode 11 (**CONFIRM**
   mapping: bit6=1&bit7=0 -> 9? -- check atari800 `gtia.c`; get this
   right before coding the dispatch).
2. When a GTIA mode is active and the ANTIC mode is F: each screen
   byte holds two 4-bit nibbles; each nibble is one wide pixel (4
   output columns at our 320-px playfield scale -> 80 wide pixels).
   - Mode 9: nibble = luminance; hue from COLBK's hue bits. Output
     color byte: `(logior (logand colbk #xF0) (ash nibble 1))` --
     verify against the palette function's bit layout (hue bits 7-4,
     luminance bits 3-1) and adjust so nibble 0-15 maps onto the 8
     luminance levels sensibly (nibble's low bit lands in bit 0,
     which the palette ignores -- that halves the levels; document).
   - Mode 10: nibble 0-8 selects a color REGISTER: 0-3 -> COLPM0-3,
     4-7 -> COLPF0-3, 8 -> COLBK (9-15: **CONFIRM** behaviour, commonly
     repeats PF/BAK).
   - Mode 11: nibble = hue; luminance from COLBK's luminance bits
     (nibble 0 renders as COLBK-luminance gray/black -- **CONFIRM**).
3. GTIA modes apply per-line (PRIOR can change mid-frame via DLI --
   per-line granularity is what our renderer already provides). ANTIC
   modes other than F with GTIA bits set produce garbage on hardware;
   render as normal mode and document.
4. Tests: for each mode, poke two known screen bytes, one frame,
   assert the exact RGB triples of the 8 affected output columns
   (compute expected values through `atari-color->r/g/b`).

Commit: "Renderer: GTIA modes 9/10/11".

---

## Phase 8 -- POKEY timer fidelity

`MISC_IMPROVEMENTS_PLAN.md` item 5, verbatim -- follow its five steps:
reload offsets (+4 at 1.79 MHz, +7 for linked 16-bit pairs at
1.79 MHz, +1 on the 64/15 kHz clocks -- **CONFIRM**), AUDCTL bit 4/3
channel linking with IRQs from the high channel, the existing
timer-test renames (N+1 -> N+4 with reference citations), the 16-bit
pair period test, and the batched-advance equivalence test update
(PERFORMANCE_PLAN Phase 3 landed, so `pokey-advance`'s event skipping
MUST be updated in the same commit to honor links/offsets -- the
50,000-cycle `pokey-tick`==`pokey-advance` equivalence test is the
net; extend it to a linked-channel configuration).

This precedes audio synthesis so the audible frequencies come out
right the first time.
Commit: "POKEY: hardware reload offsets and linked 16-bit channels".
Update `MISC_IMPROVEMENTS_PLAN.md` status: item 5 done.

---

## Phase 9 -- POKEY audio synthesis core  [hot path -> benchmark]

Turn register state into samples. Design decisions are made here --
implement as specified.

**Output format**: mono, unsigned 8-bit, one sample every 40 CPU
cycles -> 1,789,772.5 / 40 = **44,744 Hz** nominal (746-747 samples per
NTSC frame; 29,868 / 40 = 746.7).

1. New file `src/audio.lisp`, package `:atari800-cl.audio`, inserted
   in the `.asd` and `src/package.lisp` AFTER `pokey` and BEFORE
   `machine` (`:serial t` -- order matters). Core struct
   `audio-unit`: sample buffer (growable or fixed 2048 with a fill
   pointer), cycle accumulator, per-channel output-bit state, poly
   counters.
2. Synthesis model (per CPU cycle, but batched -- see step 4):
   - Channel clocking: reuse the timer state Phase 8 solidified -- a
     channel's square-wave flip-flop toggles on counter underflow.
     Distortion (AUDC bits 5-7) gates the toggle through the poly
     sequences: pure tone (AUDC high bits `101`/`111` variants),
     poly4, poly5-gated, poly17/poly9 noise (AUDCTL bit 7 selects
     9-bit). Implement the poly sequences as precomputed bit vectors
     (poly4 len 15, poly5 len 31, poly9 len 511, poly17 len 131071)
     generated at load time with the same feedback taps the RNG in
     `pokey.lisp` uses -- factor the tap logic into one shared helper
     rather than duplicating constants.
   - Volume-only mode (AUDC bit 4): channel output = volume,
     unconditionally.
   - Sample = `128 + sum over channels (if output-bit-set: +vol,
     else: -vol) * 2` clamped to 0-255 (four channels x 15 max
     volume x 2 = 120 swing each side -- fits).
   - AUDCTL high-pass filters (bits 1-2) and two-tone serial mode:
     NOT in this phase; document in the file header as out of scope.
3. API (exported): `make-audio-unit`, `audio-drain (unit)` -> fresh
   `(simple-array (unsigned-byte 8))` of the samples accumulated since
   the last drain (and resets the buffer), `+audio-sample-rate+`.
4. Wiring: add an optional `audio` slot to the `pokey` struct. In
   `pokey-advance` (and `pokey-tick`), when the slot is non-NIL,
   advance the audio unit by the same N cycles -- the audio unit steps
   channel counters itself OR (simpler, preferred) observes the
   channel underflows POKEY already computes: add a per-channel
   underflow hook the audio unit consumes. Choose the design that
   keeps the no-audio path cost at exactly one NIL check per
   advance -- benchmark to prove it (rule 3), since machines without
   audio attached (all current tests/benches) must not regress.
5. Facade: `a800:machine-attach-audio` / `machine-audio-drain` (via
   `src/machine.lisp` + `src/main.lisp`).
6. Tests (`tests/test-audio.lisp`, new suite `audio-suite :in
   atari800-cl-suite`, added to `.asd` + `tests/test-suite.lisp`
   pattern):
   - Frame sample count: one `machine-run-frame` with audio attached
     yields 746 or 747 samples.
   - Pure tone: channel 1 at 1.79 MHz, AUDF1 chosen for a period of
     exactly K samples; assert the drained buffer's flip period is K
     (count samples between level transitions).
   - Volume-only: constant buffer at the expected DC value.
   - Silence (all volumes 0): constant 128s.

Benchmark + log (audio detached AND attached rows -- label them).
Commit: "POKEY audio synthesis: four-channel PCM at 44.7 kHz".

---

## Phase 10 -- AESP audio streaming + WAV capture

1. `src/aesp.lisp`: consult `tools/protocol-comparison` and the Attic
   `PROTOCOL.md` conventions already mirrored in this file for the
   audio-frame message type; if the protocol defines one, use its
   code, else define `+aesp-audio-frame+ #x85` (next to the existing
   `#x81-#x84` audio codes) and document the payload: raw u8 mono
   samples, length = sample count. Update `%audio-config-payload` to
   declare rate 44744, format u8, channels 1 (read its current layout
   first and keep it wire-compatible).
2. Server wiring: mirror `%push-video-frame` -- the machine's
   `post-frame-fn` (already installed by the AESP server) additionally
   drains the audio unit and pushes to `audio-clients` (add the slot
   parallel to `video-clients`, subscribe handling parallel to video).
   Attach an audio unit to the machine when the first audio subscriber
   arrives (or unconditionally at server start -- simpler, costs ~0
   when nobody drains... no: the synthesis itself costs; attach on first
   subscribe, detach on last unsubscribe; guard with the server lock).
3. `scripts/capture-audio.py`: like `capture-screenshot.py` but on the
   audio port -- subscribe, collect N frames' samples, write a WAV via
   Python's `wave` module (44744 Hz, 1 channel, 1 byte/sample).
4. Tests (`tests/test-aesp.lisp`): codec roundtrip of an audio frame;
   server test in the existing live-server pattern (they self-skip in
   sandboxes) -- subscribe, run a frame via the mailbox, assert an
   AUDIO_FRAME arrives with 746-747 bytes.

Commit: "Stream POKEY audio over AESP; add WAV capture script".

---

## Phase 11 -- A/V recording tooling (the EdVenture deliverable)

One command from `.asm` to a watchable `.mp4`.

1. `scripts/capture-video.py`: subscribe to the AESP video port,
   capture N frames as numbered PNGs into a temp dir (reuse
   `capture-screenshot.py`'s frame-decode code -- refactor the shared
   parts into `scripts/aesp_client.py` imported by all three capture
   scripts rather than copy-pasting).
2. `scripts/record.sh <file.asm|file.xex> [-frames N] [-o out.mp4]`:
   orchestrates -- build with `mads-build.sh` if given `.asm`; start
   the emulator + servers via the same mechanism `atari-run.sh` uses
   (read it first; reuse, don't reimplement); run `capture-video.py`
   and `capture-audio.py` concurrently for N frames; assemble with
   `ffmpeg -framerate 59.92 -i frame%05d.png -i audio.wav -c:v libx264
   -pix_fmt yuv420p -c:a aac out.mp4` (guard: if `ffmpeg` is absent,
   leave the PNG sequence + WAV and print the assemble command).
3. Acceptance (manual, document in the script header): `./scripts/
   record.sh asm/edvent02_rasterbars.asm -frames 300 -o /tmp/rb.mp4`
   -> a 5-second video of animated raster bars. Automated smoke: a
   `--dry-run`-less run of 10 frames producing >= 10 PNGs and a WAV of
   >= 7460 samples; add it to the script as `--selftest` if easy,
   otherwise verify manually and note in the commit message.
4. README: replace/extend the screenshot paragraph with the one-liner
   recording workflow.

Commit: "One-shot A/V recording: asm -> mp4 via AESP capture".

---

## Phase 12 -- Tom Harte ProcessorTests harness

`MISC_IMPROVEMENTS_PLAN.md` item 4, verbatim -- follow its five steps
exactly (env-var-gated data at `ATARI800_CL_HARTE_TESTS`, `shasht`
JSON dependency on the TEST system only, `tests/test-harte.lisp` with
`harte-suite`, KIL/unstable handling, 500-cases-per-opcode default
with `ATARI800_CL_HARTE_FULL=1`, triage workflow in the file header).

Expect real bugs to surface (decimal-mode edges, page-cross cycles).
Fix each in `src/`, add a named regression test, keep the skip-list
empty unless a divergence is documented-unstable. Budget multiple
sessions; land the harness (skipping gracefully) in one commit, bug
fixes in follow-up commits.

Commit: "Add Tom Harte ProcessorTests harness (harte-suite)".
Then: one commit per bug found, message "Fix <opcode> <defect> (Harte case <id>)".
Update `MISC_IMPROVEMENTS_PLAN.md` status: item 4 done (and item 11
marked obsolete).

---

## Phase 13 -- POKEY keyboard IRQ (typing into BASIC)

The machine boots to BASIC's `Ready` but cannot be typed at. AESP
`KEY_DOWN` already reaches `input-set-key`, which only makes `KBCODE`
readable -- and the XL OS reads `KBCODE` from an interrupt handler,
dispatched off IRQEN bit 6. POKEY has no such source: `+irq-timer1/2/4+`
and the two serial-output bits are the whole set. Same shape as the
SEROR/SEROC work, and it turns "boots to BASIC" into "type a program
and RUN it".

1. `src/pokey.lisp`: add `+irq-other-key+` (`#x40`) and
   `+irq-break-key+` (`#x80`), per the XL OS's own `TIRQ` dispatch table
   (`minimal-xl/Atari_XL_OS_Rev.2.asm`) -- the same source that settled
   the timer-4 and serial bits in the POKEY serial commit.
2. Raise the key IRQ when a key is latched, not on a timer: the input
   state is written from socket reader threads, so POKEY cannot poll it
   safely. Give `pokey` a "key pending" flag set through the existing
   input plumbing (`attach-pokey-input` path) and consumed on the next
   `pokey-advance` from the emulator thread, which then calls
   `%raise-irq` with `+irq-other-key+`. Keep the idle cost to the same
   one-slot-read test the serial transmitter pays -- benchmark it
   (rule 3).
3. SKSTAT: bit 2 (shift held) and bit 3 (a key is down) are what the OS
   debounce path reads; `input-pokey-skstat` already composes a value,
   so extend it rather than adding a second source of truth.
4. BREAK: bit 7 is a separate IRQ and sets `BRKKEY` ($11) via the OS
   handler. Wire it the same way; it is what lets a test stop a runaway
   BASIC program.

Tests: unit (`tests/test-pokey.lisp`) that a latched key with IRQEN bit
6 set clears the IRQST bit and asserts the CPU line, and does neither
when the bit is clear. End-to-end (`tests/test-machine.lisp`, alongside
the real-ROM boot tests, skipping without ROMs): boot to `Ready`, drive
the key codes for `PRINT 2+2` and RETURN through the input state, run
frames, then assert `4` appears in screen memory. That last test is the
real acceptance criterion -- it exercises keyboard IRQ, the OS editor,
and BASIC in one shot.

Commit: "POKEY keyboard IRQ: the OS editor now sees keystrokes".

---

## Phase 14 -- `scripts/fetch-harte.sh` + fast subset gate

The Harte harness is only as useful as its data is easy to get; right
now that is a README paragraph rather than a command.

1. `scripts/fetch-harte.sh`, modelled on `scripts/fetch-test-roms.sh`:
   fetch `SingleStepTests/65x02` `6502/v1` into a gitignored directory
   (default `.cache/harte/`), no-op when already present, print the
   `export ATARI800_CL_HARTE_TESTS=...` line to eval. Prefer a sparse or
   per-file fetch over cloning the whole ~1 GB repository.
2. `--subset N` (default for the pre-commit case): fetch only N opcode
   files chosen to cover the addressing modes and the illegal families,
   so a fast gate is ~30 MB instead of a gigabyte. The harness already
   tests whichever files exist, so nothing in `tests/` changes.
3. Document both modes in `CLAUDE.md`'s test section next to the
   existing Harte paragraph.

Commit: "Add fetch-harte.sh for the SingleStepTests vectors".

---

## Phase 15 -- Documentation drift sweep

`MISC_IMPROVEMENTS_PLAN.md` item 9, which has drifted further since it
was written -- partly because of the phases above:

- `CLAUDE.md`'s Project Overview still lists "the serial/SIO bus,
  keyboard scanning" as unmodelled; the serial-output half now is, and
  Phase 13 changes the keyboard half.
- `CLAUDE.md`'s Development Plan paragraph still says Prompt 12's
  Unix-socket layer "was later removed" while `src/cli-socket.lisp`,
  `src/transport.lisp` and `src/aesp.lisp` are all present.
- The rest of misc item 9's list (README limitation bullets, renamed
  symbols in examples).

Cheap, and it keeps the file that steers every future session honest.
Do it as one commit, after Phase 13 so the keyboard wording lands once.

Commit: "Documentation drift sweep".

---

## Phase 16 -- SIO receive path + virtual disk (ATR)

The next substantial feature, and the one that changes what the
emulator is for: with a device that answers, the machine boots DOS and
runs real software instead of hand-assembled demos. The OS already
sends a complete command frame and times out waiting for a reply -- the
missing half is everything after that.

Stage it; do not attempt one commit. And write the acceptance test
FIRST: the DOS-menu boot test lands in `tests/test-machine.lisp`'s
real-ROM group -- strict-gated (Phase 21) and skipping -- in the same
commit as 16a, so the phase is done when that test stops skipping and
passes, not when the sub-items feel complete. (Lesson from Phases
1-12: the PIA and serial-transmitter showstoppers survived twelve
green phases because no phase gated on booting the real ROMs.)

**16a -- serial receive.** POKEY's input side: SERIN, the
serial-input-ready IRQ (IRQEN bit 5), and the SKSTAT framing/overrun
bits. Mirror the transmitter's structure in `src/pokey.lisp` (a
cycle countdown clocked from the same channel-4 period) so the two
halves stay symmetrical.

**16b -- device dispatch.** A `src/sio.lisp` device layer that watches
the transmitted command frame (device id, command, aux1/2, checksum),
and replies with ACK / COMPLETE / data frames on the receive side, with
the inter-frame delays the OS expects. Devices register by id, so the
disk is one implementation rather than the only one.

**16c -- ATR disk images.** Parse the 16-byte ATR header (magic
`$0296`, sector size, image size), map sector numbers to file offsets
(remembering the first three sectors are 128 bytes even on
double-density images), and serve READ (`$52`) and STATUS (`$53`)
first; WRITE (`$50`/`$57`) after, behind an explicit read-only default.

**16d -- API + protocol.** `a800:mount-disk` / `unmount-disk` on the
facade, an AESP control message to mount from a client, and a `mount`
verb on the CLI socket.

Acceptance: with a DOS 2.5 ATR mounted, a cold boot reaches the DOS
menu, and `scripts/record.sh` can film it. Add a boot test in the
`tests/test-machine.lisp` real-ROM group, skipping when no ATR is
present.

Commits: one per stage, message "SIO: <stage>".

---

## Phase 17 -- Harte bus-trace comparison

The vectors carry a full cycle-by-cycle bus trace -- `[address, value,
"read"|"write"]` per cycle -- and `tests/test-harte.lisp` currently uses
only its LENGTH, as the cycle count. Comparing the trace itself turns
the harness from "right answer in the right number of cycles" into
"right accesses in the right order", which is exactly the evidence
SCANLINE_ACCURACY_PLAN.md's stretch Phase 5 needs.

1. Give the harness an optional recording bus: wrap the CPU's
   `cpu-bus-read` / `cpu-bus-write` closures to log `(addr value kind)`
   per access (the scanline plan's Phase 5 already calls for such a stub
   -- write it once, in `tests/test-helpers.lisp`, and share it).
2. Compare against the vector's `cycles` array. Expect immediate,
   informative failures: the RMW double-write (write unmodified, then
   modified) and the indexed dummy reads are both unmodelled today, and
   both show up as a wrong access at a known index rather than as a
   wrong result.
3. Gate it behind its own env var (`ATARI800_CL_HARTE_TRACE=1`) until
   the quirks are implemented, so the default run stays green while the
   work proceeds.
4. Then implement SCANLINE_ACCURACY_PLAN.md Phase 5 items 1 and 2
   against it, one commit each, and drop the gate.

Commit: "Harte harness: compare the cycle-by-cycle bus trace".

---

## Phase 18 -- LispWorks profiling pass  [hot path -> benchmark]

`PERFORMANCE_PLAN.md` Phase 4, which remains open, aimed at the
implementation this project calls primary. LispWorks runs at roughly a
quarter of SBCL's speed (`nop` ~950 vs ~3550 fps), and every
optimization so far was measured on both but DESIGNED against SBCL's
behaviour -- the bus dispatch and `%expire-channel` in particular may
land very differently there.

Follow that plan's four steps (compat-wrapped profiling helpers,
profile the workloads, act only on what the profile names, record the
findings). The one addition: profile LispWorks FIRST, and treat the
SBCL/LispWorks gap as the thing being investigated rather than an
accepted constant.

Commit: per follow-up the profile justifies, each with
`PERFORMANCE_LOG.md` rows.

---

## Phase 19 -- 256-entry palette

Phase 7 pinned a limitation by test: the 128-entry palette collapses
GTIA mode 9's 16 luminances into 8 pairs. The color bytes the renderer
computes are already hardware-correct, so this is a palette-table
change plus the tests that currently assert the collapsed values.

Widen the table to 256 entries (hue 4 bits x luminance 4 bits), update
`atari-color->r/g/b` and their callers, and update the mode-9 renderer
test to assert 16 distinct luminances.

Commit: "Renderer: 256-entry palette recovers mode 9's 16 luminances".

---

## Phase 20 -- ANTIC display-list latch note

`MISC_IMPROVEMENTS_PLAN.md` item 10, unchanged: an honest comment block
in `src/antic.lisp` at the VBI re-latch and the DLISTL/H write cases,
describing how this emulator's re-latch-every-VBI model diverges from
hardware (which reloads only at JVB), and cross-referencing
SCANLINE_ACCURACY_PLAN.md Phase 4+ where changing the behaviour
belongs. Documentation only.

Commit: "Document the ANTIC display-list latch simplification".

---

## Phase 21 -- Strict test gate + skip census

Phases 1-12 went green while the machine could not boot the real OS:
the tests that matter most (Klaus, Harte, real-ROM boot) are env-gated
and self-skipping, so a suite pass proves least exactly where the
stakes are highest. The PIA register-map and missing-serial-transmitter
showstoppers were found by unplanned work between Phases 10 and 11, not
by any phase's gate. Make the skips impossible to not notice.

1. `tests/test-helpers.lisp`: `%skip-or-fail (reason)` -- when
   `ATARI800_CL_STRICT` is set (non-empty), FAIL with the reason;
   otherwise skip as today. Convert the Klaus, Harte, and real-ROM
   boot tests to it, and use it for every future env-gated test (the
   Phase 13 typing test, Phase 16 ATR boot, Phase 24 Acid800).
2. Skip census: `./scripts/test-sbcl.sh` and `test-lispworks.sh` echo
   one `SKIPPED: <test> (<reason>)` line per skipped test after the
   run -- both already inspect the `fiveam:run!` result list for the
   exit code, so the skipped entries are in hand. Holes stay visible
   in every transcript instead of hiding inside "N checks, 1 skip".
3. This makes ground rule 2's strict sentence operative: on this
   machine (rule 8 says the ROMs are present), a phase is done only
   when the strict run also exits 0.

Tests: the helper itself (strict env var -> failure recorded; unset ->
skip), in `tests/test-compat.lisp` or a small new group -- exercise it
via a dummy test body, not by unsetting real assets.

Commit: "Strict test gate: env-gated skips fail under ATARI800_CL_STRICT".

---

## Phase 22 -- POKEY pending-work bitmask  [hot path -> benchmark]

Serial output cost -1.2% to -4.8% depending on workload, the audio
slot cost -4.2% on `nop`, and Phases 13 and 16a each plan to add
another "one slot read plus branch" to `pokey-advance`. Four
independent per-advance branch tests where one will do. Consolidate
BEFORE 13 and 16a land, so their flags join the mask for free instead
of repeating the measure-and-shrug cycle.

1. One fixnum slot `pokey-pending` on the `pokey` struct: bit 0 =
   serial transmitter active, bit 1 = audio attached, bits 2-3
   reserved for key-pending (Phase 13) and serial receive (Phase 16a).
   The fast path in `pokey-advance` / `pokey-tick` tests `(zerop
   pending)` ONCE per call; nonzero branches to a NOT-inlined cold
   function that dispatches on the set bits. The audio advance moves
   into the cold function too -- audio is a do-work-every-advance bit
   where the others are event flags, but both shapes live behind the
   same single test.
2. Setters maintain the mask: `machine-attach-audio` (and detach)
   toggles bit 1, transmitter start/finish toggles bit 0. Keep
   `%expire-channel` untouched -- the serial commit's log entry records
   why hooks in there cost 8-9%.
3. The 50,000-cycle `pokey-tick` == `pokey-advance` equivalence test
   must run under several mask states (audio attached, serial
   mid-byte, both at once) so the consolidation cannot silently
   diverge the two paths.
4. Measure with `./scripts/bench-ab.sh` (rule 3) against the
   pre-phase commit; expect to recover part of the ~4% `nop` cost.
   Log the paired-delta table either way -- a null result is still a
   result, and it caps the cost of Phases 13 and 16a at zero new
   hot-path branches.

Commit: "POKEY: consolidate per-advance hooks into one pending-work bitmask".

---

## Phase 23 -- CONFIRM retirement pass

The CONFIRM flag means "verify against a reference"; after twelve
phases it functions as a footnote. The status headers above admit the
PRIOR priority orderings, mode 10's nibbles 9-15, and the POKEY reload
offsets all still carry theirs. Retire every flag still standing:
`grep -rn CONFIRM src/ *.md` (currently `src/pokey.lisp:55`,
`src/renderer.lisp:74`, `src/renderer.lisp:413`, plus the flags this
file and the other plan documents carry).

For each one, either:

- (a) verify it against the Altirra Hardware Reference Manual or the
  atari800 source -- the PRIOR orderings and mode-10 nibble behaviour
  against `gtia.c`'s priority tables, the reload offsets and poly taps
  against `pokey.c` -- replace the flag with a file+line citation
  comment, and add a test asserting the confirmed value where one does
  not already pin it; or
- (b) if it genuinely cannot be verified from those sources, record it
  in README.md's known-limitations list as a documented-unverified
  value and say which sources were checked.

No flag survives as a bare CONFIRM. This is an hour or two of
cross-reading the original phases already asked for and nobody did.

Commit: "Retire the CONFIRM flags: citations and tests, or documented
divergence".

---

## Phase 24 -- Acid800 gate (CPU + ANTIC subsets)

The CPU has an external ratchet (Harte); ANTIC, GTIA, and POKEY are
tested only against this emulator's own model -- their tests assert
the implementation back at itself. Acid800 under the real OS ROM is
the cheapest external check available and has been "aspirational" in
the definition of done long enough. Run it BEFORE Phase 17: the ANTIC
subset is the first outside evidence the Phase 5 steal tables and
Phase 3 WSYNC have ever faced, where 17 only deepens the CPU's
already-strongest evidence.

1. `scripts/fetch-acid800.sh`, modelled on `fetch-test-roms.sh`:
   download the Acid800 test suite into `roms/acid800/` (gitignored),
   no-op when present, note the license and source URL.
2. Env-gated tests in `tests/test-machine.lisp`'s real-ROM group,
   strict-gated via Phase 21's `%skip-or-fail`: load each test XEX via
   the existing XEX loader (`scripts/xex-loader.lisp` mechanism), run
   frames, and read the pass/fail state from screen memory the way the
   boot test reads `Ready`.
3. CPU subset first -- expected to pass given Harte; a failure here is
   information about the BUS or interrupt timing, which
   per-instruction vectors cannot see. Then the ANTIC subset. Triage
   failures the Harte way: presumed real emulator bugs, fix in `src/`,
   regression test per fix, skip only with a documented reason.
4. Move the definition-of-done bullet from "aspirational" to gated on
   whichever subsets pass, and list the ones that do not yet in
   README.md's limitations.

Commit: "Add the Acid800 harness: CPU and ANTIC subsets under the real OS".

---

## Roadmap definition of done

- Suite green on SBCL and LispWorks after every phase (rule 2).
- `./scripts/record.sh asm/edvent02_rasterbars.asm -frames 300` yields
  an mp4 with visible animated raster bars and (once a demo uses
  POKEY) audible tone.
- `PERFORMANCE_LOG.md` has rows for phases 3, 5, 6, 9.
- The plan status headers reflect reality. As of 2026-08-07:
  `SCANLINE_ACCURACY_PLAN.md` Phases 0-3 done, stretch 4-5 open (Phase
  17 below is their prerequisite); `MISC_IMPROVEMENTS_PLAN.md` items
  1-8 done, 9 and 10 open, 11 obsolete (superseded by item 4);
  `PERFORMANCE_PLAN.md` Phases 0-3 done (2 rejected on measurement),
  Phase 4 open as Phase 18 below.
- Acid800's CPU + ANTIC subsets under the real OS ROM: gated once
  Phase 24 lands (previously aspirational).

For the 13-24 tranche, done means: the machine can be typed at (13) and
booted from a disk image (16), the Harte data is one command away (14)
and checks bus traces rather than cycle counts alone (17), the docs
match the code (15, 20), a suite pass on this machine proves the
real-ROM paths instead of skipping them (21), the POKEY hot path
carries one pending-work test instead of four (22), no bare CONFIRM
flag remains anywhere (23), and Acid800's CPU subset passes under the
real OS (24).
