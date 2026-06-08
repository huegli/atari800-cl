;;;; src/main.lisp --- Public API surface re-exported from :atari800-cl.
;;;;
;;;; Code outside this project should depend only on the symbols defined
;;;; here.  The internal packages (.cpu, .machine, .bus, .compat, …) are
;;;; allowed to change shape between releases.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; This file is a "facade" — a thin wrapper that re-exports a simplified
;;;; public API.  It belongs to the :ATARI800-CL package (nickname A800),
;;;; the only package users outside this project should interact with.
;;;;
;;;; The facade drives the FULL machine: ATARI800-CL.MACHINE:ATARI-MACHINE,
;;;; which owns the CPU, system bus, MMU, PIA, ANTIC, GTIA, and POKEY.
;;;; (The older ATARI800-CL.EMULATOR package — a bare CPU+memory bundle —
;;;; is no longer used here.)
;;;;
;;;; All calls use fully-qualified names like ATARI800-CL.MACHINE:MAKE-ATARI-MACHINE.
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
  "Construct and cold-reset a fully-wired Atari 800 XL machine.

Builds an ATARI-MACHINE (CPU + bus + MMU + PIA + ANTIC + GTIA + POKEY),
then performs a cold reset.  OS-ROM and BASIC-ROM, when supplied, are
pathnames to ROM image files; their bytes are installed into the bus
before the reset reads the initial PC from the reset vector at $FFFC.
Returns the machine."
  ;; MACHINE-COLD-RESET ignores NIL :OS-PATH / :BASIC-PATH, so we can pass
  ;; the optional pathnames straight through whether or not they were given.
  (let ((machine (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset machine
                                            :os-path os-rom
                                            :basic-path basic-rom)
    machine))

(defun reset-machine (machine)
  "Cold-reset MACHINE to power-on state, preserving already-installed ROM
images.  Re-latches PORTB, reinitialises CPU registers, and reloads the
PC from the reset vector.  Returns MACHINE."
  (atari800-cl.machine:machine-cold-reset machine))

(defun step-machine (machine)
  "Execute a single CPU instruction on MACHINE.  Returns the number of
cycles consumed.

This advances only the CPU (memory and I/O reads still go through the
bus); it does NOT pump ANTIC/POKEY.  Use RUN-FRAME for full-system,
cycle-correct execution."
  (atari800-cl.cpu:step-cpu (atari800-cl.machine:atari-machine-cpu machine)))

(defun run-machine (machine &key (cycles 0))
  "Run MACHINE's CPU for CYCLES cycles (0 means a single instruction).
Like STEP-MACHINE, this advances only the CPU and does not pump
ANTIC/POKEY — use RUN-FRAME for full-system execution.  Returns MACHINE
for chaining."
  ;; RUN-CPU's lambda list is (cpu &optional memory &key cycles); the
  ;; CPU's bus is already wired, so pass NIL for MEMORY (skips re-attach)
  ;; before the :CYCLES keyword — otherwise :CYCLES is read as MEMORY.
  (atari800-cl.cpu:run-cpu (atari800-cl.machine:atari-machine-cpu machine)
                           nil :cycles cycles)
  machine)

(defun run-frame (machine &key (count 1))
  "Run COUNT full NTSC frames (29,868 color clocks each), pumping ANTIC
and POKEY in lockstep with the CPU and servicing NMI/IRQ every clock.
This is the cycle-correct way to drive the whole machine.  Returns
MACHINE for chaining."
  (dotimes (i count)
    (declare (ignore i))
    (atari800-cl.machine:machine-run-frame machine))
  machine)

(defun machine-frame-count (machine)
  "Return the number of frames MACHINE has run since construction."
  (atari800-cl.machine:atari-machine-frame-count machine))

(defun load-os-rom (machine pathname)
  "Load PATHNAME as the OS ROM image of MACHINE.
Reads the binary file and installs the bytes into the system bus.
Does not reset; call RESET-MACHINE afterwards if you need the new ROM's
reset vector.  Returns MACHINE for chaining."
  (atari800-cl.machine:machine-install-roms
   machine :os-rom (atari800-cl.machine:load-rom-file pathname))
  machine)

(defun load-basic-rom (machine pathname)
  "Load PATHNAME as the BASIC ROM image of MACHINE.
Reads the binary file and installs the bytes into the system bus.
Returns MACHINE for chaining."
  (atari800-cl.machine:machine-install-roms
   machine :basic-rom (atari800-cl.machine:load-rom-file pathname))
  machine)
