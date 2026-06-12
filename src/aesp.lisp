;;;; src/aesp.lisp --- AESP binary protocol: codec + TCP server.
;;;;
;;;; AESP is the Attic project's binary wire protocol.  Every message is an
;;;; 8-byte big-endian header followed by an optional payload:
;;;;
;;;;   offset  size  field
;;;;   ------  ----  -----
;;;;     0      2    magic    0xAE50
;;;;     2      1    version  1
;;;;     3      1    type     message type (see constants below)
;;;;     4      4    length   payload length, big-endian u32 (<= 16 MiB)
;;;;     8      N    payload
;;;;
;;;; The codec (ENCODE-/DECODE-/READ-/WRITE-AESP-MESSAGE) is pure and
;;;; socket-free.  The server (START-AESP-SERVER) listens on three TCP ports
;;;; — control (bidirectional), video, and audio (server-push, empty in this
;;;; MVP) — and drives the machine through its command mailbox.
;;;;
;;;; Payload encodings used by this MVP (our contract; pinned by tests):
;;;;   STATUS reply   : 1 byte  — bit0 running, bit1 cpu-halted.
;;;;   INFO reply     : UTF-8 JSON (hand-built; no JSON dependency).
;;;;   KEY_DOWN/UP    : [keycode].
;;;;   JOYSTICK       : [port][bits] bits: 0 up,1 down,2 left,3 right,4 trigger.
;;;;   CONSOLE_KEYS   : [bits] bits: 0 start,1 select,2 option.
;;;;   PADDLE         : [port][value].
;;;;   FRAME_CONFIG   : width(u16) height(u16) bpp(u8) fps(u8) = 384,240,4,60.
;;;;   AUDIO_CONFIG   : sample-rate(u32) bits(u8) channels(u8) = 44100,8,1.

