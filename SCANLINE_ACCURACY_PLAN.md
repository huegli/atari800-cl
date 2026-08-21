# Scanline Accuracy Plan

> **Status (2026-08-02): Phases 0-3 complete and merged to main.**
> The scanline-granular scheduler shipped (with the full per-line DMA
> steal charged to the CPU budget) and the pixel renderer now rides on
> it. The "Current state" section below describes the pre-Phase-1
> per-clock loop and is retained for historical context. Phase 0 (the
> color-clock -> CPU-cycle rename) landed via ROADMAP.md Phase 2. Phase
> 2 (WSYNC) landed via ROADMAP.md Phase 3 as a first cut that stalls
> to end-of-line, not the hardware-accurate cycle 105 (that refinement
> is still this plan's stretch Phase 4). Phase 3 (playfield DMA steal
> tables + DL fetch accounting) landed via ROADMAP.md Phase 5. It
> initially shipped with map-mode (8-14) byte counts taken from the
> renderer instead of this plan's table -- a correction that ran the
> wrong way: THIS PLAN'S TABLE WAS RIGHT (each mode's pixel width x
> bits per pixel / 8, per the Altirra Hardware Reference), and the
> renderer's map-mode geometry was the divergent part. A follow-up
> commit restored the hardware table (BYTES-PER-SCREEN-ROW in
> `src/antic.lisp`, now shared by the renderer, the steal accounting,
> and the screen-pointer advance), fixed the renderer's map modes to
> hardware geometry, and made map modes fetch on the first scanline
> of a mode line only, exactly as step 1 below specified. The
> stretch Phases 4-5 remain open.
>
> **Update (2026-08-07):** the Tom Harte harness (ROADMAP.md Phase 12)
> now pins every opcode's CYCLE COUNT -- 2,560,000 cases, zero
> failures -- which is a useful floor under Phase 5 but not a check of
> it: the harness compares only the LENGTH of each case's bus trace,
> not the accesses themselves, so Phase 5's RMW double-write (item 1)
> and indexed dummy reads (item 2) are still entirely unverified and
> almost certainly unmodelled. ROADMAP.md Phase 17 extends the harness
> to compare the trace itself and is the recommended prerequisite for
> attempting items 1-2 -- it converts them from a guess into a failing
> assertion at a known cycle index. One Phase 5-adjacent bug was fixed
> in passing: JSR read its high operand byte before pushing rather
> than after (regression test in `tests/test-regressions.lisp`).
>
> **Update (2026-08-20): Phase 5 items 1-2 done, via ROADMAP.md Phase
> 17.** "CPU: RMW double-write (unmodified value first)" and "CPU:
> indexed-addressing dummy reads at the un-carried address" land both
> quirks -- the second commit grew past its name once the full
> 2,560,000-case Harte corpus (run under the new trace comparison) showed
> the dummy-read behaviour is not unique to indexed addressing: every
> instruction whose cycle count exceeds its minimal bus need spends the
> extra cycles on a real, discarded read on hardware, and this project
> was skipping all of them. Now modelled: implied/accumulator opcodes,
> PHA/PHP/PLA/PLP, JSR/RTS/RTI, BRK's signature byte, and a taken
> branch's target computation, alongside the originally-scoped indexed
> addressing (abs,X/abs,Y/(zp),Y conditional-on-cross for reads,
> unconditional for stores/RMW; zero-page-indexed and (zp,X)
> unconditional always). The full corpus's trace comparison is green on
> both SBCL and LispWorks, `ATARI800_CL_STRICT=1` included -- see
> `CHANGES.md` and `PERFORMANCE_LOG.md` for the full writeup. Items 3-5
> (interrupt poll timing, SEI/CLI/PLP delay, BRK/NMI hijack) remain open.

Goal: move the emulator from frame-level timing to scanline-level timing
accuracy, in dependency order. Each phase is independently committable and
leaves the suite green.

## Ground rules (apply to every phase)

- Read `CLAUDE.md` first. Key constraints: no reader conditionals outside
  `src/compat.lisp`; `defstruct` over `defclass`; verbose docstrings on
  exported symbols; `.asd` is `:serial t` so file order matters.
