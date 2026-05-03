;;;; tests/test-memory.lisp --- Tests for the memory subsystem.

(in-package #:atari800-cl/tests)

(def-suite memory-suite
  :description "Tests for atari800-cl.memory."
  :in atari800-cl-suite)

(in-suite memory-suite)

(test fresh-memory-is-zero
  "A freshly constructed memory should read 0 everywhere."
  (let ((m (make-memory)))
    (is (zerop (mem-read m #x0000)))
    (is (zerop (mem-read m #x1234)))
    (is (zerop (mem-read m #xFFFF)))))

(test mem-read-write-roundtrip
  "Writes are observable by subsequent reads at the same address."
  (let ((m (make-memory)))
    (mem-write m #x0200 #x42)
    (is (= #x42 (mem-read m #x0200)))
    (mem-write m #x0200 #xFF)
    (is (= #xFF (mem-read m #x0200)))))

(test reset-memory-clears
  "RESET-MEMORY zeros out RAM."
  (let ((m (make-memory)))
    (mem-write m #x4000 #xAA)
    (reset-memory m)
    (is (zerop (mem-read m #x4000)))))
