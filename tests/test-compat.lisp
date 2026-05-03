;;;; tests/test-compat.lisp --- Tests for the portability layer.

(in-package #:atari800-cl/tests)

(def-suite compat-suite
  :description "Tests for atari800-cl.compat."
  :in atari800-cl-suite)

(in-suite compat-suite)

(test implementation-known
  "We should be running on a host we recognize."
  (is (member *implementation* '(:lispworks :sbcl :unknown)))
  (is (stringp (implementation-name))))

(test byte-vector-roundtrip
  "make-byte-vector returns a properly typed array."
  (let ((v (make-byte-vector 4 :initial-element 7)))
    (is (typep v 'byte-vector))
    (is (= 4 (length v)))
    (is (every (lambda (b) (= b 7)) v))
    (setf (aref v 0) 255)
    (is (= 255 (aref v 0)))))

(test lock-roundtrip
  "make-lock + with-lock should not error on either implementation."
  (let ((lock  (make-lock "test-lock"))
        (value 0))
    (with-lock (lock)
      (incf value))
    (is (= 1 value))))

(test binary-file-roundtrip
  "write-binary-file followed by read-binary-file returns the same bytes."
  (let* ((path  (merge-pathnames "atari800-cl-test.bin"
                                 (uiop:temporary-directory)))
         (bytes (make-byte-vector 8)))
    (loop for i below 8 do (setf (aref bytes i) i))
    (unwind-protect
         (progn
           (write-binary-file path bytes)
           (let ((round-tripped (read-binary-file path)))
             (is (equalp bytes round-tripped))))
      (when (probe-file path)
        (delete-file path)))))
