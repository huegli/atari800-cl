# AI-Prompts.md — Atari 800 XL Emulator in Common Lisp
## Perplexity Personal Computer Execution Sequence

These prompts build a headless Atari 800 XL emulator in Common Lisp step by step.
Run one prompt at a time. Review the output and confirm it is working before moving to the next.
Target platform: **LispWorks** (primary), portable to **SBCL**.

---

## Prompt 1 — Repository Scaffold

```
Create a new Common Lisp repository named atari800-cl for a headless Atari 800 XL emulator.
Target LispWorks as the primary implementation but keep all code portable to SBCL.
Use ASDF and Quicklisp. Add these dependencies (all supported on both LispWorks and SBCL):
  - alexandria
  - bordeaux-threads
  - usocket
  - flexi-streams
  - fiveam (for tests)

Create the following directory structure:
  atari800-cl/
  ├── atari800-cl.asd
  ├── atari800-cl-tests.asd
  ├── README.md
  ├── roms/
  │   └── .gitkeep
  ├── src/
  │   ├── packages.lisp
  │   ├── compat.lisp
  │   ├── cpu.lisp
  │   ├── opcodes.lisp
  │   ├── illegal.lisp
  │   ├── addressing.lisp
  │   ├── bus.lisp
  │   ├── mmu.lisp
  │   ├── pia.lisp
  │   ├── antic.lisp
  │   ├── gtia.lisp
  │   ├── pokey.lisp
  │   ├── irq.lisp
  │   ├── machine.lisp
  │   └── ipc.lisp
  └── tests/
      ├── test-helpers.lisp
      ├── test-cpu.lisp
      ├── test-illegal.lisp
      ├── test-addressing.lisp
      ├── test-mmu.lisp
      ├── test-antic.lisp
      ├── test-gtia.lisp
      ├── test-pokey.lisp
      └── test-machine.lisp

Include:
- Package definitions in packages.lisp covering all source and test packages
- A compat.lisp portability shim that abstracts LispWorks vs SBCL differences,
  including optimize proclamations, thread spawning via bordeaux-threads,
  profiling guards, and IDE inspection helpers
- Stub source files for every .lisp file listed above so the system loads without errors
- A stub FiveAM test suite in each test file with at least one passing placeholder test
- An umbrella FiveAM suite :atari800-cl/all that aggregates all test suites
- atari800-cl-tests.asd wired so (asdf:test-system :atari800-cl/tests) runs all suites
- A README.md with setup instructions for both SBCL and LispWorks

Initialize a git repository, make an initial commit, and give me the entire project
as a downloadable archive.
```

---

## Prompt 2 — 6502 CPU Core

```
In the atari800-cl repository, implement the NMOS 6502 CPU core in src/cpu.lisp.

Requirements:
- Use a typed defstruct for CPU state with slots: pc (u16), sp (u8), a (u8), x (u8),
  y (u8), p (u8 status), cycles (fixnum), irq-pending (boolean), nmi-pending (boolean)
- Define flag bit constants: C, Z, I, D, B, U, V, N
- Implement macros: flag-set-p, flag-clear-p, set-flag, update-nz
- Implement stack helpers: stack-push8, stack-push16, stack-pull8, stack-pull16
- Implement handle-nmi and handle-irq using the correct vector addresses
  ($FFFA/$FFFB for NMI, $FFFE/$FFFF for IRQ)
- Implement bus-read8, bus-write8, bus-read16 stubs that can be later wired to the bus
- Keep the CPU entirely independent of Atari-specific device logic

Implement all 13 NMOS 6502 addressing modes in src/addressing.lisp:
  immediate, zero-page, zero-page-x, zero-page-y, absolute, absolute-x (with
  page-cross penalty), absolute-y (with page-cross penalty), indirect (with
  JMP page-wrap bug), indexed-indirect (d,x), indirect-indexed (d),y with
  page-cross penalty), relative, implied, accumulator
Each mode should return (values effective-address page-crossed-p extra-cycles).

Add a FiveAM test suite :cpu-unit in tests/test-cpu.lisp covering:
- Flag set/clear macros
- Stack push/pull round trips
- NMI and IRQ vector reads
- Each addressing mode, including page-cross detection and the JMP indirect bug
- update-nz flag behavior

Run the tests under SBCL and fix all failures before delivering the updated repository.
```

