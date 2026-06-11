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
            (aref buf 3) (logand type #xFF)
            (aref buf 4) (logand (ash len -24) #xFF)
            (aref buf 5) (logand (ash len -16) #xFF)
            (aref buf 6) (logand (ash len -8)  #xFF)
            (aref buf 7) (logand len           #xFF))
      (replace buf pl :start1 +aesp-header-size+)
      buf)))

(defun decode-aesp-header (header)
  "Validate the 8-byte HEADER (a sequence of octets); return (values type
length).  Signals AESP-PROTOCOL-ERROR on bad magic, version, or oversize."
  (unless (>= (length header) +aesp-header-size+)
    (error 'aesp-protocol-error :reason "short header"))
  (let ((magic   (logior (ash (elt header 0) 8) (elt header 1)))
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
