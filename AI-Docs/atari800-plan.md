# Atari 800 XL Emulator in Common Lisp -- Detailed Build Plan

This document captures the implementation plan for a **boot-toward-BASIC Atari 800 XL emulator** in Common Lisp, targeting **LispWorks** as the main platform while keeping the code and tests portable to **SBCL**. The scope includes the **6502 CPU with documented and illegal opcodes**, **ANTIC**, **GTIA**, **POKEY**, **PIA**, and **PORTB/MMU bank switching**, with timing work aimed at **cycle/scanline accuracy**.[web:90][web:100][web:92][web:96][web:108][web:115]

The project is structured as a staged repository build with green tests at the end of each phase, using **ASDF** for system definition, **FiveAM** for tests, and portable dependencies such as **Alexandria**, **Bordeaux Threads**, **usocket**, and **flexi-streams**, all of which are usable on both SBCL and LispWorks.[web:88][web:91][web:110]

## Repository Layout

```text
atari800-cl/
|-- atari800-cl.asd
|-- atari800-cl-tests.asd
|-- README.md
|-- roms/
|   `-- .gitkeep
|-- src/
|   |-- packages.lisp
|   |-- compat.lisp
|   |-- cpu.lisp
|   |-- opcodes.lisp
|   |-- illegal.lisp
|   |-- addressing.lisp
|   |-- bus.lisp
|   |-- mmu.lisp
|   |-- pia.lisp
|   |-- antic.lisp
|   |-- gtia.lisp
|   |-- pokey.lisp
|   |-- irq.lisp
|   |-- machine.lisp
|   `-- ipc.lisp
`-- tests/
    |-- test-helpers.lisp
    |-- test-cpu.lisp
    |-- test-illegal.lisp
    |-- test-addressing.lisp
    |-- test-mmu.lisp
    |-- test-antic.lisp
    |-- test-gtia.lisp
    |-- test-pokey.lisp
    `-- test-machine.lisp
```

This layout separates CPU, chip, bus, and integration concerns cleanly, which is important for keeping the emulator testable and portable across Common Lisp implementations.[web:88][web:91]

## Phase 0 -- Tooling and Portability

The first phase establishes a single-command development workflow in both LispWorks and SBCL. The project should use **ASDF** as the system definition mechanism and **Quicklisp** for dependency resolution, with a dedicated test system so `asdf:test-system` works consistently in both Lisps.[web:88][web:91]

Core dependencies should be:

- `alexandria` for utility helpers and sequence/hash-table convenience.[web:88]
- `bordeaux-threads` for portable threading, including the future IPC server thread on SBCL and LispWorks.[web:110][web:113]
- `usocket` for socket-based communication to an external GUI/audio process.[web:88]
- `flexi-streams` for binary I/O and ROM handling.[web:88]
- `fiveam` for portable test suites and batch execution.[web:91]

A dedicated `compat.lisp` file should isolate implementation-specific differences such as profiling hooks, inspector helpers, and any minor LispWorks/SBCL behavior differences, while leaving the emulator core implementation portable.[web:61][web:110]

## Phase 1 -- 6502 Core

The CPU phase should aim first at passing **Klaus Dormann's 6502 functional test suite**, which is a strong baseline for validating all documented NMOS 6502 opcodes.[web:90][web:87] The Atari 800 XL uses the original **NMOS 6502-family behavior**, so the core should include both documented opcodes and the NMOS illegal opcodes relevant to that variant.[web:94][web:97][web:100]

The CPU should be represented with a typed `defstruct` containing `pc`, `sp`, `a`, `x`, `y`, `p`, `cycles`, and interrupt-pending fields. Typed slots are important because both SBCL and LispWorks can generate better code when slot types are explicit, and LispWorks in particular benefits from more explicit type declarations for performance-sensitive code.[web:50][web:54][web:57]

### CPU design points

- Use a 256-entry opcode table, one slot per opcode byte, populated by macro-generated handlers.[web:24][web:29]
- Implement all 13 addressing modes, including the 6502 indirect JMP page-wrap bug.[web:90][web:97]
- Preserve page-cross penalties and branch cycle behavior accurately.[web:90]
- Implement decimal mode behavior for `ADC` and `SBC`, because the Atari's CPU is NMOS 6502-compatible, not a simplified subset.[web:90][web:100]
- Keep the CPU step loop isolated from Atari-specific bus logic so the CPU can be validated independently.[web:87][web:90]

