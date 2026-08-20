;;;; tests/test-helpers.lisp --- Shared test fixtures and macros.
;;;;
;;;; Lives in the ATARI800-CL/TESTS package so every test file can use the
;;;; helpers without qualifying them.  Defines:
;;;;
;;;;   MAKE-TEST-MACHINE        — build a fully-wired ATARI-MACHINE with
;;;;                              synthetic 16K OS ROM + 8K BASIC ROM
;;;;                              filled with $EA NOPs, vectors hand-poked.
;;;;   WITH-CPU-STATE           — install a specific CPU register snapshot
;;;;                              for a targeted test, restore after.
;;;;   %MAKE-SYNTHETIC-OS-ROM   — bare ROM-array builder (used by machine
;;;;                              and regression tests).
;;;;   %MAKE-SYNTHETIC-BASIC-ROM — bare 8K-of-NOPs.
;;;;   %POKE                    — NOTINLINE AREF setter that dodges the
;;;;                              SBCL/arm64 codegen bug on >=4 KiB offsets.
;;;;   %SKIP-OR-FAIL             — SKIP unless $ATARI800_CL_STRICT is set,
;;;;                              in which case FAIL (ROADMAP.md Phase 21).
;;;;   BUS-RECORDER              — struct holding a bus access log; see
;;;;                              INSTALL-BUS-RECORDER below.
;;;;   INSTALL-BUS-RECORDER      — wrap a CPU's bus hooks to log every
;;;;                              access in order (ROADMAP.md Phase 17 /
;;;;                              SCANLINE_ACCURACY_PLAN.md Phase 5).

