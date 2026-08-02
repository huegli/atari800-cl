# Changes

A flat log of what each build phase delivered, in commit order.
For deeper detail see `git log` on the corresponding feature branch.

## ROADMAP Phase 2 — rename color clocks to CPU cycles

SCANLINE_ACCURACY_PLAN.md's previously-skipped Phase 0. The 114-unit
ANTIC and the machine scheduler use per scanline is CPU cycles, not
color clocks (a real NTSC line is 228 color clocks at twice the CPU
rate; hardware references quote cycle positions 0-113). Renamed
`+color-clocks-per-scanline+` → `+cpu-cycles-per-scanline+` and the
`antic` struct slot/accessor `color-clock`/`antic-color-clock` →
`line-cycle`/`antic-line-cycle` throughout `src/` and `tests/`, and
reworded the surrounding comments/docstrings. Pure rename — no
behaviour change.

Suite: 1708/1708 checks green on both SBCL and LispWorks (unchanged
count, confirming no behaviour change).

## ROADMAP Phase 1 — cheap hardening batch

Four independent fixes from `MISC_IMPROVEMENTS_PLAN.md`:

- **Opcode-table reload robustness** (item 1) — `*OPCODE-TABLE*` and
  `*OPCODE-MNEMONIC-TABLE*` are now load-time `DEFVAR`s in `cpu.lisp`;
  `DEFOPCODE` writes directly into them instead of through a temporary
  `*OPCODE-TABLE-BUILDER*` bulk-installed at end of file. Reloading
  `cpu-opcodes.lisp` alone in a live image no longer silently drops
  `illegal.lisp`'s 105 handlers.
- **Reset flag consistency** (item 2) — `machine-cold-reset` now sets
  P to `#x24` (U=1, I=1), matching `reset-cpu`; it previously set
  `#x34`, disagreeing about the phantom B bit (not a real register bit
  outside a pushed stack copy).
- **LispWorks `chmod-file` via FLI** (item 8) — replaced the
  `/bin/chmod` shell-out with a direct `fli:define-foreign-function`
  binding to `chmod(2)`, following the existing `%getpid` pattern.
- **`scripts/fetch-test-roms.sh`** (item 3) — downloads the prebuilt
  Klaus Dormann functional-test binary into `roms/` (gitignored,
  no-ops if already present), unblocking that test without a manual
  build step.

Suite: 1708/1708 checks green on both SBCL and LispWorks.

## Branch consolidation — everything back on main

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

- `src/renderer.lisp` — `:atari800-cl.renderer`: converts ANTIC
  display-list state + GTIA registers into a 384×240 24-bit RGB
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

- `asm/hello.asm`, `asm/edvent01.asm` — example 6502 programs in MADS
  syntax.
- `scripts/mads-build.sh` / `scripts/mads-run.sh` — assemble MADS
  sources to XEX and run them in the emulator.
- `scripts/runner.lisp` + `scripts/xex-loader.lisp` — load a XEX into
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
- Result (vs. Phase 3, mean of 3): SBCL klaus 1954 → 3381 fps;
  LispWorks irq 626 → 1607 fps.  Full rows in `PERFORMANCE_LOG.md`.

## Performance Phases 1-3 (PERFORMANCE_PLAN)

- **Phase 1** — `(optimize (speed 3) (safety 1) (debug 1))` + `ftype`
  declarations on the hot path (bus, CPU, chips).  LispWorks nop
  250 → 653 fps; SBCL nop 1961 → 2339 fps.
- **Phase 2** — page-dispatch table for `BUS-READ`/`BUS-WRITE`:
  implemented, measured, **rejected** (LispWorks regressed up to
  5.6%; the COND chain already short-circuits cheaply).  Not merged;
  details in `PERFORMANCE_LOG.md`.
- **Phase 3** — POKEY batched advance: `POKEY-ADVANCE` skips ahead to
  the next timer-expiry event and the 17/9-bit RNG shifts lazily on
  RANDOM reads; `POKEY-TICK` keeps a flat per-cycle loop (the
  batching bookkeeping costs more than it saves at N = 1), with a
  50,000-cycle equivalence test pinning the two paths together.
