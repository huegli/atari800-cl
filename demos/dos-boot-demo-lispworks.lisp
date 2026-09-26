;;;; demos/dos-boot-demo-lispworks.lisp --- LispWorks driver for
;;;; demos/dos-boot-demo.lisp (Phase 25 visual verification).
;;;;
;;;; Invoked by demos/dos-boot-demo.sh --impl lispworks via:
;;;;   lw-console -build demos/dos-boot-demo-lispworks.lisp
;;;;
;;;; The demo itself is an `sbcl --script` top-level program.  Rather
;;;; than reimplement it here -- which would let the two implementations
;;;; drift and defeat the point of comparing their output -- this driver
;;;; LOADs the real demo, so both paths run byte-identical emulator code.
;;;; Two LispWorks-isms are all that stand in the way:
;;;;
;;;;   1. Multiprocessing is not initialized before `-build` runs, and
;;;;      the AESP server's acceptor spawns processes.  A batch image
;;;;      otherwise signals "Cannot create processes before
;;;;      multiprocessing is initialized" -- the same trap
;;;;      scripts/run-lispworks.lisp and scripts/test-lispworks.lisp hit,
;;;;      and the reason the demo is loaded inside
;;;;      MP:INITIALIZE-MULTIPROCESSING below.
;;;;
;;;;   2. The demo opens with (require :asdf).  LispWorks registers the
;;;;      module under a string name, so the keyword spelling would try
;;;;      to load it a second time; pushing both spellings onto *MODULES*
;;;;      first makes that call a no-op.
;;;;
;;;; The demo's optional positional ATR argument is not reachable here --
;;;; `-build` owns the command line, so sys:*line-arguments-list* holds
;;;; LispWorks's own arguments.  The shell driver therefore passes an ATR
;;;; path through $ATARI800_CL_DOS_ATR, which the demo already honors, so
;;;; both demos take an optional ATR the same way from the caller's side.

(require "asdf")
(dolist (module-name '("asdf" "ASDF"))
  (pushnew module-name *modules* :test #'string=))

(defun demo-pathname ()
  "Pathname of demos/dos-boot-demo.lisp, resolved next to this file."
  (merge-pathnames "dos-boot-demo.lisp"
                   (uiop:pathname-directory-pathname *load-truename*)))

(defun run-dos-boot-demo ()
  "Load the demo as the initial multiprocessing process."
  (let ((demo (demo-pathname)))
    (unless (probe-file demo)
      (format *error-output* "fatal: demo not found: ~A~%" demo)
      (lispworks:quit :status 3))
    (load demo)))

;; Batch LispWorks does not init multiprocessing before -build runs; see
;; the header.  The demo's AESP server spawns processes, so it must run
;; as the initial MP process.
(mp:initialize-multiprocessing "atari800-cl-dos-demo" nil #'run-dos-boot-demo)
