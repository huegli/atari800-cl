# atari800-cl

A headless Atari 800 XL emulator written in portable Common Lisp.

This is the scaffold for a clean-room Atari 800 XL emulator targeting
both **LispWorks** (the primary development implementation) and **SBCL**
(used for CI and Linux deployment). All implementation differences are
isolated to a single portability layer in `src/compat.lisp`; the rest of
the codebase is plain, conditional-free Common Lisp.

## Status

Functional core, headless and cycle-aware enough to boot real
Atari OS+BASIC ROMs and stream state to an external renderer.

What's implemented:

- **6502 CPU** — all 151 documented NMOS opcodes plus all 105
  undocumented NMOS opcodes (compound RMW, LAX, SAX, ANC, ALR, ARR,
  AXS, LAS, TAS, unstable high-byte stores, NOPs, KIL/JAM/STP).
  Klaus Dormann's 6502 functional test runs to completion when the
  binary is present at `roms/6502_functional_test.bin`.
- **Memory map** — flat 64 KiB RAM + OS/BASIC/self-test ROM overlays,
  PORTB-driven bank-switching, I/O dispatch in `$D000-$D7FF`.
- **PIA** — 6520-compatible PORTA / DDRA / PORTB / DDRB.  PORTB writes
  propagate to the MMU.
- **ANTIC** — scanline-oriented NTSC engine (262 × 114).  Display-list
  parsing (blank lines, JMP/JVB, modes 2-F with LMS), DRAM-refresh
  cycle stealing, P/M DMA accounting, DLI/VBI NMI generation.
- **GTIA** — split write/read register windows, player-vs-player /
  player-vs-playfield / missile-vs-player / missile-vs-playfield
  collision recording, HITCLR, trigger / CONSOL / PAL defaults.
- **POKEY** — four-channel timers with per-channel clock divider,
  IRQEN/IRQST latches (active-low) and timer-1/2/4 IRQs, 17- and
  9-bit polynomial RNG behind RANDOM, audio register scaffolding.
- **Machine scheduler** — `MACHINE-RUN-FRAME` pumps 29 868 NTSC color
  clocks per frame in lockstep with ANTIC and POKEY, services NMI and
  IRQ each clock, runs the CPU when budget allows, and halts cleanly
  on KIL.

What's *not* yet implemented:

- Pixel-level ANTIC/GTIA rendering — there is no framebuffer; nothing
  inside the emulator paints.
- POKEY audio synthesis — register state is maintained; waveform
  generation is left to a downstream consumer.
- Serial I/O and SIO bus (cassette, disk, printer).
- Keyboard scanning (KBCODE never updates from a real input source).
- Light pen, paddles, cartridge mapper, and the right-cartridge slot.

See `CHANGES.md` for a phase-by-phase summary of what each commit
delivered.

## Requirements

- A Common Lisp implementation:
  - **LispWorks 7.0+** (primary development target), or
  - **SBCL 2.2+** (verified through 2.6.5 on arm64-macOS and
    x86-64-Linux; used for CI).
- **ASDF 3.3+** (bundled with both implementations).
- **Quicklisp** for fetching runtime dependencies.

For SBCL development the optional Emacs side adds either
**SLIME** or **Sly** — both load against this project unmodified.
LispWorks ships its own IDE; no extra setup required.

Runtime dependencies (all are in Quicklisp's default dist and load
on both implementations):

| System              | Min version | Purpose                                  |
| ------------------- | ----------- | ---------------------------------------- |
| `alexandria`        | any         | General-purpose utilities                |
| `bordeaux-threads`  | 0.8+        | Cross-implementation threading & locking |
| `fiveam` *(tests)*  | 1.4+        | Test framework                           |

## Getting started

```sh
git clone <this-repo> atari800-cl
cd atari800-cl
```

Make the system visible to ASDF — for example, symlink it into your
`local-projects` directory:

```sh
ln -s "$PWD" ~/quicklisp/local-projects/atari800-cl
```

### Loading the system

In a Lisp REPL (LispWorks or SBCL):

```lisp
(ql:quickload :atari800-cl)
```

### IDE setup

- **SBCL + SLIME or Sly (Emacs)** — no project-specific configuration
  needed; just `M-x slime` (or `sly`), then `,ql atari800-cl`.
- **LispWorks** — `File → Open Application Builder` and load the
  ASD file, or in the listener:
  `(load "atari800-cl.asd") (asdf:load-system :atari800-cl)`.

### Running the test suite

```lisp
(ql:quickload :atari800-cl/tests)
(asdf:test-system :atari800-cl)
```

Or from the shell with SBCL:

```sh
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(asdf:test-system :atari800-cl)'
```

