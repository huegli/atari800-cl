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