---

## Prompt 3 — All Documented Opcodes

```
In the atari800-cl repository, implement all 151 documented NMOS 6502 opcodes
in src/opcodes.lisp using a compile-time macro approach.

Requirements:
- Define a 256-entry *opcode-table* array
- Create a defopcode macro that: defines a named function for each opcode, installs it
  into *opcode-table*, handles PC advancement, cycles counting, page-cross penalties,
  and addressing mode dispatch
- Implement all opcode families: LDA/LDX/LDY, STA/STX/STY, ADC/SBC (with decimal
  mode), AND/ORA/EOR, ASL/LSR/ROL/ROR, INC/DEC, INX/INY/DEX/DEY, TAX/TAY/TXA/TYA/
  TXS/TSX, PHA/PLA/PHP/PLP, JSR/RTS/RTI, JMP, all 8 branches, BIT, CMP/CPX/CPY,
  NOP, CLC/SEC/CLI/SEI/CLV/CLD/SED, BRK
- Implement the CPU step loop: fetch opcode, dispatch through *opcode-table*, handle
  unrecognized opcodes gracefully

Add a fixture mechanism in tests/test-cpu.lisp for Klaus Dormann's 6502 functional test:
- Load the binary at $0000, set PC to $0400, run until PC stops changing (trap loop)
- Assert final PC equals $3469 (the success trap address)
- If the binary is not present, skip gracefully with a clear message and instructions
  for supplying it

Add targeted opcode unit tests for at least one variant of each opcode family.
Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 4 — Illegal Opcodes

```
In the atari800-cl repository, implement all NMOS 6502 illegal opcodes in src/illegal.lisp
that are relevant to the Atari 800 XL CPU (original NMOS 6502, not 65C02).

Include the following groups:
- Compound RMW instructions: SLO, RLA, SRE, RRA, DCP, ISC
  (each performs two official operations merged into one: e.g. SLO = ASL then ORA)
- Combined load/store: LAX (LDA+LDX), SAX (A AND X → memory)
- Bitwise-accumulator: ANC, ALR, ARR, AXS, LAS, TAS
- Unstable high-byte store variants: AHX, SHX, SHY, TAS
  (document that these behave as AND with addr_high+1 and may vary on real hardware)
- Multi-byte NOPs: all undocumented NOP variants with correct cycle counts and
  effective address reads for timing accuracy
- KIL/STP (12 opcodes): model as an unrecoverable CPU halt

Install all handlers into the existing *opcode-table*.
Clearly document any unstable instructions and their known hardware caveats in comments.

Add a FiveAM suite :illegal-opcodes in tests/test-illegal.lisp covering:
- Memory write + register effects for SLO, RLA, SRE, RRA, DCP, ISC
- Register combination effects for LAX, SAX
- Flag behavior for ANC, ALR, ARR, AXS
- Cycle counts for representative multi-byte NOP variants
- KIL handler reachability

Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 5 — Bus, MMU, and Memory Map

