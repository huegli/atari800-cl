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
> implementations. Every phase in this roadmap is now done.

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
   The suite currently passes 1450/1450 checks on both.
3. **Benchmark rule**: any phase touching the hot path
   (`src/machine.lisp` `%run-clocks`, `src/antic.lisp` scanline events,
   `src/pokey.lisp` tick/advance, `src/renderer.lisp` per-line work)
   must run `./scripts/bench-sbcl.sh` and `./scripts/bench-lispworks.sh`
   three times each before and after, and add mean-of-3 rows plus a
   short note to `PERFORMANCE_LOG.md`. Phases 3, 5, 6, and 9 below
   are hot-path phases.
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

Phases 6/7/8 are independent of 3/5 and can be reordered if blocked.
Phase 12 is independent of everything and can run any time; it is last
only because it produces no video-visible payoff.

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

## Roadmap definition of done

- Suite green on SBCL and LispWorks after every phase (rule 2).
- `./scripts/record.sh asm/edvent02_rasterbars.asm -frames 300` yields
  an mp4 with visible animated raster bars and (once a demo uses
  POKEY) audible tone.
- `PERFORMANCE_LOG.md` has rows for phases 3, 5, 6, 9.
- The plan status headers (`SCANLINE_ACCURACY_PLAN.md`: Phases 0-3
  done, 4-5 open; `MISC_IMPROVEMENTS_PLAN.md`: 1-8 done, 10 open;
  this file) reflect reality.
- Aspirational, not gating: Acid800's CPU + ANTIC subsets under the
  real OS ROM -- track once Phases 3-6 land.
