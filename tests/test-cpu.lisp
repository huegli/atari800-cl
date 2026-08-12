;;;; tests/test-cpu.lisp --- Tests for the 6502 CPU core (scaffold).
;;;;
;;;; --- Common Lisp / FiveAM notes for beginners ---
;;;;
;;;; Functions prefixed with % (like %KLAUS-FUNCTIONAL-TEST-SEARCH-PATHS)
;;;; are a CL convention for internal/private helpers — they're not
;;;; exported and shouldn't be called from outside this file.
;;;;
;;;; DEFPARAMETER defines a global variable (re-evaluated on each load).
;;;; UIOP:GETENV reads an environment variable (returns NIL if absent).
;;;; IGNORE-ERRORS wraps a form so that if it signals an error, it returns
;;;; NIL instead of interrupting execution — useful for "try this, if it
;;;; fails, that's fine" patterns.
;;;;
;;;; DOTIMES (VAR COUNT RESULT) iterates VAR from 0 to COUNT-1, then
;;;; evaluates RESULT as the return value.  RETURN-FROM exits a named
;;;; function early with a specific value.
;;;;
;;;; SKIP is a FiveAM macro that marks a test as skipped (neither pass
;;;; nor fail) with a message.  This is used here when the Klaus test
;;;; binary is not available.