- After every phase run BOTH `./scripts/test-sbcl.sh` and
  `./scripts/test-lispworks.sh`. Both must exit 0 before committing.
- Correctness over performance. If a change speeds things up, fine, but do
  not trade modelled behaviour for speed in this plan.
- New timing behaviour gets a FiveAM test in the matching `tests/test-*.lisp`
  child suite, plus a regression test in `tests/test-regressions.lisp` when
  the phase fixes a concrete discrepancy.
- Hardware references: Altirra Hardware Reference Manual (authoritative for
  ANTIC/GTIA/POKEY cycle behaviour) and the atari800 emulator source. When
  this plan says "confirm against the reference", do that before coding --
  some numbers below are stated from memory and flagged as such.

## Current state (for orientation)

- `src/machine.lisp` `%RUN-CLOCKS` advances one "color clock" at a time:
  `antic-tick` + `pokey-tick` per clock, CPU stepped from a cycle budget
  (1 budget per non-stolen clock, instructions debited via `step-cpu`'s
  return value; interrupts serviced inside `step-cpu`, 7 cycles debited).
- `src/antic.lisp` `ANTIC-TICK` does all work at color-clock 0 of each line:
  VBI on line 248, DL instruction fetch, DLI on last line of a mode line,
  and a lumped per-line steal of DRAM refresh (9) + P/M DMA (0-5).
- NOT modelled: WSYNC ($D40A -- constant `+reg-wsync+` exists, write is
  ignored), playfield/display-list DMA stealing, intra-line event positions,
  NMOS bus quirks (dummy reads, RMW double-write, interrupt-poll timing).

---

## Phase 0 -- Terminology: the line unit is CPU cycles, not color clocks

A real NTSC line is 228 color clocks = 114 CPU cycles (color clock runs at
2x CPU clock). The code calls its 114-per-line unit "color clocks", which
will cause real confusion once cycle numbers from hardware docs (which are
in CPU cycles, 0-113) start appearing in this codebase.

1. Rename `+color-clocks-per-scanline+` -> `+cpu-cycles-per-scanline+`
   (exported from `atari800-cl.antic`; update `src/package.lisp`, all uses
   in `src/antic.lisp`, `src/machine.lisp`, and tests -- grep, there are uses
   in `tests/test-antic.lisp` and `tests/test-regressions.lisp`).
2. Rename the `antic` struct slot `color-clock` -> `line-cycle` (exported
   accessor `antic-color-clock` -> `antic-line-cycle`; update package.lisp
   and all callers/tests).
3. Sweep comments/docstrings in `antic.lisp`, `machine.lisp`, `main.lisp`
   that say "color clock" for the 114-unit; reword as "CPU cycles (114 per
   line; a real line is 228 color clocks at twice the CPU rate)". Keep
   `+clocks-per-frame+` = 29,868 but fix its docstring similarly.
4. Update the stale sentence in `CLAUDE.md` ("29,868 NTSC color clocks").

Tests: suite green on both implementations (pure rename + docs).
Commit: "Rename ANTIC's line unit from color clocks to CPU cycles".

---

## Phase 1 -- Scanline-granular scheduler

Restructure the frame loop from per-clock to per-scanline. This is the
structural home for WSYNC (Phase 2) and DMA tables (Phase 3), and removes
~29,000 redundant `antic-tick`/`pokey-tick` calls per frame.

Design:

1. In `src/antic.lisp` add two scanline-level entry points (keep
   `antic-tick` working -- it is exported and heavily tested -- by
   reimplementing it later or leaving it as the 1-cycle reference path):
   - `ANTIC-BEGIN-SCANLINE (antic cpu bus)` -- everything `antic-tick`
     currently does at clock 0: VBI check/raise (line 248 + DL pointer
     re-latch), DL instruction fetch when a new mode line is due, DLI
     check/raise, and return the cycles stolen this line (for now the
     existing `%scanline-steal`).
   - `ANTIC-END-SCANLINE (antic)` -- the end-of-line bookkeeping currently
     at the 113->0 wrap: decrement `mode-scanlines-remaining`, increment
     `scanline`, wrap at `+scanlines-per-frame+` and bump `frame-count`.
   - Factor the shared logic so `antic-tick` and the new functions cannot
     drift apart (extract `%begin-scanline-events` / `%end-scanline-events`
     helpers both paths call).
