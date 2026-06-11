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
  (require :sb-bsd-sockets))

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
  "Set the permission bits of PATHNAME to MODE (an integer, e.g. #o600)."
  (let ((ns (namestring pathname)))
    #+sbcl       (sb-posix:chmod ns mode)
    #+lispworks  (system:call-system (format nil "chmod ~o ~a" mode ns) :wait t)
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
