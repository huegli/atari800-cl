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