2. In `src/pokey.lisp` add `POKEY-ADVANCE (pokey cpu n)` -- advance POKEY by
   N CPU cycles. Initial implementation: `(dotimes (i n) (pokey-tick pokey
   cpu))`. (PERFORMANCE_PLAN.md Phase 3 optimizes its internals later; this
   plan only needs the API.) Export it.
3. In `src/machine.lisp` rewrite `%RUN-CLOCKS` around a per-line inner loop:
   ```
   for each whole scanline in N:
     stolen  := antic-begin-scanline(antic, cpu, bus)
     budget  += 114 - stolen
     while budget >= 2 and not cpu-halted:
       used   := step-cpu(cpu)          ; services NMI/IRQ itself
       budget -= used
       pokey-advance(pokey, cpu, used)  ; keep POKEY/CPU interleaving
     pokey-advance(pokey, cpu, <line cycles not consumed by the CPU>)
     antic-end-scanline(antic)
   ```
   Critical interleaving requirement: POKEY must advance instruction-by-
   instruction alongside the CPU (as shown), NOT in one 114-cycle batch per
   line -- otherwise POKEY timer IRQ delivery shifts by up to a line and the
   POKEY/machine tests change meaning. The total POKEY cycles per line must
   equal exactly 114 (track consumed vs. remaining; mind that `budget` can
   carry across lines -- only top up POKEY for THIS line's 114).
   Keep the KIL/`illegal-opcode` handler-case behaviour as-is.
4. `%RUN-CLOCKS` contract: N that is not a multiple of 114 runs
   floor(N/114) full lines then one partial line (budget `min(remainder,
   114) - stolen-if-line-start`); document this in the docstring. The
   existing callers (`machine-run-frame` 29,868 = 262 lines; regression #7
   456 = 4 lines) are whole-line multiples. Keep the `abort-pred` hook,
   now checked once per scanline (its documented granularity).
5. Verify the cycle-conservation invariant still holds: regression test
   `interrupt-entry-cycles-count-against-frame-budget` must pass unchanged.

New tests (`tests/test-machine.lisp`):
- One `machine-run-frame` advances `antic-frame-count` by 1 and returns
  the scanline counter to its starting value (262 lines consumed).
- VBI NMI is raised exactly once per frame with NMIEN bit 6 set (count via
  a flag-resetting OS stub or by checking `antic-nmist` after `nmires`).
- A POKEY timer IRQ programmed to fire mid-line is serviced within the
  same scanline it fires on (guards the interleaving requirement).

Commit: "Restructure the frame scheduler to scanline granularity".

---

## Phase 2 -- WSYNC ($D40A)

The single most important register for scanline-accurate software; every
DLI handler starts with `STA WSYNC`. Semantics: a write halts the CPU until
cycle 105 of the current scanline (it resumes ~9 cycles before line end).
First implementation may stall to end-of-line; the 105-cycle refinement
lands with Phase 4's intra-line positions.

1. `src/antic.lisp`: add struct slot `wsync-pending` (boolean). In
   `ANTIC-WRITE`, add a `+reg-wsync+` case that sets it. Add
   `ANTIC-CONSUME-WSYNC (antic)` -- read-and-clear, returns the old value.
   Export both. Document the offset ($0A, mirrored across $D4xx).
2. `src/machine.lisp` inner loop: after each `step-cpu`, check
   `antic-consume-wsync`; if true, zero the remaining line budget (the CPU
   is halted until end of line) but still `pokey-advance` the skipped
   cycles. Decide and document what happens to budget carried from previous
   lines: real WSYNC freezes the CPU regardless, so clamp `budget` to 0,
   don't let a pre-existing surplus leak past the stall.
3. Edge cases to handle and test: two WSYNC writes in a row (second stalls
   to the NEXT line end -- on real hardware back-to-back STA WSYNC skips a
   full line); WSYNC written by the last instruction that fits in a line
   (no-op stall); WSYNC via a read-modify-write instruction is out of scope
   until Phase 5 (note it in a comment).

Tests (`tests/test-antic.lisp` + one regression):
- Unit: `antic-write` to $D40A sets the flag; `antic-consume-wsync` clears.
- Machine-level: synthetic OS ROM (use `%make-synthetic-os-rom` + `%poke`)
  with reset code at $C000: `STA $D40A` then `STA $00` (marker write to
  zero page, `%poke` opcodes `8D 0A D4  85 00`). Run exactly one scanline
  via `%run-clocks`; assert RAM $00 is still 0 (CPU stalled). Run one more
  line; assert the marker got written. Also assert
  `(cpu-cycles cpu)` for the first line is roughly the pre-WSYNC
  instruction cost, not a full line of execution.

Commit: "Implement WSYNC: CPU stalls to end of scanline".

---

## Phase 3 -- Playfield DMA steal tables + DL fetch accounting

> **Done** (ROADMAP.md Phase 5). The bytes-per-line table below for
> modes 8-14 is superseded -- it was stated from memory and turned out
> to disagree with the already-tested renderer; see
> `PLAYFIELD-DMA-CYCLES`'s docstring in `src/antic.lisp` for the
> corrected table actually shipped. Modes 2-7's counts (40/20) and the
> overall fetch-timing rules (name-on-first-line, font-every-line for
> text; DL-fetch byte accounting) shipped as specified below.

The largest remaining timing error: ANTIC steals only refresh (9) + P/M DMA
(0-5) per line, but real character modes steal ~40+ more cycles per line.
After this phase, per-frame CPU throughput should be within a few percent
of real hardware for standard display lists.

1. Build the steal model in `src/antic.lisp` as data + one pure function
   `PLAYFIELD-DMA-CYCLES (mode-byte dmactl first-line-p)` with docstring
   and unit tests. Inputs: ANTIC mode (low nibble), playfield width from
   DMACTL bits 0-1 (00 off, 01 narrow, 10 normal, 11 wide), and whether
   this is the first scanline of the mode line.
   Bytes-per-line table (CONFIRM against the Altirra Hardware Reference
   before encoding -- stated from memory):
   | modes      | narrow | normal | wide |
   |------------|--------|--------|------|
   | 2,3,4,5    | 32     | 40     | 48   |
   | 6,7        | 16     | 20     | 24   |
   | 8,9        | 8      | 10     | 12   |
   | A,B,C      | 16     | 20     | 24   |
   | D,E,F      | 32     | 40     | 48   |
   Fetch rules (confirm): text modes (2-7) fetch character NAMES on the
   first scanline of the mode line only (ANTIC line-buffers them) and
   character FONT data on every scanline; map modes (8-F) fetch screen
   data on the first scanline only. Blank lines (mode 0) and JMP/JVB
   steal no playfield cycles.
2. Account DL instruction fetch: 1 cycle per mode-line fetch, +2 for the
   LMS address bytes, +2 for JMP/JVB operands. `process-dl-instruction`
   knows exactly how many bytes it consumed -- return that count and charge
   it into the line's steal.
3. Wire into `ANTIC-BEGIN-SCANLINE`: steal = 9 (refresh) + P/M DMA +
   DL fetch (on mode-line boundaries) + playfield DMA for the current
   mode/width/first-line-p. ANTIC already tracks `current-mode` and
   `mode-scanlines-remaining` -- derive `first-line-p` from the fetch path.
4. Guard rails: steal must never exceed 114; `(- 114 stolen)` is the line
   budget. With wide playfield + P/M + refresh this gets close -- assert
   (in a test, not production code) the worst case stays under 114, or
   clamp with a documented comment if the confirmed numbers exceed it
   (real ANTIC + wide + HSCROL can exhaust nearly the whole line).
5. Out of scope (document in the file header): HSCROL widening the fetch
   window, the exact cycle POSITIONS of the steals (Phase 4), and the
   one-cycle differences for odd HSCROL values.

Tests:
- Unit-test `playfield-dma-cycles` against the confirmed table (all modes
  x widths x first/subsequent line).
- Frame-level: build a display list of 24 mode-2 lines + JVB in RAM,
  DMACTL = $22; run one frame; assert total CPU cycles consumed falls in
  the expected band (compute expected granted budget from the tables; use
  a +/- one-instruction tolerance). Add as a regression test -- this pins
  the whole steal model.
- Existing `test-antic.lisp` DLI/VBI tests must still pass (they use
  `antic-tick`; keep that path consistent with the new accounting or
  document the divergence explicitly).

Commit: "Model ANTIC playfield and display-list DMA cycle stealing".

---

## Phase 4 -- Intra-line event positions (stretch)

Converts "everything happens at line start" into positioned events. Needed
for software that races the beam or chains WSYNC+DLI precisely.

1. Research first (Altirra Hardware Reference): NMI assertion cycle for DLI
   and VBI (around cycle 8 -- confirm), WSYNC release at cycle 105, VCOUNT
   increment position (around cycle 111 -- confirm), and where refresh and
   playfield fetches actually occur within the line.
2. Design: split each scanline into segments bounded by event cycles. The
   machine inner loop runs the CPU segment-by-segment (budget per segment),
   firing events at their boundaries. Keep the event list static per line
   type (computed in `antic-begin-scanline`).
3. Implement in this order, each with a test: (a) WSYNC release at 105
   rather than 114; (b) DLI/VBI NMI assertion at the confirmed cycle;
   (c) VCOUNT mid-line increment (test: program polls VCOUNT in a tight
   loop and observes the transition cycle).
4. Re-validate Phase 3's frame-budget regression band.

Commit per sub-item; this phase can stop at any point and still be a net
accuracy win.

---

## Phase 5 -- NMOS 6502 bus quirks (stretch, after Phase 4)

Only meaningful once I/O timing within the line is positioned. Each item is
its own commit with tests in `tests/test-cpu-opcodes.lisp` /
`tests/test-illegal.lisp` using a recording bus stub (wrap `cpu-bus-read`/
`cpu-bus-write` closures that log accesses).

1. **Done (ROADMAP.md Phase 17, 2026-08-20).** RMW double-write:
   INC/DEC/ASL/LSR/ROL/ROR (and the illegal compound RMWs) write the
   UNMODIFIED value, then the modified one. Visible on hardware registers
   (`DEC WSYNC`, HITCLR). Tests: recording bus sees two writes,
   original-then-modified, in `tests/test-cpu-opcodes.lisp` /
   `tests/test-illegal.lisp`.
2. **Done (ROADMAP.md Phase 17, 2026-08-20)**, and broader than
   originally scoped. Dummy reads on indexed addressing page-cross:
   abs,X / abs,Y / (zp),Y read from the un-carried address (base's high
   byte + indexed low byte) before the corrected one; stores and RMW
   through those modes ALWAYS do the dummy read; zero-page-indexed and
   (zp,X) always dummy-read their unindexed address. The full Harte
   corpus, run under the new trace comparison, showed the same
   "speculative next fetch" idea applies well past indexed addressing:
   every implied/accumulator opcode, PHA/PHP/PLA/PLP, JSR/RTS/RTI, BRK's
   signature byte, and a taken branch's target computation were all
   spending their already-correct cycle count on no bus access at all,
   where hardware performs a real (if discarded) one. All now modelled;
   the trace comparison is green across the full 2.56M-case corpus on
   both implementations.
3. Interrupt poll timing: interrupts are recognized on the second-to-last
   cycle of an instruction; a taken branch without page cross delays
   recognition by one instruction. Requires modelling "poll point" per
   instruction -- significant design work; write a short design doc comment
   in `cpu.lisp` before implementing.
4. SEI/CLI/PLP one-instruction delay on the I-flag's effect on IRQ
   recognition.
5. BRK/NMI hijack (NMI arriving during BRK's vector fetch turns it into an
   NMI with B-flag quirks) -- lowest priority.

## Acceptance target for the whole plan

Aspirational: the Acid800 test suite (CPU + ANTIC subsets) passing under a
real OS ROM is the recognized bar for this level of accuracy. Not a gate
for any single phase, but track progress against it once Phases 1-4 land.

## Explicit non-goals

Pixel-level rendering/framebuffer, PAL timing, GTIA collision generation
from rendering, POKEY audio synthesis, SIO/serial, cartridge mapping.