(in-package #:atari800-cl/tests)

(def-suite cpu-suite
  :description "Tests for atari800-cl.cpu."
  :in atari800-cl-suite)

(in-suite cpu-suite)

(test reset-loads-pc-from-vector
  "On reset, PC should be loaded from the $FFFC/$FFFD vector."
  (let ((cpu (make-cpu))
        (mem (make-memory)))
    ;; Write the reset vector: low byte at $FFFC, high byte at $FFFD.
    ;; Little-endian: $C000 is stored as $00 (low), $C0 (high).
    (mem-write mem #xFFFC #x00)
    (mem-write mem #xFFFD #xC0)
    (reset-cpu cpu mem)
    (is (= #xC000 (cpu-pc cpu)))       ; PC loaded from reset vector
    (is (= #xFD   (cpu-sp cpu)))       ; SP initialised to $FD
    (is (zerop (cpu-cycles cpu)))))     ; cycle counter zeroed

(test step-advances-cycle-counter
  "STEP-CPU should make forward progress on the cycle counter."
  (let ((cpu (make-cpu))
        (mem (make-memory)))
    (reset-cpu cpu mem)                ; also wires the bus hooks
    ;; Memory is all zeros, so the first opcode is $00 (BRK), which
    ;; consumes 7 cycles.  We just check that cycles increased.
    (let ((before (cpu-cycles cpu)))
      (step-cpu cpu)
      (is (> (cpu-cycles cpu) before)))))

;;; ---------------------------------------------------------------------------
;;; Klaus Dormann's 6502 functional test
;;;
;;; This is a comprehensive test suite written in 6502 assembly that
;;; exercises nearly every opcode, addressing mode, and flag combination.
;;; It runs as a flat 64K binary that the 6502 executes; when every check
;;; passes, the PC converges to a "success trap" — a 2-byte loop that
;;; branches to itself.  If any check fails, the PC traps at a different
;;; (failure) address.
;;;
;;; Build the binary from
;;;   https://github.com/Klaus2m5/6502_65C02_functional_tests
;;; with `org=0000` and `load_data_direct=1`; the result is a flat 64K
;;; image named `6502_functional_test.bin`.  Drop it into roms/ next to
;;; the OS/BASIC images, or point ATARI800_CL_FUNCTIONAL_TEST at it.
;;;
;;; If the binary is absent (CI's common case), this test SKIPs with a
;;; message that names the path it tried -- unless $ATARI800_CL_STRICT is
;;; set, in which case the skip becomes a FAILURE (ROADMAP.md Phase 21;
;;; see %SKIP-OR-FAIL in test-helpers.lisp).

(defparameter *klaus-functional-test-filename* "6502_functional_test.bin")

(defparameter *klaus-functional-test-success-pc* #x3469
  "Trap address Klaus Dormann's test reaches once every check passes.")

(defun %klaus-functional-test-search-paths ()
  "Return candidate pathnames for the Klaus functional test binary.
Checks, in order:
  1. The $ATARI800_CL_FUNCTIONAL_TEST environment variable
  2. The roms/ directory relative to the ASDF system source
  3. The roms/ directory relative to the current working directory"
  (let ((env (uiop:getenv "ATARI800_CL_FUNCTIONAL_TEST"))
        ;; IGNORE-ERRORS returns NIL if the enclosed form signals an error.
        ;; This handles the case where ASDF can't find the system.
        (system-dir (ignore-errors
                     (asdf:system-source-directory "atari800-cl"))))
    ;; REMOVE NIL strips any NIL entries from the candidate list.
    (remove nil
            (list (and env (pathname env))
                  (and system-dir
                       ;; MERGE-PATHNAMES combines a relative path with a base.
                       ;; MAKE-PATHNAME builds a portable pathname object from
                       ;; directory/name/type components.
                       (merge-pathnames
                        (make-pathname
                         :directory '(:relative "roms")
                         :name "6502_functional_test"
                         :type "bin")
                        system-dir))
                  (merge-pathnames
                   (make-pathname
                    :directory '(:relative "roms")
                    :name "6502_functional_test"
                    :type "bin")
                   (uiop:getcwd))))))

(defun %klaus-functional-test-binary-path ()
  "Return the first existing candidate path, or NIL."
  ;; FIND-IF returns the first element for which the predicate is true.
  ;; #'PROBE-FILE is the predicate: it returns truthy if the file exists.
  (find-if #'probe-file (%klaus-functional-test-search-paths)))

(defun %load-klaus-binary-into-memory (memory bytes)
  "Blit BYTES into MEMORY starting at $0000.
Loads up to 64K bytes (the full 6502 address space)."
  (loop for i from 0 below (min (length bytes) #x10000)
        do (mem-write memory i (aref bytes i)))
  memory)

(defun %run-klaus-test (&key (max-instructions 200000000))
  "Run the Klaus test until PC stops advancing (trap) or budget is gone.
Returns the final PC.

When the test reaches a 2-byte branch-to-self loop, PC stays the same
between consecutive instructions.  We detect this as a 'trap' and return
that PC value.  If it's the success address ($3469), all checks passed."
  (let* ((path (%klaus-functional-test-binary-path))
         (bytes (atari800-cl.compat:read-binary-file path))
         (mem (make-memory))
         (cpu (make-cpu)))
    (%load-klaus-binary-into-memory mem bytes)
    ;; Wire the bus and set up initial CPU state manually (not using
    ;; RESET-CPU because the Klaus test starts at $0400, not the reset vector).
    (atari800-cl.cpu:attach-memory-bus cpu mem)
    (setf (cpu-pc cpu) #x0400          ; Klaus test entry point
          (cpu-sp cpu) #xFD
          (cpu-flags cpu) #x24
          (cpu-cycles cpu) 0)
    ;; DOTIMES iterates I from 0 to MAX-INSTRUCTIONS-1.
    ;; The third argument (CPU-PC CPU) is the return value if we exhaust
    ;; the budget without trapping.
    (let ((previous-pc -1))
      (dotimes (i max-instructions (cpu-pc cpu))
        (let ((pc (cpu-pc cpu)))
          ;; If PC didn't change, we've hit a trap (branch-to-self loop).
          (when (= pc previous-pc)
            ;; RETURN-FROM exits the named function immediately.
            (return-from %run-klaus-test pc))
          (setf previous-pc pc))
        (step-cpu cpu)))))

(test klaus-dormann-functional-test
  "Run Klaus Dormann's 6502 functional test to its success trap."
  (let ((path (%klaus-functional-test-binary-path)))
    (cond
      ;; If the binary isn't available, skip gracefully rather than failing
      ;; -- unless $ATARI800_CL_STRICT is set, in which case this becomes a
      ;; failure (ROADMAP.md Phase 21: this machine is supposed to have it).
      ((null path)
       (%skip-or-fail "Klaus Dormann functional-test binary ~A not found in roms/ ~
              (or via $ATARI800_CL_FUNCTIONAL_TEST). ~
              Build from https://github.com/Klaus2m5/6502_65C02_functional_tests ~
              with org=0000 and load_data_direct=1 to produce a 64KiB image, ~
              then drop it at roms/~A and re-run."
             *klaus-functional-test-filename*
             *klaus-functional-test-filename*))
      (t
       (let ((final-pc (%run-klaus-test)))
         ;; The IS form with a format string provides a descriptive failure message.
         ;; ~4,'0X formats as 4-digit zero-padded hex.
         (is (= *klaus-functional-test-success-pc* final-pc)
             "Klaus functional test should trap at $~4,'0X (success); ~
              instead trapped at $~4,'0X."
             *klaus-functional-test-success-pc*
             final-pc))))))
