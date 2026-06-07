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
           #:documented-opcodes
           #:illegal-opcodes
           #:*illegal-opcode-list*
           #:illegal-opcode))

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
           #:load-os-rom
           #:load-basic-rom
           #:*version*))
