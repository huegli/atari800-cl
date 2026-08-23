;;;; src/compat.lisp --- Portability layer for LispWorks/SBCL.
;;;;
;;;; The emulator's core targets two implementations:
;;;;
;;;;   * LispWorks (primary) — used for development and packaged builds.
;;;;   * SBCL (secondary)    — used for CI and Linux deployment.
;;;;
;;;; Anywhere their APIs diverge, route the call through this file rather
;;;; than reaching for #+lispworks / #+sbcl in business logic.  The intent
;;;; is that all other source files (src/cpu, src/bus, src/machine,
;;;; src/main, …) contain *zero* implementation-specific reader
;;;; conditionals.
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

;;; On SBCL the POSIX + BSD-socket contribs are loaded on demand for the
;;; process/filesystem/Unix-socket helpers below.  REQUIRE is a no-op if a
;;; module is already present.
#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix)
  (require :sb-bsd-sockets)
  (require :sb-sprof))

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

(defun thread-alive-p (thread)
  "Return true if THREAD has not yet finished."
  (bordeaux-threads:thread-alive-p thread))

(defun destroy-thread (thread)
  "Forcibly terminate THREAD (last resort when a clean stop times out)."
  (ignore-errors (bordeaux-threads:destroy-thread thread)))

(defun current-thread ()
  "Return the current thread object."
  (bordeaux-threads:current-thread))

(defun make-condition-variable (&optional (name "atari800-cl-condvar"))
  "Create a condition variable with NAME (passed through to bordeaux-threads)."
  (bordeaux-threads:make-condition-variable :name name))

(defun condition-wait (condition-variable lock &key timeout)
  "Atomically release LOCK and wait on CONDITION-VARIABLE, re-acquiring LOCK
on wake.  Must be called with LOCK held.  With TIMEOUT (seconds), give up
after that long.  Returns NIL if it timed out, non-NIL otherwise."
  (bordeaux-threads:condition-wait condition-variable lock :timeout timeout))

(defun condition-notify (condition-variable)
  "Wake one thread waiting on CONDITION-VARIABLE."
  (bordeaux-threads:condition-notify condition-variable))

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
;;; Process / filesystem helpers
;;;
;;; Used by the socket-protocol servers (AESP / CLI): the CLI socket path
;;; embeds the PID, and the socket file is chmod'd to 0600.

#+lispworks
(fli:define-foreign-function (%getpid "getpid") () :result-type :int)

#+lispworks
(fli:define-foreign-function (%chmod "chmod")
    ((path (:reference-pass :ef-mb-string))
     (mode :int))
  :result-type :int)

(defun current-process-id ()
  "Return the current OS process id as an integer."
  #+sbcl       (sb-posix:getpid)
  #+lispworks  (%getpid)
  #-(or sbcl lispworks)
  (error "current-process-id: unsupported implementation"))

(defun delete-file-if-exists (pathname)
  "Delete PATHNAME if it exists.  Return T if a file was removed, else NIL."
  (when (probe-file pathname)
    (delete-file pathname)
    t))

(defun chmod-file (pathname mode)
  "Set the permission bits of PATHNAME to MODE (an integer, e.g. #o600).
Returns the namestring of PATHNAME.  Signals an error if the underlying
chmod(2) call fails (non-zero return)."
  (let ((ns (namestring pathname)))
    #+sbcl       (sb-posix:chmod ns mode)
    #+lispworks  (let ((result (%chmod ns mode)))
                   (unless (zerop result)
                     (error "chmod-file: chmod(2) failed for ~A (mode #o~O)" ns mode)))
    #-(or sbcl lispworks)
    (error "chmod-file: unsupported implementation")
    ns))

;;; ---------------------------------------------------------------------------
;;; Unix-domain stream sockets
;;;
;;; usocket (0.8.x) has NO local-socket support, so these are implemented
;;; per-implementation (verified end-to-end on both, 2026-06-08):
;;;   * SBCL       — sb-bsd-sockets:local-socket.
;;;   * LispWorks  — an FLI wrapper around libc socket(AF_UNIX,…)/bind/
;;;                  listen/accept/connect, with the accepted fd wrapped in
;;;                  a COMM:SOCKET-STREAM.
;;;
;;; ACCEPT-UNIX-CLIENT / OPEN-UNIX-CLIENT return a bidirectional character
;;; stream (the CLI line protocol is text); closing the stream closes the
;;; connection.

