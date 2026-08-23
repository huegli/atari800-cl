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

(test chmod-file-actually-changes-mode
  "CHMOD-FILE really changes the permission bits, not just returns
without error: after #o400 (read-only) an output open must fail; after
#o600 it must succeed again.  Exercises the LispWorks FLI chmod(2)
binding / SBCL's sb-posix:chmod doing real work.  (Assumes the test
does not run as root, where permission checks are bypassed.)"
  (let ((path (merge-pathnames "atari800-cl-chmod-mode-test.tmp"
                               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (s path :direction :output :if-exists :supersede)
             (write-line "x" s))
           (chmod-file path #o400)
           (signals error
             (with-open-file (s path :direction :output :if-exists :append)
               (write-line "y" s)))
           (chmod-file path #o600)
           (finishes
             (with-open-file (s path :direction :output :if-exists :append)
               (write-line "y" s))))
      (ignore-errors (chmod-file path #o600))
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

;;; ---------------------------------------------------------------------------
;;; WITH-PROFILING (PERFORMANCE_PLAN.md Phase 4 step 1 / ROADMAP.md Phase 18)
;;;
;;; These tests assert only the macro's CONTRACT -- return values, single
;;; execution, clean expansion -- never on profiler report contents, which
;;; are implementation-specific and, on a LispWorks image without the
;;; profiler system, may be a documented no-op instead of a real profile.

(test with-profiling-returns-body-values
  "WITH-PROFILING returns all of BODY's values, not just the first."
  (multiple-value-bind (a b c)
      (with-profiling ()
        (values 1 2 3))
    (is (= 1 a))
    (is (= 2 b))
    (is (= 3 c))))

(test with-profiling-runs-body-exactly-once
  "A side effect inside BODY happens exactly once, not zero or twice --
guards against a macro expansion that accidentally duplicates BODY (e.g.
splicing it into both a success and a cleanup path)."
  (let ((count 0))
    (with-profiling ()
      (incf count))
    (is (= 1 count) "expected BODY to run exactly once; ran ~D times" count)))

(test with-profiling-accepts-mode-keyword
  "The :MODE keyword is accepted (and, per implementation, honored or
documented-ignored) without signalling -- both :CPU (the default) and
:ALLOC must expand and run cleanly."
  (let ((cpu-count 0) (alloc-count 0))
    (with-profiling (:mode :cpu)
      (incf cpu-count))
    (with-profiling (:mode :alloc)
      (incf alloc-count))
    (is (= 1 cpu-count))
    (is (= 1 alloc-count))))

(test with-profiling-propagates-body-error
  "If BODY signals, the condition propagates out of WITH-PROFILING rather
than being swallowed by the profiler set-up/tear-down."
  (signals division-by-zero
    (with-profiling ()
      (/ 1 0))))

;;; ---------------------------------------------------------------------------
;;; FAST-AREF (ROADMAP.md Phase 26 -- the scoped LispWorks (safety 0) array
;;; access carve-out)
;;;
;;; These tests check FAST-AREF's observable contract -- read/write values
;;; and SETF return value identical to plain AREF -- on both hosts, plus
;;; the macroexpansion shape each host is supposed to produce. The
;;; expansion-shape test below branches on *IMPLEMENTATION* at run time
;;; (never on #+/#- reader conditionals, which CLAUDE.md reserves for
;;; src/compat.lisp alone): LispWorks, run without ATARI800_CL_CHECKED_AREF
;;; set, must show the unchecked (safety 0) LOCALLY form; SBCL must show
;;; the plain checked access.

(test fast-aref-reads-like-aref
  "FAST-AREF reads the same values AREF would, on a fixnum array and on a
differently-typed array, for every index."
  (let ((fx (make-array 4 :element-type 'fixnum :initial-contents '(10 20 30 40)))
        (u8 (make-byte-vector 4 :initial-element 0)))
    (dotimes (i 4) (setf (aref u8 i) (* i 11)))
    (dotimes (i 4)
      (is (= (aref fx i) (fast-aref (simple-array fixnum (4)) fx i))
          "index ~D: fast-aref should read the same fixnum AREF does" i)
      (is (= (aref u8 i)
             (fast-aref (simple-array (unsigned-byte 8) (4)) u8 i))
          "index ~D: fast-aref should read the same byte AREF does" i))))

(test fast-aref-setf-writes-like-aref-and-returns-value
  "(SETF FAST-AREF) writes the same way (SETF AREF) would, and -- like
(SETF AREF) -- the SETF form's own value is the stored value."
  (let ((fx (make-array 4 :element-type 'fixnum :initial-element 0))
        (u8 (make-byte-vector 4 :initial-element 0)))
    (let ((result (setf (fast-aref (simple-array fixnum (4)) fx 2) 777)))
      (is (= 777 result) "setf of fast-aref should return the stored value")
      (is (= 777 (aref fx 2)) "the write should be visible through plain AREF too"))
    (let ((result (setf (fast-aref (simple-array (unsigned-byte 8) (4)) u8 1) 200)))
      (is (= 200 result))
      (is (= 200 (aref u8 1))))))

(test fast-aref-setf-evaluates-array-and-index-once
  "The SETF expander must evaluate its ARRAY and INDEX subforms exactly
once each, even though the expansion binds them to temporaries and reads
them back out -- guards against a hand-written expander that accidentally
duplicates a side-effecting subform."
  (let ((arrays (list (make-array 4 :element-type 'fixnum :initial-element 0)
                       (make-array 4 :element-type 'fixnum :initial-element 0)))
        (array-calls 0)
        (indices (list 0 1 2 3))
        (index-calls 0))
    (flet ((next-array () (incf array-calls) (pop arrays))
           (next-index () (incf index-calls) (pop indices)))
      (setf (fast-aref (simple-array fixnum (4)) (next-array) (next-index)) 42))
    (is (= 1 array-calls) "array subform should be evaluated exactly once")
    (is (= 1 index-calls) "index subform should be evaluated exactly once")))

(test fast-aref-expansion-shape
  "FAST-AREF's macroexpansion has the shape ROADMAP.md Phase 26 specifies
for the running host. Dispatches on *IMPLEMENTATION* (a run-time value from
this package) rather than a #+/#- reader conditional, since CLAUDE.md
reserves reader conditionals for src/compat.lisp alone.

  * :SBCL -- FAST-AREF is an identity: it expands to a plain checked
    (AREF (THE type array) index), no LOCALLY/OPTIMIZE wrapper at all.

  * :LISPWORKS, ATARI800_CL_CHECKED_AREF unset (the default this suite
    runs under) -- the expansion must be wrapped in a LOCALLY declaring
    (SAFETY 0) -- the one inlining trapdoor Phase 26 licenses -- with
    both the array and the index THE-asserted. If the checked-mode env
    var IS set in this process, the unchecked shape is unreachable and
    this test skips rather than failing."
  (let ((expansion (macroexpand-1 '(fast-aref (simple-array fixnum (4)) arr idx))))
    (case *implementation*
      (:sbcl
       (is (equal '(aref (the (simple-array fixnum (4)) arr) idx) expansion)
           "unexpected FAST-AREF expansion on SBCL: ~S" expansion))
      (:lispworks
       (let ((checked (uiop:getenv "ATARI800_CL_CHECKED_AREF")))
         (if (and checked (plusp (length checked)))
             (skip "ATARI800_CL_CHECKED_AREF is set in this process; the unchecked expansion is not reachable here.")
             (progn
               (is (eq 'locally (first expansion))
                   "expected a LOCALLY wrapper; got ~S" expansion)
               (let ((decl (find 'declare (rest expansion)
                                  :key (lambda (f) (and (consp f) (first f))))))
                 (is (not (null decl)) "expected a DECLARE form in the LOCALLY body")
                 (let ((optimize-decl (find 'optimize (rest decl)
                                             :key (lambda (f) (and (consp f) (first f))))))
                   (is (not (null optimize-decl)) "expected an (OPTIMIZE ...) declaration")
                   (is (member '(safety 0) (rest optimize-decl) :test #'equal)
                       "expected (SAFETY 0) among ~S" optimize-decl)))))))
      (t (skip "no FAST-AREF expansion-shape expectation for ~S" *implementation*)))))

;;; ---------------------------------------------------------------------------
;;; %SKIP-OR-FAIL self-test (ROADMAP.md Phase 21 -- the strict test gate)
;;;
;;; %SKIP-OR-FAIL (tests/test-helpers.lisp) is what turns the Klaus, Harte,
;;; and real-ROM boot tests' graceful skips into failures under
;;; $ATARI800_CL_STRICT.  Exercised here via *STRICT-MODE-OVERRIDE* rather
;;; than the real environment variable, against two standalone probe tests
;;; (%PROBE-SKIP-OR-FAIL-LENIENT / -STRICT, also in test-helpers.lisp) that
;;; are never members of any suite, so running FIVEAM:RUN on them here is
;;; the only way they ever execute.

(test skip-or-fail-respects-strict-mode
  "%SKIP-OR-FAIL skips when strict mode is off and fails when it is on,
using the same reason either way."
  (let ((*strict-mode-override* nil))
    (let ((results (fiveam:run '%probe-skip-or-fail-lenient)))
      (is (= 1 (length results))
          "expected exactly one result from the lenient probe, got ~D"
          (length results))
      (is (typep (first results) 'fiveam::test-skipped)
          "lenient mode: %SKIP-OR-FAIL should SKIP, got a ~A"
          (type-of (first results)))))
  (let ((*strict-mode-override* t))
    (let ((results (fiveam:run '%probe-skip-or-fail-strict)))
      (is (= 1 (length results))
          "expected exactly one result from the strict probe, got ~D"
          (length results))
      (is (typep (first results) 'fiveam::test-failure)
          "strict mode: %SKIP-OR-FAIL should FAIL, got a ~A"
          (type-of (first results))))))