### CI batch commands

The exit status keys off `fiveam:run!` (returns `T` only when every
check passes), **not** `asdf:test-system` — the latter returns `T` even
when tests fail and would mask failures in CI.

SBCL — exits 0 on success, 1 on any test failure (suitable for CI):

```sh
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

LispWorks — the console image is `lw-console`. Command-line `-eval`
forms are read before the init file loads Quicklisp, so load
`setup.lisp` first and defer the `ql:` symbol with `read-from-string`:

```sh
lw-console -eval '(load "~/quicklisp/setup.lisp")' \
           -eval '(funcall (read-from-string "ql:quickload") :atari800-cl/tests)' \
           -eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

The umbrella `ATARI800-CL-SUITE` aggregates every per-component suite
(compat, memory, CPU, opcodes, illegal opcodes, MMU, PIA, ANTIC,
GTIA, POKEY, machine, regressions); a green
`asdf:test-system` means the whole emulator passed.

### Smoke-testing the API

The public façade (package `atari800-cl`, nickname `a800`) builds and
drives the full machine:

```lisp
(let ((m (a800:make-machine)))     ; full machine, cold-reset
  (a800:step-machine m)            ; one CPU instruction; returns cycles
  (a800:run-frame m :count 1)      ; one NTSC frame (CPU + ANTIC + POKEY)
  (a800:machine-frame-count m))
;; => 1
```

Once you have ROM images, point `make-machine` at them and run whole
frames:

```lisp
(defparameter *m*
  (a800:make-machine
    :os-rom    #P"roms/atariosxl.rom"
    :basic-rom #P"roms/ataribas.rom"))

;; RUN-FRAME drives the entire machine; RUN-MACHINE/STEP-MACHINE advance
;; only the CPU (handy for debugging, but they don't pump ANTIC/POKEY).
(a800:run-frame *m* :count 60)     ; ~1 second of emulated time
```

## ROM images

ROM images are **not** included — they remain copyrighted by Atari
Corporation's successors. Drop your own dumps into `roms/` (the
directory is `.gitignore`d for `*.rom` / `*.bin`):

| File                  | Size    | Purpose       | Notes                                                          |
| --------------------- | ------- | ------------- | -------------------------------------------------------------- |
| `roms/atariosxl.rom`  | 16 KiB  | 800 XL OS ROM | Maps to `$C000-$CFFF` and `$D800-$FFFF`. Holds the self-test code at offset `$1000-$17FF` (mirrored at `$5000-$57FF` when bit 7 of PORTB is 0). |
| `roms/ataribas.rom`   |  8 KiB  | BASIC ROM     | Maps to `$A000-$BFFF` when PORTB bit 1 is 0.                   |

Common hashes (verify before using a dump):

```
md5: c5c11546fb909c64eb1bdfc1eb89b3fe   atariosxl.rom   (16384 bytes)
md5: 0bac0c6a50104045d902df4503a4c30b   ataribas.rom    ( 8192 bytes)
```

Legitimate sources: the Atari 800 XL service manual / firmware
listings, AtariAge community archives, or your own physical 800 XL
dumped via a cartridge / cassette interface.

## Running toward BASIC

Once you have legal ROM dumps in `roms/`, you can boot the emulator
through to its BASIC prompt entirely from the REPL:

```lisp
(ql:quickload :atari800-cl)

;; 1. Construct a fully-wired machine (CPU + BUS + MMU + PIA + ANTIC +
;;    GTIA + POKEY).
(defvar *m* (atari800-cl.machine:make-atari-machine))

;; 2. Cold reset: load ROMs, set PORTB = $FF, load PC from the reset
;;    vector at $FFFC.
(atari800-cl.machine:machine-cold-reset
  *m*
  :os-path    #P"roms/atariosxl.rom"
  :basic-path #P"roms/ataribas.rom")

;; 3. Inspect the first 100 CPU instructions executed.
(atari800-cl.machine:machine-trace-step *m* 100)
;; => list of (:pc ... :opcode ... :mnemonic "..." :a ... :x ... ...)

;; 4. Run forward 10 NTSC frames (262 scanlines each).
(dotimes (_ 10) (atari800-cl.machine:machine-run-frame *m*))

;; 5. Poll the bank-switching state.
(atari800-cl.machine:machine-portb-state *m*)
;; => (:portb #xFF :os-rom-mapped T :basic-rom-mapped NIL :selftest-mapped NIL)

;; 6. Where is ANTIC right now?
(atari800-cl.machine:machine-scanline *m*)
;; => 0   ;; just wrapped to the next frame

;; 7. Are any interrupts still pending?
(atari800-cl.machine:machine-pending-interrupts *m*)
;; => (:irq-pending NIL :nmi-pending NIL :i-flag-masked T)
```

