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
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; IN-PACKAGE sets the current package (namespace) so that every symbol
;;;; defined below belongs to that package.
;;;;
;;;; DEFPARAMETER creates a global "special" (dynamically scoped) variable.
;;;; By convention, special variables are surrounded by *earmuffs*.
;;;;
;;;; DEFUN defines a function.  DEFMACRO defines a macro, which rewrites
;;;; code at compile time (like a code template).
;;;;
;;;; DEFTYPE defines a named type alias that the compiler can use for
;;;; optimisation and that the programmer can use in DECLARE forms.
;;;;
;;;; DECLAIM issues a global declaration (e.g. INLINE) that the compiler
;;;; can use to optimise calls across the entire file.
;;;;
;;;; Reader conditionals (#+feature / #-feature) are evaluated at *read*
;;;; time: the Lisp reader skips or includes the next form depending on
;;;; whether the named feature is present in *FEATURES*.  For example,
;;;; #+sbcl means "include this form only when running on SBCL".
;;;; #-(or lispworks sbcl) means "include only if NEITHER is present".

(in-package #:atari800-cl.compat)

;;; ---------------------------------------------------------------------------
;;; Implementation identification
;;;
;;; *IMPLEMENTATION* is set once at load time using reader conditionals.
;;; Only one branch survives: the Lisp reader sees #+lispworks and, if it
;;; is running on LispWorks, reads :lispworks; otherwise it skips to the
;;; next branch.

(defparameter *implementation*
  #+lispworks :lispworks
  #+sbcl      :sbcl
  #-(or lispworks sbcl) :unknown
  "Keyword identifying the host Common Lisp implementation.")

(defun implementation-name ()
  "Return a human-readable string naming the host implementation."
  ;; FORMAT builds a string: ~A inserts an argument in human-readable form.
  ;; LISP-IMPLEMENTATION-TYPE and -VERSION are standard CL functions.
  (format nil "~A ~A"
          (lisp-implementation-type)
          (lisp-implementation-version)))

;;; ---------------------------------------------------------------------------
;;; Numeric type aliases used throughout the emulator
;;;
;;; DEFTYPE creates a named type abbreviation.  (UNSIGNED-BYTE 8) is CL's
;;; built-in type for integers 0–255; we call it U8 for brevity.  Similarly,
;;; (UNSIGNED-BYTE 16) covers 0–65535 and we call it U16.
;;;
;;; BYTE-VECTOR is a type for one-dimensional arrays of U8 values.
;;; SIMPLE-ARRAY means a non-adjustable, non-displaced array — the most
;;; efficient representation on both LispWorks and SBCL.
;;; The optional LENGTH parameter lets callers specify the exact size, but
;;; defaults to '* which means "any length".

(deftype u8  () '(unsigned-byte 8))
(deftype u16 () '(unsigned-byte 16))

(deftype byte-vector (&optional (length '*))
  ;; The backquote (`) builds a list template; the comma (,) inserts a
  ;; computed value.  So this expands to, e.g., (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (1024)).
  `(simple-array (unsigned-byte 8) (,length)))

;; DECLAIM INLINE tells the compiler it may copy this function's body into
;; each call site instead of doing a function call, which avoids the overhead
;; of a function call for small, frequently called functions.
(declaim (inline make-byte-vector))

(defun make-byte-vector (length &key (initial-element 0))
  "Allocate a SIMPLE-ARRAY of (UNSIGNED-BYTE 8).
Both LispWorks and SBCL specialize this representation, but we go through
a single helper so callers never need to know the spelling."
  ;; MAKE-ARRAY is CL's array constructor.  :ELEMENT-TYPE tells the
  ;; implementation to use a compact packed representation of bytes rather
  ;; than a general array of Lisp objects.  :INITIAL-ELEMENT fills every
  ;; slot with the given value (0 by default).
  (make-array length
              :element-type '(unsigned-byte 8)
              :initial-element initial-element))

;;; ---------------------------------------------------------------------------
;;; Threading and locking
;;;
;;; bordeaux-threads is a widely used Common Lisp library that provides a
;;; uniform threading API across implementations.  We re-export thin
;;; wrappers so emulator code can depend on :atari800-cl.compat instead
;;; of pulling in :bordeaux-threads everywhere.
;;;
;;; The PACKAGE:SYMBOL syntax (e.g. bordeaux-threads:make-lock) accesses
;;; an exported symbol from another package.

(defun make-lock (&optional (name "atari800-cl-lock"))
  "Create a lock with NAME (passed through to bordeaux-threads)."
  ;; &OPTIONAL means the parameter can be omitted; if so, NAME defaults
  ;; to the string "atari800-cl-lock".
  (bordeaux-threads:make-lock name))

(defmacro with-lock ((lock) &body body)
  "Hold LOCK for the dynamic extent of BODY."
  ;; DEFMACRO defines a compile-time code transformation.  The backquote
  ;; template below produces code that calls bordeaux-threads:with-lock-held.
  ;; ,LOCK inserts the caller's lock expression; ,@BODY splices in the
  ;; caller's body forms.  &BODY is like &REST but tells the editor to
  ;; indent the forms as a block.
  `(bordeaux-threads:with-lock-held (,lock) ,@body))

(defun make-thread (function &key name)
  "Spawn a new thread running FUNCTION."
  ;; &KEY declares a keyword argument: callers write (make-thread fn :name "foo").
  ;; OR returns its first non-NIL argument, so (or name "...") provides a default.
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
;;; vector".  Plain WITH-OPEN-FILE with an (UNSIGNED-BYTE 8) element type
;;; gives us a uniform spelling on both hosts.

(defun read-binary-file (pathname)
  "Read PATHNAME into a freshly allocated (UNSIGNED-BYTE 8) vector."
  ;; WITH-OPEN-FILE opens a file, binds the stream to a variable (IN),
  ;; executes the body, and guarantees the file is closed afterwards —
  ;; even if an error is signalled.  It is the CL equivalent of a
  ;; try-with-resources / context-manager pattern.
  ;;
  ;; :ELEMENT-TYPE '(UNSIGNED-BYTE 8) opens the file in binary mode so
  ;; that READ-SEQUENCE fills a byte vector directly.
  (with-open-file (in pathname
                      :direction :input
                      :element-type '(unsigned-byte 8))
    ;; LET* is like LET but each binding can refer to earlier ones.
    ;; FILE-LENGTH returns the file size in bytes (since the element-type
    ;; is a single byte).
    (let* ((length (file-length in))
           (buf    (make-byte-vector length)))
      ;; READ-SEQUENCE fills BUF from the stream and returns the number
      ;; of elements actually read.
      (read-sequence buf in)
      buf)))

(defun write-binary-file (pathname bytes)
  "Write BYTES (a sequence of (UNSIGNED-BYTE 8)) to PATHNAME."
  ;; :IF-EXISTS :SUPERSEDE means overwrite any existing file.
  ;; :IF-DOES-NOT-EXIST :CREATE creates it if missing.
  (with-open-file (out pathname
                       :direction :output
                       :element-type '(unsigned-byte 8)
                       :if-exists :supersede
                       :if-does-not-exist :create)
    (write-sequence bytes out))
  ;; Returning PATHNAME lets callers chain: (read-binary-file (write-binary-file ...)).
  pathname)

;;; ---------------------------------------------------------------------------
;;; Misc

(defmacro without-gc-warnings (&body body)
  "Execute BODY with implementation-specific GC chatter suppressed.
LispWorks and SBCL print different things during long-running emulator
loops; routing through here keeps the noise centralized."
  ;; This macro uses reader conditionals at *macro definition* time.
  ;; Only the branch matching the current implementation is compiled.
  ;; PROGN groups multiple forms into one; it simply executes them in order.
  #+sbcl      `(let ((sb-ext:*muffled-warnings* t)) ,@body)
  #+lispworks `(progn ,@body)        ; LispWorks is quiet by default
  #-(or sbcl lispworks) `(progn ,@body))
