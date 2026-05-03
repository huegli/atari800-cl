;;;; tests/package.lisp --- Test package definition.
;;;;
;;;; We deliberately :IMPORT-FROM #:fiveam (rather than :USE'ing it) so
;;;; that FiveAM's exports — which include short, common names like TEST,
;;;; PASS, FAIL, RUN, IS, SKIP — don't pollute the test package and
;;;; can't collide with symbols exported from the emulator's internal
;;;; packages.  This also avoids an SBCL package-lock error where
;;;; defining a function whose home would be FIVEAM (e.g. RUN-ALL-TESTS)
;;;; signals SYMBOL-PACKAGE-LOCKED-ERROR; LispWorks doesn't lock the
;;;; FiveAM package the same way, but the cleaner import keeps the two
;;;; implementations behaving identically.

(in-package #:cl-user)

(defpackage #:atari800-cl/tests
  (:use #:cl
        #:atari800-cl.compat
        #:atari800-cl.memory
        #:atari800-cl.cpu
        #:atari800-cl.emulator)
  (:import-from #:fiveam
                #:def-suite
                #:in-suite
                #:test
                #:is
                #:is-true
                #:is-false
                #:signals
                #:finishes
                #:pass
                #:fail
                #:skip
                #:run!)
  (:documentation "FiveAM test suite for atari800-cl.")
  (:export #:atari800-cl-suite
           #:run-tests))