```
In the atari800-cl repository, implement the Atari 800 XL memory map and bus layer
in src/bus.lisp and src/mmu.lisp.

Memory map to implement:
  $0000-$7FFF  RAM (always present)
  $8000-$9FFF  Cartridge right slot or RAM
  $A000-$BFFF  BASIC ROM or RAM (controlled by PORTB bit 1)
  $C000-$CFFF  OS ROM low or RAM (controlled by PORTB bit 0)
  $D000-$D0FF  GTIA registers
  $D200-$D2FF  POKEY registers
  $D300-$D3FF  PIA registers
  $D400-$D4FF  ANTIC registers
  $D800-$FFFF  OS ROM high or RAM (controlled by PORTB bit 0, vectors at top)

MMU requirements (src/mmu.lisp):
- Represent PORTB as a single typed slot
- PORTB bit 0: 0 = RAM at $C000-$FFFF, 1 = OS ROM mapped
- PORTB bit 1: 0 = BASIC ROM at $A000-$BFFF, 1 = RAM
- PORTB bit 7: 0 = self-test ROM at $5000-$57FF, 1 = RAM
- Provide os-rom-mapped-p, basic-rom-mapped-p, selftest-mapped-p predicates
- OS and BASIC ROM backing arrays are loaded separately at reset time (not stored
  in the repo); keep these as nullable slots in the bus struct

Bus requirements (src/bus.lisp):
- bus-read and bus-write dispatch through the memory map
- Hardware register ranges stub-dispatch to chip structs (wire up as chips are added)
- Use (simple-array (unsigned-byte 8) (65536)) for RAM for SBCL/LispWorks performance
- Add bus-read16 for vector fetches

Add a FiveAM suite :mmu in tests/test-mmu.lisp covering:
- PORTB bit toggle tests for BASIC ROM visibility
- PORTB bit toggle tests for OS ROM visibility
- Self-test mapping toggle
- Address decode: a write to $D300 routes to the PIA stub, not to RAM
- RAM reads and writes at multiple addresses

Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 6 — PIA

```
In the atari800-cl repository, implement the Atari 800 XL PIA (6520-compatible)
in src/pia.lisp.

Requirements:
- Represent PIA with a typed defstruct containing: ddra, porta, ddrb, portb (all u8)
- Register map at $D300-$D303:
    $D300 / offset 0: PORTA — joystick/input lines (stubbed as all-inputs for now)
    $D301 / offset 1: DDRA  — data direction register for port A
    $D302 / offset 2: PORTB — MMU control output
    $D303 / offset 3: DDRB  — data direction register for port B
