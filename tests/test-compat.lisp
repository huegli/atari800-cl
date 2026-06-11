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

;;; ---------------------------------------------------------------------------
;;; Process / filesystem helpers

(test current-process-id-is-positive
  "CURRENT-PROCESS-ID returns this process's PID (a positive integer)."
  (let ((pid (current-process-id)))
    (is (integerp pid))
    (is (plusp pid) "PID should be > 0; got ~S" pid)))

(test delete-file-if-exists-semantics
  "Returns T and removes the file when present; NIL when absent."
  (let ((path (merge-pathnames "atari800-cl-del-test.tmp"
                               (uiop:temporary-directory)))
        )
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-line "x" s))
    (is (eq t (delete-file-if-exists path)) "first delete removes file")
    (is (null (probe-file path)) "file is gone")
    (is (null (delete-file-if-exists path)) "second delete is a no-op -> NIL")))

(test chmod-file-runs-without-error
  "CHMOD-FILE applies a mode to an existing file without error."
  (let ((path (merge-pathnames "atari800-cl-chmod-test.tmp"
                               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output :if-exists :supersede)
             (write-line "x" s))
           (finishes (chmod-file path #o600))
           (is (and (probe-file path) t) "file survives chmod"))
      (delete-file-if-exists path))))

;;; ---------------------------------------------------------------------------
;;; Unix-domain stream sockets
;;;
;;; usocket has no local-socket support, so these go through the
;;; per-implementation compat helpers (sb-bsd-sockets / LispWorks FLI).
;;; This test is the product-code form of the Stage-0 spike.

(test unix-socket-roundtrip
  "open-unix-listener / accept-unix-client / open-unix-client carry a line
across a Unix-domain socket on whichever implementation we're running."
  (if (not (unix-listener-available-p))
      (skip "Unix-domain listener bind is not permitted in this execution environment.")
      (let* ((path (format nil "/tmp/atari800-cl-test-~D.sock" (current-process-id)))
             (listener (open-unix-listener path)))
        (unwind-protect
             (let ((reply nil))
               (let ((client-thread
                       (make-thread
                        (lambda ()
                          (let ((s (open-unix-client path)))
                            (unwind-protect
                                 (progn (write-line "hello-unix" s) (force-output s))
                              (close s))))
                        :name "unix-roundtrip-client")))
                 (let ((server-stream (accept-unix-client listener)))
                   (unwind-protect
                        (setf reply (read-line server-stream))
                     (close server-stream)))
                 (join-thread client-thread))
               (is (string= "hello-unix" reply)
                   "server read what the client wrote; got ~S" reply))
          (close-unix-listener listener)))))
