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
;;;;
;;;; RUN-TESTS additionally prints a "skip census" after FiveAM's own
;;;; report: one SKIPPED: <test> (<reason>) line per skipped check
;;;; (ROADMAP.md Phase 21).  FiveAM's default report already lists skips
;;;; under "Skip Details:", but that section is easy to miss in a long
;;;; scroll of test-dribble output and is not consistently one line per
;;;; skip -- the census makes every skip grep-able (`grep SKIPPED`) and
;;;; impossible to overlook, which is the point: this project once had
;;;; twelve green suite runs in a row while the real-ROM boot test was
;;;; either absent or silently skipping.

(in-package #:atari800-cl/tests)

;; Define the root test suite.  All other suites are children of this one.
(def-suite atari800-cl-suite
  :description "Top-level test suite for atari800-cl.")

(defun %print-skip-census (results)
  "Print one SKIPPED: <test-name> (<reason>) line per TEST-SKIPPED result
in RESULTS (a FIVEAM:RUN result list), or a single \"(none)\" line when
nothing skipped.  NAME/REASON/TEST-CASE are FiveAM internals -- not
exported, so referenced package-qualified -- but stable across the
20241012 release this project pins."
  (let ((skipped (remove-if-not (lambda (r) (typep r 'fiveam::test-skipped))
                                 results)))
    (format t "~&~%Skip census:~%")
    (if (null skipped)
        (format t "  SKIPPED: (none)~%")
        (dolist (r skipped)
          (format t "  SKIPPED: ~A (~A)~%"
                  (fiveam::name (fiveam::test-case r))
                  (fiveam::reason r))))))

(defun run-tests ()
  "Run the full atari800-cl test suite, print FiveAM's usual report plus
the skip census (see above), and return T iff every check passed (a skip
is not a failure -- matching FIVEAM:RUN!'s own notion of success).

Note: we deliberately avoid the name RUN-ALL-TESTS because FiveAM
exports a symbol of that name and :USE'ing #:fiveam brings it in."
  ;; 'ATARI800-CL-SUITE is a quoted symbol naming the suite to run.
  ;; FIVEAM:EXPLAIN! prints FiveAM's usual summary, e.g.:
  ;;   Did 351 checks.  Pass: 351 (100%)  Skip: 0  Fail: 0
  ;; and returns T iff nothing failed -- the same status RUN! returns.
  (let* ((results (fiveam:run 'atari800-cl-suite))
         (status (fiveam:explain! results)))
    (%print-skip-census results)
    status))
