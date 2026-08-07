;;;; tests/test-harte.lisp --- Tom Harte / SingleStepTests 6502 harness.
;;;;
;;;; Per-opcode JSON vectors with full before/after CPU + memory state and a
;;;; cycle-by-cycle bus trace: the strongest CPU-accuracy ratchet available
;;;; to this project (MISC_IMPROVEMENTS_PLAN.md item 4 / ROADMAP.md Phase 12).
;;;;
;;;; ---------------------------------------------------------------------------
;;;; Getting the data
;;;;
;;;; The vectors live in the SingleStepTests/65x02 repository, directory
;;;; `6502/v1/` — one JSON file per opcode, 10,000 cases each, NMOS 6502
;;;; WITH decimal mode and illegal opcodes, which is exactly this
;;;; emulator's target.  The repo is ~1 GB; it is deliberately NOT
;;;; vendored.  Clone it anywhere and point the env var at the directory:
;;;;
;;;;     git clone https://github.com/SingleStepTests/65x02
;;;;     export ATARI800_CL_HARTE_TESTS=$PWD/65x02/6502/v1
;;;;     ./scripts/test-sbcl.sh
;;;;
;;;; A partial checkout works too: the harness tests whichever `<hex>.json`
;;;; files it finds.  With the variable unset (or the directory empty) the
;;;; test SKIPs, exactly like the Klaus functional test in test-cpu.lisp.
;;;;
;;;; Depth: 500 cases per opcode by default, so a full 256-opcode run stays
;;;; minutes rather than hours.  `ATARI800_CL_HARTE_FULL=1` runs all 10,000.
;;;;
;;;; ---------------------------------------------------------------------------
;;;; Triage workflow — READ THIS BEFORE ADDING A SKIP
;;;;
;;;; A failure here is presumed a REAL emulator bug, not a bad vector.  The
;;;; order of work is:
;;;;
;;;;   1. Fix it in `src/`.
;;;;   2. Add a focused regression test to `tests/test-regressions.lisp`
;;;;      naming the opcode and the failing case id (the `name` field, e.g.
;;;;      "7d 3f 21").
;;;;   3. Only then, if the divergence is documented-unstable silicon
;;;;      behaviour, add the opcode to +HARTE-SKIP-OPCODES+ with a comment
;;;;      saying why.
;;;;
;;;; The skip list starts empty on purpose.  Expected candidates are the
;;;; unstable stores and magic-constant opcodes ($8B XAA, $AB LAX #imm, and
;;;; the SHA/SHX/SHY/TAS family): the vectors encode ONE chosen hardware
;;;; behaviour, and `src/illegal.lisp` documents this emulator's own choice,
;;;; so a mismatch there may be legitimate.  Everything else is a bug.
;;;;
;;;; KIL/JAM opcodes are handled, not skipped: the emulator signals
;;;; ILLEGAL-OPCODE and halts, so the harness asserts that condition and
;;;; does not compare post-state (real hardware wedges until reset; the
;;;; vectors model the wedge as a long cycle list).

