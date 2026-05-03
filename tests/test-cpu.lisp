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

;;; ---------------------------------------------------------------------------
;;; Klaus Dormann's 6502 functional test
;;;
;;; Build the binary from
;;;   https://github.com/Klaus2m5/6502_65C02_functional_tests
;;; with `org=0000` and `load_data_direct=1`; the result is a flat 64K
;;; image named `6502_functional_test.bin`.  Drop it into roms/ next to
;;; the OS/BASIC images, or point ATARI800_CL_FUNCTIONAL_TEST at it.
;;; The PC converges to $3469 (the success trap) after a few hundred
;;; million cycles.
;;;
;;; If the binary is absent (CI's common case), this test SKIPs with a
;;; message that names the path it tried.

(defparameter *klaus-functional-test-filename* "6502_functional_test.bin")

(defparameter *klaus-functional-test-success-pc* #x3469
  "Trap address Klaus Dormann's test reaches once every check passes.")

(defun %klaus-functional-test-search-paths ()
  "Return candidate pathnames for the Klaus functional test binary."
  (let ((env (uiop:getenv "ATARI800_CL_FUNCTIONAL_TEST"))
        (system-dir (ignore-errors
                     (asdf:system-source-directory "atari800-cl"))))
    (remove nil
            (list (and env (pathname env))
                  (and system-dir
                       (merge-pathnames
                        (make-pathname
                         :directory '(:relative "roms")
                         :name "6502_functional_test"
                         :type "bin")
                        system-dir))
                  (merge-pathnames
                   (make-pathname
                    :directory '(:relative "roms")
                    :name "6502_functional_test"
                    :type "bin")
                   (uiop:getcwd))))))

(defun %klaus-functional-test-binary-path ()
  "Return the first existing candidate path, or NIL."
  (find-if #'probe-file (%klaus-functional-test-search-paths)))

(defun %load-klaus-binary-into-memory (memory bytes)
  "Blit BYTES into MEMORY starting at $0000."
  (loop for i from 0 below (min (length bytes) #x10000)
        do (mem-write memory i (aref bytes i)))
  memory)

(defun %run-klaus-test (&key (max-instructions 200000000))
  "Run the Klaus test until PC stops advancing (trap) or budget is gone.
Returns the final PC."
  (let* ((path (%klaus-functional-test-binary-path))
         (bytes (atari800-cl.compat:read-binary-file path))
         (mem (make-memory))
         (cpu (make-cpu)))
    (%load-klaus-binary-into-memory mem bytes)
    (atari800-cl.cpu:attach-memory-bus cpu mem)
    (setf (cpu-pc cpu) #x0400
          (cpu-sp cpu) #xFD
          (cpu-flags cpu) #x24
          (cpu-cycles cpu) 0)
    (let ((previous-pc -1))
      (dotimes (i max-instructions (cpu-pc cpu))
        (let ((pc (cpu-pc cpu)))
          (when (= pc previous-pc)
            (return-from %run-klaus-test pc))
          (setf previous-pc pc))
        (step-cpu cpu mem)))))

(test klaus-dormann-functional-test
  "Run Klaus Dormann's 6502 functional test to its success trap."
  (let ((path (%klaus-functional-test-binary-path)))
    (cond
      ((null path)
       (skip "Klaus Dormann functional-test binary ~A not found in roms/ ~
              (or via $ATARI800_CL_FUNCTIONAL_TEST). ~
              Build from https://github.com/Klaus2m5/6502_65C02_functional_tests ~
              with org=0000 and load_data_direct=1 to produce a 64KiB image, ~
              then drop it at roms/~A and re-run."
             *klaus-functional-test-filename*
             *klaus-functional-test-filename*))
      (t
       (let ((final-pc (%run-klaus-test)))
         (is (= *klaus-functional-test-success-pc* final-pc)
             "Klaus functional test should trap at $~4,'0X (success); ~
              instead trapped at $~4,'0X."
             *klaus-functional-test-success-pc*
             final-pc))))))
