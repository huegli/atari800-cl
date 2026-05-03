;;;; src/compat.lisp --- Portability layer for LispWorks/SBCL.
;;;;
;;;; The emulator's core targets two implementations:
;;;;
;;;;   * LispWorks (primary) — used for development and packaged builds.
;;;;   * SBCL (secondary)    — used for CI and Linux deployment.
;;;;
;;;; Anywhere their APIs diverge, route the call through this file rather
;;;; than reaching for #+lispworks / #+sbcl in business logic.  The intent
;;;; is that src/cpu, src/memory, src/emulator, src/main contain *zero*
;;;; implementation-specific reader conditionals.

(in-package #:atari800-cl.compat)

;;; ---------------------------------------------------------------------------
;;; Implementation identification

(defparameter *implementation*
  #+lispworks :lispworks
  #+sbcl      :sbcl
  #-(or lispworks sbcl) :unknown
  "Keyword identifying the host Common Lisp implementation.")

(defun implementation-name ()
  "Return a human-readable string naming the host implementation."
  (format nil "~A ~A"
          (lisp-implementation-type)
          (lisp-implementation-version)))

;;; ---------------------------------------------------------------------------
;;; Numeric type aliases used throughout the emulator

(deftype u8  () '(unsigned-byte 8))
(deftype u16 () '(unsigned-byte 16))

(deftype byte-vector (&optional (length '*))
  `(simple-array (unsigned-byte 8) (,length)))

(declaim (inline make-byte-vector))
(defun make-byte-vector (length &key (initial-element 0))
  "Allocate a SIMPLE-ARRAY of (UNSIGNED-BYTE 8).
Both LispWorks and SBCL specialize this representation, but we go through
a single helper so callers never need to know the spelling."
  (make-array length
              :element-type '(unsigned-byte 8)
              :initial-element initial-element))

;;; ---------------------------------------------------------------------------
;;; Threading and locking
;;;
;;; bordeaux-threads provides the cross-implementation surface.  We re-export
;;; thin wrappers so emulator code can depend on :atari800-cl.compat instead
;;; of pulling in :bordeaux-threads everywhere.

(defun make-lock (&optional (name "atari800-cl-lock"))
  "Create a lock with NAME (passed through to bordeaux-threads)."
  (bordeaux-threads:make-lock name))

(defmacro with-lock ((lock) &body body)
  "Hold LOCK for the dynamic extent of BODY."
  `(bordeaux-threads:with-lock-held (,lock) ,@body))

(defun make-thread (function &key name)
  "Spawn a new thread running FUNCTION."
  (bordeaux-threads:make-thread function :name (or name "atari800-cl-thread")))

(defun join-thread (thread)
  "Wait for THREAD to finish."
  (bordeaux-threads:join-thread thread))

(defun current-thread ()
  "Return the current thread object."
  (bordeaux-threads:current-thread))

;;; ---------------------------------------------------------------------------
;;; Binary file I/O
;;;
;;; The path we want is "open in binary mode, read N bytes into a byte
;;; vector".  flexi-streams gives us a uniform spelling on both hosts.

(defun read-binary-file (pathname)
  "Read PATHNAME into a freshly allocated (UNSIGNED-BYTE 8) vector."
  (with-open-file (in pathname
                      :direction :input
                      :element-type '(unsigned-byte 8))
    (let* ((length (file-length in))
           (buf    (make-byte-vector length)))
      (read-sequence buf in)
      buf)))

(defun write-binary-file (pathname bytes)
  "Write BYTES (a sequence of (UNSIGNED-BYTE 8)) to PATHNAME."
  (with-open-file (out pathname
                       :direction :output
                       :element-type '(unsigned-byte 8)
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (write-sequence bytes out))
  pathname)

;;; ---------------------------------------------------------------------------
;;; Misc

(defmacro without-gc-warnings (&body body)
  "Execute BODY with implementation-specific GC chatter suppressed.
LispWorks and SBCL print different things during long-running emulator
loops; routing through here keeps the noise centralized."
  #+sbcl      `(let ((sb-ext:*muffled-warnings* 't)) ,@body)
  #+lispworks `(progn ,@body)        ; LispWorks is quiet by default
  #-(or sbcl lispworks) `(progn ,@body))
