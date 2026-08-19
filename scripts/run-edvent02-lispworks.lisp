;;;; scripts/run-edvent02-lispworks.lisp --- LispWorks IDE bring-up for
;;;; EdVenture video 2 (asm/edvent02.asm) against the minimal-xl OS.
;;;;
;;;; Invoked as the LispWorks `-init` file:
;;;;
;;;;   lispworks-binary -init scripts/run-edvent02-lispworks.lisp
;;;;
;;;; (see scripts/run-edvent02-lispworks.sh, which launches the real
;;;; LispWorks IDE executable this way -- NOT lw-console, so you get the
;;;; full interactive environment with listener/editor/inspector).
;;;;
;;;; `-init` REPLACES the normal ~/.lispworks load, so step 1 below loads
;;;; the user's own init file explicitly (Quicklisp + local-projects setup)
;;;; to keep the IDE otherwise exactly as it would start normally.  Steps 2+
;;;; then:
;;;;
;;;;   - quickload :atari800-cl and load the XEX loader, as standalone
;;;;     top-level forms (see the note above STEP 2 below for why this
;;;;     ordering matters)
;;;;   - build minimal-xl/minimal_os.rom via `make` if it isn't there yet
;;;;   - assemble asm/edvent02.asm with MADS via scripts/mads-build.sh
;;;;   - build an atari-machine cold-reset against the minimal-xl OS ROM
;;;;     (no BASIC ROM -- minimal-xl is a complete OS replacement)
;;;;   - load the assembled XEX onto the bus and park the CPU at its entry
;;;;     point (mirrors scripts/runner.lisp's XEX bring-up)
;;;;   - start the machine run loop and the AESP + CLI servers
;;;;
;;;; *machine* / *runner* / *aesp-server* / *cli-server* are left bound in
;;;; ATARI800-CL-LAUNCH for REPL poking; (atari800-cl-launch:stop-all) tears
;;;; everything down.

(in-package #:cl-user)

;; 1.  Keep the IDE otherwise normal: run the user's own init file, which
;;     sets up Quicklisp and registers ~/quicklisp/local-projects with ASDF.
(let ((personal-init (merge-pathnames ".lispworks" (user-homedir-pathname))))
  (when (probe-file personal-init)
    (load personal-init)))

(require "asdf")

(defpackage #:atari800-cl-launch
  (:use #:cl)
  (:export #:*machine* #:*runner* #:*aesp-server* #:*cli-server* #:stop-all))

(in-package #:atari800-cl-launch)

(defparameter *machine* nil)
(defparameter *runner* nil)
(defparameter *aesp-server* nil)
(defparameter *cli-server* nil)

(defparameter *root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

;; 2.  Load :atari800-cl and the XEX loader as their OWN top-level forms,
;;     executed here.  `-init` LOADs this file, which reads and evaluates
;;     one top-level form at a time -- but each DEFUN below is itself a
;;     single top-level form, read in its entirety before it runs.  If a
;;     DEFUN's body mentioned ATARI800-CL: or ATARI-XL-BBEDIT.XEX: symbols
;;     before those packages existed, the READER (not the evaluator) would
;;     fail with "cannot find package" while merely tokenizing the DEFUN --
;;     regardless of when it's later called.  So these loads must run, and
;;     complete, before any DEFUN that references their symbols is read.
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*root*) :inherit-configuration))
(ql:quickload :atari800-cl :silent t)
(load (merge-pathnames #P"scripts/xex-loader.lisp" *root*))

;; 3.  Everything from here on may freely reference ATARI800-CL: /
;;     ATARI800-CL.*: / ATARI-XL-BBEDIT.XEX: symbols.

(defun stop-all ()
  "Stop the AESP/CLI servers and the machine run loop."
  (when *aesp-server*
    (atari800-cl:stop-aesp-server *aesp-server*)
    (setf *aesp-server* nil))
  (when *cli-server*
    (atari800-cl:stop-cli-socket *cli-server*)
    (setf *cli-server* nil))
  (when *runner*
    (atari800-cl:stop-machine *runner*)
    (setf *runner* nil))
  (format t "~&Servers stopped.~%"))

(defun run-program-or-die (argv what)
  (multiple-value-bind (output error-output status)
      (uiop:run-program argv :output t :error-output t :ignore-error-status t)
    (declare (ignore output error-output))
    (unless (zerop status)
      (error "~A failed (exit ~D): ~{~A~^ ~}" what status argv))))

(defun build-minimal-xl-os (root)
  "Assemble minimal-xl/minimal_os.rom via `make` if it is missing."
  (let* ((dir (merge-pathnames #P"minimal-xl/" root))
         (rom (merge-pathnames #P"minimal_os.rom" dir)))
    (unless (probe-file rom)
      (format t "~&==> building minimal-xl OS (make -C ~A)~%" dir)
      (run-program-or-die (list "make" "-C" (namestring dir)) "minimal-xl make"))
    (unless (probe-file rom)
      (error "minimal-xl OS ROM still missing after build: ~A" rom))
    rom))

(defun assemble-edvent02 (root)
  "Assemble asm/edvent02.asm to asm/build/edvent02.xex with MADS via
scripts/mads-build.sh, so listing/label output and error handling stay
consistent with the rest of the project's asm workflow."
  (let* ((src (merge-pathnames #P"asm/edvent02.asm" root))
         (xex (merge-pathnames #P"asm/build/edvent02.xex" root))
         (builder (merge-pathnames #P"scripts/mads-build.sh" root)))
    (format t "~&==> assembling ~A~%" src)
    (run-program-or-die (list (namestring builder) (namestring src)) "mads-build.sh")
    (unless (probe-file xex)
      (error "expected XEX not found after build: ~A" xex))
    xex))

(defun start-edvent02 ()
  (let* ((root *root*)
         (os-rom (build-minimal-xl-os root))
         (xex    (assemble-edvent02 root)))

    (setf *machine* (atari800-cl:make-machine :os-rom os-rom))

    ;; Let the minimal-xl OS's own RESET routine run for a few frames before
    ;; we hijack the CPU.  edvent02.asm only points SDLSTL at its own
    ;; display list and never touches DMACTL itself -- it assumes, like any
    ;; program run from a normal Atari boot, that the OS has already turned
    ;; playfield DMA on (minimal_os.asm sets SDMCTL/DMACTL early in RESET,
    ;; well within one frame, long before its CIO/disk-boot code runs).
    ;; Skip this and DMACTL stays at its post-reset $00 (DMA off): ANTIC
    ;; never fetches any display list and the screen just shows background
    ;; color forever, however correct the rest of edvent02's state is.
    (dotimes (i 5)
      (atari800-cl.machine:machine-run-frame *machine*))

    (let* ((load-result (atari-xl-bbedit.xex:load-xex *machine* xex))
           (entry (atari-xl-bbedit.xex:xex-entry-point load-result))
           (cpu (atari800-cl.machine:atari-machine-cpu *machine*)))
      (setf (atari800-cl.cpu:cpu-halted cpu) nil)
      (setf (atari800-cl.cpu:cpu-pc cpu) entry)
      ;; We're yanking the CPU out of the OS's RESET routine mid-boot (it
      ;; was partway through its SIO disk-boot attempt during the warmup
      ;; above), which leaves two pieces of OS bookkeeping stuck as if that
      ;; attempt were still in progress: the I flag (interrupts disabled --
      ;; RESET does SEI at the very top and only CLIs once boot finishes)
      ;; and minimal_os.asm's CRITIC byte ($0042, set around the SIO call
      ;; and cleared after it returns).  minimal_os.asm's deferred VBI
      ;; stage -- which copies SDLSTL into the real DLISTL/DLISTH hardware
      ;; registers every frame -- explicitly skips itself whenever either
      ;; is set ("skipped when CRITIC is set or the interrupted code had
      ;; IRQs disabled").  Left stuck, edvent02's SDLSTL write would never
      ;; reach ANTIC: RTCLOK keeps ticking (the immediate stage is
      ;; unconditional) but the display list never changes, so the screen
      ;; stays on the OS's own boot banner forever.  Clear both, matching
      ;; the idle state a real boot reaches once it gives up on SIO.
      (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-i+)
      (atari800-cl.bus:bus-write (atari800-cl.machine:atari-machine-bus *machine*)
                                  #x0042 0)
      (format t "~&==> edvent02 loaded, entry $~4,'0X~%" entry))

    ;; START-MACHINE spawns the run-loop thread but leaves the machine
    ;; PAUSED (RUNNING-P NIL) -- it's normally a protocol client's RESUME
    ;; that flips this.  We have no client yet, so resume it ourselves via
    ;; MACHINE-SUBMIT (the only safe way to mutate the machine from this,
    ;; non-emulator, thread); otherwise the CPU never executes a single
    ;; instruction and no frames are ever rendered.
    (setf *runner* (atari800-cl:start-machine *machine*))
    (atari800-cl.machine:machine-submit
     *machine*
     (lambda (m) (setf (atari800-cl.machine:atari-machine-running-p m) t))
     :priority t)

    (setf *aesp-server* (atari800-cl:start-aesp-server *machine*))
    (setf *cli-server* (atari800-cl:start-cli-socket *machine*))

    (format t "~&=== atari800-cl running EdVenture video 2 (LispWorks IDE) ===~%")
    (format t "AESP control: 127.0.0.1:47800~%")
    (format t "AESP video:   127.0.0.1:47801~%")
    (format t "AESP audio:   127.0.0.1:47802~%")
    (format t "CLI socket:   ~A~%"
            (atari800-cl.cli-socket:cli-server-path *cli-server*))
    (format t "~&Type (atari800-cl-launch:stop-all) to shut down.~%")
    ;; Machine-readable sentinel: scripts/run-edvent02-lispworks.sh polls the
    ;; log for this exact line to know when it's safe to take a screenshot
    ;; and print the Attic launch instructions.
    (format t "~&EDVENT02_READY~%")
    (force-output)))

(defun start-edvent02/safe ()
  (handler-case (start-edvent02)
    (error (c)
      (format *error-output* "~&fatal: edvent02 bring-up failed: ~A~%" c)
      (force-output *error-output*))))

;; 4.  -init runs before the IDE has started multiprocessing (env:start-
;;     environment hasn't run yet), so a800:start-machine et al. would
;;     signal "Cannot create processes before multiprocessing is
;;     initialized" if called directly here.  Per the LispWorks manual's
;;     own recipe for this exact situation, push a process spec onto
;;     MP:*INITIAL-PROCESSES* instead of calling start-edvent02/safe now --
;;     the IDE's own startup calls MP:INITIALIZE-MULTIPROCESSING shortly
;;     after -init finishes, which spawns everything on *INITIAL-PROCESSES*
;;     once multiprocessing is actually available.
(push (list "edvent02-bringup" nil #'start-edvent02/safe)
      mp:*initial-processes*)
