;;;; src/ipc.lisp --- Optional headless IPC server.
;;;;
;;;; The emulator runs perfectly well without ever opening a socket —
;;;; this file is the OPTIONAL bridge that lets an external process
;;;; (typically a Python or Web renderer + audio player) consume the
;;;; machine's state in real time.
;;;;
;;;; Architecture:
;;;;   ipc-server-start spawns a background thread that:
;;;;     1. Creates a Unix-domain stream socket at SOCKET-PATH
;;;;     2. Accepts ONE client connection (blocking accept)
;;;;     3. Loops: run one frame on the attached machine, then
;;;;        serialize and push the resulting state down the socket.
;;;;
;;;; Wire protocol (56 bytes per frame, little-endian):
;;;;
;;;;   offset  size   field          notes
;;;;   ------  ----   -----          -----
;;;;     0      4     magic          "A8XL" (#x41 #x38 #x58 #x4C)
;;;;     4      4     frame-number   u32 little-endian
;;;;     8      2     scanline       u16 little-endian (0..261)
;;;;    10      6     reserved       all zeros for now
;;;;    16     32     gtia-writes    GTIA write-register array
;;;;                                 (HPOS / SIZE / GRAF / COL / PRIOR /…)
;;;;    48      4     pokey-audf     AUDF1..AUDF4
;;;;    52      4     pokey-audc     AUDC1..AUDC4
;;;;
;;;; Total: +IPC-FRAME-SIZE+ = 56 bytes.
;;;;
;;;; Portability:
;;;;   The transport is implemented with SB-BSD-SOCKETS on SBCL.
;;;;   On other implementations, IPC-SERVER-START signals an error so
;;;;   the optional layer fails loudly without taking down the rest of
;;;;   the emulator.  Threading uses BORDEAUX-THREADS (atari800-cl.compat).

;;; Load SBCL's Unix-socket contrib at compile/load time.  REQUIRE is a
;;; no-op if the module is already present.
#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets))

(in-package #:atari800-cl.ipc)

;;; ---------------------------------------------------------------------------
;;; Wire-protocol constants

(defparameter +ipc-magic+
  (let ((v (make-array 4 :element-type '(unsigned-byte 8))))
    (setf (aref v 0) #x41    ; 'A'
          (aref v 1) #x38    ; '8'
          (aref v 2) #x58    ; 'X'
          (aref v 3) #x4C)   ; 'L'
    v))

(defconstant +ipc-header-size+ 16)
(defconstant +ipc-gtia-size+   32)
(defconstant +ipc-audio-size+   8)
(defconstant +ipc-frame-size+  (+ +ipc-header-size+
                                  +ipc-gtia-size+
                                  +ipc-audio-size+))

;;; ---------------------------------------------------------------------------
;;; Server struct

(defstruct ipc-server
  "Handle returned by IPC-SERVER-START.

Slots:
  THREAD        — the background bordeaux-threads thread.
  LISTEN-SOCKET — server-side listening socket (sb-bsd-sockets object).
  SOCKET-PATH   — pathname of the Unix-domain socket file.
  STOP-FLAG     — set by IPC-SERVER-STOP to break the run-frame loop.
  MACHINE       — the ATARI-MACHINE the server is driving."
  thread
  listen-socket
  socket-path
  (stop-flag nil :type boolean)
  machine)

;;; ---------------------------------------------------------------------------
;;; Frame serialisation

(defun %encode-frame (machine buffer)
  "Fill BUFFER (a 56-byte u8 array) with one wire-format frame for MACHINE.
Returns BUFFER."
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer))
  (fill buffer 0)
  ;; Magic
  (dotimes (i 4)
    (setf (aref buffer i) (aref +ipc-magic+ i)))
  ;; Frame number (u32 LE)
  (let ((fn (atari800-cl.machine:atari-machine-frame-count machine)))
    (setf (aref buffer 4) (logand fn #xFF)
          (aref buffer 5) (logand (ash fn -8) #xFF)
          (aref buffer 6) (logand (ash fn -16) #xFF)
          (aref buffer 7) (logand (ash fn -24) #xFF)))
  ;; Scanline (u16 LE)
  (let ((s (atari800-cl.machine:machine-scanline machine)))
    (setf (aref buffer 8) (logand s #xFF)
          (aref buffer 9) (logand (ash s -8) #xFF)))
  ;; Reserved (offsets 10..15) — left as zero.
  ;; GTIA write-register array.
  (let ((gw (atari800-cl.gtia:gtia-write-regs
             (atari800-cl.machine:atari-machine-gtia machine))))
    (dotimes (i +ipc-gtia-size+)
      (setf (aref buffer (+ +ipc-header-size+ i)) (aref gw i))))
  ;; POKEY AUDF/AUDC arrays.
  (let* ((pk    (atari800-cl.machine:atari-machine-pokey machine))
         (audf  (atari800-cl.pokey:pokey-audf pk))
         (audc  (atari800-cl.pokey:pokey-audc pk))
         (base  (+ +ipc-header-size+ +ipc-gtia-size+)))
    (dotimes (i 4)
      (setf (aref buffer (+ base i))     (aref audf i)
            (aref buffer (+ base 4 i))   (aref audc i))))
  buffer)

(defun ipc-send-frame (connection machine)
  "Serialize MACHINE's current state into a +IPC-FRAME-SIZE+-byte payload
and write it through CONNECTION (an sb-bsd-sockets:local-socket)."
  #+sbcl
  (let ((buf (make-array +ipc-frame-size+ :element-type '(unsigned-byte 8))))
    (%encode-frame machine buf)
    (sb-bsd-sockets:socket-send connection buf +ipc-frame-size+))
  #-sbcl
  (error "IPC frame send is only implemented on SBCL in this build."))

;;; ---------------------------------------------------------------------------
;;; Server lifecycle

#+sbcl
(defun %make-listener (path)
  (let ((sock (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (when (probe-file path)
      (delete-file path))
    (sb-bsd-sockets:socket-bind sock (namestring path))
    (sb-bsd-sockets:socket-listen sock 1)
    sock))

#+sbcl
(defun %close-socket (sock)
  (when sock (ignore-errors (sb-bsd-sockets:socket-close sock))))

(defun ipc-server-start (machine socket-path)
  "Spawn a background thread that listens on SOCKET-PATH (a pathname or
namestring) and, after each accepted connection, runs MACHINE one frame
at a time and pushes the frame state out via IPC-SEND-FRAME.

Returns an IPC-SERVER handle.  Pass that handle to IPC-SERVER-STOP to
shut down."
  #+sbcl
  (let* ((path     (etypecase socket-path
                     (pathname (namestring socket-path))
                     (string socket-path)))
         (listener (%make-listener path))
         (server   (make-ipc-server :listen-socket listener
                                    :socket-path   path
                                    :machine       machine)))
    (setf (ipc-server-thread server)
          (make-thread
           (lambda ()
             (let ((client nil))
               (unwind-protect
                    (block server-body
                      ;; SOCKET-ACCEPT blocks until a client connects
                      ;; OR the listener is closed by IPC-SERVER-STOP.
                      (handler-case
                          (setf client (sb-bsd-sockets:socket-accept listener))
                        (error () (return-from server-body)))
                      (loop until (ipc-server-stop-flag server)
                            do (atari800-cl.machine:machine-run-frame
                                (ipc-server-machine server))
                               (handler-case
                                   (ipc-send-frame client
                                                   (ipc-server-machine server))
                                 (error () (loop-finish)))))
                 (%close-socket client))))
           :name "atari800-cl-ipc-server"))
    server)
  #-sbcl
  (declare (ignore machine socket-path))
  #-sbcl
  (error "IPC server is only implemented on SBCL in this build."))

(defun ipc-server-stop (server &key (timeout 2.0))
  "Signal SERVER to stop and wait up to TIMEOUT seconds for the thread to
exit.  Closes the listening socket (and removes the socket file).
Returns T if the thread exited cleanly; NIL on timeout."
  #+sbcl
  (let ((path (ipc-server-socket-path server))
        (thread (ipc-server-thread server)))
    (setf (ipc-server-stop-flag server) t)
    ;; Closing the listener unblocks accept().
    (%close-socket (ipc-server-listen-socket server))
    (setf (ipc-server-listen-socket server) nil)
    (let ((deadline (+ (get-internal-real-time)
                       (* timeout internal-time-units-per-second)))
          (exited nil))
      (loop while (and thread
                       (bt:thread-alive-p thread)
                       (< (get-internal-real-time) deadline))
            do (sleep 0.01))
      (setf exited (or (null thread)
                       (not (bt:thread-alive-p thread))))
      (when (and thread (bt:thread-alive-p thread))
        ;; Forcibly destroy if still hanging.
        (ignore-errors (bt:destroy-thread thread)))
      (when (and path (probe-file path))
        (ignore-errors (delete-file path)))
      exited))
  #-sbcl
  (declare (ignore server timeout))
  #-sbcl
  (error "IPC server is only implemented on SBCL in this build."))