- Klaus Dormann functional test added as a `klaus` benchmark workload.

## Frame-rate benchmark harness (PERFORMANCE_PLAN Phase 0)

- `scripts/bench.lisp` — portable `:atari800-cl.bench` package building
  the machine with an inlined synthetic OS ROM (no real ROM images
  needed).  Two workloads: `nop` (a NOP sled that loops back via a JMP
  placed below the vector region) and `irq` (a busy loop that arms POKEY
  timer 1, enables IRQs, and fields a bare-`RTI` handler).  Runs 60
  warm-up + 600 timed frames and prints one
  `BENCH <workload> frames=600 seconds=… fps=… realtime-x=…` line per
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

- **Foundation** — `usocket` + `flexi-streams` re-added; `compat.lisp`
  gained process-id / chmod / file-delete and Unix-domain socket helpers
  (`sb-bsd-sockets` on SBCL, an FLI `AF_UNIX` wrapper on LispWorks, since
  usocket has no local-socket support), plus condition-variable and
  thread-lifecycle wrappers.
- **Host input** — `atari800-cl.input`: a mutex-guarded input-state for
  joystick/console/paddle/keyboard, delegated to from PIA/GTIA/POKEY reads
  when attached.
- **Concurrency core** — `atari-machine` gained a command mailbox, a
  background `machine-run-loop` (+ `start-machine`/`stop-machine`), and
  `machine-submit` so non-emulator threads mutate the machine safely.
  `machine-run-frame` was refactored over a new `%run-clocks` helper
  (correctness-neutral).
- **AESP** (`atari800-cl.aesp`) — 8-byte big-endian binary protocol
  (magic `0xAE50`); pure codec + a 3-port (control/video/audio) TCP
  server covering ping/pause/resume/reset/status/info, input events, and
  video/audio subscribe→config.
- **CLI** (`atari800-cl.cli-socket`) — `CMD:<verb>` → `OK:`/`ERR:` text
  protocol over a Unix socket: ping/version/pause/resume/step/reset/
  status/read/write/fill/registers/quit.
- **Façade** — `a800:start-machine`/`stop-machine`,
  `start-aesp-server`/`stop-aesp-server`, `start-cli-socket`/
  `stop-cli-socket`.

Suite grew from 1254 to 1398 checks, green on both SBCL and LispWorks.

## Public façade now drives the full machine; legacy emulator removed

- The `:atari800-cl` (`a800`) façade was rewired from the bare
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

## Phase 14 — Repository handoff (Prompt 14)

- Comprehensive README rewrite: project status, dependency table with
  versions, SBCL + LispWorks setup with SLIME/Sly, full-suite
  invocation per platform, ROM acquisition + boot-toward-BASIC walk-through,
  IPC wire protocol, and a "Known limitations" section that names
  every area still stubbed.
- This file (`CHANGES.md`) — phase-level changelog.
- Docstring audit and type declarations on the hot paths.

## Phase 13 — Test harness audit + CI commands (Prompt 13)

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

## Phase 12 — Headless IPC layer (Prompt 12)

- `src/ipc.lisp` adds an *optional* Unix-domain-socket server that
  spawns a `bordeaux-threads` background thread, accepts one client,
  and pushes a 56-byte wire frame after every `MACHINE-RUN-FRAME`.
- Wire protocol: 4-byte magic `"A8XL"`, u32 frame number, u16
  scanline, 6 reserved bytes, 32 bytes of GTIA write registers, 8
  bytes of POKEY AUDF/AUDC. README documents byte offsets.
- Test coverage includes a real loopback exchange (client connects,
  receives a frame, decodes the header) plus thread-lifecycle tests.

## Phase 11 — ROM loading + boot-toward-BASIC instrumentation (Prompt 11)

- `MACHINE-COLD-RESET` accepts byte arrays or file paths for OS + BASIC.
- New REPL helpers: `MACHINE-TRACE-STEP` (returns N execution
  snapshots with mnemonic strings), `MACHINE-PORTB-STATE`,
  `MACHINE-SCANLINE`, `MACHINE-PENDING-INTERRUPTS`.