### Illegal opcode coverage

The illegal opcode implementation should include the standard NMOS families such as **SLO**, **RLA**, **SRE**, **RRA**, **DCP**, **ISC**, **LAX**, **SAX**, **ANC**, **ALR**, **ARR**, **XAA**, **AXS**, **AHX**, **SHX**, **SHY**, **TAS**, the multi-byte NOPs, and the KIL/STP opcodes.[web:94][web:97][web:100] The plan should clearly distinguish between relatively stable composite instructions and the more unstable high-byte/store variants, which can vary subtly on real silicon.[web:94][web:97]

### CPU tests

The CPU test suite should include:

- Klaus Dormann's functional test binary as the primary end-to-end validation target.[web:90]
- Focused unit tests for stack operations, interrupt handling, decimal mode, and branch penalties.[web:87][web:90]
- Targeted illegal opcode tests verifying register changes, memory writes, and flags for each implemented family.[web:94][web:100]

## Phase 2 -- Bus, Memory Map, MMU, and PIA

The next phase should model the **Atari 800 XL memory map** and the bank-switching behavior controlled through **PORTB**. The XL/XE memory map places GTIA at `$D000`, POKEY at `$D200`, PIA at `$D300`, ANTIC at `$D400`, and overlays BASIC and OS ROM according to MMU state.[web:81][web:92][web:95]

### Memory map responsibilities

- `$0000-$7FFF`: normal RAM.[web:81][web:92]
- `$8000-$9FFF`: cartridge space or RAM depending on configuration.[web:92]
- `$A000-$BFFF`: BASIC ROM or RAM depending on PORTB/MMU state.[web:92][web:106]
- `$C000-$FFFF`: OS ROM or RAM depending on MMU state, with vectors at the top of memory.[web:92][web:95]
- `$D000-$D4FF`: hardware register windows for GTIA, POKEY, PIA, and ANTIC.[web:81][web:92]

### PORTB/MMU

PORTB should be modeled explicitly because on the 800XL it controls ROM visibility and self-test mapping. The implementation should support at least OS ROM enable/disable, BASIC ROM enable/disable, and self-test mapping behavior tied to PORTB bits used on the 800XL.[web:92][web:95][web:106]

### PIA

The 6520 PIA should expose joystick and control-port related state through PORTA and should route PORTB writes to the MMU model. Even if joystick and keyboard wiring are initially stubbed or simplified, the architectural path from PIA registers to machine state must be correct from the beginning.[web:95][web:81]

### MMU/PIA tests

Tests in this phase should verify that:

- Writes to PORTB change whether BASIC ROM or RAM appears at `$A000-$BFFF`.[web:92][web:106]
- Writes to PORTB change whether OS ROM or RAM appears at `$C000-$FFFF`.[web:92][web:95]
- Register reads and writes at `$D300-$D303` map correctly to the PIA model.[web:81][web:92]

## Phase 3 -- ANTIC

ANTIC should be implemented as a **scanline and DMA engine**, not merely as a static register block, because you explicitly want cycle/scanline timing accuracy and because ANTIC steals cycles from the CPU during DMA fetches.[web:96][web:101]

### ANTIC responsibilities

- Parse the display list and advance through it correctly.[web:81][web:96]
- Model scanlines and color clocks for NTSC timing.[web:96]
- Emulate DMA fetches for display data and player/missile data.[web:96]
- Track and expose cycle stealing so the top-level scheduler can reduce effective CPU execution time.[web:96][web:101]
- Support DLI and VBI interrupt signaling once the interrupt layer is in place.[web:81][web:96]

### ANTIC tests

Tests should cover:

- Correct parsing of representative display list instructions.[web:81]
- Correct cycle-steal counts on representative scanlines, including refresh and DMA activity.[web:96]
- Correct scanline progression and line/frame wraparound.[web:96]
- DLI scheduling at the expected display list boundaries.[web:81][web:96]

