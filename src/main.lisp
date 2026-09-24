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
  (atari800-cl.cpu:run-cpu (atari800-cl.machine:atari-machine-cpu machine)
                           :cycles cycles)
  machine)

(defun run-frame (machine &key (count 1))
  "Run COUNT full NTSC frames (29,868 CPU cycles each), pumping ANTIC
and POKEY in lockstep with the CPU and servicing pending NMI/IRQ between
instructions.  This is the cycle-correct way to drive the whole machine.
Returns MACHINE for chaining."
  (dotimes (i count)
    (declare (ignore i))
    (atari800-cl.machine:machine-run-frame machine))
  machine)

(defun machine-frame-count (machine)
  "Return the number of frames MACHINE has run since construction."
  (atari800-cl.machine:atari-machine-frame-count machine))

;;; ---------------------------------------------------------------------------
;;; Audio

(defconstant +audio-sample-rate+ atari800-cl.audio:+audio-sample-rate+
  "Sample rate of the PCM MACHINE-AUDIO-DRAIN returns, in Hz (44,744 =
the 1.79 MHz CPU clock / 40).  Samples are mono, unsigned 8-bit.")

(defun machine-attach-audio (machine &optional (audio nil audio-supplied-p))
  "Attach POKEY audio synthesis to MACHINE and return the audio unit.
With no second argument a fresh unit is created; pass NIL to detach.
Once attached, each RUN-FRAME accumulates 746-747 samples; collect them
with MACHINE-AUDIO-DRAIN.  Machines without audio attached pay nothing
beyond a NIL test per POKEY advance."
  (if audio-supplied-p
      (atari800-cl.machine:machine-attach-audio machine audio)
      (atari800-cl.machine:machine-attach-audio machine)))

(defun machine-audio-drain (machine)
  "Return a fresh (SIMPLE-ARRAY (UNSIGNED-BYTE 8)) of the mono 8-bit PCM
samples MACHINE has accumulated since the last drain, emptying its
buffer.  Empty when no audio unit is attached (see MACHINE-ATTACH-AUDIO)."
  (atari800-cl.machine:machine-audio-drain machine))

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

;;; ---------------------------------------------------------------------------
;;; Host disk bridge (ROADMAP.md Phase 16, revised; src/hostdev.lisp,
;;; src/xex.lisp) -- mounting real ATR images and synthesizing bootable
;;; ones from raw XEX/OBX binaries.  MAKE-MACHINE always builds a machine
;;; with a HOST-BRIDGE already attached (ATARI800-CL.MACHINE:MAKE-ATARI-
;;; MACHINE does this unconditionally), so these three functions work
;;; against any MACHINE with no extra setup.  Since ROADMAP.md Phase 25c
;;; the machine's serial-wire SIO layer (src/sio.lisp) reads the same
;;; bridge's drives vector live, so one mount serves BOTH transports:
;;; the $D1xx shortcut and the emulated SIO wire the real OS boots
;;; through.

(defun mount-disk (machine unit path &key (read-only t))
  "Mount PATH (an .atr disk image file) into MACHINE's host disk bridge
at drive UNIT (1-8, i.e. D1: through D8:), replacing whatever was
mounted there.  READ-ONLY defaults to true -- WRITE commands against a
read-only image answer the SIO write-protect status; write SUPPORT
itself does not exist yet regardless of this flag (see
ATARI800-CL.HOSTDEV's package docstring).  The mounted image is visible
to both the $D1xx bridge and the serial-wire SIO layer (the real OS's
SIO boot answers from it over the wire).  Does not reset MACHINE; call
RESET-MACHINE afterward (or mount before the machine's first cold reset)
so the OS's boot sequence sees the new disk.  Returns MACHINE for
chaining."
  (atari800-cl.hostdev:mount-disk-file
   (atari800-cl.machine:atari-machine-hostdev machine) unit path
   :read-only read-only)
  machine)

(defun unmount-disk (machine unit)
  "Remove whatever disk image is mounted at MACHINE's host disk bridge
drive UNIT (1-8), if any.  Returns MACHINE for chaining."
  (atari800-cl.hostdev:unmount-disk
   (atari800-cl.machine:atari-machine-hostdev machine) unit)
  machine)

(defun load-xex (machine path &key (unit 1) (read-only t))
  "Synthesize a bootable ATR disk image in memory from the XEX/OBX binary
at PATH (ATARI800-CL.HOSTDEV:LOAD-XEX, prepending fixtures/xexboot.bin's
assembled boot-sector loader -- see its docstring) and mount it into
MACHINE's host disk bridge at drive UNIT (default 1, i.e. D1:).  No file
of the synthesized image is ever written to disk.  Does NOT reset
MACHINE -- call RESET-MACHINE afterward (or build a fresh machine and
cold-reset it) so the OS's boot sequence loads the program from the
newly mounted disk.  Returns MACHINE for chaining."
  (atari800-cl.hostdev:load-xex
   (atari800-cl.machine:atari-machine-hostdev machine) unit path
   :read-only read-only)
  machine)

;;; ---------------------------------------------------------------------------
;;; Background run loop + protocol servers
;;;
;;; The servers post state-mutating commands to the machine's command mailbox,
;;; which only drains while a run loop is active — so START-MACHINE before
;;; (or alongside) starting a server.

(defun start-machine (machine)
  "Start a background thread that drives MACHINE (its frame scheduler + command
mailbox) and return a runner handle for STOP-MACHINE.  The machine starts
paused; RESUME it via a protocol client (or by posting to its mailbox)."
  (atari800-cl.machine:start-machine machine))

(defun stop-machine (runner)
  "Stop the background run loop started by START-MACHINE.  Returns RUNNER."
  (atari800-cl.machine:stop-machine runner))

(defun start-aesp-server (machine &rest options &key &allow-other-keys)
  "Start the AESP binary-protocol server (control/video/audio TCP ports) for
MACHINE and return a server handle for STOP-AESP-SERVER.  OPTIONS are passed
through (e.g. :host, :control-port, :video-port, :audio-port; pass a port of
0 for an OS-assigned one)."
  (apply #'atari800-cl.aesp:start-aesp-server machine options))

(defun stop-aesp-server (server)
  "Stop an AESP server started by START-AESP-SERVER.  Returns SERVER."
  (atari800-cl.aesp:stop-aesp-server server))

(defun start-cli-socket (machine &rest options &key &allow-other-keys)
  "Start the CLI line-protocol server on a Unix-domain socket for MACHINE and
return a server handle for STOP-CLI-SOCKET.  OPTIONS are passed through
(e.g. :path; the default is /tmp/atari800-cl-<pid>.sock, mode 0600)."
  (apply #'atari800-cl.cli-socket:start-cli-socket machine options))

(defun stop-cli-socket (server)
  "Stop a CLI server started by START-CLI-SOCKET.  Returns SERVER."
  (atari800-cl.cli-socket:stop-cli-socket server))
