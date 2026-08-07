# atari800-cl

A headless Atari 800 XL emulator written in portable Common Lisp.

This is the scaffold for a clean-room Atari 800 XL emulator targeting
both **LispWorks** (the primary development implementation) and **SBCL**
(used for CI and Linux deployment). All implementation differences are
isolated to a single portability layer in `src/compat.lisp`; the rest of
the codebase is plain, conditional-free Common Lisp.

## Status

Functional core, headless and cycle-aware enough to boot real
Atari OS+BASIC ROMs, render the display to an RGB framebuffer, and
stream video frames to external clients.

What's implemented:

- **6502 CPU** — all 151 documented NMOS opcodes plus all 105
  undocumented NMOS opcodes (compound RMW, LAX, SAX, ANC, ALR, ARR,
  AXS, LAS, TAS, unstable high-byte stores, NOPs, KIL/JAM/STP).
  Klaus Dormann's 6502 functional test runs to completion when the
  binary is present at `roms/6502_functional_test.bin`.
- **Memory map** — flat 64 KiB RAM + OS/BASIC/self-test ROM overlays,
  PORTB-driven bank-switching, I/O dispatch in `$D000-$D7FF`.
- **PIA** — 6520-compatible PORTA/DDRA at `$D300` and PORTB/DDRB at
  `$D301` (each pair selected by bit 2 of PACTL/PBCTL at `$D302`/`$D303`).
  PORTB writes propagate to the MMU.
- **ANTIC** — scanline-oriented NTSC engine (262 × 114).  Display-list
  parsing (blank lines, JMP/JVB, modes 2-F with LMS), DRAM-refresh
  cycle stealing, P/M DMA accounting, DLI/VBI NMI generation.
- **GTIA** — split write/read register windows, player-vs-player /
  player-vs-playfield / missile-vs-player / missile-vs-playfield
  collision recording, HITCLR, trigger / CONSOL / PAL defaults.
- **POKEY** — four-channel timers with per-channel clock divider,
  hardware reload offsets (AUDF+4 at 1.79 MHz) and linked 16-bit
  channel pairs, IRQEN/IRQST latches (active-low) and timer-1/2/4
  IRQs, 17- and 9-bit polynomial RNG behind RANDOM.
- **POKEY audio** — four-channel synthesis into mono 8-bit PCM at
  44 744 Hz: poly4/5/9/17 distortions, volume-only mode, and mixing,
  attached on demand with `machine-attach-audio` and collected with
  `machine-audio-drain` (746–747 samples per frame).
- **Machine scheduler** — `MACHINE-RUN-FRAME` runs one NTSC frame
  (29 868 clocks = 262 scanlines × 114 CPU cycles) scanline-by-scanline:
  ANTIC fires each line's events and reports its stolen cycles, the CPU
  executes whole instructions against the line's remaining budget with
  POKEY advanced alongside, and the line is closed — halting cleanly on
  KIL.  A background run loop + command mailbox let other threads drive
  the machine safely.
- **Pixel renderer** — a per-scanline renderer converts ANTIC
  display-list state + GTIA registers into a 384×240 24-bit RGB
  framebuffer (background, playfield modes 2-F, player/missile
  compositing with PRIOR priority arbitration).  Completed frames are
  pushed to AESP video subscribers, and
  `scripts/capture-screenshot.py` saves PNG/PPM screenshots.
- **Audio** — POKEY synthesises its four channels (poly4/5/9/17
  distortions, volume-only mode) into mono 8-bit PCM at 44 744 Hz.
  Frames are pushed to AESP audio subscribers as `AUDIO_PCM`, and
  `scripts/capture-audio.py` saves WAVs.  Synthesis is attached only
  while someone is listening.
- **Host input** — a thread-safe input-state feeds live joystick,
  console-key, paddle, and keyboard values into PIA/GTIA/POKEY reads.