- pia-read dispatches by (logand addr #x03)
- pia-write dispatches by (logand addr #x03); writes to PORTB (offset 2) must call
  mmu-write-portb to update the MMU model immediately
- Writes to PORTA direction should be modeled but PORTA data writes can be ignored
  (it is an input port on the 800XL)

Wire pia-read and pia-write into bus-read and bus-write at the $D300-$D3FF range.

Add a FiveAM suite :pia in tests/test-mmu.lisp (or a separate file if you prefer):
- Write to $D302 and confirm the MMU portb field updates
- Write to $D301 and confirm DDRA field updates
- Read from $D300 returns PORTA value
- PORTB write triggers correct MMU mapping change (reuse the MMU tests as integration)

Run all tests and fix every failure before delivering the updated repository.
```

---

## Prompt 7 — ANTIC Scanline and DMA Engine

```
In the atari800-cl repository, implement the ANTIC chip for the Atari 800 XL
in src/antic.lisp as a scanline-oriented, cycle-stealing DMA engine.

Use NTSC timing throughout:
  262 scanlines per frame
  114 color clocks per scanline
  Active display: scanlines 8-247 (varies by display list; model the range)
  VBlank start: scanline 248
  DRAM refresh: 9 cycles stolen per normal scanline
  DMA cycles stolen for display-list fetch, display-data fetch, and P/M DMA
  depend on DMACTL and the current mode line

Requirements:
- Typed defstruct with: register array (32 u8), display-list pointer (u16), DL offset
  (u8), scanline counter (u9), color-clock counter (u8), dmactl shadow (u8),
  stolen-cycles accumulator (fixnum)
- Implement register reads/writes at $D400-$D41F; shadow DMACTL and DLISTL/DLISTH
  into struct fields on write
- Implement antic-tick (cpu bus) → integer:
    advances one color clock
    performs display-list fetch on the correct clock within the line
    accounts for DRAM refresh steals
    accounts for P/M DMA steals when enabled
    returns the number of cycles stolen this tick
- Implement display-list instruction parsing: blank lines, mode lines 2-F,
  jump (JMP/JVB), DLI bit, and LMS modifier
- Signal NMI for DLI and VBI via the irq.lisp routing layer when those events occur

Wire ANTIC into the bus at $D400-$D4FF.
Wire antic-tick into the machine frame loop stub.

Add a FiveAM suite :antic in tests/test-antic.lisp covering:
- Display-list fetch advances DL offset correctly
- Blank-line instructions advance scanlines without DMA fetches
- DRAM refresh always contributes the correct base steal count
- P/M DMA steal count changes with DMACTL settings
- Scanline and frame wraparound reset counters correctly
- DLI scheduling fires at the expected display-list boundary

Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 8 — GTIA

```
In the atari800-cl repository, implement the GTIA chip for the Atari 800 XL
in src/gtia.lisp.

GTIA has separate write and read register windows. All registers are at $D000-$D01F.

Write-side registers (by offset):
  0-3:   HPOSP0-HPOSP3  horizontal position of players
  4-7:   HPOSM0-HPOSM3  horizontal position of missiles
  8-11:  SIZEP0-SIZEP3  player sizes
  12:    SIZEM           missile sizes
  13-16: GRAFP0-GRAFP3  player graphics data
  17:    GRAFM           missile graphics data
  18-21: COLPM0-COLPM3  player/missile colors
  22-25: COLPF0-COLPF3  playfield colors
  26:    COLBK           background color
  27:    PRIOR           priority control
  28:    VDELAY          vertical delay
  29:    GRACTL          graphics control (enables P/M DMA to graphics regs)
  30:    HITCLR          write-only: clears all collision registers
  31:    CONSOL          console keys (read) / speaker (write)

Read-side registers (by offset, all collision latches):
  0-3:   M0PF-M3PF   missile-to-playfield
  4-7:   P0PF-P3PF   player-to-playfield
  8-11:  M0P-M3P     missile-to-player
  12-15: P0P-P3P     player-to-player
  16-19: TRIG0-TRIG3 trigger inputs
  20:    PAL          PAL/NTSC indicator
  31:    CONSOL       console key state

Requirements:
- Typed defstruct with separate write-register array (32 u8) and read-register array (32 u8)
- gtia-read dispatches from the read array
- gtia-write dispatches to the write array; HITCLR (offset 30) clears the read array
  collision registers (offsets 0-15) on any write
- Implement gtia-record-collision (gtia obj-a obj-b) that sets the appropriate bit
  in the correct read-side collision register
- TRIG0-TRIG3 default to 1 (not pressed); CONSOL defaults to 7 (no keys)
- PAL register returns 1 for NTSC

Wire gtia-read/gtia-write into bus-read/bus-write at $D000-$D0FF.

Add a FiveAM suite :gtia in tests/test-gtia.lisp covering:
- Register write then read round-trip for HPOSP0, COLPM0, COLPF0, PRIOR
- gtia-record-collision sets the expected read-register bit for at least four
  player/missile/playfield collision combinations
- HITCLR write clears all collision registers
- CONSOL and TRIG defaults
- gtia-read from read-side offset returns correct initial values

Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 9 — POKEY Timers, IRQs, and Audio Scaffolding

```
In the atari800-cl repository, implement the POKEY chip for the Atari 800 XL
in src/pokey.lisp.

POKEY register map at $D200-$D2FF (use offset = addr & $0F for read, addr & $0F for write):

Write registers:
  0,2,4,6:  AUDF1-AUDF4    audio frequency dividers (1 per channel)
  1,3,5,7:  AUDC1-AUDC4    audio control + volume per channel
  8:        AUDCTL          audio control (clock select, filter, linked channels)
  9:        STIMER          write-only: reset all timer counters from AUDFx
  10:       SKREST          write-only: reset SKSTAT
  13:       SEROUT          serial output (stub)
  14:       IRQEN           IRQ enable register
  15:       SKCTL           serial/keyboard control

Read registers:
  0,2,4,6:  POT0-POT7       paddle potentiometers (stub at $FF)
  8:        ALLPOT          all-pots state (stub at $FF)
  9:        KBCODE          keyboard scan code
  10:       RANDOM          polynomial RNG output
  14:       IRQST           IRQ status (active low; 1 = not pending)
  15:       SKSTAT          serial/keyboard status

Timer behavior:
- Each audio channel (1-4) has a countdown counter loaded from AUDFx
- Timers 1, 2, 4 can generate IRQs when they underflow if the corresponding
  IRQEN bit is set (bits 0, 1, 3 respectively)
- Countdown clock base is 64 kHz (divide CPU clock by 28) unless AUDCTL selects
  1.79 MHz for channels 1 or 3
- Linked-channel mode (AUDCTL bits 4 and 3) for 16-bit timers on channels 1+2
  and 3+4
- STIMER write reloads all counters from current AUDF values

Implement pokey-tick (pokey cpu) → boolean:
- Decrements active timer counters by one CPU-clock unit (accounting for clock
  divider ratio)
- Fires IRQ and updates IRQST when a timer underflows with IRQ enabled
- Sets cpu-irq-pending to t when an IRQ fires
- Returns t if an IRQ was raised this tick

Implement polynomial RNG state for the RANDOM register using the appropriate
17-bit and 9-bit LFSR model selected by AUDCTL bit 7.

Wire pokey-read/pokey-write into bus-read/bus-write at $D200-$D2FF.

Add a FiveAM suite :pokey in tests/test-pokey.lisp covering:
- Timer 1 fires IRQ after AUDF1+1 CPU-clock ticks (at 64 kHz base)
- Timer 2 fires IRQ independently
- IRQEN masking: timer IRQ does not set cpu-irq-pending when IRQEN bit is clear
- IRQST bit clears when IRQ fires and is restored by software write to IRQEN
- STIMER reloads counters from AUDF values
- RANDOM register returns non-zero and changes across ticks

Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 10 — Interrupt Routing and Machine Scheduler

```
In the atari800-cl repository, implement the interrupt-routing layer in src/irq.lisp
and the top-level machine scheduler in src/machine.lisp.

IRQ routing (src/irq.lisp):
- ANTIC raises NMI for VBI (scanline 248, color clock 0) and DLI (set by display list)
- POKEY raises IRQ for timer underflows, serial events, and keyboard
- Route NMI by setting cpu-nmi-pending; route IRQ by setting cpu-irq-pending
- Provide check-and-dispatch-nmi and check-and-dispatch-irq functions called
  from the machine scheduler

Machine struct (src/machine.lisp):
- Top-level defstruct owning: cpu, bus, mmu, pia, antic, gtia, pokey, frame-count
- All back-pointers in the bus struct (to gtia, pokey, pia, antic, mmu) should be
  set during machine construction

Machine scheduler:
- NTSC constants: 262 scanlines, 114 color clocks per scanline = 29,868 color
  clocks per frame
- machine-run-frame (machine) runs one full NTSC frame:
    For each color clock in the frame:
      1. Call antic-tick; record any stolen cycles
      2. Call pokey-tick
      3. Check and dispatch NMI if pending
      4. Check and dispatch IRQ if pending (respects I flag)
      5. If ANTIC did not steal this cycle, fetch and execute one CPU instruction
         via *opcode-table*
  Increment frame-count after each frame

ROM loading helpers:
- load-rom-file (path) → (simple-array (unsigned-byte 8) (*))
- machine-cold-reset (machine os-path basic-path):
    Load OS ROM into bus os-rom slot
    Load BASIC ROM into bus basic-rom slot
    Set PORTB to #xFF (OS on, BASIC on)
    Set CPU P to #x34, SP to #xFF
    Set CPU PC from reset vector at $FFFC/$FFFD

Add a FiveAM suite :machine in tests/test-machine.lisp covering:
- machine-run-frame advances cpu-cycles by approximately 29,868 per frame
- machine-run-frame advances antic scanline through a full frame and resets
- A synthetic NMI (set nmi-pending before running) reaches handle-nmi within one frame
- A synthetic IRQ (set irq-pending, I flag clear) reaches handle-irq within one frame
- Cold reset with synthetic ROM fixtures sets PC to the correct reset vector value

Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 11 — ROM Loading and Boot-Toward-BASIC Milestone

```
In the atari800-cl repository, add ROM support and bring the machine to a state
where it can begin executing real Atari 800 XL OS and BASIC code.

Requirements:
- The repo must remain ROM-free for copyright reasons
- Create roms/.gitkeep and add roms/ to .gitignore
- Document in README.md exactly which ROM files are needed, their expected sizes
  and checksums if known, and where to obtain them legally (e.g. the AtariAge forums
  or the Atari 800 XL service manual sources)
- machine-cold-reset should load and map the ROMs as documented in the memory map

Boot instrumentation: add a debug-trace facility in src/machine.lisp:
- machine-trace-step (machine n): runs n CPU instructions and returns a list of
  (pc opcode mnemonic a x y p sp cycles) snapshots
- machine-portb-state (machine): returns the current PORTB value and its decoded
  meaning (OS mapped, BASIC mapped, self-test mapped)
- machine-scanline (machine): returns current ANTIC scanline
- machine-pending-interrupts (machine): returns irq-pending and nmi-pending state

Add a README.md section "Running toward BASIC" with step-by-step REPL instructions:
  1. (ql:quickload :atari800-cl)
  2. (defvar *m* (atari800-cl::make-atari-machine))
  3. (atari800-cl::machine-cold-reset *m* "roms/atarixl.rom" "roms/ataribas.rom")
  4. (atari800-cl::machine-trace-step *m* 100) ; inspect early boot instructions
  5. (dotimes (_ 10) (atari800-cl::machine-run-frame *m*)) ; run 10 frames

Add smoke tests in tests/test-machine.lisp using synthetic ROM fixtures that:
- Verify cold reset reads the correct reset vector address
- Verify that after reset, PORTB correctly maps OS and BASIC ROMs
- Verify machine-trace-step returns the expected number of snapshots
- Verify machine-run-frame runs without error across 5 frames with synthetic ROMs

Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 12 — IPC Layer for Headless Architecture

```
In the atari800-cl repository, implement the optional headless IPC layer in src/ipc.lisp.

Architecture:
- The emulator should run fully without a connected client (no mandatory IPC)
- When enabled, after each machine-run-frame the emulator serializes state and
  sends it over a Unix domain socket to an external renderer/audio process
- The IPC thread must be portable across SBCL and LispWorks using bordeaux-threads
  and usocket

Requirements:
- ipc-server-start (machine socket-path): spawns a server thread using bt:make-thread;
  listens on the given Unix socket path; accepts one client connection; loops calling
  machine-run-frame then ipc-send-frame
- ipc-send-frame (connection machine): serializes and sends:
    A fixed-size header: magic bytes, frame number, scanline count
    GTIA write-register array (32 bytes) as the framebuffer proxy for now
    POKEY AUDF/AUDC arrays (8 bytes) as audio state proxy
- ipc-server-stop (server): signals the server thread to exit cleanly
- Define the wire protocol as a simple struct in README.md with byte offsets

Add a FiveAM test in tests/test-machine.lisp:
- ipc-server-start creates a thread that is alive after startup
- ipc-server-stop terminates the thread within a reasonable timeout
- A loopback test: connect a client socket, run one frame, verify the header bytes
  are received correctly (magic + frame number = 1)

Do not make the IPC thread mandatory. All other tests must still pass without IPC running.
Run all tests under SBCL and fix every failure before delivering the updated repository.
```

---

## Prompt 13 — Test Harness Audit and CI Commands

```
In the atari800-cl repository, audit and strengthen the entire test harness.

Requirements:
- Ensure every FiveAM suite is registered under the umbrella suite :atari800-cl/all
- Confirm (asdf:test-system :atari800-cl/tests) runs all suites end to end
- Add a helper macro in tests/test-helpers.lisp: make-test-machine that constructs
  a machine with synthetic ROM fixtures suitable for any test that needs a running
  machine without real ROM files
- Add a helper macro: with-cpu-state ((cpu &key pc sp a x y p) &body body) that
  sets up a CPU for a targeted test and restores state after

SBCL batch command — add to README.md:
  sbcl --eval "(ql:quickload :atari800-cl/tests)" \
       --eval "(let ((result (asdf:test-system :atari800-cl/tests))) \
                 (uiop:quit (if result 0 1)))"

LispWorks command — document in README.md:
  lispworks -eval "(ql:quickload :atari800-cl/tests)" \
            -eval "(let ((result (asdf:test-system :atari800-cl/tests))) \
                    (lispworks:quit :status (if result 0 1)))"

Review all test suites and:
- Add clearer assertion messages to every (fiveam:is ...) call
- Remove any placeholder tests that no longer test anything real
- Ensure each test is independent (no shared mutable state between tests)
- Add at least two regression tests for known edge cases discovered during development

Run the complete suite under SBCL and achieve 100% pass rate before delivering
the updated repository.
```

---

## Prompt 14 — Final Polish and Repository Handoff

```
Review the complete atari800-cl repository and prepare it for handoff.

README.md must include:
- Project overview: what the emulator does and does not yet implement
- Dependency list with versions and Quicklisp availability
- Setup instructions for SBCL (with SLIME/Sly) and LispWorks
- How to run the full test suite on each platform
- How to run toward BASIC with user-supplied ROM files
- Known limitations: which Atari 800 XL features are architectural stubs,
  which timing areas are approximate, and what the next planned work items are
- Wire protocol documentation for the IPC layer

Code review tasks:
- Ensure all public functions in each package have docstrings
- Add type declarations to all performance-sensitive functions (especially those
  in the machine frame loop) so both SBCL and LispWorks can generate unboxed code
- Confirm compat.lisp handles all platform differences that were discovered during
  implementation; remove any workarounds that are no longer needed
- Add a CHANGES.md or inline git log summary of what each phase delivered

Git hygiene:
- Confirm the repo has a clean commit history with one commit per completed phase
- Add a .gitignore covering: roms/, *.fasl, *.fas, *.lib, *.dx64fsl, *.dx32fsl,
  *.lx64fsl, *.ofasl, compiled-cache/, .cache/

Run the full test suite one final time under SBCL. Deliver the complete repository
as a downloadable archive with a README that is accurate and complete.
```

---

## Quick Reference: Validation Checklist

Use these checks after each prompt before continuing to the next phase.

| Check | What to verify |
|---|---|
| Tests pass | `(asdf:test-system :atari800-cl/tests)` is green |
| Both Lisps | Code loads without errors on SBCL; LispWorks portability not broken |
| No ROMs committed | `roms/` contains only `.gitkeep` |
| CPU isolated | CPU unit tests pass without any Atari chip code |
| Timing accounts | Stolen cycles from ANTIC are subtracted from CPU budget |
| IRQs routed | POKEY timer fires → cpu-irq-pending; ANTIC VBI fires → cpu-nmi-pending |
| ROM-free boot | Synthetic ROM fixtures in tests; real ROM loading documented only |
| IPC optional | All tests pass without the IPC server running |

## Compact Summary of Prompts

| # | Topic |
|---|---|
| 1 | Repository scaffold, ASDF, portability layer, stub files |
| 2 | 6502 CPU struct, flags, stack, addressing modes |
| 3 | All 151 documented NMOS 6502 opcodes, Klaus Dormann fixture |
| 4 | All NMOS illegal opcodes (SLO, LAX, KIL, etc.) |
| 5 | Atari 800 XL bus, memory map, MMU, PORTB bank switching |
| 6 | PIA (PORTA joystick, PORTB → MMU routing) |
| 7 | ANTIC scanline engine, DMA cycle stealing, DLI/VBI |
| 8 | GTIA registers, player/missile, collision latches |
| 9 | POKEY timers, IRQ generation, IRQEN/IRQST, audio scaffolding |
| 10 | Interrupt routing, machine scheduler, cold reset |
| 11 | ROM loading, boot-toward-BASIC milestone, REPL instrumentation |
| 12 | Headless IPC server thread via bordeaux-threads + usocket |
| 13 | Test harness audit, CI batch commands, regression tests |
| 14 | Final polish, documentation, repository handoff |
