;;;; src/emulator.lisp --- Top-level machine wiring.
;;;;
;;;; A MACHINE bundles a CPU and a MEMORY together so callers can drive
;;;; the emulator with a single object.  Future milestones add ANTIC /
;;;; GTIA / POKEY peripherals here.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; This file is intentionally small.  It shows how DEFSTRUCT can
;;;; compose larger objects from smaller ones: a MACHINE contains a CPU
;;;; and a MEMORY as slots, each with their own DEFSTRUCT definition in
;;;; other files.
;;;;
;;;; The slot initialisers (MAKE-CPU) and (MAKE-MEMORY) are called when
;;;; MAKE-MACHINE creates a new instance.  Each call returns a fresh,
;;;; independent object, so every MACHINE gets its own CPU and MEMORY.

(in-package #:atari800-cl.emulator)

;;; ---------------------------------------------------------------------------
;;; Machine struct
;;;
;;; DEFSTRUCT automatically generates:
;;;   MAKE-MACHINE    — constructor
;;;   MACHINE-CPU     — accessor for the CPU slot
;;;   MACHINE-MEMORY  — accessor for the MEMORY slot
;;;   MACHINE-P       — type predicate (returns T if the argument is a MACHINE)

(defstruct machine
  "Atari 800 XL machine state.
Bundles a 6502 CPU and a 64K memory into one object.  Future milestones
will add ANTIC, GTIA, POKEY, and PIA peripheral slots here."
  (cpu    (make-cpu)    :type cpu)
  (memory (make-memory) :type memory))

;;; ---------------------------------------------------------------------------
;;; Machine operations
;;;
;;; Each function extracts the relevant sub-object from the MACHINE struct
;;; and delegates to the lower-level API.  Returning MACHINE from functions
;;; that mutate state allows method chaining:
;;;   (run-machine (reset-machine (make-machine)))

(defun reset-machine (machine)
  "Reset both memory and CPU.  Returns MACHINE for chaining."
  (reset-memory (machine-memory machine))
  ;; RESET-CPU takes an optional MEMORY argument to wire the bus hooks.
  (reset-cpu (machine-cpu machine) (machine-memory machine))
  machine)

(defun step-machine (machine)
  "Execute one CPU instruction.  Returns the number of cycles consumed."
  (step-cpu (machine-cpu machine) (machine-memory machine)))

(defun run-machine (machine &key (cycles 0))
  "Run the machine for CYCLES cycles (0 means a single step).
Returns MACHINE for chaining."
  (run-cpu (machine-cpu machine) (machine-memory machine) :cycles cycles)
  machine)
