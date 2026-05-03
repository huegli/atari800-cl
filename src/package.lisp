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

(in-package #:cl-user)

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
           #:+flag-c+ #:+flag-z+ #:+flag-i+ #:+flag-d+
           #:+flag-b+ #:+flag-u+ #:+flag-v+ #:+flag-n+
           #:+nmi-vector+ #:+reset-vector+ #:+irq-vector+
           #:*opcode-table*
           #:documented-opcodes
           #:illegal-opcode))

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
