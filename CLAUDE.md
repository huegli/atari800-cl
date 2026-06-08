# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Headless Atari 800 XL emulator in portable Common Lisp. Primary target is **LispWorks**; also supports **SBCL**.

The emulated machine is functionally complete at the chip-state level:

- **6502 CPU** — all 256 opcodes (151 documented + 105 NMOS illegal/undocumented), with NMI/IRQ servicing.
- **MMU** — PORTB-driven bank switching (OS ROM, BASIC ROM, self-test overlay).
- **System bus** — full Atari 800 XL memory map with RAM/ROM banking and memory-mapped I/O dispatch to the four chips.
- **PIA** (6520), **ANTIC** (NTSC scanline timing + display-list DMA), **GTIA** (player/missile state + collision latches), **POKEY** (timers, IRQ, RNG, audio register scaffolding).
- **Machine scheduler** — `MACHINE-RUN-FRAME` pumps 29,868 NTSC color clocks per frame, ticking ANTIC/POKEY and stepping the CPU.

What is *not* modelled: pixel-level video rendering (no framebuffer), POKEY audio synthesis (register state only), serial/SIO bus, keyboard scanning, paddles/light-pen, and cartridge mapping. See README.md "Known limitations" for the full list. Correctness, especially 6502 behavioral accuracy, is prioritized over performance.

## Build & Test Commands

Load the system in a Lisp REPL:
```lisp
(ql:quickload :atari800-cl)
```

Run the full test suite in a REPL:
```lisp
(ql:quickload :atari800-cl/tests)
(asdf:test-system :atari800-cl)
```

**Tests must pass on BOTH SBCL and LispWorks** — this is a portability
project, and a change is not done until the suite is green on both. Run
both before committing.

> **Exit-code gotcha:** `asdf:test-system` returns `T` even when tests
> *fail*, so it is useless for shell/CI exit codes. Always key the exit
> status off `fiveam:run!`, which returns `T` only when every check
> passes. The commands below do this (exit 0 = all pass, 1 = failure).

Run from shell with **SBCL** (`.sbclrc` loads Quicklisp before `--eval`):
```sh
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

Run from shell with **LispWorks** (the console image is `lw-console` in
`$PATH`). Command-line `-eval` forms are *read* before the init file
loads Quicklisp, so load `setup.lisp` first and defer the `ql:` symbol
with `read-from-string`:
```sh
lw-console -eval '(load "~/quicklisp/setup.lisp")' \
           -eval '(funcall (read-from-string "ql:quickload") :atari800-cl/tests)' \
           -eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

Run a single FiveAM test by name:
```lisp
(fiveam:run! 'atari800-cl/tests::reset-loads-pc-from-vector)
```

Run a single test suite (e.g. just the CPU opcode tests):
```lisp
(fiveam:run! 'atari800-cl/tests::cpu-opcode-suite)
```

## Architecture

### Package layering (bottom-up dependency order)

Each chip lives in its own package; `:use` edges define the layering. The `.asd` lists files in this dependency order (`:serial t`).

1. **atari800-cl.compat** (`src/compat.lisp`) — Portability layer isolating all `#+lispworks`/`#+sbcl` differences: type aliases (`u8`, `u16`, `byte-vector`), threading, binary I/O, GC warnings. **All conditional compilation lives here**; other source files must not use reader conditionals.

2. **atari800-cl.memory** (`src/memory.lisp`) — Legacy flat 64K address space, RAM + ROM overlay slots. Used only by the legacy `emulator` facade (below); the full machine uses `bus`/`mmu` instead.

3. **atari800-cl.mmu** (`src/mmu.lisp`) — Bank-switching unit: owns the PORTB shadow byte and exposes the OS-ROM / BASIC-ROM / self-test predicates the bus consults on ROM-overlap reads.

4. **atari800-cl.bus** (`src/bus.lisp`) — System bus owning RAM + ROM images and the full memory map. Routes every address to RAM, a ROM image, or one of the four chip I/O ranges (`$D000` GTIA, `$D200` POKEY, `$D300` PIA, `$D400` ANTIC). Chips register **read/write closures** into the bus when attached, so `bus.lisp` never references chip-package symbols — this breaks what would otherwise be circular package dependencies.

5. **atari800-cl.cpu** (`src/cpu.lisp` + `src/cpu-opcodes.lisp` + `src/illegal.lisp`) — Bus-agnostic NMOS 6502 core. The CPU communicates via two function slots (`cpu-bus-read`, `cpu-bus-write`) rather than referencing memory directly, so anything (the bus, or a bare memory object via the legacy `attach-memory-bus`) can intercept reads/writes. The 256-entry dispatch table (`*opcode-table*`) is a simple-vector of `(lambda (cpu) -> cycles)` built by `DEFOPCODE`; `illegal.lisp` fills the remaining 105 undocumented slots.