- **Protocol servers** — AESP (binary, 3 TCP ports) and a CLI (text,
  Unix socket) let an external GUI/CLI/web client drive the emulator.
  See [Protocol servers](#protocol-servers-aesp--cli).

What's *not* yet implemented:

- Streaming the synthesised audio over AESP — samples are produced and
  drainable in-process, but `AUDIO_SUBSCRIBE` still replies with a
  config and sends no frames.
- Serial I/O and SIO bus (cassette, disk, printer).
- Light pen, cartridge mapper, and the right-cartridge slot.

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
| `usocket`           | 0.8+        | TCP transport for the AESP server        |
| `flexi-streams`     | any         | Octet/string + in-memory streams (AESP)  |
| `fiveam` *(tests)*  | 1.4+        | Test framework                           |

The Unix-domain socket used by the CLI server is handled per-implementation
in `compat.lisp` (`sb-bsd-sockets` on SBCL, an FLI `AF_UNIX` wrapper on
LispWorks) — usocket has no local-socket support.

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
forms are read before Quicklisp loads (so defer non-CL symbols with
`read-from-string`) **and** before multiprocessing is fully initialized
— creating threads too early raises *"Cannot create processes before
multiprocessing is initialized"* and fails every threaded test. Run the
suite inside `mp:initialize-multiprocessing`:

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

(An interactive `(asdf:test-system :atari800-cl)` from the LispWorks REPL
needs no such wrapper — the REPL already runs under multiprocessing.)

The umbrella `ATARI800-CL-SUITE` aggregates every per-component suite
(compat, input, memory, CPU, opcodes, illegal opcodes, MMU, PIA, ANTIC,
GTIA, POKEY, machine, AESP, CLI, regressions); a green
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

The emulator runs headless: it opens no window and plays no sound
itself.  The built-in pixel renderer paints a 384×240 RGB framebuffer
each frame, which AESP video subscribers receive as `VIDEO_FRAME`
pushes, and POKEY synthesises mono 8-bit PCM which audio subscribers
receive as `AUDIO_PCM` pushes.  In-process, attach synthesis with
`a800:machine-attach-audio` and collect samples with
`a800:machine-audio-drain` after each frame; to capture from outside,
use `scripts/capture-audio.py` (WAV) and `scripts/capture-screenshot.py`
(PNG/PPM).

## Raster effects (WSYNC)

`STA WSYNC` ($D40A) — the register every DLI handler starts with —
stalls the CPU to the end of the current scanline, so a program can
change a color register (or anything else) once per line and produce
classic "raster bar" effects. `asm/edvent02_rasterbars.asm` is a
minimal demo: it waits for the top of the display, then loops writing
a new `COLBK` value after each `WSYNC` release, painting 64 distinct
horizontal color bands. Build and capture a screenshot with:

```sh
./scripts/mads-build.sh asm/edvent02_rasterbars.asm
./scripts/atari-run.sh asm/build/edvent02_rasterbars.xex -frame 30 -o rasterbars.png
```

## Protocol servers (AESP + CLI)

The emulator can be driven by an external GUI/CLI/web client over two
socket protocols (compatible with the [Attic](https://github.com/huegli/attic)
project's `PROTOCOL.md`).  Both run against a single background emulator
thread; a client never touches the machine directly — requests are posted
to the machine's command mailbox and executed on the emulator thread.

```lisp
(ql:quickload :atari800-cl)

(defparameter *m* (a800:make-machine))
(defparameter *runner* (a800:start-machine *m*))               ; background run loop

;; AESP — binary protocol over three TCP ports (control/video/audio).
(defparameter *aesp* (a800:start-aesp-server *m*))             ; default ports 47800-47802
;; CLI — text line protocol over a Unix-domain socket.
(defparameter *cli*  (a800:start-cli-socket  *m*))             ; /tmp/atari800-cl-<pid>.sock

;; ... clients connect and drive the machine ...

(a800:stop-aesp-server *aesp*)
(a800:stop-cli-socket  *cli*)
(a800:stop-machine     *runner*)
```

**AESP** (binary).  Each message is an 8-byte big-endian header — magic
`0xAE50`, version 1, a 1-byte type, and a 4-byte payload length (≤ 16 MiB)
— followed by the payload.  The MVP control surface: `PING`→`PONG`;
`PAUSE`/`RESUME`/`RESET`→`ACK`; `STATUS`/`INFO`; the input events
`KEY_DOWN`/`KEY_UP`/`JOYSTICK`/`CONSOLE_KEYS`/`PADDLE`→`ACK`;
`VIDEO_SUBSCRIBE`→`FRAME_CONFIG` followed by per-frame `VIDEO_FRAME`
pushes of the rendered 384×240 RGB framebuffer, and
`AUDIO_SUBSCRIBE`→`AUDIO_CONFIG` (44 744 Hz, 8-bit, mono) followed by
per-frame `AUDIO_PCM` pushes of 746–747 raw mono samples to audio-port
clients; any other type → `ERROR`.  The Nth `AUDIO_PCM` pairs with the
Nth `VIDEO_FRAME` — both are pushed from the same post-frame hook, so
A/V capture needs no timestamps.  Synthesis runs only while an audio
client is connected.

**CLI** (text).  Newline-terminated `CMD:<verb> [args]` requests yield
`OK:<data>` or `ERR:<msg>` replies.  MVP verbs: `ping`, `version`,
`pause`, `resume`, `step [n]`, `reset [cold|warm]`, `status`,
`read $ADDR N`, `write $ADDR HEX,HEX,…`, `fill $START $END $VALUE`,
`registers [REG=$VAL …]`, `quit`.  Anything else replies
`ERR:Not implemented` or `ERR:unknown command`.

```sh
# CLI: a one-shot ping (any line-oriented socket client works).
printf 'CMD:ping\n' | nc -U /tmp/atari800-cl-$(pgrep -n sbcl).sock
# => OK:pong
```

Not yet implemented (both protocols): `BOOT_FILE`, `AUDIO_SYNC`, and
the debugger/disk/BASIC/state/screenshot command families.

## Project layout

```
atari800-cl/
├── atari800-cl.asd          # main system definition
├── atari800-cl-tests.asd    # convenience alias for the test system
├── README.md
├── CHANGES.md               # phase-by-phase changelog
├── PERFORMANCE_LOG.md       # benchmark results per optimization commit
├── PERFORMANCE_PLAN.md      # performance work plan (Phases 0-3 done)
├── SCANLINE_ACCURACY_PLAN.md # timing-accuracy roadmap (Phase 1 done)
├── MISC_IMPROVEMENTS_PLAN.md
├── .gitignore
├── AI-Docs/
│   └── AI-Prompts.md        # the build-by-prompt plan
├── asm/                     # example 6502 programs (MADS syntax)
├── minimal-xl/              # git submodule: minimal XL OS for bring-up
├── scripts/
│   ├── test-sbcl.sh         # noninteractive test runners
│   ├── test-lispworks.sh
│   ├── bench-sbcl.sh        # frame-rate benchmark harness
│   ├── bench-lispworks.sh
│   ├── mads-build.sh        # assemble MADS sources to XEX
│   ├── atari-run.sh         # run a XEX and capture a screenshot
│   ├── capture-screenshot.py # AESP video-frame → PNG/PPM
│   └── capture-audio.py     # AESP AUDIO_PCM → WAV
├── src/
│   ├── package.lisp         # all package definitions
│   ├── compat.lisp          # LispWorks/SBCL portability layer (+ sockets)
│   ├── input.lisp           # thread-safe host input state
│   ├── memory.lisp          # legacy flat 64K memory (scaffold)
│   ├── mmu.lisp             # PORTB-driven bank-switching unit
│   ├── bus.lisp             # system bus + memory map + I/O dispatch
│   ├── pia.lisp             # 6520 PIA
│   ├── cpu.lisp             # 6502 register file + interrupt service
│   ├── cpu-opcodes.lisp     # 151 documented opcodes
│   ├── illegal.lisp         # 105 NMOS undocumented opcodes
│   ├── antic.lisp           # NTSC display-list / DMA engine
│   ├── gtia.lisp            # player/missile + collision latches
│   ├── pokey.lisp           # timers + IRQ + RNG
│   ├── audio.lisp           # POKEY audio synthesis → 8-bit PCM
│   ├── irq.lisp             # NMI/IRQ routing helpers
│   ├── renderer.lisp        # per-scanline 384×240 RGB pixel renderer
│   ├── machine.lisp         # top-level ATARI-MACHINE + run-frame + mailbox
│   ├── transport.lisp       # TCP (usocket) + Unix-socket transport
│   ├── aesp.lisp            # AESP binary protocol codec + 3-port server
│   ├── cli-socket.lisp      # CLI text line protocol over a Unix socket
│   └── main.lisp            # public :atari800-cl façade
├── tests/
│   ├── package.lisp
│   ├── test-suite.lisp      # root FiveAM suite
│   ├── test-helpers.lisp    # shared fixtures + MAKE-TEST-MACHINE
│   ├── test-compat.lisp
│   ├── test-input.lisp
│   ├── test-memory.lisp
│   ├── test-cpu.lisp
│   ├── test-cpu-opcodes.lisp
│   ├── test-illegal.lisp
│   ├── test-mmu.lisp
│   ├── test-pia.lisp
│   ├── test-antic.lisp
│   ├── test-renderer.lisp
│   ├── test-gtia.lisp
│   ├── test-pokey.lisp
│   ├── test-machine.lisp
│   ├── test-aesp.lisp
│   ├── test-cli-socket.lisp
│   └── test-regressions.lisp
└── roms/                    # user-supplied ROM images (gitignored)
    └── .gitkeep
```

## Known limitations

- **Audio synthesis is approximate.** POKEY produces mono 8-bit PCM at
  44 744 Hz, streamed over AESP as `AUDIO_PCM`, but does not model
  AUDCTL's two high-pass filters (bits 1-2), two-tone serial mode, or
  real POKEY's non-linear volume/mixer curve (this mixer is linear and
  bipolar).
- **Rendering is scanline-granular, not cycle-exact.**  The pixel
  renderer paints each scanline once, from the chip state at the end
  of the line; GTIA register changes *within* a line (mid-scanline
  color splits and similar raster tricks) render with the final
  values only.
- **Cycle accounting is scanline-approximate.**  ANTIC's full DMA
  steal is charged against each scanline's CPU budget, but the steal
  is lumped at the start of the line rather than spread across it,
  WSYNC ($D40A) writes are ignored, and playfield/display-list DMA
  stealing is not yet counted (see `SCANLINE_ACCURACY_PLAN.md` for
  the roadmap).  Cycle-position-sensitive tricks are out of scope
  today.
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
