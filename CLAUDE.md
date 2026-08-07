# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Headless Atari 800 XL emulator in portable Common Lisp. Primary target is **LispWorks**; also supports **SBCL**.

The emulated machine is functionally complete at the chip-state level:

- **6502 CPU** — all 256 opcodes (151 documented + 105 NMOS illegal/undocumented), with NMI/IRQ servicing.
- **MMU** — PORTB-driven bank switching (OS ROM, BASIC ROM, self-test overlay).
- **System bus** — full Atari 800 XL memory map with RAM/ROM banking and memory-mapped I/O dispatch to the four chips.
- **PIA** (6520), **ANTIC** (NTSC scanline timing + display-list DMA + P/M DMA), **GTIA** (player/missile state + collision latches + full PRIOR priority), **POKEY** (timers with hardware reload offsets and linked 16-bit channels, IRQ, RNG).
- **POKEY audio synthesis** (`src/audio.lisp`) — four-channel polynomial distortion (poly4/5/9/17) + mixing into mono 8-bit PCM at ~44.7 kHz, attached on demand via `machine-attach-audio` so machines without audio pay only a NIL test per POKEY advance.
- **Machine scheduler** — `MACHINE-RUN-FRAME` runs one NTSC frame (29,868 clocks = 262 scanlines × 114 CPU cycles) scanline-by-scanline: `ANTIC-BEGIN-SCANLINE` fires the line's events and reports stolen cycles, the CPU executes against the line's remaining budget with POKEY advanced instruction-by-instruction, and `ANTIC-END-SCANLINE` closes the line.
- **Pixel renderer** — per-scanline 384×240 24-bit RGB framebuffer rendering (background + playfield modes 2-F + player/missile compositing with PRIOR arbitration), driven by the machine's per-scanline callback and pushed to clients over AESP video frames; `scripts/capture-screenshot.py` grabs PNG/PPM screenshots.

What is *not* modelled: POKEY's two high-pass filters (AUDCTL bits 1-2) and two-tone serial mode, the serial/SIO bus, keyboard scanning, paddles/light-pen, and cartridge mapping. See README.md "Known limitations" for the full list. Correctness, especially 6502 behavioral accuracy, is prioritized over performance.

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

Preferred noninteractive runners:
```sh
./scripts/test-sbcl.sh
./scripts/test-lispworks.sh
```

These scripts are designed for both normal shells and restricted sandbox
execution environments. They deliberately avoid relying on `.sbclrc`,
LispWorks init-file side effects, or Quicklisp writing to
`~/quicklisp/local-projects/system-index.txt`. Instead they:

- register this repository and the installed Quicklisp software tree directly
  with ASDF via `asdf:initialize-source-registry`;
- redirect ASDF/FASL output into `.cache/fasls/` inside the repository via
  `asdf:initialize-output-translations`, because some sandboxes forbid writes
  to `~/.cache/common-lisp`;
- run `fiveam:run!` directly for the shell exit status, because
  `asdf:test-system` can return successfully even when FiveAM reports failed
  checks;
- run the LispWorks test body inside `mp:initialize-multiprocessing`, because
  batch LispWorks images otherwise signal `Cannot create processes before
  multiprocessing is initialized` when tests create threads; and
- allow `QUICKLISP_SOFTWARE=/path/to/software` if the dependency tree is not
  at the default `~/quicklisp/dists/quicklisp/software`.

Sandbox caveat: some tool sandboxes deny listener creation with `EPERM` for
both TCP loopback sockets and Unix-domain sockets, even under `/tmp` and inside
the repository. The live AESP TCP server tests, CLI Unix socket server tests,
and Unix socket roundtrip test probe this capability and skip themselves when
listener bind is prohibited. On an unrestricted local shell these tests should
run normally.

