# Changes

A flat log of what each build phase delivered, in commit order.
For deeper detail see `git log` on the corresponding feature branch.

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
