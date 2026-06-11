;;;; src/transport.lisp --- Socket transport for the protocol servers.
;;;;
;;;; A thin layer the AESP and CLI servers build on:
;;;;
;;;;   * TCP (AESP) — via usocket, which is portable across SBCL and
;;;;     LispWorks.  Streams are binary ((unsigned-byte 8)) because AESP is
;;;;     a binary protocol.
;;;;   * Unix-domain (CLI) — usocket has NO local-socket support, so these
;;;;     delegate to the per-implementation helpers in :atari800-cl.compat
;;;;     (sb-bsd-sockets / LispWorks FLI).  The CLI line protocol is text,
;;;;     so those streams are character streams.
;;;;
;;;; Keeping both behind one package means the servers never reach for
;;;; usocket or compat socket primitives directly.

(in-package #:atari800-cl.transport)

;;; ---------------------------------------------------------------------------
;;; TCP (binary)

(defun tcp-listen (host port &key (reuse-address t) (backlog 8))
  "Open a binary TCP listener bound to HOST:PORT.  PORT 0 asks the OS for an
ephemeral port (see TCP-LISTENER-PORT).  Returns a usocket listener."
  (usocket:socket-listen host port
                         :reuse-address reuse-address
                         :backlog backlog
                         :element-type '(unsigned-byte 8)))

(defun tcp-listener-port (listener)
  "Return the local port LISTENER is bound to (useful after binding port 0)."
  (usocket:get-local-port listener))

(defun tcp-accept (listener)
  "Block until a client connects to LISTENER; return a usocket connection
whose stream is binary.  Signals on a closed listener (used to unblock)."
  (usocket:socket-accept listener :element-type '(unsigned-byte 8)))

(defun tcp-connect (host port)
  "Open a binary TCP client connection to HOST:PORT.  Returns a usocket
connection (used by tests and any client code)."
  (usocket:socket-connect host port :element-type '(unsigned-byte 8)))

(defun tcp-stream (connection)
  "Return the bidirectional binary stream of a usocket CONNECTION."
  (usocket:socket-stream connection))

(defun tcp-close (socket)
  "Close SOCKET (a usocket listener or connection).  Never errors."
  (when socket (ignore-errors (usocket:socket-close socket)))
  nil)

;;; ---------------------------------------------------------------------------
;;; Unix-domain (text) — delegates to :atari800-cl.compat

(defun unix-listen (path &key (backlog 4))
  "Open a Unix-domain listener at PATH (text streams).  Returns a
COMPAT:UNIX-LISTENER."
  (open-unix-listener path :backlog backlog))

(defun unix-accept (listener)
  "Block until a client connects to a Unix-domain LISTENER; return a
bidirectional character stream."
  (accept-unix-client listener))

(defun unix-connect (path)
  "Connect to a Unix-domain listener at PATH; return a character stream."
  (open-unix-client path))

(defun unix-close (listener)
  "Close a Unix-domain LISTENER and unlink its socket file."
  (close-unix-listener listener))