> **Exit-code gotcha:** `asdf:test-system` returns `T` even when tests
> *fail*, so it is useless for shell/CI exit codes. Always key the exit
> status off `fiveam:run!`, which returns `T` only when every check
> passes. The commands below do this (exit 0 = all pass, 1 = failure).

Legacy manual shell form for **SBCL** (`.sbclrc` loads Quicklisp before `--eval`; prefer `./scripts/test-sbcl.sh` for automation):
```sh
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

Legacy manual shell form for **LispWorks** (the console image is `lw-console` in
`$PATH`; prefer `./scripts/test-lispworks.sh` for automation). Two LispWorks-isms matter here:
- Command-line `-eval` forms are *read* before the init file loads
  Quicklisp, so load `setup.lisp` first and defer non-CL symbols
  (`ql:`, `fiveam:`) with `read-from-string`.
- **Multiprocessing is initialized asynchronously at startup.** If
  `-eval` forms create threads before it's ready you get *"Cannot create
  processes before multiprocessing is initialized"* — and **every
  threaded test (mailbox/run-loop, AESP/CLI servers, sockets) fails
  intermittently.** Run the suite inside `mp:initialize-multiprocessing`
  so threads are safe. (The REPL already runs under multiprocessing, so
  an interactive `(asdf:test-system …)` is fine — this only bites batch
  `-eval` runs.)
```sh
lw-console -eval '(mp:initialize-multiprocessing "ci" ()
                    (lambda ()
                      (load "~/quicklisp/setup.lisp")
                      (funcall (read-from-string "ql:quickload") :atari800-cl/tests)
                      (lw:quit :status
                        (if (funcall (read-from-string "fiveam:run!")
                                     (read-from-string "atari800-cl/tests::atari800-cl-suite"))
                            0 1))))'
