;;;; src/main.lisp --- Public API surface re-exported from :atari800-cl.
;;;;
;;;; Code outside this project should depend only on the symbols defined
;;;; here.  The internal packages (.cpu, .memory, .emulator, .compat) are
;;;; allowed to change shape between releases.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; This file is a "facade" — a thin wrapper that re-exports a simplified
;;;; public API.  It belongs to the :ATARI800-CL package, which is the
;;;; only package users outside this project should interact with.
;;;;
;;;; All calls use fully-qualified names like ATARI800-CL.EMULATOR:MAKE-MACHINE.
;;;; The PACKAGE:SYMBOL syntax accesses an exported symbol from another
;;;; package without importing it.  This keeps the public package's namespace
;;;; clean and makes the cross-package dependencies explicit at each call site.
;;;;
;;;; &KEY declares keyword arguments.  Callers write:
;;;;   (make-machine :os-rom #P"roms/atariosxl.rom")
;;;; The #P"..." syntax creates a pathname object from a string.

(in-package #:atari800-cl)

(defparameter *version* "0.0.1"
  "Semantic version of atari800-cl.")

(defun make-machine (&key os-rom basic-rom)
  "Construct a fresh Atari 800 XL machine.

OS-ROM and BASIC-ROM, when supplied, are pathnames to ROM image files
that get loaded into the machine's memory map.  The machine is
automatically reset (CPU initialised, PC loaded from reset vector)
before being returned."
  ;; LET binds a local variable.  WHEN executes its body only if the
  ;; test is non-NIL (our way of saying "if this optional argument was provided").
  (let ((machine (atari800-cl.emulator:make-machine)))
    (when os-rom    (load-os-rom machine os-rom))
    (when basic-rom (load-basic-rom machine basic-rom))
    (atari800-cl.emulator:reset-machine machine)
    machine))

(defun reset-machine (machine)
  "Reset MACHINE to power-on state.  Returns MACHINE."
  (atari800-cl.emulator:reset-machine machine))

(defun step-machine (machine)
  "Execute a single CPU instruction on MACHINE.
Returns the number of cycles consumed."
  (atari800-cl.emulator:step-machine machine))

(defun run-machine (machine &key (cycles 0))
  "Run MACHINE for CYCLES cycles (0 means a single step).
Returns MACHINE for chaining."
  (atari800-cl.emulator:run-machine machine :cycles cycles))

(defun load-os-rom (machine pathname)
  "Load PATHNAME as the OS ROM image of MACHINE.
Reads the binary file and installs the bytes into the memory struct.
Returns MACHINE for chaining."
  ;; We access the memory through the machine, then call the memory-layer
  ;; functions with the fully-qualified ATARI800-CL.MEMORY: prefix.
  (atari800-cl.memory:install-os-rom
   (atari800-cl.emulator:machine-memory machine)
   (atari800-cl.memory:load-rom pathname))
  machine)

(defun load-basic-rom (machine pathname)
  "Load PATHNAME as the BASIC ROM image of MACHINE.
Reads the binary file and installs the bytes into the memory struct.
Returns MACHINE for chaining."
  (atari800-cl.memory:install-basic-rom
   (atari800-cl.emulator:machine-memory machine)
   (atari800-cl.memory:load-rom pathname))
  machine)