## Phase 4 -- GTIA

GTIA should be modeled as the visible graphics priority and collision device, with support for player/missile positioning, colors, priority mixing, console keys, and collision latches.[web:109][web:115][web:118]

### GTIA responsibilities

- Implement write and read register windows with correct mirroring semantics where applicable.[web:118]
- Support player and missile horizontal positions, sizes, graphics registers, and color registers.[web:109][web:118]
- Implement collision register updates between players, missiles, and playfield objects.[web:109][web:112]
- Implement HITCLR behavior to clear collision latches.[web:109][web:118]
- Expose console key state and trigger inputs via the appropriate registers.[web:118]

### GTIA tests

Tests should verify:

- Register reads and writes at GTIA offsets behave correctly.[web:118]
- Collision registers set the expected bits when synthetic overlaps are fed into the pixel pipeline.[web:109][web:112]
- Priority and graphics control registers affect the modeled state as expected.[web:109][web:115]

## Phase 5 -- POKEY

POKEY should be implemented as both a timer/IRQ source and an audio/input device. For your scope, the timer and interrupt side is especially important because many machine behaviors depend on it, while audio generation can initially be correct in divider/timer behavior even before the waveform path is fully polished.[web:108][web:117][web:120]

### POKEY responsibilities

- Four audio channels with `AUDF`, `AUDC`, and `AUDCTL` behavior.[web:108][web:120]
- Timer countdown/reload logic derived from audio divider settings.[web:117][web:120]
- `IRQEN` and `IRQST` handling with correct pending IRQ signaling to the CPU.[web:117][web:120]
- Keyboard scan code and serial/input-related state through `KBCODE` and `SKSTAT`.[web:108][web:117]
- Polynomial counters and noise-related state for audio correctness over time.[web:108][web:120]

### POKEY tests

Tests should verify:

- Timer IRQs fire after the correct countdown intervals for representative channel configurations.[web:117]
- IRQ enable masks gate interrupt generation correctly.[web:117][web:120]
- Register reads return the expected status bits for timer and keyboard state.[web:108][web:117]
- Audio divider reload logic behaves consistently across channels.[web:120]

## Phase 6 -- Interrupt Routing and Whole-Machine Scheduler

After the individual chips exist, the emulator should add an interrupt-routing layer and a machine-level scheduler that advances the system in hardware order. Since ANTIC DMA steals cycles, the frame loop must not simply run the CPU for a fixed instruction count; it must interleave chip ticks, DMA steals, and CPU execution in a shared time base.[web:96][web:101]

### Machine scheduler responsibilities

- Maintain a top-level machine struct holding CPU, bus, MMU, PIA, ANTIC, GTIA, and POKEY.[web:81][web:92]
- Tick ANTIC at scanline/color-clock granularity.[web:96]
- Tick POKEY timers on the CPU timing base.[web:117][web:120]
- Dispatch NMIs and IRQs into the CPU when chip state requests them.[web:81][web:96][web:117]
- Advance one full NTSC frame with correct scanline and color-clock totals.[web:96]

### Integration tests

Whole-machine tests should include:

- Cold reset loads vectors from OS ROM correctly when MMU state maps the OS in.[web:92][web:95]
- Running one frame advances scanline state and CPU cycles without error.[web:96]
- DLI/NMI and POKEY IRQ smoke tests reach the CPU pending-interrupt path.[web:96][web:117]

## Phase 7 -- ROM Loading and Boot Toward BASIC

This milestone is the architectural target for the initial repository. The repo should be **ROM-free** for copyright reasons, but it should include a `.gitignored` `roms/` directory and code paths that load user-supplied OS and BASIC ROM images, map them into the machine, set the initial PORTB state, and perform a cold reset through the 6502 reset vector.[web:92][web:95]

### ROM boot tasks

- Load OS ROM into the machine's ROM backing store and expose it via MMU rules.[web:92][web:95]
- Load BASIC ROM and map it at `$A000-$BFFF` according to PORTB.[web:92][web:106]
- Set up reset state so the CPU reads `$FFFC/$FFFD` and begins execution in OS code.[web:92]
- Run machine frames until reaching a visible "boot toward BASIC" milestone such as stable execution through the reset path and early OS/BASIC initialization.[web:92][web:86]

