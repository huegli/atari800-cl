;;;; src/package.lisp --- Package definitions for atari800-cl.
;;;;
;;;; The emulator is split across a small set of internal packages:
;;;;
;;;;   atari800-cl.compat   — implementation portability layer
;;;;   atari800-cl.memory   — 64K address space and memory map
;;;;   atari800-cl.cpu      — 6502 CPU core
;;;;   atari800-cl.emulator — top-level machine glue
;;;;   atari800-cl          — public façade re-exporting user-facing API
;;;;
;;;; Internal packages keep their symbols private; only :atari800-cl
;;;; exports a stable public API.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; A "package" in Common Lisp is a namespace for symbols (names).
;;;; DEFPACKAGE declares which symbols a package exports (makes public)
;;;; and which other packages it imports from.
;;;;
;;;; (:USE #:cl) means "import all exported symbols from the CL package",
;;;; which gives us standard functions like DEFUN, LET, LOOP, etc.
;;;;
;;;; (:USE #:atari800-cl.compat) means "also import all exports from our
;;;; compat package", so we can write U8 instead of ATARI800-CL.COMPAT:U8.
;;;;
;;;; (:EXPORT #:symbol) makes SYMBOL accessible to other packages that
;;;; :USE this one, or via the PACKAGE:SYMBOL qualified syntax.
;;;;
;;;; The #: prefix (e.g. #:cl, #:make-cpu) creates an "uninterned symbol"
;;;; — a symbol not belonging to any package.  This is conventional in
;;;; DEFPACKAGE because it avoids accidentally interning symbols into the
;;;; current package as a side effect of reading the form.  It is purely
;;;; a hygiene measure; :CL (a keyword) would also work but is less idiomatic.

;; We define our packages in CL-USER, the standard "scratch" package that
;; exists in every Common Lisp environment.
(in-package #:cl-user)

;;; ---------------------------------------------------------------------------
;;; atari800-cl.compat — Portability layer
;;;
;;; This is the lowest-level package.  It only :USE's #:cl (standard CL)
;;; and exports type aliases (U8, U16, BYTE-VECTOR), threading helpers,
;;; and binary I/O wrappers.

(defpackage #:atari800-cl.compat
  (:use #:cl)
  (:documentation
   "Portability layer hiding LispWorks/SBCL implementation differences.")
  (:export #:*implementation*
           #:implementation-name
           #:make-byte-vector
           #:byte-vector
           #:u8
           #:u16
           #:make-lock
           #:with-lock
           #:make-thread
           #:join-thread
           #:current-thread
           #:read-binary-file
           #:write-binary-file
           #:without-gc-warnings))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.memory — 64K address space
;;;
;;; Depends on compat for the U8/U16/BYTE-VECTOR types.  Exports the
;;; MEMORY struct and its accessor functions.

(defpackage #:atari800-cl.memory
  (:use #:cl #:atari800-cl.compat)
  (:documentation "64K address space, RAM/ROM banks, and memory-mapped I/O hooks.")
  (:export #:memory
           #:make-memory
           #:mem-read
           #:mem-write
           #:load-rom
           #:install-os-rom
           #:install-basic-rom
           #:reset-memory))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.cpu — 6502 CPU core
;;;
;;; Depends on both compat (types) and memory (for ATTACH-MEMORY-BUS).
;;; The export list is large because we expose the full register file,
;;; flag constants, interrupt vectors, and the opcode dispatch table.
;;; Constants follow the CL convention of +PLUS-SIGNS+ for named constants
;;; (defined with DEFCONSTANT) and *EARMUFFS* for special variables
;;; (defined with DEFPARAMETER or DEFVAR).

(defpackage #:atari800-cl.cpu
  (:use #:cl #:atari800-cl.compat #:atari800-cl.memory)
  (:documentation "6502 CPU core: registers, flags, instruction decode and step.")
  (:export #:cpu
           #:make-cpu
           #:reset-cpu
           #:step-cpu
           #:run-cpu
           #:cpu-pc
           #:cpu-a
           #:cpu-x
           #:cpu-y
           #:cpu-sp
           #:cpu-flags
           #:cpu-cycles
           #:cpu-bus-read
           #:cpu-bus-write
           #:cpu-pending-irq
           #:cpu-pending-nmi
           #:cpu-halted
           #:attach-memory-bus
           #:trigger-nmi
           #:set-irq-line
           #:flag-set?
           #:set-flag
           #:clear-flag
           #:set-flag-to
           #:status-byte-for-push
           #:status-byte-from-pull
           #:push-byte
           #:pull-byte
           #:push-word
           #:pull-word
           ;; Flag-bit constants (DEFCONSTANT, hence +plus-sign+ naming)
           #:+flag-c+ #:+flag-z+ #:+flag-i+ #:+flag-d+
           #:+flag-b+ #:+flag-u+ #:+flag-v+ #:+flag-n+
           ;; Interrupt vector addresses
           #:+nmi-vector+ #:+reset-vector+ #:+irq-vector+
           ;; Opcode dispatch table and introspection
           #:*opcode-table*
           #:*opcode-mnemonic-table*
           #:documented-opcodes
           #:illegal-opcodes
           #:*illegal-opcode-list*
           #:illegal-opcode
           ;; Interrupt service functions (used by IRQ routing layer)
           #:service-nmi
           #:service-irq))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.mmu — Memory Management Unit (PORTB bank-switching)
;;;
;;; Owns the PORTB shadow register and the OS/BASIC/self-test ROM mapping
;;; predicates.  The PIA writes here whenever software writes $D302;
;;; the bus consults these predicates on every read.

(defpackage #:atari800-cl.mmu
  (:use #:cl #:atari800-cl.compat)
  (:documentation "Atari 800 XL PORTB-driven memory bank switching.")
  (:export #:mmu
           #:make-mmu
           #:mmu-portb
           #:mmu-write-portb
           #:reset-mmu
           #:os-rom-mapped-p
           #:basic-rom-mapped-p
           #:selftest-mapped-p
           #:portb-decode
           #:+portb-os-rom-mask+
           #:+portb-basic-rom-mask+
           #:+portb-selftest-mask+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.bus — Atari 800 XL system bus and memory map
;;;
;;; The CPU talks through BUS-READ / BUS-WRITE.  The bus owns 64K RAM,
;;; the OS and BASIC ROM images, a reference to the MMU, and per-chip
;;; dispatch closures that get installed when individual chips are
;;; attached (PIA, GTIA, POKEY, ANTIC — added in later milestones).

(defpackage #:atari800-cl.bus
  (:use #:cl #:atari800-cl.compat #:atari800-cl.mmu)
  (:documentation "Atari 800 XL system bus: memory map and I/O dispatch.")
  (:export #:bus
           #:make-bus
           #:bus-ram
           #:bus-os-rom
           #:bus-basic-rom
           #:bus-mmu
           #:bus-read
           #:bus-write
           #:bus-read16
           #:install-os-rom
           #:install-basic-rom
           #:attach-mmu
           #:bus-peek-ram
           #:bus-poke-ram
           ;; Chip object back-pointers
           #:bus-gtia #:bus-pokey #:bus-pia #:bus-antic
           ;; Per-chip dispatch closures (installed by chip attach functions)
           #:bus-gtia-read-fn  #:bus-gtia-write-fn
           #:bus-pokey-read-fn #:bus-pokey-write-fn
           #:bus-pia-read-fn   #:bus-pia-write-fn
           #:bus-antic-read-fn #:bus-antic-write-fn
           ;; Region constants
           #:+selftest-base+   #:+selftest-end+
           #:+basic-rom-base+  #:+basic-rom-end+
           #:+os-rom-low-base+ #:+os-rom-low-end+
           #:+io-base+         #:+io-end+
           #:+os-rom-high-base+ #:+os-rom-high-end+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.pia — 6520 PIA (joystick input + PORTB → MMU output)
;;;
;;; The PIA owns PORTA / DDRA / PORTB / DDRB at $D300-$D303.  A write
;;; to PORTB (offset 2) propagates to the attached MMU so bank-switching
;;; takes effect on the next bus access.

(defpackage #:atari800-cl.pia
  (:use #:cl #:atari800-cl.compat #:atari800-cl.mmu #:atari800-cl.bus)
  (:documentation "Atari 800 XL PIA (6520-compatible).")
  (:export #:pia
           #:make-pia
           #:pia-porta #:pia-ddra
           #:pia-portb #:pia-ddrb
           #:pia-mmu
           #:pia-read
           #:pia-write
           #:reset-pia
           #:attach-pia))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.antic — Display list / DMA engine for the 800 XL
;;;
;;; Scanline-oriented model: ANTIC-TICK advances one NTSC color clock,
;;; performs display-list parsing on the correct scanline boundaries,
;;; lumps DRAM refresh and P/M DMA steals at color-clock 0 of each
;;; scanline, and raises NMI lines for DLI and VBI events.

(defpackage #:atari800-cl.antic
  (:use #:cl #:atari800-cl.compat #:atari800-cl.bus #:atari800-cl.cpu)
  (:documentation "Atari 800 XL ANTIC video controller (NTSC scanline timing).")
  (:export #:antic
           #:make-antic
           #:antic-registers
           #:antic-dlist-pointer
           #:antic-dl-offset
           #:antic-scanline
           #:antic-color-clock
           #:antic-dmactl
           #:antic-nmien
           #:antic-nmist
           #:antic-current-mode
           #:antic-mode-scanlines-remaining
           #:antic-dli-armed
           #:antic-jvb-wait
           #:antic-frame-count
           #:antic-stolen-cycles
           #:antic-tick
           #:antic-read
           #:antic-write
           #:reset-antic
           #:attach-antic
           #:mode-line-scanlines
           #:+scanlines-per-frame+
           #:+color-clocks-per-scanline+
           #:+vbi-scanline+
           #:+dram-refresh-cycles+
           #:+nmi-dli+ #:+nmi-vbi+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.gtia — GTIA (player/missile + collision latches + console)
;;;
;;; GTIA registers occupy $D000-$D0FF.  The write side accepts HPOS,
;;; size, graphics, color, priority, HITCLR, and CONSOL (speaker)
;;; values.  The read side returns collision latches, console keys,
;;; triggers, and the PAL/NTSC indicator.

(defpackage #:atari800-cl.gtia
  (:use #:cl #:atari800-cl.compat #:atari800-cl.bus)
  (:documentation "Atari 800 XL GTIA chip (player/missile + collisions).")
  (:export #:gtia
           #:make-gtia
           #:gtia-write-regs
           #:gtia-read-regs
           #:gtia-read
           #:gtia-write
           #:gtia-record-collision
           #:gtia-clear-collisions
           #:reset-gtia
           #:attach-gtia
           ;; Register offsets (write side)
           #:+w-hposp0+ #:+w-hposm0+ #:+w-sizep0+ #:+w-sizem+
           #:+w-grafp0+ #:+w-grafm+
           #:+w-colpm0+ #:+w-colpf0+ #:+w-colbk+
           #:+w-prior+  #:+w-vdelay+ #:+w-gractl+
           #:+w-hitclr+ #:+w-consol+
           ;; Register offsets (read side)
           #:+r-m0pf+ #:+r-p0pf+ #:+r-m0p+ #:+r-p0p+
           #:+r-trig0+ #:+r-pal+ #:+r-consol+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.pokey — POKEY (timers + IRQ + audio + serial + keyboard)
;;;
;;; This file models POKEY's timer-based IRQ generation, the polynomial
;;; RNG used by the RANDOM register, and the IRQEN/IRQST latch protocol.
;;; Audio output and serial I/O are register-only stubs.

(defpackage #:atari800-cl.pokey
  (:use #:cl #:atari800-cl.compat #:atari800-cl.bus #:atari800-cl.cpu)
  (:documentation "Atari 800 XL POKEY — timers, IRQ, RNG, audio scaffolding.")
  (:export #:pokey
           #:make-pokey
           #:pokey-audf #:pokey-audc
           #:pokey-audctl #:pokey-skctl
           #:pokey-irqen #:pokey-irqst
           #:pokey-timer-counts #:pokey-sub-counters
           #:pokey-poly17-state #:pokey-poly9-state
           #:pokey-kbcode
           #:pokey-tick
           #:pokey-read #:pokey-write
           #:pokey-random
           #:reset-pokey
           #:attach-pokey
           #:+irq-timer1+ #:+irq-timer2+ #:+irq-timer4+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.irq — NMI / IRQ routing helpers
;;;
;;; Thin wrappers the machine scheduler calls every clock to service
;;; whichever interrupt the chips have asserted.

(defpackage #:atari800-cl.irq
  (:use #:cl #:atari800-cl.compat #:atari800-cl.cpu)
  (:documentation "Atari 800 XL interrupt routing.")
  (:export #:check-and-dispatch-nmi
           #:check-and-dispatch-irq))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.machine — Top-level NTSC scheduler
;;;
;;; Owns the CPU plus every chip (mmu, bus, pia, antic, gtia, pokey)
;;; and runs the frame-loop that pumps them in lockstep.  Distinct
;;; from atari800-cl.emulator (the legacy CPU + flat-memory scaffold);
;;; this is the real Atari 800 XL machine.

(defpackage #:atari800-cl.machine
  (:use #:cl #:atari800-cl.compat
        #:atari800-cl.cpu #:atari800-cl.bus #:atari800-cl.mmu
        #:atari800-cl.pia #:atari800-cl.antic #:atari800-cl.gtia
        #:atari800-cl.pokey #:atari800-cl.irq)
  (:documentation "Atari 800 XL top-level machine + frame scheduler.")
  (:export #:atari-machine
           #:make-atari-machine
           #:atari-machine-cpu  #:atari-machine-bus
           #:atari-machine-mmu  #:atari-machine-pia
           #:atari-machine-antic #:atari-machine-gtia
           #:atari-machine-pokey
           #:atari-machine-frame-count
           #:machine-run-frame
           #:machine-cold-reset
           #:machine-install-roms
           #:load-rom-file
           #:+clocks-per-frame+
           ;; Debug / REPL instrumentation
           #:machine-trace-step
           #:machine-portb-state
           #:machine-scanline
           #:machine-pending-interrupts))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.emulator — Top-level machine wiring
;;;
;;; Depends on compat, memory, and cpu.  Bundles them into one MACHINE
;;; struct and provides the step/run interface.

(defpackage #:atari800-cl.emulator
  (:use #:cl
        #:atari800-cl.compat
        #:atari800-cl.memory
        #:atari800-cl.cpu)
  (:documentation "Top-level Atari 800 XL machine: wiring CPU + memory + I/O.")
  (:export #:machine
           #:make-machine
           #:reset-machine
           #:step-machine
           #:run-machine
           #:machine-cpu
           #:machine-memory))

;;; ---------------------------------------------------------------------------
;;; atari800-cl — Public facade
;;;
;;; This package :USE's only #:cl — it does NOT :USE the internal packages.
;;; Instead, src/main.lisp calls internal functions with fully-qualified
;;; names (e.g. atari800-cl.emulator:make-machine).  This keeps the public
;;; API surface small and explicit: only the symbols listed in :EXPORT are
;;; part of the stable contract.
;;;
;;; (:NICKNAMES #:a800) lets users type A800:MAKE-MACHINE as a shorthand.

(defpackage #:atari800-cl
  (:use #:cl)
  (:nicknames #:a800)
  (:documentation
   "Public API for the atari800-cl headless Atari 800 XL emulator.")
  (:export #:make-machine
           #:reset-machine
           #:step-machine
           #:run-machine
           #:run-frame
           #:machine-frame-count
           #:load-os-rom
           #:load-basic-rom
           #:*version*))
