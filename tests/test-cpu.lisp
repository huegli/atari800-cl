;;;; tests/test-cpu.lisp --- Tests for the 6502 CPU core (scaffold).

(in-package #:atari800-cl/tests)

(def-suite cpu-suite
  :description "Tests for atari800-cl.cpu."
  :in atari800-cl-suite)

(in-suite cpu-suite)

(test reset-loads-pc-from-vector
  "On reset, PC should be loaded from the $FFFC/$FFFD vector."
  (let ((cpu (make-cpu))
        (mem (make-memory)))
    (mem-write mem #xFFFC #x00)
    (mem-write mem #xFFFD #xC0)
    (reset-cpu cpu mem)
    (is (= #xC000 (cpu-pc cpu)))
    (is (= #xFD   (cpu-sp cpu)))
    (is (zerop (cpu-cycles cpu)))))

(test step-advances-cycle-counter
  "STEP-CPU should make forward progress on the cycle counter."
  (let ((cpu (make-cpu))
        (mem (make-memory)))
    (reset-cpu cpu mem)
    (let ((before (cpu-cycles cpu)))
      (step-cpu cpu mem)
      (is (> (cpu-cycles cpu) before)))))
