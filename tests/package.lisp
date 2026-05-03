;;;; tests/package.lisp --- Test package definition.

(in-package #:cl-user)

(defpackage #:atari800-cl/tests
  (:use #:cl
        #:fiveam
        #:atari800-cl.compat
        #:atari800-cl.memory
        #:atari800-cl.cpu
        #:atari800-cl.emulator)
  (:documentation "FiveAM test suite for atari800-cl.")
  (:export #:atari800-cl-suite
           #:run-tests))
