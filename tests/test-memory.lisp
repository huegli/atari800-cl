;;;; tests/test-memory.lisp --- Tests for the memory subsystem.
;;;;
;;;; --- Common Lisp / FiveAM notes for beginners ---
;;;;
;;;; Each test creates a fresh MEMORY object with (MAKE-MEMORY), so tests
;;;; are fully isolated — no shared state between tests.
;;;;
;;;; The #x prefix denotes hexadecimal: #x0000 = 0, #xFFFF = 65535,
;;;; #x42 = 66, #xFF = 255, #xAA = 170.

(in-package #:atari800-cl/tests)

(def-suite memory-suite
  :description "Tests for atari800-cl.memory."
  :in atari800-cl-suite)

(in-suite memory-suite)

(test fresh-memory-is-zero
  "A freshly constructed memory should read 0 everywhere."
  (let ((m (make-memory)))
    ;; ZEROP returns T if the value is zero.
    (is (zerop (mem-read m #x0000)))   ; first address
    (is (zerop (mem-read m #x1234)))   ; arbitrary middle address
    (is (zerop (mem-read m #xFFFF))))) ; last address (top of 64K)

(test mem-read-write-roundtrip
  "Writes are observable by subsequent reads at the same address."
  (let ((m (make-memory)))
    (mem-write m #x0200 #x42)
    (is (= #x42 (mem-read m #x0200)))
    ;; Overwrite with a different value and verify.
    (mem-write m #x0200 #xFF)
    (is (= #xFF (mem-read m #x0200)))))

(test mem-read-write-boundary
  "Writes at the extremes of the address space round-trip correctly."
  (let ((m (make-memory)))
    (mem-write m #x0000 #xDE)         ; very first byte
    (mem-write m #xFFFF #xAD)         ; very last byte
    (is (= #xDE (mem-read m #x0000)))
    (is (= #xAD (mem-read m #xFFFF)))))

(test reset-memory-clears
  "RESET-MEMORY zeros out RAM."
  (let ((m (make-memory)))
    (mem-write m #x4000 #xAA)
    (reset-memory m)
    (is (zerop (mem-read m #x4000)))))