- `*OPCODE-MNEMONIC-TABLE*` populated alongside `*OPCODE-TABLE*` by
  `DEFOPCODE` so tracing decodes opcodes without a separate disassembler.
- README "Running toward BASIC" walk-through plus a ROM-image table
  with sizes and md5 hashes.

## Phase 10 — IRQ routing + machine scheduler (Prompt 10)

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

## Phase 9 — POKEY (Prompt 9)

- Timer model with per-channel divider (28-cycle 64 kHz default,
  114-cycle 15 kHz, 1-cycle 1.79 MHz for channels 1 and 3).
- IRQEN/IRQST latches with active-low semantics; writing IRQEN
  restores ack'd bits.
- Two LFSRs (17-bit and 9-bit) clocked every `POKEY-TICK`;
  `POKEY-RANDOM` picks one based on AUDCTL bit 7.
- Stub I/O for paddles, ALLPOT, SKSTAT, serial.

## Phase 8 — GTIA (Prompt 8)

- Split write/read register windows at `$D000-$D0FF`.
- Cold-reset defaults: TRIG0-3 = 1, PAL = 1 (NTSC), CONSOL = 7.
- `GTIA-RECORD-COLLISION` takes keyword identifiers and OR's the
  correct bit into the correct collision register, including the
  symmetric P{a}P / P{b}P latching for player-player collisions.
- `HITCLR` clears the 16-byte collision area only; triggers / PAL /
  CONSOL stay intact.

## Phase 7 — ANTIC (Prompt 7)

- Scanline-oriented engine: 262 lines × 114 color clocks (NTSC).
- DRAM refresh (9 cyc / line) + P/M DMA (+1 missile, +4 player)
  lumped at color-clock 0 of each scanline.
- Display-list parsing: mode 0 (N+1 blank lines), mode 1 (JMP / JVB),
  modes 2-F with per-mode scanline counts, LMS modifier (bit 6), DLI
  bit (bit 7) gated by NMIEN bit 7.
- VBI at scanline 248 (NMIEN bit 6).

## Phase 6 — PIA (Prompt 6)

- 6520 PIA shadow with PORTA / DDRA / PORTB / DDRB at `$D300-$D303`,
  mirrored across the page by `(addr & $03)`.
- PORTB write propagates to `MMU-WRITE-PORTB` for immediate
  bank-switching.

## Phase 5 — Bus + MMU (Prompt 5)

- `atari800-cl.mmu`: PORTB shadow + `os-rom-mapped-p`,
  `basic-rom-mapped-p`, `selftest-mapped-p` predicates.
- `atari800-cl.bus`: 64 KiB RAM + ROM overlays + per-chip dispatch
  closure slots.  ROM reads dispatch through the MMU; I/O writes
  reach chips via attached closures and NEVER leak to RAM.
- `BUS-PEEK-RAM` / `BUS-POKE-RAM` (NOTINLINE) escape the SBCL/arm64
  large-constant-offset codegen bug.

## Phase 4 — Illegal opcodes (Prompt 4)

- 105 NMOS-specific undocumented opcodes: compound RMW (SLO, RLA,
  SRE, RRA, DCP, ISC), LAX, SAX, ANC, ALR, ARR, XAA (unstable), AXS,
  LAS, TAS / AHX / SHX / SHY (unstable stores), SBC duplicate, 27
  multi-byte / extra NOPs, 12 KIL/JAM/STP halt opcodes.
- `documented-opcodes` filters them against `*illegal-opcode-list*`
  so the legacy "151 documented" count stays accurate.

## Phases 1-3 — Scaffold / CPU / Documented opcodes

Bootstrap commits (pre-Prompt-5).  Repository layout, compat layer,
flat memory model, 6502 register file, addressing-mode helpers, all
151 documented opcodes via the `DEFOPCODE` macro family, Klaus
Dormann 6502 functional-test fixture.

See `AI-Docs/AI-Prompts.md` for the per-phase prompt text.