A practical smoke test here is not "full BASIC prompt achieved on day one," but rather "real ROMs load, reset vector executes, and the machine can run repeated frames without immediate fatal architectural failures." That makes the milestone realistic while still aligned to Option C.[web:86][web:92]

## Phase 8 -- IPC to External GUI/Audio

Because you prefer the emulator itself to remain headless, the machine should expose a socket-based IPC layer for framebuffer and audio delivery to another process, using `usocket` and a portability wrapper over threads.[web:110][web:113]

### IPC responsibilities

- Start a server thread portably under SBCL and LispWorks using Bordeaux Threads.[web:110][web:113]
- After each completed frame, serialize a framebuffer snapshot and audio/timer output buffer to the socket.[web:110]
- Keep this layer optional so the full test suite can run headless without a connected client.

## Suggested Test Strategy

The repo should use **FiveAM** suites by component and one umbrella suite for CI-style execution. That allows both focused development and a single batch test command through `asdf:test-system`.[web:91]

Recommended suite grouping:

- `:cpu-functional` for Klaus Dormann end-to-end CPU validation.[web:90]
- `:illegal-opcodes` for NMOS unofficial instruction coverage.[web:94][web:100]
- `:addressing` for addressing mode edge cases such as page crossing and JMP indirect wraparound.[web:90][web:97]
- `:mmu` for PORTB and ROM mapping behavior.[web:92][web:95]
- `:antic` for scanline and DMA timing tests.[web:96]
- `:gtia` for collision and register behavior.[web:109][web:112]
- `:pokey` for timer, IRQ, and status-register behavior.[web:117][web:120]
- `:machine` for reset, interrupt smoke tests, and frame-loop integration.[web:92][web:96]

## Development Order and Gates

The best implementation order is the following:

1. **ASDF + portability layer**, so the project loads cleanly everywhere.[web:88][web:110]
2. **6502 documented opcode core**, then Klaus functional test green.[web:90]
3. **Illegal opcode layer**, then targeted illegal-opcode tests green.[web:94][web:100]
4. **Bus + MMU + PIA**, then bank-switch tests green.[web:92][web:95]
5. **ANTIC scanline engine**, then DMA/cycle-steal tests green.[web:96]
6. **GTIA**, then collision tests green.[web:109][web:112]
7. **POKEY**, then timer/IRQ tests green.[web:117][web:120]
8. **Interrupt routing + machine scheduler**, then frame-loop smoke tests green.[web:96]
9. **ROM loader + boot path**, then run with supplied ROMs toward BASIC initialization.[web:86][web:92]
10. **IPC layer**, then optional external renderer/audio integration.[web:110]

Each phase should leave the repository in a runnable and testable state before proceeding to the next one, which is especially important for a system with so many interacting timing components.

## Commands to Run on Perplexity Personal Computer

Once the repository exists, the expected workflow on Perplexity Personal Computer should be:

```lisp
(ql:quickload :atari800-cl)
(asdf:test-system :atari800-cl/tests)
```

For SBCL batch usage, the command-line equivalent should be:

```bash
sbcl --eval "(ql:quickload :atari800-cl/tests)" \
     --eval "(asdf:test-system :atari800-cl/tests)" \
     --quit
```

For LispWorks, the same test system should be runnable from the IDE listener or a batch session, assuming the same Quicklisp and ASDF setup is available.[web:88][web:91][web:61]

## Milestone Definition

The milestone for this plan is not yet "complete game-compatible 800XL emulation." It is a narrower but serious target: a portable Common Lisp repository with a validated 6502 core, implemented NMOS illegal opcodes, architectural models of ANTIC/GTIA/POKEY/PIA, correct XL memory mapping and PORTB/MMU behavior, a cycle-aware whole-machine scheduler, and a ROM-loading path capable of executing real 800XL OS/BASIC reset flow toward boot.[web:90][web:92][web:96][web:100]

That is the right shape for a Perplexity Personal Computer execution plan because it is ambitious but modular, testable at each stage, and directly aligned with your preferred headless architecture and Common Lisp toolchain.[memory:1]