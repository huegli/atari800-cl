;;;; runner.lisp --- Entry point for `bin/atari-run.sh`.
;;;;
;;;; Loads atari800-cl, parses argv, constructs a machine (optionally with
;;;; OS / BASIC ROMs), loads the supplied XEX file, sets the CPU's PC to the
;;;; XEX's entry point, and single-steps the CPU until either:
;;;;
;;;;   (a) the next opcode at PC is $00 (BRK),                or
;;;;   (b) the CPU sets its HALTED flag (KIL / illegal),      or
;;;;   (c) the step budget is exhausted (`--max-steps`).
;;;;
;;;; On exit the runner prints register state and the surrounding bytes
;;;; (4 bytes at PC) so the developer can see where execution stopped.
;;;;
;;;; Usage (via bin/atari-run.sh):
;;;;
;;;;   sbcl --script runner.lisp PROGRAM.xex [--max-steps N]
;;;;                             [--os-rom PATH] [--basic-rom PATH]
;;;;                             [--init-runs N]      ; how many BRK to skip
;;;;                                                    if you want to bypass
;;;;                                                    intermediate BRKs
;;;;
;;;; Exit codes:
;;;;    0 — clean halt at BRK
;;;;    1 — step budget exhausted (likely infinite loop)
;;;;    2 — CPU halted on illegal opcode / KIL
;;;;    3 — bad command line or failed to load the XEX

