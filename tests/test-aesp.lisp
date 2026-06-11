;;;; tests/test-aesp.lisp --- AESP codec + server tests.
;;;;
;;;; Two child suites under the root: AESP-CODEC-SUITE (pure, byte-exact)
;;;; and AESP-SERVER-SUITE (boots a real 3-port TCP server and exercises the
;;;; control messages over a loopback usocket client).

(in-package #:atari800-cl/tests)

(def-suite aesp-suite
  :description "AESP binary protocol (codec + server)."
  :in atari800-cl-suite)

;;; ===========================================================================
;;; Codec — pure, byte-exact

(def-suite aesp-codec-suite :description "AESP wire codec." :in aesp-suite)
(in-suite aesp-codec-suite)

(defun %octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

(test aesp-encode-ping-is-byte-exact
  "A no-payload PING encodes to the canonical 8-byte header."
  (let ((bytes (atari800-cl.aesp:encode-aesp-message atari800-cl.aesp:+aesp-ping+)))
    (is (equalp (%octets #xAE #x50 #x01 #x00 #x00 #x00 #x00 #x00) bytes)
        "PING header; got ~S" bytes)))

(test aesp-encode-with-payload-sets-length-big-endian
  "The 4-byte length field is big-endian and the payload follows the header."
  (let* ((payload (%octets 1 2 3))
         (bytes (atari800-cl.aesp:encode-aesp-message atari800-cl.aesp:+aesp-info+ payload)))
    (is (= 11 (length bytes)))
    (is (equalp (%octets #xAE #x50 #x01 #x06 #x00 #x00 #x00 #x03 1 2 3) bytes))))

(test aesp-decode-header-roundtrip
  "DECODE-AESP-HEADER recovers the type and length ENCODE put in."
  (let ((bytes (atari800-cl.aesp:encode-aesp-message #x44 (%octets 9 9 9 9 9))))
    (multiple-value-bind (type len) (atari800-cl.aesp:decode-aesp-header bytes)
      (is (= #x44 type))
      (is (= 5 len)))))

(test aesp-decode-rejects-bad-magic
  "A header with the wrong magic raises AESP-PROTOCOL-ERROR."
  (signals atari800-cl.aesp:aesp-protocol-error
    (atari800-cl.aesp:decode-aesp-header
     (%octets #x00 #x00 #x01 #x00 #x00 #x00 #x00 #x00))))

(test aesp-decode-rejects-bad-version
  "A header with an unknown version raises AESP-PROTOCOL-ERROR."
  (signals atari800-cl.aesp:aesp-protocol-error
    (atari800-cl.aesp:decode-aesp-header
     (%octets #xAE #x50 #x02 #x00 #x00 #x00 #x00 #x00))))

(test aesp-decode-rejects-oversize-length
  "A length over the 16 MiB cap raises AESP-PROTOCOL-ERROR."
  (signals atari800-cl.aesp:aesp-protocol-error
    (atari800-cl.aesp:decode-aesp-header
     (%octets #xAE #x50 #x01 #x00 #xFF #xFF #xFF #xFF))))

(test aesp-read-write-over-a-stream-roundtrip
  "WRITE-AESP-MESSAGE then READ-AESP-MESSAGE over an in-memory binary stream
recovers the type and payload."
  (let ((buf (flexi-streams:make-in-memory-output-stream)))
    (atari800-cl.aesp:write-aesp-message buf atari800-cl.aesp:+aesp-status+ (%octets #x2A))
    (let ((in (flexi-streams:make-in-memory-input-stream
               (flexi-streams:get-output-stream-sequence buf))))
      (multiple-value-bind (type payload) (atari800-cl.aesp:read-aesp-message in)
        (is (= atari800-cl.aesp:+aesp-status+ type))
        (is (equalp (%octets #x2A) payload))))))

(test aesp-read-signals-eof-on-empty-stream
  "Reading from a closed/empty stream signals END-OF-FILE (clean close)."
  (let ((in (flexi-streams:make-in-memory-input-stream (%octets))))
    (signals end-of-file (atari800-cl.aesp:read-aesp-message in))))

;;; ===========================================================================
;;; Server — real 3-port TCP server over loopback

(def-suite aesp-server-suite
  :description "AESP TCP server: control message round-trips + clean shutdown."
  :in aesp-suite)
(in-suite aesp-server-suite)

(defun %aesp-request (stream type &optional payload)
  "Send a control message and read the single reply; (values type payload)."
  (atari800-cl.aesp:write-aesp-message stream type payload)
  (atari800-cl.aesp:read-aesp-message stream))

(defmacro with-aesp-server ((mvar svar streamvar) &body body)
  "Start a paused run-loop + an AESP server on ephemeral ports, connect a
control client (STREAMVAR), run BODY, then tear it all down."
  (let ((stop (gensym "STOP")) (loop-th (gensym "LOOP")) (conn (gensym "CONN")))
    `(if (not (tcp-listener-available-p))
         (skip "TCP listener bind is not permitted in this execution environment.")
         (let* ((,mvar (atari800-cl.machine:make-atari-machine))
            (,stop (list nil))
            (,loop-th (make-thread
                       (lambda () (atari800-cl.machine:machine-run-loop
                                   ,mvar :stop-flag (lambda () (car ,stop))))
                       :name "aesp-test-runloop"))
            (,svar (atari800-cl.aesp:start-aesp-server
                    ,mvar :host "127.0.0.1"
                          :control-port 0 :video-port 0 :audio-port 0))
            (,conn (atari800-cl.transport:tcp-connect
                    "127.0.0.1" (atari800-cl.aesp:aesp-server-control-port ,svar)))
            (,streamvar (atari800-cl.transport:tcp-stream ,conn)))
       (declare (ignorable ,mvar ,svar ,streamvar))
       (unwind-protect (progn ,@body)
         (ignore-errors (atari800-cl.transport:tcp-close ,conn))
         (atari800-cl.aesp:stop-aesp-server ,svar)
         (setf (car ,stop) t)
         (join-thread ,loop-th))))))

(test aesp-server-ping-pong
  "PING returns a payload-less PONG."
  (with-aesp-server (m srv s)
    (multiple-value-bind (ty pl) (%aesp-request s atari800-cl.aesp:+aesp-ping+)
      (is (= atari800-cl.aesp:+aesp-pong+ ty))
      (is (= 0 (length pl))))))

(test aesp-server-input-events-update-input-and-ack
  "KEY_DOWN / JOYSTICK / CONSOLE_KEYS / PADDLE each ACK and mutate the
machine's input-state as the chip getters see it."
  (with-aesp-server (m srv s)
    (let ((in (atari800-cl.machine:atari-machine-input m)))
      (is (= atari800-cl.aesp:+aesp-ack+
             (%aesp-request s atari800-cl.aesp:+aesp-key-down+ (%octets #x2A))))
      (is (= #x2A (input-pokey-kbcode in)))
      ;; stick 0 up + trigger -> PORTA $FE, TRIG0 0
      (is (= atari800-cl.aesp:+aesp-ack+
             (%aesp-request s atari800-cl.aesp:+aesp-joystick+ (%octets 0 #b00010001))))
      (is (= #xFE (input-pia-porta in)))
      (is (= 0 (input-gtia-trig in 0)))
      ;; START -> CONSOL $06
      (is (= atari800-cl.aesp:+aesp-ack+
             (%aesp-request s atari800-cl.aesp:+aesp-console-keys+ (%octets #b001))))
      (is (= #x06 (input-gtia-consol in)))
      ;; paddle 1 = 123
      (is (= atari800-cl.aesp:+aesp-ack+
             (%aesp-request s atari800-cl.aesp:+aesp-paddle+ (%octets 1 123))))
      (is (= 123 (input-pokey-pot in 1))))))

(test aesp-server-pause-resume-reset-ack
  "PAUSE/RESUME/RESET round-trip through the mailbox and ACK; RESUME flips
the machine to running."
  (with-aesp-server (m srv s)
    (is (= atari800-cl.aesp:+aesp-ack+ (%aesp-request s atari800-cl.aesp:+aesp-resume+)))
    (is-true (%wait-until (lambda () (atari800-cl.machine:atari-machine-running-p m))))
    (is (= atari800-cl.aesp:+aesp-ack+ (%aesp-request s atari800-cl.aesp:+aesp-pause+)))
    (is-true (%wait-until (lambda () (not (atari800-cl.machine:atari-machine-running-p m)))))
    (is (= atari800-cl.aesp:+aesp-ack+ (%aesp-request s atari800-cl.aesp:+aesp-reset+)))))

(test aesp-server-status-and-info
  "STATUS returns a 1-byte payload; INFO returns JSON naming the emulator."
  (with-aesp-server (m srv s)
    (multiple-value-bind (ty pl) (%aesp-request s atari800-cl.aesp:+aesp-status+)
      (is (= atari800-cl.aesp:+aesp-status+ ty))
      (is (= 1 (length pl))))
    (multiple-value-bind (ty pl) (%aesp-request s atari800-cl.aesp:+aesp-info+)
      (is (= atari800-cl.aesp:+aesp-info+ ty))
      (is (plusp (length pl)))
      (is-true (search "atari800-cl"
                       (flexi-streams:octets-to-string pl :external-format :utf-8))))))

(test aesp-server-subscribe-replies-config
  "VIDEO_SUBSCRIBE returns FRAME_CONFIG (384,240,4,60); AUDIO_SUBSCRIBE
returns AUDIO_CONFIG (44100,8,1)."
  (with-aesp-server (m srv s)
    (multiple-value-bind (ty pl) (%aesp-request s atari800-cl.aesp:+aesp-video-subscribe+)
      (is (= atari800-cl.aesp:+aesp-frame-config+ ty))
      (is (equalp (%octets #x01 #x80 #x00 #xF0 #x04 #x3C) pl)))
    (multiple-value-bind (ty pl) (%aesp-request s atari800-cl.aesp:+aesp-audio-subscribe+)
      (is (= atari800-cl.aesp:+aesp-audio-config+ ty))
      (is (equalp (%octets #x00 #x00 #xAC #x44 #x08 #x01) pl)))))

(test aesp-server-unknown-type-errors
  "An unknown message type yields ERROR with the not-implemented code."
  (with-aesp-server (m srv s)
    (multiple-value-bind (ty pl) (%aesp-request s #x7E)
      (is (= atari800-cl.aesp:+aesp-error+ ty))
      (is (equalp (%octets atari800-cl.aesp:+aesp-err-not-implemented+) pl)))))

(test aesp-server-stops-cleanly-with-active-client
  "STOP-AESP-SERVER returns promptly even with a client still connected."
  (with-aesp-server (m srv s)
    ;; The WITH-AESP-SERVER teardown stops the server while the client stream
    ;; is still open; reaching here without hanging is the assertion.
    (is (atari800-cl.aesp:aesp-server-p srv))))
