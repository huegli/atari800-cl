;;;; src/emulator.lisp --- Top-level machine wiring.
;;;;
;;;; A MACHINE bundles a CPU and a MEMORY together so callers can drive
;;;; the emulator with a single object.  Future milestones add ANTIC /
;;;; GTIA / POKEY peripherals here.

(in-package #:atari800-cl.emulator)

(defstruct machine
  "Atari 800 XL machine state."
  (cpu    (make-cpu)    :type cpu)
  (memory (make-memory) :type memory))

(defun reset-machine (machine)
  "Reset both memory and CPU."
  (reset-memory (machine-memory machine))
  (reset-cpu (machine-cpu machine) (machine-memory machine))
  machine)

(defun step-machine (machine)
  "Step the CPU once."
  (step-cpu (machine-cpu machine) (machine-memory machine)))

(defun run-machine (machine &key (cycles 0))
  "Run the machine for CYCLES cycles (0 means a single step)."
  (run-cpu (machine-cpu machine) (machine-memory machine) :cycles cycles)
  machine)