(in-package #:cl-user)

;;; ---------------------------------------------------------------------------
;;; 1.  Load Quicklisp + atari800-cl + the local XEX loader.
;;; ---------------------------------------------------------------------------

(let ((ql-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (find-package :ql)
    (when (probe-file ql-init)
      (load ql-init))))

(handler-case
    (funcall (read-from-string "ql:quickload") :atari800-cl :silent t)
  (error (c)
    (format *error-output* "fatal: could not load :atari800-cl — ~A~%" c)
    (uiop:quit 3)))

;; Load the XEX loader that lives next to this file.
(load (merge-pathnames "xex-loader.lisp"
                       (or *load-truename* *compile-file-truename*
                           (make-pathname :defaults *default-pathname-defaults*))))

;;; ---------------------------------------------------------------------------
;;; 2.  Tiny argv parser.  Positional: XEX path.  Long options take a value.
;;; ---------------------------------------------------------------------------

(defun %argv ()
  (or
   #+sbcl       (cdr sb-ext:*posix-argv*)         ; drop the program name
   #+lispworks  (cdr sys:*line-arguments-list*)
   #+ccl        (cdr ccl:*command-line-argument-list*)
   nil))

(defun parse-options (args)
  "Return (values xex-path opts-plist)."
  (let ((xex nil)
        (opts '(:max-steps 20000000
                :os-rom    nil
                :basic-rom nil)))
    (loop while args do
      (let ((a (pop args)))
        (cond
          ((string= a "--max-steps")
           (setf (getf opts :max-steps) (parse-integer (pop args))))
          ((string= a "--os-rom")
           (setf (getf opts :os-rom) (pop args)))
          ((string= a "--basic-rom")
           (setf (getf opts :basic-rom) (pop args)))
          ((or (string= a "-h") (string= a "--help"))
           (format t "usage: atari-run PROGRAM.xex [--max-steps N] [--os-rom PATH] [--basic-rom PATH]~%")
           (uiop:quit 0))
          ((and (not xex) (not (eql (char a 0) #\-)))
           (setf xex a))
          (t
           (format *error-output* "unknown argument: ~A~%" a)
           (uiop:quit 3)))))
    (unless xex
      (format *error-output* "error: no XEX file given~%")
      (uiop:quit 3))
    (values xex opts)))

;;; ---------------------------------------------------------------------------
;;; 3.  Helpers to reach into the machine / CPU.  We resolve symbols at
;;;     run time (rather than naming the packages at read time) so this
;;;     file compiles even when :atari800-cl has not yet been loaded.
;;; ---------------------------------------------------------------------------

(defmacro sym (pkg name)  `(find-symbol ,name ,pkg))

(defun cpu-of (machine)
  (funcall (sym "ATARI800-CL.MACHINE" "ATARI-MACHINE-CPU") machine))

(defun bus-of (machine)
  (funcall (sym "ATARI800-CL.MACHINE" "ATARI-MACHINE-BUS") machine))

(defun cpu-pc (cpu)     (funcall (sym "ATARI800-CL.CPU" "CPU-PC") cpu))
(defun (setf cpu-pc) (v cpu)
  (funcall (fdefinition `(setf ,(sym "ATARI800-CL.CPU" "CPU-PC"))) v cpu))
(defun cpu-a   (cpu)    (funcall (sym "ATARI800-CL.CPU" "CPU-A")     cpu))
(defun cpu-x   (cpu)    (funcall (sym "ATARI800-CL.CPU" "CPU-X")     cpu))
(defun cpu-y   (cpu)    (funcall (sym "ATARI800-CL.CPU" "CPU-Y")     cpu))
(defun cpu-sp  (cpu)    (funcall (sym "ATARI800-CL.CPU" "CPU-SP")    cpu))
(defun cpu-flags (cpu)  (funcall (sym "ATARI800-CL.CPU" "CPU-FLAGS") cpu))
(defun cpu-cycles (cpu) (funcall (sym "ATARI800-CL.CPU" "CPU-CYCLES") cpu))
(defun cpu-halted (cpu) (funcall (sym "ATARI800-CL.CPU" "CPU-HALTED") cpu))
(defun step-cpu (cpu)   (funcall (sym "ATARI800-CL.CPU" "STEP-CPU") cpu))
(defun bus-read (bus addr)
  (funcall (sym "ATARI800-CL.BUS" "BUS-READ") bus addr))

(defun flag-string (f)
  "Decode the packed NV-BDIZC flags byte."
  (with-output-to-string (s)
    (loop for bit in '((7 . #\N) (6 . #\V) (5 . #\-) (4 . #\B)
                       (3 . #\D) (2 . #\I) (1 . #\Z) (0 . #\C))
          do (princ (if (logbitp (car bit) f)
                        (cdr bit)
                        (char-downcase (cdr bit)))
                    s))))

(defun dump-state (cpu bus reason &key (start-pc nil))
  (let* ((pc (cpu-pc cpu)))
    (format t "~%---- stopped: ~A ----~%" reason)
    (format t "PC=$~4,'0X  A=$~2,'0X  X=$~2,'0X  Y=$~2,'0X  SP=$~2,'0X  P=~A ($~2,'0X)  cycles=~D~%"
            pc (cpu-a cpu) (cpu-x cpu) (cpu-y cpu) (cpu-sp cpu)
            (flag-string (cpu-flags cpu)) (cpu-flags cpu)
            (cpu-cycles cpu))
    (when start-pc
      (format t "started at $~4,'0X~%" start-pc))
    (format t "bytes at PC: ")
    (loop for i from 0 below 4
          do (format t "$~2,'0X " (bus-read bus (logand #xFFFF (+ pc i)))))
    (terpri)))

;;; ---------------------------------------------------------------------------
;;; 4.  Main.
;;; ---------------------------------------------------------------------------

(defun main ()
  (multiple-value-bind (xex opts) (parse-options (%argv))
    (let* ((make-machine    (sym "ATARI800-CL.MACHINE" "MAKE-ATARI-MACHINE"))
           (cold-reset      (sym "ATARI800-CL.MACHINE" "MACHINE-COLD-RESET"))
           (machine         (funcall make-machine))
           (os-path         (getf opts :os-rom))
           (basic-path      (getf opts :basic-rom))
           (max-steps       (getf opts :max-steps)))

      ;; Cold-reset gives a deterministic post-power-on state.  If ROM paths
      ;; were supplied they are loaded; otherwise the machine boots "naked"
      ;; (RAM only, no OS) which is fine for standalone test programs.
      (if (or os-path basic-path)
          (funcall cold-reset machine :os-path (and os-path (pathname os-path))
                                       :basic-path (and basic-path (pathname basic-path)))
          (funcall cold-reset machine))

      (format t "==> machine cold-reset~%")

      ;; Load the XEX.  This installs every non-vector segment into the bus
      ;; and returns the entry-point plist.
      (let* ((load-result
               (handler-case
                   (atari-xl-bbedit.xex:load-xex machine xex)
                 (error (c)
                   (format *error-output* "fatal: failed to load ~A: ~A~%" xex c)
                   (uiop:quit 3))))
             (entry (getf load-result :entry))
             (init  (getf load-result :init))
             (cpu   (cpu-of machine))
             (bus   (bus-of machine)))

        (format t "==> loaded ~A~%" xex)
        (format t "    segments: ~{$~{~4,'0X~}-$~{~4,'0X~}~^, ~}~%"
                (loop for (s . e) in (getf load-result :segments)
                      collect (list (list s) (list e))))
        (when init (format t "    INIT vector: $~4,'0X (not auto-invoked)~%" init))
        (format t "    RUN  entry : $~4,'0X~%" entry)

        ;; Park the PC at the entry point and clear the halted flag.
        (setf (cpu-pc cpu) entry)

        ;; Step until we reach a BRK opcode, hit the budget, or HALT.
        (let ((start-pc entry)
              (steps 0))
          (loop
            (when (cpu-halted cpu)
              (dump-state cpu bus "CPU halted (illegal opcode / KIL)" :start-pc start-pc)
              (uiop:quit 2))
            (when (>= steps max-steps)
              (dump-state cpu bus
                          (format nil "step budget exhausted (~D)" max-steps)
                          :start-pc start-pc)
              (uiop:quit 1))
            ;; Peek the next opcode WITHOUT consuming it.  If it's $00 (BRK),
            ;; stop cleanly before the CPU pushes its frame and vectors
            ;; through $FFFE.
            (when (= #x00 (bus-read bus (cpu-pc cpu)))
              (dump-state cpu bus "BRK reached" :start-pc start-pc)
              (uiop:quit 0))
            (handler-case (step-cpu cpu)
              (error (c)
                (dump-state cpu bus
                            (format nil "lisp error: ~A" c)
                            :start-pc start-pc)
                (uiop:quit 2)))
            (incf steps)))))))

(main)
