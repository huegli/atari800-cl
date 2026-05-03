;;;; tests/test-suite.lisp --- Root FiveAM suite.

(in-package #:atari800-cl/tests)

(def-suite atari800-cl-suite
  :description "Top-level test suite for atari800-cl.")

(defun run-tests ()
  "Run the full atari800-cl test suite and return the FiveAM result.

Note: we deliberately avoid the name RUN-ALL-TESTS because FiveAM
exports a symbol of that name and :USE'ing #:fiveam brings it in."
  (run! 'atari800-cl-suite))
