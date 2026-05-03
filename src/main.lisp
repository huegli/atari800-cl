;;;; src/main.lisp --- Public API surface re-exported from :atari800-cl.
;;;;
;;;; Code outside this project should depend only on the symbols defined
;;;; here.  The internal packages (.cpu, .memory, .emulator, .compat) are
;;;; allowed to change shape between releases.

(in-package #:atari800-cl)

(defparameter *version* "0.0.1"
  "Semantic version of atari800-cl.")

(defun make-machine (&key os-rom basic-rom)
  "Construct a fresh Atari 800 XL machine.

OS-ROM and BASIC-ROM, when supplied, are pathnames to ROM image files
that get loaded into the machine's memory map."
  (let ((machine (atari800-cl.emulator:make-machine)))
    (when os-rom    (load-os-rom machine os-rom))
    (when basic-rom (load-basic-rom machine basic-rom))
    (atari800-cl.emulator:reset-machine machine)
    machine))

(defun reset-machine (machine)
  "Reset MACHINE to power-on state."
  (atari800-cl.emulator:reset-machine machine))

(defun step-machine (machine)
  "Execute a single CPU instruction on MACHINE."
  (atari800-cl.emulator:step-machine machine))

(defun run-machine (machine &key (cycles 0))
  "Run MACHINE for CYCLES cycles (0 means a single step)."
  (atari800-cl.emulator:run-machine machine :cycles cycles))

(defun load-os-rom (machine pathname)
  "Load PATHNAME as the OS ROM image of MACHINE."
  (atari800-cl.memory:install-os-rom
   (atari800-cl.emulator:machine-memory machine)
   (atari800-cl.memory:load-rom pathname))
  machine)

(defun load-basic-rom (machine pathname)
  "Load PATHNAME as the BASIC ROM image of MACHINE."
  (atari800-cl.memory:install-basic-rom
   (atari800-cl.emulator:machine-memory machine)
   (atari800-cl.memory:load-rom pathname))
  machine)