(in-package #:atari800-cl/tests)

(def-suite harte-suite
  :description "Tom Harte / SingleStepTests per-opcode CPU vectors."
  :in atari800-cl-suite)

(in-suite harte-suite)

(defparameter *harte-default-cases* 500
  "Cases per opcode when ATARI800_CL_HARTE_FULL is not set.")

(defparameter +harte-skip-opcodes+ '()
  "Opcodes excluded from the comparison, each with a comment justifying it.
Starts empty by design — see the triage workflow in the file header.  A
skip is a last resort for documented-unstable silicon, never a way to
silence a failing check.")

;;; ---------------------------------------------------------------------------
;;; Data discovery

(defun %harte-directory ()
  "The `6502/v1` directory from $ATARI800_CL_HARTE_TESTS, or NIL."
  (let ((env (uiop:getenv "ATARI800_CL_HARTE_TESTS")))
    (when (and env (plusp (length env)))
      (let ((dir (uiop:ensure-directory-pathname env)))
        (when (probe-file dir) dir)))))

(defun %harte-case-limit ()
  "How many cases per opcode to run: all 10,000 with ATARI800_CL_HARTE_FULL=1."
  (let ((full (uiop:getenv "ATARI800_CL_HARTE_FULL")))
    (if (and full (member full '("1" "t" "T" "yes" "true") :test #'string=))
        most-positive-fixnum
        *harte-default-cases*)))

(defun %harte-opcode-from-path (path)
  "Opcode number encoded in a vector file's name (\"7d.json\" -> #x7D), or NIL."
  (let ((name (pathname-name path)))
    (when (and name (= 2 (length name)))
      (ignore-errors (parse-integer name :radix 16)))))

(defun %harte-vector-files (dir)
  "Sorted (opcode . path) pairs for every `<hex>.json` file in DIR."
  (sort (loop for path in (directory (merge-pathnames "*.json" dir))
              for opcode = (%harte-opcode-from-path path)
              when opcode collect (cons opcode path))
        #'< :key #'car))

;;; ---------------------------------------------------------------------------
;;; One case

(defun %harte-state (case-object key)
  "The `initial` or `final` sub-object of a parsed case."
  (gethash key case-object))

(defun %harte-load-state (cpu mem state)
  "Install STATE's registers and RAM pairs into CPU / MEM."
  (setf (cpu-pc cpu)    (gethash "pc" state)
        (cpu-sp cpu)    (gethash "s" state)
        (cpu-a cpu)     (gethash "a" state)
        (cpu-x cpu)     (gethash "x" state)
        (cpu-y cpu)     (gethash "y" state)
        (cpu-flags cpu) (gethash "p" state))
  (loop for pair across (gethash "ram" state)
        do (mem-write mem (aref pair 0) (aref pair 1))))

(defun %harte-compare (cpu mem state cycles-used expected-cycles)
  "Compare CPU / MEM against STATE.  Returns a list of mismatch strings."
  (let ((problems '()))
    (flet ((check (label got want)
             (unless (= got want)
               (push (format nil "~A: got $~2,'0X want $~2,'0X" label got want)
                     problems))))
      (unless (= (cpu-pc cpu) (gethash "pc" state))
        (push (format nil "PC: got $~4,'0X want $~4,'0X"
                      (cpu-pc cpu) (gethash "pc" state))
              problems))
      (check "S" (cpu-sp cpu)    (gethash "s" state))
      (check "A" (cpu-a cpu)     (gethash "a" state))
      (check "X" (cpu-x cpu)     (gethash "x" state))
      (check "Y" (cpu-y cpu)     (gethash "y" state))
      (check "P" (cpu-flags cpu) (gethash "p" state))
      (loop for pair across (gethash "ram" state)
            for addr = (aref pair 0)
            for want = (aref pair 1)
            for got = (mem-read mem addr)
            unless (= got want)
              do (push (format nil "RAM $~4,'0X: got $~2,'0X want $~2,'0X"
                               addr got want)
                       problems))
      (unless (= cycles-used expected-cycles)
        (push (format nil "cycles: got ~D want ~D" cycles-used expected-cycles)
              problems)))
    (nreverse problems)))

(defun %harte-run-case (case-object)
  "Run one case.  Returns NIL on success, else a description of the failure."
  (let* ((cpu (make-cpu))
         (mem (make-memory))
         (initial (%harte-state case-object "initial"))
         (final   (%harte-state case-object "final"))
         (expected-cycles (length (gethash "cycles" case-object)))
         (halted nil)
         (cycles-used 0))
    (attach-memory-bus cpu mem)
    (%harte-load-state cpu mem initial)
    (handler-case
        (setf cycles-used (step-cpu cpu))
      ;; KIL/JAM: the emulator refuses to continue, which is the modelled
      ;; equivalent of hardware wedging until reset.  Post-state is not
      ;; comparable, so a signalled condition IS the expected outcome.
      (illegal-opcode () (setf halted t)))
    (cond
      (halted nil)
      (t
       (let ((problems (%harte-compare cpu mem final cycles-used
                                       expected-cycles)))
         (when problems
           (format nil "~A: ~{~A~^; ~}"
                   (gethash "name" case-object) problems)))))))

(defun %harte-map-cases (path limit function)
  "Call FUNCTION on up to LIMIT parsed cases from PATH.  Returns the count.

The files are one big JSON array of 10,000 cases, 3-5 MB each; parsing a
whole file at once materialises every case at once and exhausts a default
1 GB SBCL heap partway through a 256-opcode run.  So we step the array
ourselves — consume the opening bracket, then read one value at a time,
eating the commas — which keeps only the current case live and, at the
default depth, parses 500 objects instead of 10,000."
  ;; :ELEMENT-TYPE 'CHARACTER is not redundant — LispWorks opens character
  ;; streams as BASE-CHAR by default and then refuses a UTF-8 external
  ;; format, since UTF-8 can produce characters outside BASE-CHAR.
  (with-open-file (in path :external-format :utf-8 :element-type 'character)
    (loop for ch = (read-char in nil nil)
          until (or (null ch) (char= ch #\[)))
    (loop with count = 0
          while (< count limit)
          for ch = (peek-char t in nil nil)
          do (cond
               ((null ch) (return count))
               ((char= ch #\]) (return count))
               ((char= ch #\,) (read-char in))
               (t (funcall function (shasht:read-json in))
                  (incf count)))
          finally (return count))))

(defun %harte-run-opcode (path limit)
  "Run up to LIMIT cases from PATH.  Returns (values run-count failures)."
  (let ((failures '()))
    (values (%harte-map-cases
             path limit
             (lambda (case-object)
               (let ((problem (%harte-run-case case-object)))
                 (when problem (push problem failures)))))
            (nreverse failures))))

;;; ---------------------------------------------------------------------------
;;; The test

(test harte-processor-tests
  "Every opcode vector file found under $ATARI800_CL_HARTE_TESTS must pass:
registers, memory and cycle count after a single STEP-CPU."
  (let ((dir (%harte-directory)))
    (if (null dir)
        (skip "$ATARI800_CL_HARTE_TESTS is unset or does not exist; skipping ~
               the Tom Harte vectors.  Clone SingleStepTests/65x02 and point ~
               the variable at its 6502/v1 directory to enable them.")
        (let ((files (%harte-vector-files dir))
              (limit (%harte-case-limit))
              (total-cases 0)
              (total-failures 0))
          (if (null files)
              (skip "No <hex>.json vector files in ~A; skipping." dir)
              (progn
                (dolist (entry files)
                  (destructuring-bind (opcode . path) entry
                    (unless (member opcode +harte-skip-opcodes+)
                      (multiple-value-bind (run failures)
                          (%harte-run-opcode path limit)
                        (incf total-cases run)
                        (incf total-failures (length failures))
                        ;; One check per opcode keeps the check count sane
                        ;; while still naming the opcode that broke; the
                        ;; message carries the first few failing cases.
                        (is (null failures)
                            "opcode $~2,'0X: ~D/~D cases failed~%    ~{~A~^~%    ~}~@[~%    ...~]"
                            opcode (length failures) run
                            (subseq failures 0 (min 5 (length failures)))
                            (> (length failures) 5))))))
                (is (zerop total-failures)
                    "~D of ~D Harte cases failed across ~D opcode~:P"
                    total-failures total-cases (length files))))))))
