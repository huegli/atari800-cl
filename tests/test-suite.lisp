;;;; tests/test-suite.lisp --- Root FiveAM suite.
;;;;
;;;; --- Common Lisp / FiveAM notes for beginners ---
;;;;
;;;; FiveAM organises tests into suites (groups).  DEF-SUITE creates a
;;;; named suite; child suites use :IN to declare their parent.  This
;;;; creates a tree:
;;;;
;;;;   atari800-cl-suite          (root — defined here)
;;;;     compat-suite             (tests/test-compat.lisp)
;;;;     memory-suite             (tests/test-memory.lisp)
;;;;     cpu-suite                (tests/test-cpu.lisp)
;;;;     cpu-opcodes-suite        (tests/test-cpu-opcodes.lisp)
;;;;
;;;; RUN! runs all tests in a suite (and its children) and prints a report.
;;;; The trailing ! is a CL naming convention meaning "this function has
;;;; side effects" (here: printing to *standard-output*).

(in-package #:atari800-cl/tests)

;; Define the root test suite.  All other suites are children of this one.
(def-suite atari800-cl-suite
  :description "Top-level test suite for atari800-cl.")

(defun run-tests ()
  "Run the full atari800-cl test suite and return the FiveAM result.

Note: we deliberately avoid the name RUN-ALL-TESTS because FiveAM
exports a symbol of that name and :USE'ing #:fiveam brings it in."
  ;; 'ATARI800-CL-SUITE is a quoted symbol naming the suite to run.
  ;; RUN! runs it and prints a summary like:
  ;;   Did 351 checks.  Pass: 351 (100%)  Skip: 0  Fail: 0
  (run! 'atari800-cl-suite))