The emulator runs headless: there is no built-in video / audio
output. A downstream renderer or audio player can drive the machine
with `MACHINE-RUN-FRAME` and read the program-visible chip state
(GTIA write registers, POKEY audio registers, ANTIC scanline) directly
after each frame.

## Project layout

```
atari800-cl/
├── atari800-cl.asd          # main system definition
├── atari800-cl-tests.asd    # convenience alias for the test system
├── README.md
├── CHANGES.md               # phase-by-phase changelog
├── .gitignore
├── AI-Docs/
│   └── AI-Prompts.md        # the build-by-prompt plan
├── src/
│   ├── package.lisp         # all package definitions
│   ├── compat.lisp          # LispWorks/SBCL portability layer
│   ├── memory.lisp          # legacy flat 64K memory (scaffold)
│   ├── mmu.lisp             # PORTB-driven bank-switching unit
│   ├── bus.lisp             # system bus + memory map + I/O dispatch
│   ├── pia.lisp             # 6520 PIA
│   ├── cpu.lisp             # 6502 register file + interrupt service
│   ├── cpu-opcodes.lisp     # 151 documented opcodes
│   ├── illegal.lisp         # 105 NMOS undocumented opcodes
│   ├── antic.lisp           # NTSC display-list / DMA engine
│   ├── gtia.lisp            # player/missile + collision latches
│   ├── pokey.lisp           # timers + IRQ + RNG + audio scaffolding
│   ├── irq.lisp             # NMI/IRQ routing helpers
│   ├── machine.lisp         # top-level ATARI-MACHINE + run-frame
│   └── main.lisp            # public :atari800-cl façade
├── tests/
│   ├── package.lisp
│   ├── test-suite.lisp      # root FiveAM suite
│   ├── test-helpers.lisp    # shared fixtures + MAKE-TEST-MACHINE
│   ├── test-compat.lisp
│   ├── test-memory.lisp
│   ├── test-cpu.lisp
│   ├── test-cpu-opcodes.lisp
│   ├── test-illegal.lisp
│   ├── test-mmu.lisp
│   ├── test-pia.lisp
│   ├── test-antic.lisp
│   ├── test-gtia.lisp
│   ├── test-pokey.lisp
│   ├── test-machine.lisp
│   └── test-regressions.lisp
└── roms/                    # user-supplied ROM images (gitignored)
    └── .gitkeep
```

## Known limitations

- **No pixel rendering or audio synthesis.** ANTIC and GTIA emulate
  the program-visible state of the chips (display list parsing, mode
  lines, P/M positions, collision latches), but the emulator does
  *not* paint a framebuffer.  Likewise POKEY emulates timer / IRQ /
  RNG accurately, but does not produce a PCM stream.  Pixel and audio
  output are expected to live in a downstream renderer that reads the
  chip state after each frame.
- **Cycle accounting is approximate.**  ANTIC's DMA steal is lumped
  at color-clock 0 of each scanline rather than spread across the
  line, and `MACHINE-RUN-FRAME` uses a budget-style CPU advance
  rather than a true cycle-accurate interleave.  Cycle-sensitive
  tricks (raster effects, mid-scanline reprogramming) are out of
  scope today.
- **Decimal-mode quirks** for ADC/SBC follow the standard reference,
  but ARR's decimal-mode flag behaviour is not modelled (binary mode
  is always assumed for that one undocumented opcode).
- **Unstable opcodes** (XAA, AHX, SHX, SHY, TAS, LAX #imm) use the
  most-consistent canonical implementation — real hardware results
  vary chip-to-chip and the emulator does not try to reproduce the
  fault-injection that happens on indexed page crosses.
- **No real keyboard, joystick, light pen, paddles, or SIO bus.**
  PORTA reads return $FF (no buttons pressed), POT0-7 return $FF,
  KBCODE stays 0.  TRIG0-3 default to 1 (released).
- **No cartridge or right-cartridge support.**  $8000-$9FFF behaves
  as plain RAM with no mapper.

## Portability notes

The `atari800-cl.compat` package owns every place where LispWorks and
SBCL disagree:

- thread / lock primitives (delegated to `bordeaux-threads`),
- binary file I/O,
- GC-warning suppression,
- numeric-type aliases (`u8`, `u16`, `byte-vector`).

If you find yourself reaching for `#+lispworks` / `#+sbcl` in any source
file other than `compat.lisp` (`src/cpu.lisp`, `src/bus.lisp`,
`src/machine.lisp`, `src/main.lisp`, …), add the abstraction to
`compat.lisp` instead.

## License

MIT. See source headers.