(in-package #:atari800-cl.aesp)

;;; ---------------------------------------------------------------------------
;;; Constants (wrapped so they have compile-time values for CASE keys).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +aesp-magic+       #xAE50)
  (defconstant +aesp-version+     1)
  (defconstant +aesp-header-size+ 8)
  (defconstant +aesp-max-payload+ #x1000000)   ; 16 MiB

  ;; Message types.
  (defconstant +aesp-ping+              #x00)
  (defconstant +aesp-pong+              #x01)
  (defconstant +aesp-pause+             #x02)
  (defconstant +aesp-resume+            #x03)
  (defconstant +aesp-reset+             #x04)
  (defconstant +aesp-status+            #x05)
  (defconstant +aesp-info+              #x06)
  (defconstant +aesp-boot-file+         #x07)   ; deferred
  (defconstant +aesp-ack+               #x0F)
  (defconstant +aesp-error+             #x3F)
  (defconstant +aesp-key-down+          #x40)
  (defconstant +aesp-key-up+            #x41)
  (defconstant +aesp-joystick+          #x42)
  (defconstant +aesp-console-keys+      #x43)
  (defconstant +aesp-paddle+            #x44)
  (defconstant +aesp-frame-config+      #x62)
  (defconstant +aesp-video-subscribe+   #x63)
  (defconstant +aesp-video-unsubscribe+ #x64)
  (defconstant +aesp-audio-config+      #x81)
  (defconstant +aesp-audio-subscribe+   #x83)
  (defconstant +aesp-audio-unsubscribe+ #x84)

  ;; ERROR payload codes.
  (defconstant +aesp-err-server-busy+     #x04)
  (defconstant +aesp-err-not-implemented+ #x05))

(deftype octet-vector () '(simple-array (unsigned-byte 8) (*)))

(define-condition aesp-protocol-error (error)
  ((reason :initarg :reason :reader aesp-protocol-error-reason))
  (:report (lambda (c s)
             (format s "AESP protocol error: ~A" (aesp-protocol-error-reason c))))
  (:documentation "Signalled by the codec on a malformed AESP header/payload."))

;;; ---------------------------------------------------------------------------
;;; Codec

(defun %make-octets (n)
  (make-array n :element-type '(unsigned-byte 8)))

(defun encode-aesp-message (type &optional payload)
  "Return a fresh octet vector: the 8-byte big-endian header for TYPE plus
PAYLOAD (a sequence of octets, default empty).  Signals AESP-PROTOCOL-ERROR
if the payload exceeds +AESP-MAX-PAYLOAD+."
  (let* ((pl  (if payload (coerce payload 'octet-vector) (%make-octets 0)))
         (len (length pl)))
    (when (> len +aesp-max-payload+)
      (error 'aesp-protocol-error :reason (format nil "payload too large: ~D" len)))
    (let ((buf (%make-octets (+ +aesp-header-size+ len))))
      (setf (aref buf 0) #xAE
            (aref buf 1) #x50
            (aref buf 2) +aesp-version+
            (aref buf 3) (ldb (byte 8 0) type)
            (aref buf 4) (ldb (byte 8 24) len)
            (aref buf 5) (ldb (byte 8 16) len)
            (aref buf 6) (ldb (byte 8 8)  len)
            (aref buf 7) (ldb (byte 8 0)  len))
      (replace buf pl :start1 +aesp-header-size+)
      buf)))

(defun decode-aesp-header (header)
  "Validate the 8-byte HEADER (a sequence of octets); return (values type
length).  Signals AESP-PROTOCOL-ERROR on bad magic, version, or oversize."
  (unless (>= (length header) +aesp-header-size+)
    (error 'aesp-protocol-error :reason "short header"))
  (let ((magic   (dpb (elt header 0) (byte 8 8) (elt header 1)))
        (version (elt header 2))
        (type    (elt header 3))
        (len     (logior (ash (elt header 4) 24) (ash (elt header 5) 16)
                         (ash (elt header 6) 8)  (elt header 7))))
    (unless (= magic +aesp-magic+)
      (error 'aesp-protocol-error :reason (format nil "bad magic #x~4,'0X" magic)))
    (unless (= version +aesp-version+)
      (error 'aesp-protocol-error :reason (format nil "bad version ~D" version)))
    (when (> len +aesp-max-payload+)
      (error 'aesp-protocol-error :reason (format nil "payload too large: ~D" len)))
    (values type len)))

(defun write-aesp-message (stream type &optional payload)
  "Encode a message and write it to binary STREAM, flushing afterward."
  (write-sequence (encode-aesp-message type payload) stream)
  (force-output stream)
  (values))

(defun read-aesp-message (stream)
  "Read one AESP message from binary STREAM; return (values type payload).
Signals END-OF-FILE on a clean close before any header byte, or
AESP-PROTOCOL-ERROR on a truncated/malformed frame."
  (let* ((header (%make-octets +aesp-header-size+))
         (n      (read-sequence header stream)))
    (when (zerop n) (error 'end-of-file :stream stream))
    (when (< n +aesp-header-size+)
      (error 'aesp-protocol-error :reason "truncated header"))
    (multiple-value-bind (type len) (decode-aesp-header header)
      (let ((payload (%make-octets len)))
        (when (plusp len)
          (let ((m (read-sequence payload stream)))
            (when (< m len)
              (error 'aesp-protocol-error :reason "truncated payload"))))
        (values type payload)))))

;;; ---------------------------------------------------------------------------
;;; Payload builders + appliers

(defun %octets-of (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

(defun %u16-be (buf i v)
  (setf (aref buf i) (ldb (byte 8 8) v) (aref buf (1+ i)) (ldb (byte 8 0) v)))

(defun %u32-be (buf i v)
  (setf (aref buf i)       (ldb (byte 8 24) v)
        (aref buf (+ i 1)) (ldb (byte 8 16) v)
        (aref buf (+ i 2)) (ldb (byte 8 8)  v)
        (aref buf (+ i 3)) (ldb (byte 8 0)  v)))

(defun %status-byte (machine)
  "STATUS reply: bit0 running, bit1 cpu-halted."
  (let ((b 0))
    (when (atari-machine-running-p machine) (setf b (logior b #b01)))
    (when (atari800-cl.cpu:cpu-halted (atari-machine-cpu machine))
      (setf b (logior b #b10)))
    (%octets-of b)))

(defun %info-json (machine)
  "INFO reply: a small hand-built UTF-8 JSON blob (no JSON dependency)."
  (flexi-streams:string-to-octets
   (format nil "{\"emulator\":\"atari800-cl\",\"frame\":~D,\"scanline\":~D,\"running\":~A}"
           (atari-machine-frame-count machine)
           (machine-scanline machine)
           (if (atari-machine-running-p machine) "true" "false"))
   :external-format :utf-8))

(defun %frame-config-payload ()
  "FRAME_CONFIG: width(u16) height(u16) bpp(u8) fps(u8) = 384,240,4,60."
  (let ((b (%make-octets 6)))
    (%u16-be b 0 384) (%u16-be b 2 240)
    (setf (aref b 4) 4 (aref b 5) 60)
    b))

(defun %audio-config-payload ()
  "AUDIO_CONFIG: sample-rate(u32) bits(u8) channels(u8) = 44100,8,1."
  (let ((b (%make-octets 6)))
    (%u32-be b 0 44100)
    (setf (aref b 4) 8 (aref b 5) 1)
    b))

(defun %apply-key (machine payload down)
  (when (>= (length payload) 1)
    (input-set-key (atari-machine-input machine) (aref payload 0) down)))

(defun %apply-joystick (machine payload)
  (when (>= (length payload) 2)
    (let ((port (ldb (byte 1 0) (aref payload 0)))
          (bits (aref payload 1)))
      (input-set-joystick (atari-machine-input machine) port
                          :up (logbitp 0 bits) :down (logbitp 1 bits)
                          :left (logbitp 2 bits) :right (logbitp 3 bits)
                          :trigger (logbitp 4 bits)))))

(defun %apply-console (machine payload)
  (when (>= (length payload) 1)
    (let ((bits (aref payload 0)))
      (input-set-console (atari-machine-input machine)
                         :start (logbitp 0 bits) :select (logbitp 1 bits)
                         :option (logbitp 2 bits)))))

(defun %apply-paddle (machine payload)
  (when (>= (length payload) 2)
    (input-set-paddle (atari-machine-input machine)
                      (ldb (byte 2 0) (aref payload 0)) (aref payload 1))))

;;; ---------------------------------------------------------------------------
;;; Server

(defstruct (aesp-server (:constructor %make-aesp-server))
  "Handle for a running 3-port AESP server.  CONTROL/VIDEO/AUDIO ports carry
the bound port numbers (useful when started on ephemeral port 0)."
  machine
  host
  control-listener video-listener audio-listener
  control-port video-port audio-port
  (lock    (make-lock "aesp-server"))
  (threads '())
  (clients '())
  (running t))

(defun %add-thread (server th)
  (with-lock ((aesp-server-lock server)) (push th (aesp-server-threads server)))
  th)

(defun %register-client (server conn)
  (with-lock ((aesp-server-lock server)) (push conn (aesp-server-clients server))))

(defun %unregister-client (server conn)
  (with-lock ((aesp-server-lock server))
    (setf (aesp-server-clients server) (remove conn (aesp-server-clients server)))))

(defun %ack (stream) (write-aesp-message stream +aesp-ack+))

(defun %submit-or-busy (server stream thunk)
  "Submit a state-mutating THUNK through the machine's mailbox and ACK; if
the mailbox is full, reply ERROR/server-busy instead.  Requires a running
MACHINE-RUN-LOOP to drain the mailbox."
  (handler-case
      (progn (machine-submit (aesp-server-machine server) thunk :priority t)
             (%ack stream))
    (mailbox-full ()
      (write-aesp-message stream +aesp-error+ (%octets-of +aesp-err-server-busy+)))))

(defun %handle-control (server stream type payload)
  "Dispatch one control-port message and write its reply."
  (let ((machine (aesp-server-machine server)))
    (case type
      (#.+aesp-ping+    (write-aesp-message stream +aesp-pong+))
      (#.+aesp-pause+   (%submit-or-busy server stream
                          (lambda (m) (setf (atari-machine-running-p m) nil))))
      (#.+aesp-resume+  (%submit-or-busy server stream
                          (lambda (m) (setf (atari-machine-running-p m) t))))
      (#.+aesp-reset+   (%submit-or-busy server stream
                          (lambda (m) (machine-cold-reset m))))
      (#.+aesp-status+  (write-aesp-message stream +aesp-status+ (%status-byte machine)))
      (#.+aesp-info+    (write-aesp-message stream +aesp-info+ (%info-json machine)))
      (#.+aesp-key-down+ (%apply-key machine payload t)   (%ack stream))
      (#.+aesp-key-up+   (%apply-key machine payload nil) (%ack stream))
      (#.+aesp-joystick+ (%apply-joystick machine payload) (%ack stream))
      (#.+aesp-console-keys+ (%apply-console machine payload) (%ack stream))
      (#.+aesp-paddle+   (%apply-paddle machine payload) (%ack stream))
      (#.+aesp-video-subscribe+
       (write-aesp-message stream +aesp-frame-config+ (%frame-config-payload)))
      (#.+aesp-video-unsubscribe+ (%ack stream))
      (#.+aesp-audio-subscribe+
       (write-aesp-message stream +aesp-audio-config+ (%audio-config-payload)))
      (#.+aesp-audio-unsubscribe+ (%ack stream))
      (t (write-aesp-message stream +aesp-error+
                             (%octets-of +aesp-err-not-implemented+))))))

(defun %aesp-reader (server conn stream kind)
  "Per-client reader loop.  Control clients get their messages dispatched;
video/audio clients are held open (no inbound handling in this MVP).  Exits
on EOF / closed socket / any stream error."
  (unwind-protect
       (handler-case
           (loop
             (multiple-value-bind (type payload) (read-aesp-message stream)
               (when (eq kind :control)
                 (%handle-control server stream type payload))))
         (end-of-file () nil)
         (error () nil))
    (%unregister-client server conn)
    (tcp-close conn)))

(defun %aesp-acceptor (server listener kind)
  "Accept connections on LISTENER until the server stops; spawn a reader per
client.  A closed listener (from STOP-AESP-SERVER) makes ACCEPT error, which
ends the loop."
  (loop
    (let ((conn (handler-case (tcp-accept listener)
                  (error () (return)))))
      (cond
        ((not (aesp-server-running server)) (tcp-close conn) (return))
        (t (%register-client server conn)
           (%add-thread server
             (make-thread (lambda () (%aesp-reader server conn (tcp-stream conn) kind))
                          :name (format nil "aesp-~(~A~)-reader" kind))))))))

(defun start-aesp-server (machine &key (host "127.0.0.1")
                                       (control-port 47800)
                                       (video-port 47801)
                                       (audio-port 47802))
  "Start the 3-port AESP server (control/video/audio) on HOST and return an
AESP-SERVER.  Ensures MACHINE has an INPUT-STATE wired in.  Control messages
that mutate machine state (PAUSE/RESUME/RESET) go through the command
mailbox, so a MACHINE-RUN-LOOP must be draining it for those to complete.
Pass any port as 0 to get an OS-assigned port (read it back from the
AESP-SERVER-*-PORT accessors)."
  (declare (type atari-machine machine))
  (unless (atari-machine-input machine)
    (attach-input machine (make-input-state)))
  (let (cl vl al)
    (handler-case
        (progn
          (setf cl (tcp-listen host control-port)
                vl (tcp-listen host video-port)
                al (tcp-listen host audio-port))
          (let ((server (%make-aesp-server
                         :machine machine :host host
                         :control-listener cl :video-listener vl :audio-listener al
                         :control-port (tcp-listener-port cl)
                         :video-port   (tcp-listener-port vl)
                         :audio-port   (tcp-listener-port al))))
            (%add-thread server (make-thread (lambda () (%aesp-acceptor server cl :control))
                                             :name "aesp-control-acceptor"))
            (%add-thread server (make-thread (lambda () (%aesp-acceptor server vl :video))
                                             :name "aesp-video-acceptor"))
            (%add-thread server (make-thread (lambda () (%aesp-acceptor server al :audio))
                                             :name "aesp-audio-acceptor"))
            server))
      (error (e)
        ;; Bind/spawn failed partway: close whatever opened, re-signal.
        (tcp-close cl) (tcp-close vl) (tcp-close al)
        (error e)))))

(defun stop-aesp-server (server &key (timeout 2.0))
  "Stop SERVER: close the listeners (unblocking the acceptors), close all
client connections (unblocking the readers), then join the threads, forcibly
destroying any that outlive TIMEOUT seconds.  Returns SERVER."
  (setf (aesp-server-running server) nil)
  (tcp-close (aesp-server-control-listener server))
  (tcp-close (aesp-server-video-listener server))
  (tcp-close (aesp-server-audio-listener server))
  (dolist (conn (copy-list (aesp-server-clients server)))
    (tcp-close conn))
  (let ((deadline (+ (get-internal-real-time)
                     (truncate (* timeout internal-time-units-per-second)))))
    (dolist (th (copy-list (aesp-server-threads server)))
      (loop while (and (thread-alive-p th) (< (get-internal-real-time) deadline))
            do (sleep 0.005))
      (when (thread-alive-p th) (destroy-thread th))))
  server)