6. **Peripheral chips** — **atari800-cl.pia** (`src/pia.lisp`, 6520; PORTB writes route through `mmu`), **atari800-cl.antic** (`src/antic.lisp`), **atari800-cl.gtia** (`src/gtia.lisp`), **atari800-cl.pokey** (`src/pokey.lisp`), and **atari800-cl.irq** (`src/irq.lisp`, NMI/IRQ line routing into the CPU).

7. **atari800-cl.machine** (`src/machine.lisp`) — The real top-level: the `atari-machine` struct owns one of each chip plus the bus. `make-atari-machine` builds and wires everything (chip closures into the bus, bus into the CPU's hooks); `machine-cold-reset` loads ROMs and boots; `machine-run-frame` is the frame scheduler. Also provides REPL instrumentation (`machine-trace-step`, `machine-portb-state`, `machine-scanline`, `machine-pending-interrupts`).

8. **atari800-cl.emulator** (`src/emulator.lisp`) — **Legacy** `machine` struct gluing just CPU + `memory` together (no chips). Predates the full `machine` package; kept because the public facade still wraps it.

9. **atari800-cl** (`src/main.lisp`) — Public facade (nicknamed `a800`) re-exporting a user-facing API. **Note:** it currently wraps the legacy `emulator`, not the full `atari-machine` — driving the complete machine means calling `atari800-cl.machine:` functions directly.

### CPU opcode pattern

Opcodes are defined via the `DEFOPCODE` macro which creates a named function (`OPCODE-<MNEMONIC>-<HEX>`) and installs it into `*opcode-table-builder*` (copied into `*opcode-table*` once all files load). Family macrolets (`load-op`, `store-op`, `logical`, `arith`, `cmp-op`, `memop`, `rmw`) generate all addressing-mode variants from compact declarations. Documented opcodes live in `cpu-opcodes.lisp`; the 105 NMOS illegal/undocumented opcodes (KIL/JAM, SLO/RLA/SRE/RRA/DCP/ISC, LAX/SAX, etc.) live in `illegal.lisp`.

### Test structure

Tests use FiveAM. The root suite is `atari800-cl-suite` in `tests/test-suite.lisp`; each component file defines a child suite `:in` it: `compat-suite`, `memory-suite`, `cpu-suite`, `cpu-opcodes-suite`, `illegal-opcodes`, `mmu-suite`, `pia-suite`, `antic-suite`, `gtia-suite`, `pokey-suite`, `machine-suite`, and `regression-suite`. Shared fixtures (`%MAKE-SYNTHETIC-OS-ROM`, `MAKE-TEST-MACHINE`, `WITH-CPU-STATE`, `%POKE`) live in `tests/test-helpers.lisp`. The test package `:import-from`s FiveAM symbols (not `:use`) to avoid name collisions between implementations.

The **Klaus Dormann 6502 functional test** (`tests/test-cpu.lisp`) runs if `roms/6502_functional_test.bin` exists (or `$ATARI800_CL_FUNCTIONAL_TEST` points to it), otherwise it skips gracefully. Build the binary from https://github.com/Klaus2m5/6502_65C02_functional_tests with `org=0000` and `load_data_direct=1`.

## Development Plan

`AI-Docs/AI-Prompts.md` contains the step-by-step build plan (Prompts 1–14) that produced the emulator; all of it is complete. (Prompt 12's optional Unix-socket IPC layer was later removed — see `CHANGES.md`.) The prompt file and `AI-Docs/atari800-plan.md` are historical records; consult them for context, but the code and `CHANGES.md` are the source of truth for current state.

## Key Conventions

- ASDF `:serial t` — file order in the `.asd` matters; new source files must be inserted at the correct position in the dependency chain.
- All implementation-specific code goes in `src/compat.lisp`. Never add `#+lispworks`/`#+sbcl` elsewhere.
- The CPU is bus-agnostic: peripherals hook into `cpu-bus-read`/`cpu-bus-write`, not into the memory struct directly.
- Prefer `defstruct` over `defclass`. Write verbose docstrings on exported functions and structs.
- Correctness (especially 6502 behavioral accuracy) is the priority over performance.
- ROM images (`roms/*.rom`, `roms/*.bin`) are gitignored and never committed.
