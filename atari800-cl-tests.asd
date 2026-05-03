;;;; atari800-cl-tests.asd --- Convenience system that forwards to
;;;; atari800-cl/tests so that `(asdf:load-system :atari800-cl-tests)` works.

(defsystem #:atari800-cl-tests
  :description "Convenience alias for the atari800-cl/tests test system"
  :author "Nikolai Schlegel"
  :license "MIT"
  :version "0.0.1"
  :depends-on (#:atari800-cl/tests)
  :perform (test-op (op c)
             (uiop:symbol-call :asdf :test-system :atari800-cl)))
