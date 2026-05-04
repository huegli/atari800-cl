;;;; tests/test-compat.lisp --- Tests for the portability layer.
;;;;
;;;; --- Common Lisp / FiveAM notes for beginners ---
;;;;
;;;; TEST defines a single test case.  The first string is a description.
;;;; Inside a test, IS checks that an expression is true:
;;;;   (is (= 4 (+ 2 2)))   — passes if 2+2 equals 4
;;;; IS-TRUE checks that the value is non-NIL (truthy):
;;;;   (is-true (stringp x)) — passes if X is a string
;;;;
;;;; MEMBER tests whether an element is in a list:
;;;;   (member :sbcl '(:lispworks :sbcl :unknown)) → (:SBCL :UNKNOWN)
;;;; MEMBER returns the tail of the list starting at the match, which is
;;;; truthy; if the element isn't found, it returns NIL (falsy).
;;;;
;;;; EVERY tests that a predicate is true for every element of a sequence:
;;;;   (every #'evenp '(2 4 6)) → T
;;;; #'EVENP is shorthand for (FUNCTION EVENP).
;;;;
;;;; UNWIND-PROTECT guarantees that its cleanup forms run even if an error
;;;; is signalled during the protected form — like try/finally in Java.
;;;; PROBE-FILE returns a truthy value if the file exists.

(in-package #:atari800-cl/tests)

;;; This suite is a child of ATARI800-CL-SUITE (the root), specified by :IN.
(def-suite compat-suite
  :description "Tests for atari800-cl.compat."
  :in atari800-cl-suite)

;; IN-SUITE sets the current suite so that all subsequent TEST forms in
;; this file belong to COMPAT-SUITE.
(in-suite compat-suite)

(test implementation-known
  "We should be running on a host we recognize."
  (is (member *implementation* '(:lispworks :sbcl :unknown)))
  (is (stringp (implementation-name))))

(test byte-vector-roundtrip
  "make-byte-vector returns a properly typed array."
  (let ((v (make-byte-vector 4 :initial-element 7)))
    ;; TYPEP tests whether a value belongs to a type.
    (is (typep v 'byte-vector))
    (is (= 4 (length v)))
    ;; EVERY with a LAMBDA checks that every element is 7.
    (is (every (lambda (b) (= b 7)) v))
    ;; SETF + AREF writes to the array; verify the write is visible.
    (setf (aref v 0) 255)
    (is (= 255 (aref v 0)))))

(test lock-roundtrip
  "make-lock + with-lock should not error on either implementation."
  (let ((lock  (make-lock "test-lock"))
        (value 0))
    ;; WITH-LOCK acquires the lock, runs the body, then releases it.
    ;; INCF increments VALUE in place.
    (with-lock (lock)
      (incf value))
    (is (= 1 value))))

(test binary-file-roundtrip
  "write-binary-file followed by read-binary-file returns the same bytes."
  ;; MERGE-PATHNAMES combines a filename with a directory to get a full path.
  ;; UIOP:TEMPORARY-DIRECTORY returns the OS temp directory.
  (let* ((path  (merge-pathnames "atari800-cl-test.bin"
                                 (uiop:temporary-directory)))
         (bytes (make-byte-vector 8)))
    ;; Fill the vector: element 0 = 0, element 1 = 1, ..., element 7 = 7.
    (loop for i below 8 do (setf (aref bytes i) i))
    ;; UNWIND-PROTECT ensures we delete the temp file even if the test fails.
    (unwind-protect
         (progn
           (write-binary-file path bytes)
           (let ((round-tripped (read-binary-file path)))
             ;; EQUALP compares arrays element-by-element.
             (is (equalp bytes round-tripped))))
      ;; Cleanup form: delete the temp file if it exists.
      (when (probe-file path)
        (delete-file path)))))
