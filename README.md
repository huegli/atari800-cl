# atari800-cl

A headless Atari 800 XL emulator written in portable Common Lisp.

This is the scaffold for a clean-room Atari 800 XL emulator targeting
both **LispWorks** (the primary development implementation) and **SBCL**
(used for CI and Linux deployment). All implementation differences are
isolated to a single portability layer in `src/compat.lisp`; the rest of
the codebase is plain, conditional-free Common Lisp.

## Status

Early scaffold. The repository contains:

- `src/package.lisp` — internal package layout
- `src/compat.lisp` — LispWorks/SBCL portability layer
- `src/memory.lisp` — flat 64K address space (RAM only for now)
- `src/cpu.lisp` — 6502 register file and stub `step-cpu`
- `src/emulator.lisp` — `machine` glue that owns a CPU + memory
- `src/main.lisp` — public `:atari800-cl` API
- `tests/` — FiveAM suites for compat, memory, and CPU
- `atari800-cl.asd`, `atari800-cl-tests.asd` — ASDF system definitions

The 6502 instruction decoder, ANTIC/GTIA/POKEY peripherals, and the
PORTB-controlled OS/BASIC bank switching are deliberately stubbed —
those are the next milestones.

## Requirements

- A Common Lisp implementation: **LispWorks 7+** (primary) or
  **SBCL 2.x** (secondary).
- **ASDF 3+** (bundled with both implementations).
- **Quicklisp** for dependency management.

Runtime dependencies, all of which work on both implementations:

| System              | Purpose                                  |
| ------------------- | ---------------------------------------- |
| `alexandria`        | General-purpose utilities                |
| `bordeaux-threads`  | Cross-implementation threading & locking |
| `usocket`           | Network sockets (future debugger/RPC)    |
| `flexi-streams`     | Binary I/O & encoding helpers            |
| `fiveam` *(tests)*  | Test framework                           |

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

### Smoke-testing the API

```lisp
(let ((m (atari800-cl.emulator:make-machine)))
  (atari800-cl.emulator:reset-machine m)
  (atari800-cl.emulator:step-machine m)
  (atari800-cl.cpu:cpu-cycles
    (atari800-cl.emulator:machine-cpu m)))
;; => 1
```

Once you have ROM images, the public façade looks like this:

```lisp
(defparameter *m*
  (atari800-cl:make-machine
    :os-rom    #P"roms/atariosxl.rom"
    :basic-rom #P"roms/ataribas.rom"))

(atari800-cl:run-machine *m* :cycles 1000)
```

## ROM images

ROM images are **not** included — they remain copyrighted by Atari
Corporation's successors. Drop your own dumps into `roms/` (the
directory is `.gitignore`d for `*.rom` / `*.bin`):

```
roms/atariosxl.rom    16 KiB  OS ROM
roms/ataribas.rom      8 KiB  BASIC ROM
```

## Project layout

```
atari800-cl/
├── atari800-cl.asd          # main system
├── atari800-cl-tests.asd    # convenience alias for the test system
├── README.md
├── .gitignore
├── src/
│   ├── package.lisp
│   ├── compat.lisp          # LispWorks/SBCL portability layer
│   ├── memory.lisp
│   ├── cpu.lisp
│   ├── emulator.lisp
│   └── main.lisp
├── tests/
│   ├── package.lisp
│   ├── test-suite.lisp
│   ├── test-compat.lisp
│   ├── test-memory.lisp
│   └── test-cpu.lisp
└── roms/                    # ROM images go here (gitignored)
    └── .gitkeep
```

## Portability notes

The `atari800-cl.compat` package owns every place where LispWorks and
SBCL disagree:

- thread / lock primitives (delegated to `bordeaux-threads`),
- binary file I/O,
- GC-warning suppression,
- numeric-type aliases (`u8`, `u16`, `byte-vector`).

If you find yourself reaching for `#+lispworks` / `#+sbcl` in
`src/cpu.lisp`, `src/memory.lisp`, `src/emulator.lisp`, or `src/main.lisp`,
add the abstraction to `compat.lisp` instead.

## License

MIT. See source headers.