```

Run a single FiveAM test by name:
```lisp
(fiveam:run! 'atari800-cl/tests::reset-loads-pc-from-vector)
```

Run a single test suite (e.g. just the CPU opcode tests):
```lisp
(fiveam:run! 'atari800-cl/tests::cpu-opcode-suite)
```

## Benchmarking

Frame-rate benchmark harness for measuring optimization deltas. Works
without real ROM images (synthetic NOP/IRQ workloads built inline).

```sh
./scripts/bench-sbcl.sh
./scripts/bench-lispworks.sh
```

Each prints one machine-readable line per workload:
`BENCH <workload> frames=600 seconds=<s> fps=<fps> realtime-x=<fps/59.92>`.
Five workloads: `nop` (NOP-sled baseline), `irq` (busy loop + POKEY
timer 1 IRQs exercising the interrupt path), `display` (NOP sled with a
24-line mode-2 display list fetched by ANTIC — DMA-active steal
accounting — and the pixel renderer attached via the scanline callback),
`audio` (NOP sled with POKEY audio synthesis attached and all four
channels voiced, draining per frame — every other workload runs with
audio detached, so the pair of rows shows both that the no-audio path
stays free and what synthesis costs), and `klaus` (the Klaus Dormann
functional test as a CPU-heavy load; skips if the binary is absent).
Tune via `atari800-cl.bench:*warmup-frames*` / `*measured-frames*`.

**Rule: every optimization commit updates `PERFORMANCE_LOG.md` with
before/after numbers from BOTH implementations.** Measure first, commit
the delta in the commit message, and log it here.

## Architecture

### Package layering (bottom-up dependency order)

Each chip lives in its own package; `:use` edges define the layering. The `.asd` lists files in this dependency order (`:serial t`).

1. **atari800-cl.compat** (`src/compat.lisp`) — Portability layer isolating all `#+lispworks`/`#+sbcl` differences: type aliases (`u8`, `u16`, `byte-vector`), threading, binary I/O, GC warnings. **All conditional compilation lives here**; other source files must not use reader conditionals.

2. **atari800-cl.memory** (`src/memory.lisp`) — Legacy flat 64K address space, RAM + ROM overlay slots. Backs the CPU's optional `attach-memory-bus` path and the test harness; the full machine uses `bus`/`mmu` instead.

3. **atari800-cl.mmu** (`src/mmu.lisp`) — Bank-switching unit: owns the PORTB shadow byte and exposes the OS-ROM / BASIC-ROM / self-test predicates the bus consults on ROM-overlap reads.

4. **atari800-cl.bus** (`src/bus.lisp`) — System bus owning RAM + ROM images and the full memory map. Routes every address to RAM, a ROM image, or one of the four chip I/O ranges (`$D000` GTIA, `$D200` POKEY, `$D300` PIA, `$D400` ANTIC). Chips register **read/write closures** into the bus when attached, so `bus.lisp` never references chip-package symbols — this breaks what would otherwise be circular package dependencies.

5. **atari800-cl.cpu** (`src/cpu.lisp` + `src/cpu-opcodes.lisp` + `src/illegal.lisp`) — Bus-agnostic NMOS 6502 core. The CPU communicates via two function slots (`cpu-bus-read`, `cpu-bus-write`) rather than referencing memory directly, so anything (the bus, or a bare memory object via the legacy `attach-memory-bus`) can intercept reads/writes. The 256-entry dispatch table (`*opcode-table*`) is a simple-vector of `(lambda (cpu) -> cycles)` built by `DEFOPCODE`; `illegal.lisp` fills the remaining 105 undocumented slots.

6. **Peripheral chips** — **atari800-cl.pia** (`src/pia.lisp`, 6520; PORTB writes route through `mmu`), **atari800-cl.antic** (`src/antic.lisp`), **atari800-cl.gtia** (`src/gtia.lisp`), **atari800-cl.pokey** (`src/pokey.lisp`), **atari800-cl.audio** (`src/audio.lisp`, POKEY audio synthesis; loads after `pokey`, whose `step-lfsr` builds its poly tables and whose struct holds the attachment — POKEY calls it through function slots, never naming the package), and **atari800-cl.irq** (`src/irq.lisp`, NMI/IRQ line routing into the CPU).

7. **atari800-cl.renderer** (`src/renderer.lisp`) — Per-scanline NTSC pixel renderer: converts ANTIC display-list state + GTIA registers into a 384×240 24-bit RGB framebuffer (background flood, 320-pixel playfield for modes 2-F, player/missile compositing via PRIOR). Sits between the chips and the machine in the `.asd` order; the machine invokes it through its `scanline-fn` / `post-frame-fn` callback slots, and the AESP server pushes completed frames to video subscribers.

8. **atari800-cl.machine** (`src/machine.lisp`) — The real top-level: the `atari-machine` struct owns one of each chip plus the bus. `make-atari-machine` builds and wires everything (chip closures into the bus, bus into the CPU's hooks); `machine-cold-reset` loads ROMs and boots; `machine-run-frame` is the frame scheduler, with optional `scanline-fn` (after each completed active scanline) and `post-frame-fn` (after each frame) callbacks for rendering. Also provides REPL instrumentation (`machine-trace-step`, `machine-portb-state`, `machine-scanline`, `machine-pending-interrupts`).

9. **atari800-cl** (`src/main.lisp`) — Public facade (nicknamed `a800`) re-exporting a user-facing API. Wraps the full `atari-machine`: `make-machine` builds and cold-resets a complete machine, `step-machine`/`run-machine` advance the CPU, and `run-frame` drives the whole system (ANTIC/POKEY in lockstep) one or more NTSC frames at a time. ROM-loading and instrumentation reach into the `atari800-cl.machine` / `atari800-cl.cpu` packages.

### CPU opcode pattern

Opcodes are defined via the `DEFOPCODE` macro which creates a named function (`OPCODE-<MNEMONIC>-<HEX>`) and installs it into `*opcode-table-builder*` (copied into `*opcode-table*` once all files load). Family macrolets (`load-op`, `store-op`, `logical`, `arith`, `cmp-op`, `memop`, `rmw`) generate all addressing-mode variants from compact declarations. Documented opcodes live in `cpu-opcodes.lisp`; the 105 NMOS illegal/undocumented opcodes (KIL/JAM, SLO/RLA/SRE/RRA/DCP/ISC, LAX/SAX, etc.) live in `illegal.lisp`.

### Test structure

Tests use FiveAM. The root suite is `atari800-cl-suite` in `tests/test-suite.lisp`; each component file defines a child suite `:in` it: `compat-suite`, `memory-suite`, `cpu-suite`, `harte-suite`, `cpu-opcodes-suite`, `illegal-opcodes`, `mmu-suite`, `pia-suite`, `antic-suite`, `renderer-suite`, `gtia-suite`, `pokey-suite`, `machine-suite`, and `regression-suite`. Shared fixtures (`%MAKE-SYNTHETIC-OS-ROM`, `MAKE-TEST-MACHINE`, `WITH-CPU-STATE`, `%POKE`) live in `tests/test-helpers.lisp`. The test package `:import-from`s FiveAM symbols (not `:use`) to avoid name collisions between implementations.

The **Klaus Dormann 6502 functional test** (`tests/test-cpu.lisp`) runs if `roms/6502_functional_test.bin` exists (or `$ATARI800_CL_FUNCTIONAL_TEST` points to it), otherwise it skips gracefully. Run `./scripts/fetch-test-roms.sh` to download the prebuilt binary (org=0000, load_data_direct=1) from https://github.com/Klaus2m5/6502_65C02_functional_tests into `roms/`; it no-ops if the file is already present. The run is slow (max-instructions ~200M) — a couple of minutes on SBCL, longer on LispWorks.

The **Tom Harte / SingleStepTests vectors** (`tests/test-harte.lisp`) are the
CPU accuracy ratchet: per-opcode JSON cases with full before/after CPU +
memory state and a cycle-by-cycle bus trace. The data is ~1 GB and is not
vendored; the harness skips unless `$ATARI800_CL_HARTE_TESTS` points at a
checkout's `6502/v1` directory:

```sh
git clone https://github.com/SingleStepTests/65x02
export ATARI800_CL_HARTE_TESTS=$PWD/65x02/6502/v1
./scripts/test-sbcl.sh                    # 500 cases/opcode (~128k cases)
ATARI800_CL_HARTE_FULL=1 ./scripts/test-sbcl.sh   # all 10,000 (~2.56M cases)
```

A partial checkout works — whichever `<hex>.json` files exist get tested.
**A failure here is presumed a real emulator bug**: fix it in `src/`, add a
focused regression test to `tests/test-regressions.lisp` naming the opcode
and case id, and only then consider the (currently empty) skip list. The
file header spells out the triage workflow.

## Development Plan

`AI-Docs/AI-Prompts.md` contains the step-by-step build plan (Prompts 1–14) that produced the emulator; all of it is complete. (Prompt 12's optional Unix-socket IPC layer was later removed — see `CHANGES.md`.) The prompt file and `AI-Docs/atari800-plan.md` are historical records; consult them for context, but the code and `CHANGES.md` are the source of truth for current state.

## Key Conventions

- ASDF `:serial t` — file order in the `.asd` matters; new source files must be inserted at the correct position in the dependency chain.
- All implementation-specific code goes in `src/compat.lisp`. Never add `#+lispworks`/`#+sbcl` elsewhere.
- The CPU is bus-agnostic: peripherals hook into `cpu-bus-read`/`cpu-bus-write`, not into the memory struct directly.
- Prefer `defstruct` over `defclass`. Write verbose docstrings on exported functions and structs.
- Correctness (especially 6502 behavioral accuracy) is the priority over performance.
- ROM images (`roms/*.rom`, `roms/*.bin`) are gitignored and never committed.