(defstruct (unix-listener (:constructor %make-unix-listener))
  "Opaque handle for a bound, listening Unix-domain socket.
HANDLE is implementation-specific (an SB-BSD-SOCKETS socket on SBCL, a raw
integer fd on LispWorks); PATH is the filesystem path it is bound to."
  handle
  (path "" :type string))

#+lispworks
(progn
  ;; libc entry points (resolved from libSystem / libc of the running host).
  (fli:define-foreign-function (%c-socket "socket")
      ((domain :int) (type :int) (protocol :int)) :result-type :int)
  (fli:define-foreign-function (%c-bind "bind")
      ((fd :int) (addr (:pointer (:unsigned :byte))) (len :int)) :result-type :int)
  (fli:define-foreign-function (%c-listen "listen")
      ((fd :int) (backlog :int)) :result-type :int)
  (fli:define-foreign-function (%c-accept "accept")
      ((fd :int) (addr (:pointer :void)) (len (:pointer :int))) :result-type :int)
  (fli:define-foreign-function (%c-connect "connect")
      ((fd :int) (addr (:pointer (:unsigned :byte))) (len :int)) :result-type :int)
  (fli:define-foreign-function (%c-close "close")
      ((fd :int)) :result-type :int)

  (defconstant +af-unix+     1)         ; AF_UNIX (same value on Darwin + Linux)
  (defconstant +sock-stream+ 1)

  (defun %fill-sockaddr-un (buf path)
    "Fill a sockaddr_un at BUF (a >=110-byte foreign buffer).  Return the
addrlen to pass to bind/connect.  The layout differs by platform: Darwin
has a leading 1-byte SUN_LEN then a 1-byte family; Linux has a 2-byte
family and no SUN_LEN.  Either way the path starts at offset 2 and addrlen
= 2 + strlen(path)."
    (let* ((bytes (map 'list #'char-code path))
           (plen  (length bytes)))
      (dotimes (i 110) (setf (fli:dereference buf :index i) 0))
      #+darwin
      (setf (fli:dereference buf :index 0) (+ 2 plen)   ; sun_len
            (fli:dereference buf :index 1) +af-unix+)   ; sun_family (1 byte)
      #-darwin
      (setf (fli:dereference buf :index 0) +af-unix+    ; sun_family low byte
            (fli:dereference buf :index 1) 0)           ; sun_family high byte
      (loop for b in bytes for i from 2 do (setf (fli:dereference buf :index i) b))
      (+ 2 plen)))

  (defun %unix-socket ()
    (let ((fd (%c-socket +af-unix+ +sock-stream+ 0)))
      (when (< fd 0) (error "socket(AF_UNIX) failed"))
      fd))

  (defun %unix-bind (fd path)
    (fli:with-dynamic-foreign-objects ()
      (let* ((buf  (fli:allocate-dynamic-foreign-object
                    :type '(:unsigned :byte) :nelems 110))
             (alen (%fill-sockaddr-un buf path)))
        (when (< (%c-bind fd buf alen) 0)
          (error "bind(~A) failed" path)))))

  (defun %unix-connect (fd path)
    (fli:with-dynamic-foreign-objects ()
      (let* ((buf  (fli:allocate-dynamic-foreign-object
                    :type '(:unsigned :byte) :nelems 110))
             (alen (%fill-sockaddr-un buf path)))
        (when (< (%c-connect fd buf alen) 0)
          (error "connect(~A) failed" path)))))

  (defun %unix-accept (fd)
    (let ((cfd (%c-accept fd (fli:make-pointer :address 0 :type :void)
                          (fli:make-pointer :address 0 :type :int))))
      (when (< cfd 0) (error "accept() failed"))
      cfd))

  (defun %fd->stream (fd)
    (make-instance 'comm:socket-stream :socket fd :direction :io
                                       :element-type 'base-char)))

(defun open-unix-listener (path &key (backlog 4))
  "Create, bind, and listen on a Unix-domain stream socket at PATH.
Any pre-existing file at PATH is removed first.  Returns a UNIX-LISTENER."
  (let ((ns (namestring path)))
    (delete-file-if-exists ns)
    #+sbcl
    (let ((s (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (sb-bsd-sockets:socket-bind s ns)
      (sb-bsd-sockets:socket-listen s backlog)
      (%make-unix-listener :handle s :path ns))
    #+lispworks
    (let ((fd (%unix-socket)))
      (%unix-bind fd ns)
      (when (< (%c-listen fd backlog) 0) (error "listen() failed"))
      (%make-unix-listener :handle fd :path ns))
    #-(or sbcl lispworks)
    (error "open-unix-listener: unsupported implementation")))

(defun accept-unix-client (listener)
  "Block until a client connects to LISTENER; return a bidirectional
character stream for the accepted connection."
  #+sbcl
  (let ((c (sb-bsd-sockets:socket-accept (unix-listener-handle listener))))
    (sb-bsd-sockets:socket-make-stream c :input t :output t
                                         :element-type 'character
                                         :buffering :none))
  #+lispworks
  (%fd->stream (%unix-accept (unix-listener-handle listener)))
  #-(or sbcl lispworks)
  (error "accept-unix-client: unsupported implementation"))

(defun open-unix-client (path)
  "Connect to a Unix-domain listener at PATH; return a bidirectional
character stream for the connection."
  (let ((ns (namestring path)))
    #+sbcl
    (let ((c (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (sb-bsd-sockets:socket-connect c ns)
      (sb-bsd-sockets:socket-make-stream c :input t :output t
                                           :element-type 'character
                                           :buffering :none))
    #+lispworks
    (let ((fd (%unix-socket)))
      (%unix-connect fd ns)
      (%fd->stream fd))
    #-(or sbcl lispworks)
    (error "open-unix-client: unsupported implementation")))

(defun close-unix-listener (listener)
  "Close LISTENER and unlink its socket file.  Returns NIL."
  #+sbcl       (sb-bsd-sockets:socket-close (unix-listener-handle listener))
  #+lispworks  (%c-close (unix-listener-handle listener))
  (delete-file-if-exists (unix-listener-path listener))
  nil)

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

;;; ---------------------------------------------------------------------------
;;; Statistical profiling (PERFORMANCE_PLAN.md Phase 4 step 1 / ROADMAP.md
;;; Phase 18)
;;;
;;; WITH-PROFILING is the ONE place a profiling pass is allowed to reach for
;;; an implementation-specific profiler; everywhere else in the tree calls
;;; this macro instead of naming SB-SPROF or HCL directly.
;;;
;;; SBCL routes straight to SB-SPROF, a statistical (signal-driven) sampling
;;; profiler that supports both :CPU and :ALLOC sampling natively.
;;;
;;; LispWorks routes to HCL:START-PROFILING / HCL:STOP-PROFILING, the same
;;; entry points behind the IDE's "Profile" command (HCL:PROFILE macroexpands
;;; to a bare wrapper around SYSTEM::WITH-PROFILING with no keyword options at
;;; all, so calling START-/STOP-PROFILING directly is the only way to control
;;; where the report is printed and to unwind-protect it around BODY).
;;; MODE is accepted-and-ignored on this branch: probing
;;; HCL:SET-UP-PROFILER's :KIND :ALLOCATION option while developing this
;;; helper (LispWorks 8.1.1, Darwin/arm64 console image) crashed the image
;;; outright -- a segfault inside the GC sweep -- so only the default
;;; statistical call/time sampler is used, regardless of MODE.

#+sbcl
(defun %sbcl-with-profiling (thunk mode)
  "Run THUNK under SB-SPROF statistical profiling in MODE (:CPU, :ALLOC, or
:TIME -- forwarded verbatim to SB-SPROF:START-PROFILING's :MODE argument),
printing a flat report to *STANDARD-OUTPUT* once profiling stops.  Both the
STOP-PROFILING call and the REPORT attempt are inside THUNK's
UNWIND-PROTECT cleanup, so they still run if THUNK signals; the signalled
condition then propagates normally (THUNK's values are only returned on a
normal return, per UNWIND-PROTECT semantics).  A ~5ms sample interval and a
generous 100000-sample cap are sensible defaults for the few-second
benchmark workloads this helper is meant for -- short runs never hit the
cap, and 5ms resolves plenty of detail without dominating a short run's
own sample count."
  (sb-sprof:start-profiling :mode mode
                             :sample-interval 0.005
                             :max-samples 100000
                             :threads :all)
  (unwind-protect
       (funcall thunk)
    (sb-sprof:stop-profiling)
    ;; REPORT itself stops profiling too (harmless double-stop) and prints
    ;; nothing useful if THUNK never got a chance to run -- IGNORE-ERRORS
    ;; keeps a reporting hiccup from masking THUNK's own condition.
    (ignore-errors (sb-sprof:report :type :flat :stream *standard-output*))))

#+lispworks
(defun %lispworks-with-profiling (thunk mode)
  "Run THUNK under HCL:START-PROFILING / HCL:STOP-PROFILING, printing a flat
report to *STANDARD-OUTPUT* once profiling stops.  MODE is accepted for
signature parity with the SBCL branch of WITH-PROFILING but ignored --
see the section comment above for why.  STOP-PROFILING is inside THUNK's
UNWIND-PROTECT cleanup, so it still runs if THUNK signals; the signalled
condition then propagates normally.

If HCL:START-PROFILING itself errors (e.g. a delivered application image
built without the profiler system loaded), THUNK's set-up never ran, so
there is nothing to unwind: this degrades to a no-op that runs THUNK
unprofiled and emits a WARNING explaining why, per PERFORMANCE_PLAN.md
Phase 4 step 1's sanctioned fallback."
  (declare (ignore mode))
  (if (handler-case (progn (hcl:start-profiling) t)
        (error (e)
          (warn "atari800-cl.compat: LispWorks profiler unavailable (~A); running body unprofiled." e)
          nil))
      (unwind-protect
           (funcall thunk)
        (ignore-errors (hcl:stop-profiling :print t :stream *standard-output*)))
      (funcall thunk)))

(defmacro with-profiling ((&key (mode :cpu)) &body body)
  "Run BODY under a statistical profiler appropriate to the host Lisp,
printing a flat profile report to *STANDARD-OUTPUT* once profiling stops,
and returning BODY's values on a normal return.  This is the ONE compat
entry point PERFORMANCE_PLAN.md Phase 4 / ROADMAP.md Phase 18's profiling
pass is meant to use; no other file should reach for SB-SPROF or HCL
directly.

MODE selects the sampling kind:
  :CPU    -- CPU-time sampling.  The default; supported on both hosts.
  :ALLOC  -- allocation-based sampling.  Fully supported on SBCL
             (forwarded to SB-SPROF:START-PROFILING's :MODE).  On
             LispWorks, MODE is accepted but IGNORED -- this helper
             always profiles with the default statistical sampler
             regardless of what is passed, because the LispWorks entry
             point that exposes an allocation-kind switch
             (HCL:SET-UP-PROFILER :KIND :ALLOCATION) crashed the
             console image this helper was developed against.
  :TIME   -- wall-clock sampling.  SBCL only; forwarded like :ALLOC.

Set-up/tear-down is UNWIND-PROTECTed around BODY on both implementations,
so profiling is always stopped -- and, where the underlying API allows it,
the report is always attempted -- even if BODY signals; the condition
itself still propagates normally afterward.

  * SBCL: wraps SB-SPROF:START-PROFILING / STOP-PROFILING / REPORT
    (:TYPE :FLAT) around BODY.  SB-SPROF is REQUIREd near the top of this
    file.
  * LispWorks: wraps HCL:START-PROFILING / HCL:STOP-PROFILING around
    BODY.  If the profiler is unavailable in this image, degrades to a
    no-op that runs BODY and signals a WARNING explaining why."
  #+sbcl
  `(%sbcl-with-profiling (lambda () ,@body) ,mode)
  #+lispworks
  `(%lispworks-with-profiling (lambda () ,@body) ,mode)
  #-(or sbcl lispworks)
  `(progn
     (warn "atari800-cl.compat: WITH-PROFILING has no profiler implementation for ~A; running BODY unprofiled."
           (lisp-implementation-type))
     ,@body))

;;; ---------------------------------------------------------------------------
;;; FAST-AREF -- a scoped, auditable (safety 0) array access
;;; (PERFORMANCE_PLAN.md's carve-out; ROADMAP.md Phase 26)
;;;
;;; Phase 18's profiling pass found that on LispWorks 8.1.1 (ARM64), every
;;; checked array access -- no matter how precisely its element type and
;;; dimensions are declared -- compiles to an out-of-line SYSTEM::AREF1 /
;;; SET-AREF1 call at (safety 1); only (safety 0) gets LispWorks to inline
;;; the access. SBCL's ARM64 backend already inlines the identical
;;; bounds-checked access at (safety 1), so SBCL never needs the trapdoor.
;;;
;;; FAST-AREF is that trapdoor, narrowed as far as it can go: it is a
;;; single macro, defined only here, and its unchecked form is only ever
;;; reached on LispWorks. Everywhere else in the tree -- SBCL entirely,
;;; and LispWorks under ATARI800_CL_CHECKED_AREF -- FAST-AREF expands to
;;; the exact same checked (AREF (THE type array) index) form a caller
;;; would have written by hand. Nothing about FAST-AREF changes what gets
;;; modelled; it only changes how one array read/write is compiled.
;;;
;;; %CHECKED-AREF-P below is called at macroexpansion time, i.e. compile
;;; time -- not at run time -- so the choice between the checked and
;;; unchecked expansion is baked into the fasl. That is exactly why the
;;; fasl-cache directory matters: ASDF decides whether to recompile a file
;;; by comparing source/fasl timestamps, never by diffing environment
;;; variables, so a checked (ATARI800_CL_CHECKED_AREF=1) run launched
;;; after an ordinary run would silently reuse the *unchecked* fasls it
;;; finds sitting in .cache/fasls/ and prove nothing. scripts/test-
;;; lispworks.lisp (and, for symmetry, scripts/test-sbcl.sh) route
;;; ATARI800_CL_CHECKED_AREF runs to a separate .cache/fasls-checked/
;;; output-translation directory instead, so a checked run always starts
;;; from a from-scratch compile and can never observe a stale unchecked
;;; fasl.

(defun %checked-aref-env-value ()
  "Return the value of the ATARI800_CL_CHECKED_AREF environment variable as
a string, or NIL if it is unset. Read at macroexpansion (i.e. compile)
time by FAST-AREF and its SETF expander -- never at run time -- so the
checked/unchecked decision is fixed when the fasl is produced. See the
section comment above for why that makes the output-translation cache
directory part of this mechanism's contract, not an implementation detail."
  #+sbcl       (sb-ext:posix-getenv "ATARI800_CL_CHECKED_AREF")
  #+lispworks  (lispworks:environment-variable "ATARI800_CL_CHECKED_AREF")
  #-(or sbcl lispworks) (uiop:getenv "ATARI800_CL_CHECKED_AREF"))

(defun %checked-aref-p ()
  "True when ATARI800_CL_CHECKED_AREF is set to a non-empty string. On
LispWorks this forces FAST-AREF's normally-unchecked expansion back to the
fully checked (AREF (THE type array) index) form used on SBCL -- the audit
switch a checked LispWorks build is one env var (and one from-scratch
recompile; see above) away from."
  (let ((v (%checked-aref-env-value)))
    (and v (plusp (length v)))))

(defun %fast-aref-read-form (type array index)
  "Return the form (FAST-AREF TYPE ARRAY INDEX) expands to, given already-
evaluated (or safely re-evaluable) ARRAY and INDEX forms. Shared by the
FAST-AREF macro and its SETF expander so the read path and the write
path's read-modify never disagree about which expansion is in effect."
  (let ((checked-form `(aref (the ,type ,array) ,index)))
    #+sbcl
    checked-form
    #+lispworks
    (if (%checked-aref-p)
        checked-form
        ;; The one (safety 0) site in the whole tree. SPEED 3 is what
        ;; actually gets LispWorks to inline AREF1 instead of calling out
        ;; to SYSTEM::AREF1; SAFETY 0 is what lets it skip the bounds
        ;; check that call performs. DEBUG is deliberately left at the
        ;; file's ambient policy ("debug per file" in the ROADMAP text)
        ;; rather than pinned here.
        `(locally (declare (optimize (safety 0) (speed 3)))
           (aref (the ,type ,array) (the fixnum ,index))))
    #-(or sbcl lispworks)
    checked-form))

(defun %fast-aref-write-form (type array index value)
  "Return the form (SETF (FAST-AREF TYPE ARRAY INDEX) VALUE) expands to,
given already-evaluated (or safely re-evaluable) ARRAY, INDEX, and VALUE
forms. Mirrors %FAST-AREF-READ-FORM's checked/unchecked decision exactly;
see its docstring."
  (let ((checked-form `(setf (aref (the ,type ,array) ,index) ,value)))
    #+sbcl
    checked-form
    #+lispworks
    (if (%checked-aref-p)
        checked-form
        `(locally (declare (optimize (safety 0) (speed 3)))
           (setf (aref (the ,type ,array) (the fixnum ,index)) ,value)))
    #-(or sbcl lispworks)
    checked-form))

(defmacro fast-aref (type array index)
  "Read ARRAY at INDEX, asserting ARRAY is of the literal array TYPE (e.g.
(SIMPLE-ARRAY FIXNUM (4))). (SETF FAST-AREF) is also defined, so
`(setf (fast-aref type array index) v)` works and, like SETF of AREF,
returns V.

CONTRACT -- read this before writing a call site: a FAST-AREF call site
MUST make INDEX provably in range *by construction*, independent of
whatever bounds check this macro may or may not perform underneath it --
e.g. masked with LOGAND against the array's size, bounded by a LOOP whose
trip count is the array's LENGTH, or typed to exactly the array's
dimension. The call site MUST carry a one-line comment naming that proof
(\"index masked to 4 slots\", \"loop bound is (length buf)\", etc.). An
access that cannot state its proof in one line stays plain AREF -- do not
reach for FAST-AREF just because a loop is hot.

The two hosts this project targets need this guarantee to different
degrees, which is exactly what makes it worth stating explicitly rather
than trusting the compiler:

  * SBCL: FAST-AREF expands to (AREF (THE type array) index) -- fully
    bounds-checked, unchanged semantics. SBCL's ARM64 backend already
    inlines this at the project's (safety 1) floor, so on SBCL the macro
    is an identity in both semantics and performance; SBCL never sees the
    unchecked expansion described below.

  * LispWorks: FAST-AREF expands to the same access wrapped in
    (locally (declare (optimize (safety 0) (speed 3))) ...), with both
    ARRAY and INDEX THE-asserted -- ARRAY to TYPE, INDEX to FIXNUM. This
    is the ONLY place in the codebase (safety 0) is allowed to appear
    (PERFORMANCE_PLAN.md's floor is (safety 1) everywhere else, on both
    hosts); it exists because LispWorks 8.1.1's ARM64 backend only
    inlines AREF/SET-AREF1 at (safety 0), routing every (safety 1) access
    through an out-of-line generic dispatch call regardless of how
    precisely the array is typed (ROADMAP.md Phase 26, following the
    Phase 18 profiling pass). Getting this wrong at a call site that
    cannot actually prove its index in range is a real out-of-bounds
    write, not a slowdown -- hence the contract above.

CHECKED MODE -- the audit switch: with the environment variable
ATARI800_CL_CHECKED_AREF set to any non-empty string AT COMPILE
(macroexpansion) TIME, the LispWorks expansion becomes identical to the
SBCL one (fully checked) -- i.e. a checked LispWorks build is one env var
away. Because the checked/unchecked choice is baked into the fasl at
compile time, not read at run time, ASDF's ordinary timestamp-based
recompilation will NOT pick up a change to this env var by itself: a
checked run launched after an ordinary run would silently reuse
already-compiled unchecked fasls and prove nothing. scripts/test-
lispworks.lisp (and scripts/test-sbcl.sh, for symmetry, though SBCL is
always fully checked) route ATARI800_CL_CHECKED_AREF runs to a separate
.cache/fasls-checked/ ASDF output-translation directory instead of the
default .cache/fasls/, guaranteeing a from-scratch recompile every time
the switch is set."
  (%fast-aref-read-form type array index))

(define-setf-expander fast-aref (type array index &environment env)
  "SETF expansion for FAST-AREF -- see FAST-AREF's docstring for the full
contract. Evaluates ARRAY and INDEX exactly once each (bound to fresh
temporaries) regardless of how many times the underlying access form
mentions them, matching ordinary SETF-of-AREF evaluation semantics; the
stored value, like SETF of AREF, is the expansion's result."
  (declare (ignore env))
  (let ((array-var (gensym "FAST-AREF-ARRAY"))
        (index-var (gensym "FAST-AREF-INDEX"))
        (store-var (gensym "FAST-AREF-VALUE")))
    (values
     (list array-var index-var)
     (list array index)
     (list store-var)
     (%fast-aref-write-form type array-var index-var store-var)
     (%fast-aref-read-form type array-var index-var))))