(in-package #:atari800-cl/tests)

;;; ---------------------------------------------------------------------------
;;; The NOTINLINE %POKE helper.  Used by every test that writes a constant
;;; large index into a typed array — the SBCL arm64 backend has a bug
;;; ("Invalid STR/LDR arguments... :OFFSET 16384") triggered by AREF with
;;; constant indices >= 4096 into a typed slot-accessed array.

(declaim (notinline %poke))

(defun %poke (rom i v)
  "Write V to ROM[I].  Guaranteed NOTINLINE to keep the compiler from
folding I into a constant STR immediate."
  (setf (aref rom i) v))

;;; ---------------------------------------------------------------------------
;;; Synthetic ROM fixtures

(defun %make-synthetic-os-rom (&key (reset-pc #xC000)
                                    (nmi-pc   #xFE00)
                                    (irq-pc   #xFE00))
  "Construct a 16 KiB synthetic OS ROM image:
    - Every byte starts as #xEA (NOP).
    - $FFFC/$FFFD (reset vector) → RESET-PC (default $C000).
    - $FFFA/$FFFB (NMI vector)   → NMI-PC   (default $FE00, a NOP).
    - $FFFE/$FFFF (IRQ vector)   → IRQ-PC   (default $FE00, a NOP).
  Returns a (simple-array (unsigned-byte 8) (16384))."
  (let ((rom (make-array #x4000 :element-type '(unsigned-byte 8)
                                :initial-element #xEA)))
    (%poke rom #x3FFC (logand reset-pc #xFF))
    (%poke rom #x3FFD (logand (ash reset-pc -8) #xFF))
    (%poke rom #x3FFA (logand nmi-pc #xFF))
    (%poke rom #x3FFB (logand (ash nmi-pc -8) #xFF))
    (%poke rom #x3FFE (logand irq-pc #xFF))
    (%poke rom #x3FFF (logand (ash irq-pc -8) #xFF))
    rom))

(defun %make-synthetic-basic-rom ()
  "8 KiB of NOP filler so the bus reads return predictable bytes when
PORTB is configured to expose BASIC."
  (make-array #x2000 :element-type '(unsigned-byte 8) :initial-element #xEA))

;;; ---------------------------------------------------------------------------
;;; BUS-RECORDER / INSTALL-BUS-RECORDER — cycle-by-cycle bus trace capture
;;; (ROADMAP.md Phase 17, SCANLINE_ACCURACY_PLAN.md Phase 5)
;;;
;;; The Tom Harte / SingleStepTests vectors (tests/test-harte.lisp) carry a
;;; full cycle-by-cycle bus trace per case, and SCANLINE_ACCURACY_PLAN.md's
;;; Phase 5 (NMOS bus quirks: RMW double-write, indexed dummy reads) both
;;; need a way to see every access a CPU makes, in order, while it runs.
;;; This stub is written once here and shared by both.
;;;
;;; INSTALL-BUS-RECORDER wraps whatever CPU-BUS-READ / CPU-BUS-WRITE
;;; closures are already installed on a CPU (e.g. by ATTACH-MEMORY-BUS or
;;; a full machine's wiring) rather than replacing them outright: the
;;; recorder's closures log the access, then delegate to the previously
;;; installed ones, so the CPU keeps working exactly as before and gains
;;; only an observation side effect. Call it AFTER wiring the CPU's real
;;; bus, not before.

(defstruct bus-recorder
  "Records every bus access observed through a CPU wrapped by
INSTALL-BUS-RECORDER, in access order. LOG is an adjustable vector of
3-element lists (ADDRESS VALUE KIND), KIND being :READ or :WRITE. Use
BUS-RECORDER-LOG to read the entries back and BUS-RECORDER-RESET to empty
the log for reuse across more than one instruction."
  (log (make-array 0 :adjustable t :fill-pointer 0) :type vector))

(defun bus-recorder-reset (recorder)
  "Empty RECORDER's log in place (fill-pointer back to 0) so the same
recorder can be reused around another instruction without reinstalling it.
Returns RECORDER."
  (setf (fill-pointer (bus-recorder-log recorder)) 0)
  recorder)

(defun install-bus-recorder (cpu)
  "Wrap CPU's current CPU-BUS-READ / CPU-BUS-WRITE closures with logging
and return a fresh BUS-RECORDER.

Every subsequent read appends (ADDRESS VALUE :READ) to the recorder's log
and every write appends (ADDRESS VALUE :WRITE), in the exact order the CPU
performs them -- the first entry of an instruction's log is always its
opcode fetch. After logging, each wrapped closure delegates to the bus
hooks that were installed on CPU at the time of this call, so an existing
ATTACH-MEMORY-BUS (or full machine) wiring keeps working unchanged.

Typical use, around one STEP-CPU call:

  (let ((recorder (install-bus-recorder cpu)))
    (step-cpu cpu)
    (bus-recorder-log recorder))       ; => the access log

To record more than one instruction into the same log, just keep calling
STEP-CPU before reading BUS-RECORDER-LOG; to start a fresh instruction's
log without re-wrapping the closures, call BUS-RECORDER-RESET instead of
INSTALL-BUS-RECORDER again."
  (let* ((recorder (make-bus-recorder))
         (inner-read (cpu-bus-read cpu))
         (inner-write (cpu-bus-write cpu)))
    (unless (and inner-read inner-write)
      (error "INSTALL-BUS-RECORDER requires CPU's bus hooks to already be ~
              wired (call ATTACH-MEMORY-BUS or otherwise attach a bus first)."))
    (setf (cpu-bus-read cpu)
          (lambda (addr)
            (let ((value (funcall (the function inner-read) addr)))
              (vector-push-extend (list addr value :read)
                                   (bus-recorder-log recorder))
              value))
          (cpu-bus-write cpu)
          (lambda (addr value)
            (vector-push-extend (list addr value :write)
                                 (bus-recorder-log recorder))
            (funcall (the function inner-write) addr value)))
    recorder))

;;; ---------------------------------------------------------------------------
;;; %SKIP-OR-FAIL — the strict test gate (ROADMAP.md Phase 21)
;;;
;;; Several tests depend on an asset this project does not vendor (a ROM
;;; image, a downloaded vector corpus) and SKIP gracefully when it is
;;; absent, exactly like a missing optional dependency.  That is correct
;;; for a checkout or sandbox that has never had the asset — but on a
;;; machine that is SUPPOSED to have it (CLAUDE.md/ROADMAP.md rule 8 lists
;;; the ROM images as already present here), a silent skip can hide a real
;;; regression: the suite went green for ten phases in this project's own
;;; history while the emulator could not boot the real OS at all, because
;;; the one test that would have caught it was in a skip-tolerant posture.
;;;
;;; %SKIP-OR-FAIL is a drop-in replacement for a bare SKIP call: it skips
;;; exactly as before unless $ATARI800_CL_STRICT is set to a non-empty
;;; value, in which case the same reason becomes a FAILURE instead.  Every
;;; env-gated test that depends on an asset rule 8 promises is present
;;; (Klaus, Harte, the real-ROM boot tests, and future ones — Phase 13's
;;; typing test, Phase 16's ATR boot test, Phase 24's Acid800 tests) should
;;; use this instead of SKIP directly.  Tests that skip because the
;;; EXECUTION ENVIRONMENT forbids something (TCP/Unix listener bind denied
;;; in a sandbox) are a different category — that is not an asset this
;;; machine promises, so those keep using bare SKIP.

(defvar *strict-mode-override* :unset
  "Test-only override for %STRICT-MODE-P.  When not :UNSET, its value (T
or NIL) is used verbatim instead of reading $ATARI800_CL_STRICT, so the
self-test below can exercise both branches without touching the process
environment (which is not portable to set at runtime on both SBCL and
LispWorks, and would race any other test reading the same variable).")

(defun %strict-mode-p ()
  "True when strict mode is active: *STRICT-MODE-OVERRIDE* if bound to
other than :UNSET, else whether $ATARI800_CL_STRICT is set to a non-empty
value.  See %SKIP-OR-FAIL."
  (if (eq *strict-mode-override* :unset)
      (let ((value (uiop:getenv "ATARI800_CL_STRICT")))
        (and value (plusp (length value)) t))
      *strict-mode-override*))

(defmacro %skip-or-fail (reason-control &rest reason-args)
  "Record a TEST-SKIPPED result with the given reason (as SKIP would),
unless strict mode (%STRICT-MODE-P) is active, in which case record a
FAILURE with the same reason instead.  REASON-CONTROL/REASON-ARGS are a
FORMAT control string and its arguments, exactly as passed to SKIP."
  `(if (%strict-mode-p)
       (is-true nil ,reason-control ,@reason-args)
       (skip ,reason-control ,@reason-args)))

;;; Two standalone probes used only by the self-test in
;;; tests/test-compat.lisp (SKIP-OR-FAIL-RESPECTS-STRICT-MODE).  :SUITE NIL
;;; keeps them out of every suite's tree -- they must never run as part of
;;; an ordinary suite pass (their whole purpose is to fail or skip on
;;; command), only when invoked by name via FIVEAM:RUN under a bound
;;; *STRICT-MODE-OVERRIDE*.

(test (%probe-skip-or-fail-lenient :suite nil)
  (%skip-or-fail "probe: lenient mode should skip, not fail"))

(test (%probe-skip-or-fail-strict :suite nil)
  (%skip-or-fail "probe: strict mode should fail, not skip"))

;;; ---------------------------------------------------------------------------
;;; Environment probes for live socket integration tests

(defvar *tcp-listener-available-p* :unknown)
(defvar *unix-listener-available-p* :unknown)

(defun tcp-listener-available-p ()
  "Return true when this process can bind a loopback TCP listener.
Some command sandboxes deny listener creation even though the implementation
and project code support it.  The live AESP server tests use this to skip
only when the execution environment blocks the required socket primitive."
  (when (eq *tcp-listener-available-p* :unknown)
    (setf *tcp-listener-available-p*
          (handler-case
              (let ((listener (usocket:socket-listen "127.0.0.1" 0
                                                      :reuse-address t)))
                (unwind-protect t
                  (ignore-errors (usocket:socket-close listener))))
            (error () nil))))
  *tcp-listener-available-p*)

(defun unix-listener-available-p ()
  "Return true when this process can bind a Unix-domain listener."
  (when (eq *unix-listener-available-p* :unknown)
    (setf *unix-listener-available-p*
          (let ((path (format nil "/tmp/atari800-cl-probe-~D.sock"
                              (current-process-id))))
            (handler-case
                (let ((listener (open-unix-listener path)))
                  (unwind-protect t
                    (ignore-errors (close-unix-listener listener))))
              (error ()
                (ignore-errors (delete-file-if-exists path))
                nil)))))
  *unix-listener-available-p*)

;;; ---------------------------------------------------------------------------
;;; MAKE-TEST-MACHINE

(defun make-test-machine (&key (reset-pc #xC000) os-rom basic-rom)
  "Return a freshly-built ATARI-MACHINE already cold-reset with synthetic
ROMs in place.  Caller can pass their own OS-ROM / BASIC-ROM byte arrays
to override the defaults; otherwise the helper builds the standard NOP
fixtures."
  (let* ((m (atari800-cl.machine:make-atari-machine))
         (os (or os-rom (%make-synthetic-os-rom :reset-pc reset-pc)))
         (basic (or basic-rom (%make-synthetic-basic-rom))))
    (atari800-cl.machine:machine-cold-reset m :os-rom os :basic-rom basic)
    m))

;;; ---------------------------------------------------------------------------
;;; WITH-CPU-STATE
;;;
;;; Save the CPU's six general-purpose register slots (PC, SP, A, X, Y, P)
;;; on entry, force any keyword-supplied overrides, execute BODY, then
;;; restore the prior values.  Useful for surgical tests that need to
;;; pin specific flag bits without leaking state into the surrounding
;;; suite.

(defmacro with-cpu-state ((cpu &key pc sp a x y p) &body body)
  "Bind CPU's PC/SP/A/X/Y/P to the supplied values during BODY (each
keyword optional; nil keeps the current value).  Restores the original
register snapshot when BODY returns, even via non-local exit."
  (let ((saved-pc (gensym "PC"))  (saved-sp (gensym "SP"))
        (saved-a  (gensym "A"))   (saved-x  (gensym "X"))
        (saved-y  (gensym "Y"))   (saved-p  (gensym "P"))
        (cpu-var (gensym "CPU")))
    `(let* ((,cpu-var ,cpu)
            (,saved-pc (cpu-pc ,cpu-var))
            (,saved-sp (cpu-sp ,cpu-var))
            (,saved-a  (cpu-a  ,cpu-var))
            (,saved-x  (cpu-x  ,cpu-var))
            (,saved-y  (cpu-y  ,cpu-var))
            (,saved-p  (cpu-flags ,cpu-var)))
       (unwind-protect
            (progn
              ,@(when pc `((setf (cpu-pc    ,cpu-var) ,pc)))
              ,@(when sp `((setf (cpu-sp    ,cpu-var) ,sp)))
              ,@(when a  `((setf (cpu-a     ,cpu-var) ,a)))
              ,@(when x  `((setf (cpu-x     ,cpu-var) ,x)))
              ,@(when y  `((setf (cpu-y     ,cpu-var) ,y)))
              ,@(when p  `((setf (cpu-flags ,cpu-var) ,p)))
              ,@body)
         (setf (cpu-pc    ,cpu-var) ,saved-pc
               (cpu-sp    ,cpu-var) ,saved-sp
               (cpu-a     ,cpu-var) ,saved-a
               (cpu-x     ,cpu-var) ,saved-x
               (cpu-y     ,cpu-var) ,saved-y
               (cpu-flags ,cpu-var) ,saved-p)))))
