;;;; tests/package.lisp --- Test package definition.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; :IMPORT-FROM vs :USE in DEFPACKAGE:
;;;;
;;;;   (:USE #:fiveam) would make ALL of FiveAM's exported symbols
;;;;   directly available.  The problem is that FiveAM exports very
;;;;   common names like TEST, PASS, FAIL, RUN, IS, SKIP — these would
;;;;   collide with symbols from CL or from our own emulator packages.
;;;;   On SBCL this triggers SYMBOL-PACKAGE-LOCKED-ERROR.
;;;;
;;;;   (:IMPORT-FROM #:fiveam #:test #:is ...) imports only the specific
;;;;   symbols we need.  This avoids collisions and keeps both LispWorks
;;;;   and SBCL behaving identically.
;;;;
;;;; (:USE #:atari800-cl.cpu) imports ALL exports from the CPU package,
;;;;   which is fine because those names (MAKE-CPU, CPU-PC, etc.) are
;;;;   specific enough not to collide with anything.

(in-package #:cl-user)

(defpackage #:atari800-cl/tests
  (:use #:cl
        #:atari800-cl.compat
        #:atari800-cl.memory
        #:atari800-cl.cpu
        #:atari800-cl.input)
  ;; Selective import from FiveAM — only the macros and functions we use.
  (:import-from #:fiveam
                #:def-suite       ; define a test suite
                #:in-suite        ; set the current suite for subsequent tests
                #:test            ; define a single test
                #:is              ; assert that an expression is true
                #:is-true         ; assert that expression evaluates to non-NIL
                #:is-false        ; assert that expression evaluates to NIL
                #:signals         ; assert that a condition (error) is signalled
                #:finishes        ; assert that expression completes without error
                #:pass            ; unconditionally pass
                #:fail            ; unconditionally fail
                #:skip            ; skip this test with a message
                #:run!)           ; run a test/suite and print results
  (:documentation "FiveAM test suite for atari800-cl.")
  ;; Export the suite name and runner so external callers can run our tests.
  (:export #:atari800-cl-suite
           #:run-tests))
