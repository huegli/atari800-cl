;;;; src/cpu.lisp --- 6502 CPU core (scaffold).
;;;;
;;;; This file currently defines the CPU state structure and stub entry
;;;; points.  The instruction decoder and per-opcode handlers will be
;;;; filled in incrementally; every opcode implemented should be exercised
;;;; from tests/test-cpu.lisp.

(in-package #:atari800-cl.cpu)

(defstruct cpu
  "6502 CPU register state.

Slots:
  PC     — 16-bit program counter
  A      — accumulator
  X, Y   — index registers
  SP     — 8-bit stack pointer (low byte of stack at $0100+SP)
  FLAGS  — processor status (NV-BDIZC packed into a u8)
  CYCLES — total cycles executed since last reset"
  (pc     0 :type u16)
  (a      0 :type u8)
  (x      0 :type u8)
  (y      0 :type u8)
  (sp     #xFD :type u8)
  (flags  #x24 :type u8)
  (cycles 0 :type (unsigned-byte 64)))

(defun reset-cpu (cpu memory)
  "Apply 6502 reset semantics to CPU using reset vector at $FFFC/$FFFD."
  (declare (type cpu cpu) (type memory memory))
  (let ((lo (mem-read memory #xFFFC))
        (hi (mem-read memory #xFFFD)))
    (setf (cpu-pc cpu)     (logior lo (ash hi 8))
          (cpu-a  cpu)     0
          (cpu-x  cpu)     0
          (cpu-y  cpu)     0
          (cpu-sp cpu)     #xFD
          (cpu-flags cpu)  #x24
          (cpu-cycles cpu) 0))
  cpu)

(defun step-cpu (cpu memory)
  "Execute a single instruction.  Stub: returns 0 cycles consumed."
  (declare (ignore memory))
  ;; TODO(0.1): implement opcode fetch / decode / execute.
  (incf (cpu-cycles cpu))
  0)

(defun run-cpu (cpu memory &key (cycles 0))
  "Run for CYCLES cycles (0 means a single step) and return the CPU."
  (if (zerop cycles)
      (step-cpu cpu memory)
      (loop while (< (cpu-cycles cpu) cycles)
            do (step-cpu cpu memory)))
  cpu)
