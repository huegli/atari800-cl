# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Headless Atari 800 XL emulator in portable Common Lisp. Primary target is **LispWorks**; also supports **SBCL**. Early stage — the 6502 CPU core is complete, but ANTIC/GTIA/POKEY peripherals and PORTB bank switching are not yet implemented.

## Build & Test Commands

Load the system in a Lisp REPL:
```lisp
(ql:quickload :atari800-cl)
```

Run the full test suite:
```lisp
(ql:quickload :atari800-cl/tests)
(asdf:test-system :atari800-cl)
```

Run from shell (SBCL):
```sh
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(asdf:test-system :atari800-cl)'
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

1. **atari800-cl.compat** (`src/compat.lisp`) — Portability layer isolating all `#+lispworks`/`#+sbcl` differences: type aliases (`u8`, `u16`, `byte-vector`), threading, binary I/O, GC warnings. **All conditional compilation lives here**; other source files must not use reader conditionals.

2. **atari800-cl.memory** (`src/memory.lisp`) — Flat 64K address space. Currently RAM-only; ROM overlay slots (`os-rom`, `basic-rom`) exist but bank-switching is not yet wired.

3. **atari800-cl.cpu** (`src/cpu.lisp` + `src/cpu-opcodes.lisp`) — Bus-agnostic NMOS 6502 core. The CPU communicates via two function slots (`cpu-bus-read`, `cpu-bus-write`) rather than directly referencing memory, so peripherals can intercept reads/writes. `attach-memory-bus` wires a memory object into these slots. The 256-entry dispatch table (`*opcode-table*`) is a simple-vector of `(lambda (cpu) -> cycles)` built by `DEFOPCODE` macros in `cpu-opcodes.lisp`.

4. **atari800-cl.emulator** (`src/emulator.lisp`) — `machine` struct gluing CPU + memory together. Future peripherals (ANTIC, GTIA, POKEY, PIA) will be added here.

5. **atari800-cl** (`src/main.lisp`) — Public facade re-exporting user-facing API. Nicknamed `a800`.

### CPU opcode pattern

Opcodes are defined via `DEFOPCODE` macro which creates a named function (`OPCODE-<MNEMONIC>-<HEX>`) and installs it into `*opcode-table-builder*`. Family macrolets (`load-op`, `store-op`, `logical`, `arith`, `cmp-op`, `memop`, `rmw`) generate all addressing-mode variants from compact declarations. NIL entries in the table are illegal/undocumented opcodes.

### Test structure

Tests use FiveAM. The root suite is `atari800-cl-suite` in `tests/test-suite.lisp`. Child suites: `compat-suite`, `memory-suite`, `cpu-suite`, `cpu-opcode-suite`. The test package `:import-from`s FiveAM symbols (not `:use`) to avoid name collisions between implementations.

The **Klaus Dormann 6502 functional test** (`tests/test-cpu.lisp`) runs if `roms/6502_functional_test.bin` exists (or `$ATARI800_CL_FUNCTIONAL_TEST` points to it), otherwise it skips gracefully. Build the binary from https://github.com/Klaus2m5/6502_65C02_functional_tests with `org=0000` and `load_data_direct=1`.

## Development Plan

`AI-Docs/AI-Prompts.md` contains the step-by-step build plan for the emulator. Prompts #1–#3 are completed. Consult this file before planning new work.

## Key Conventions

- ASDF `:serial t` — file order in the `.asd` matters; new source files must be inserted at the correct position in the dependency chain.
- All implementation-specific code goes in `src/compat.lisp`. Never add `#+lispworks`/`#+sbcl` elsewhere.
- The CPU is bus-agnostic: peripherals hook into `cpu-bus-read`/`cpu-bus-write`, not into the memory struct directly.
- Prefer `defstruct` over `defclass`. Write verbose docstrings on exported functions and structs.
- Correctness (especially 6502 behavioral accuracy) is the priority over performance.
- ROM images (`roms/*.rom`, `roms/*.bin`) are gitignored and never committed.
