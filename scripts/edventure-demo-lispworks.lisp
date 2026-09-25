;;;; scripts/edventure-demo-lispworks.lisp --- LispWorks driver for
;;;; scripts/edventure-demo.lisp.
;;;;
;;;; Invoked by scripts/edventure-demo.sh --impl lispworks via:
;;;;   lw-console -build scripts/edventure-demo-lispworks.lisp
;;;;
;;;; The demo itself is an `sbcl --script` top-level program.  Rather
;;;; than reimplement it here -- which would let the two implementations
;;;; drift and defeat the point of running identical emulator code on
;;;; both -- this driver LOADs the real demo, the same approach
;;;; scripts/dos-boot-demo-lispworks.lisp uses; see its header for the
;;;; two LispWorks-isms this works around:
;;;;
;;;;   1. Multiprocessing is not initialized before `-build` runs, and
;;;;      the AESP server's acceptor spawns processes.  A batch image
;;;;      otherwise signals "Cannot create processes before
;;;;      multiprocessing is initialized" -- the reason the demo is
;;;;      loaded inside MP:INITIALIZE-MULTIPROCESSING below.
;;;;
;;;;   2. The demo opens with (require :asdf).  LispWorks registers the
;;;;      module under a string name, so the keyword spelling would try
;;;;      to load it a second time; pushing both spellings onto *MODULES*
;;;;      first makes that call a no-op.
;;;;
;;;; The demo's optional positional branch argument is not reachable
;;;; here -- `-build` owns the command line, so sys:*line-arguments-list*
;;;; holds LispWorks's own arguments.  scripts/edventure-demo.sh
;;;; therefore passes a branch through $ATARI800_CL_EDVENTURE_BRANCH
;;;; instead, which the demo already checks as a fallback when no
;;;; positional argument is given.
;;;;
;;;; The demo's SIGINT/SIGTERM handlers (which delete its temp EdVenture
;;;; clone if the process is killed mid-boot, before the clone is
;;;; removed on the normal path) have a #+lispworks branch using
;;;; SYSTEM:SET-SIGNAL-HANDLER alongside the #+sbcl one; see that
;;;; branch's own comment in scripts/edventure-demo.lisp for the one
;;;; corner it does not cover (a signal arriving while the process is
;;;; still inside its initial mktemp/git-clone subprocess calls).

(require "asdf")
(dolist (module-name '("asdf" "ASDF"))
  (pushnew module-name *modules* :test #'string=))

(defun demo-pathname ()
  "Pathname of scripts/edventure-demo.lisp, resolved next to this file."
  (merge-pathnames "edventure-demo.lisp"
                   (uiop:pathname-directory-pathname *load-truename*)))

(defun run-edventure-demo ()
  "Load the demo as the initial multiprocessing process."
  (let ((demo (demo-pathname)))
    (unless (probe-file demo)
      (format *error-output* "fatal: demo not found: ~A~%" demo)
      (lispworks:quit :status 3))
    (load demo)))

;; Batch LispWorks does not init multiprocessing before -build runs; see
;; the header. The demo's AESP server spawns processes, so it must run
;; as the initial MP process.
(mp:initialize-multiprocessing "atari800-cl-edventure-demo" nil #'run-edventure-demo)
