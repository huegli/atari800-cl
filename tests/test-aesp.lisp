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

(test aesp-audio-pcm-uses-the-protocol-code-and-raw-sample-payload
  "AUDIO_PCM is the protocol's own 0x80 (protocol_spec.py's AESP_MESSAGES
table), and its payload is raw mono u8 samples with no prefix — the
payload length IS the sample count."
  (is (= #x80 atari800-cl.aesp:+aesp-audio-pcm+)
      "AUDIO_PCM must use the protocol's code, not a locally invented one")
  (let ((samples (make-array 747 :element-type '(unsigned-byte 8))))
    (dotimes (i 747)
      (setf (aref samples i) (mod (* i 7) 256)))
    (let ((bytes (atari800-cl.aesp:encode-aesp-message
                  atari800-cl.aesp:+aesp-audio-pcm+ samples)))
      (multiple-value-bind (type len) (atari800-cl.aesp:decode-aesp-header bytes)
        (is (= atari800-cl.aesp:+aesp-audio-pcm+ type))
        (is (= 747 len) "payload length must equal the sample count"))
      (is (equalp samples (subseq bytes atari800-cl.aesp:+aesp-header-size+))
          "the payload must be the samples verbatim"))))

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
  "VIDEO_SUBSCRIBE returns FRAME_CONFIG (336,240,4,60) -- the cropped
width FRAME_RAW actually sends (Attic-compatible, not the renderer's
internal 384; see +AESP-FRAME-RAW-WIDTH+); byte 4 is bytes per pixel,
matching FRAME_RAW's BGRA8888 wire format.  AUDIO_SUBSCRIBE returns
AUDIO_CONFIG (44744,8,1) -- the synthesiser's real rate, $0000AEC8, not
the 44,100 declared before there were samples to describe."
  (with-aesp-server (m srv s)
    (multiple-value-bind (ty pl) (%aesp-request s atari800-cl.aesp:+aesp-video-subscribe+)
      (is (= atari800-cl.aesp:+aesp-frame-config+ ty))
      (is (equalp (%octets #x01 #x50 #x00 #xF0 #x04 #x3C) pl)))
    (multiple-value-bind (ty pl) (%aesp-request s atari800-cl.aesp:+aesp-audio-subscribe+)
      (is (= atari800-cl.aesp:+aesp-audio-config+ ty))
      (is (equalp (%octets #x00 #x00 #xAE #xC8 #x08 #x01) pl))
      (is (= atari800-cl.audio:+audio-sample-rate+
             (logior (ash (aref pl 0) 24) (ash (aref pl 1) 16)
                     (ash (aref pl 2) 8)  (aref pl 3)))
          "the declared rate must be the synthesiser's actual rate"))))

;;; ---------------------------------------------------------------------------
;;; Audio streaming (ROADMAP.md Phase 10)

(defun %run-frames-via-mailbox (machine n)
  "Run N frames on the emulator thread through the command mailbox."
  (dotimes (i n)
    (atari800-cl.machine:machine-submit
     machine (lambda (m) (atari800-cl.machine:machine-run-frame m)))))

(test aesp-server-pushes-audio-pcm-to-audio-clients
  "A client on the audio port receives one AUDIO_PCM per frame carrying a
frame's worth of samples (746-747 at 44,744 Hz).  Synthesis is attached
at the end of the frame during which the first client connects, so the
first push arrives one frame later."
  (with-aesp-server (m srv s)
    (let* ((conn (atari800-cl.transport:tcp-connect
                  "127.0.0.1" (atari800-cl.aesp:aesp-server-audio-port srv)))
           (stream (atari800-cl.transport:tcp-stream conn)))
      (unwind-protect
           (progn
             ;; Wait for the acceptor thread to register the connection.
             (is-true (%wait-until
                       (lambda ()
                         (atari800-cl.aesp::aesp-server-audio-clients srv)))
                      "the audio client must be registered before frames run")
             ;; Frame 1 attaches synthesis; frames 2-3 carry samples.
             (%run-frames-via-mailbox m 3)
             (is-true (atari800-cl.aesp::aesp-server-audio-unit srv)
                      "an audio unit must be attached while a client is connected")
             (multiple-value-bind (ty pl) (atari800-cl.aesp:read-aesp-message stream)
               (is (= atari800-cl.aesp:+aesp-audio-pcm+ ty)
                   "expected AUDIO_PCM, got #x~2,'0X" ty)
               (is (<= 746 (length pl) 747)
                   "expected one frame of samples (746-747), got ~D" (length pl))))
        (ignore-errors (atari800-cl.transport:tcp-close conn))))))

(test aesp-server-without-audio-clients-does-not-synthesise
  "With nobody listening on the audio port, no audio unit is attached and
the machine accumulates no samples — synthesis costs nothing."
  (with-aesp-server (m srv s)
    (%run-frames-via-mailbox m 2)
    (is-false (atari800-cl.aesp::aesp-server-audio-unit srv)
              "no audio unit may be attached without a subscriber")
    (is (zerop (length (atari800-cl.machine:machine-audio-drain m)))
        "an unattached machine must accumulate no samples")))

(test aesp-server-detaches-audio-when-last-client-leaves
  "Closing the last audio client detaches synthesis again on the next
frame, so a machine nobody is listening to stops paying for it."
  (with-aesp-server (m srv s)
    (let ((conn (atari800-cl.transport:tcp-connect
                 "127.0.0.1" (atari800-cl.aesp:aesp-server-audio-port srv))))
      (is-true (%wait-until
                (lambda () (atari800-cl.aesp::aesp-server-audio-clients srv))))
      (%run-frames-via-mailbox m 1)
      (is-true (atari800-cl.aesp::aesp-server-audio-unit srv))
      ;; Drop the client and let the reader thread unregister it.
      (ignore-errors (atari800-cl.transport:tcp-close conn))
      (is-true (%wait-until
                (lambda ()
                  (null (atari800-cl.aesp::aesp-server-audio-clients srv))))
               "the reader thread must unregister a closed audio client")
      (%run-frames-via-mailbox m 1)
      (is-false (atari800-cl.aesp::aesp-server-audio-unit srv)
                "the audio unit must be detached once the last client leaves"))))

;;; ---------------------------------------------------------------------------
;;; Video push economics (ROADMAP.md Phase 28)

(defun %spawn-video-drain (stream)
  "Continuously drain FRAME_RAW-shaped messages off STREAM into a list
(protected by a lock), so a test can run frames through the machine's
command mailbox (which blocks the CALLING thread until the emulator
thread finishes the frame, post-frame push included) without
deadlocking against its own unread ~322 KB FRAME_RAW payload -- the
socket write inside the push would otherwise be able to block waiting
for the very thread that is waiting on MACHINE-SUBMIT to return.
Returns (values thread lock box); (CAR BOX) is the list of received
(type . payload) conses, newest first.  The thread exits quietly on any
stream error (EOF once the connection closes)."
  (let ((lock (make-lock "video-drain"))
        (box (list nil)))
    (values
     (make-thread
      (lambda ()
        (handler-case
            (loop
              (multiple-value-bind (ty pl) (atari800-cl.aesp:read-aesp-message stream)
                (with-lock (lock) (push (cons ty pl) (car box)))))
          (error () nil)))
      :name "aesp-test-video-drain")
     lock box)))

(defun %video-drain-count (lock box)
  (with-lock (lock) (length (car box))))

(defun %video-drain-messages (lock box)
  "The messages BOX holds so far, oldest first."
  (with-lock (lock) (reverse (car box))))

(defun %stop-video-drain (conn thread &key (timeout 2.0))
  "Tear down a %SPAWN-VIDEO-DRAIN thread: close CONN (which unblocks
THREAD's pending READ-AESP-MESSAGE on most implementations once the
socket errors out) then wait up to TIMEOUT seconds for THREAD to exit,
forcibly destroying it if it outlives that.  Mirrors STOP-AESP-SERVER's
own thread-teardown pattern -- needed because a bare JOIN-THREAD can
hang: closing a socket out from under another thread's blocked read is
not guaranteed to unblock that read promptly (or at all) on every
implementation."
  (ignore-errors (atari800-cl.transport:tcp-close conn))
  (let ((deadline (+ (get-internal-real-time)
                     (truncate (* timeout internal-time-units-per-second)))))
    (loop while (and (thread-alive-p thread) (< (get-internal-real-time) deadline))
          do (sleep 0.005))
    (when (thread-alive-p thread) (destroy-thread thread))))

(test aesp-server-scanline-fn-gated-without-video-client
  "With no video client connected, the scanline-fn gate (Phase 28a) skips
rendering entirely.  Sentinel-fill the framebuffer first -- a real render
would overwrite it with COLBK-based fill -- and confirm it survives
running frames with VIDEO-ACTIVE-P false."
  (with-aesp-server (m srv s)
    (let ((fb (atari800-cl.aesp::aesp-server-framebuffer srv)))
      (is-false (atari800-cl.aesp::aesp-server-video-active-p srv)
                "no video client is connected, so the gate must be closed")
      (fill fb #xAB)
      (%run-frames-via-mailbox m 3)
      (is (every (lambda (b) (= b #xAB)) fb)
          "framebuffer must stay untouched while the video gate is closed"))))

(test aesp-server-video-connect-forces-full-render-before-first-push
  "Connecting a video client sets VIDEO-ACTIVE-P and NEEDS-FULL-RENDER-P;
%PUSH-VIDEO-FRAME does not push a frame until one has rendered cleanly
top-to-bottom with the gate open, at which point the scanline-fn's row-0
handler clears NEEDS-FULL-RENDER-P and the client receives a FRAME_RAW."
  (with-aesp-server (m srv s)
    (let* ((conn (atari800-cl.transport:tcp-connect
                  "127.0.0.1" (atari800-cl.aesp:aesp-server-video-port srv)))
           (stream (atari800-cl.transport:tcp-stream conn)))
      (is-true (%wait-until
                (lambda () (atari800-cl.aesp::aesp-server-video-clients srv)))
               "the video client must be registered before frames run")
      (is-true (atari800-cl.aesp::aesp-server-video-active-p srv))
      (is-true (atari800-cl.aesp::aesp-server-needs-full-render-p srv)
               "a freshly connected client must force one full render first")
      (multiple-value-bind (drain-th lock box) (%spawn-video-drain stream)
        (unwind-protect
             (progn
               (%run-frames-via-mailbox m 2)
               (is-false (atari800-cl.aesp::aesp-server-needs-full-render-p srv)
                         "the flag must clear once a full frame rendered with the gate open")
               (is-true (%wait-until (lambda () (plusp (%video-drain-count lock box)))))
               (let ((msg (first (%video-drain-messages lock box))))
                 (is (= atari800-cl.aesp:+aesp-frame-raw+ (car msg)))
                 (is (= (* atari800-cl.aesp::+aesp-frame-raw-width+ 240 4)
                        (length (cdr msg))))))
          (%stop-video-drain conn drain-th))))))

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

;;; ---------------------------------------------------------------------------
;;; Host disk bridge (ROADMAP.md Phase 16, revised; stage 16e).  Reuses
;;; %MAKE-SD-ATR-BYTES / %MAKE-SYNTHETIC-XEX from test-hostdev.lisp -- one
;;; ATARI800-CL/TESTS package, no import needed.

(defun %mount-payload (unit read-only path)
  (concatenate '(vector (unsigned-byte 8))
               (%octets unit (if read-only 1 0))
               (flexi-streams:string-to-octets path :external-format :utf-8)))

(defparameter *aesp-mount-test-counter* 0)
(defun %aesp-mount-test-path (ext)
  (format nil "/tmp/atari800-cl-aesptest-~D-~D.~A"
          (current-process-id) (incf *aesp-mount-test-counter*) ext))

(test aesp-server-mount-and-unmount-round-trip
  "MOUNT loads an .atr file into the host bridge at the given unit and
ACKs; MOUNTED-DISK then reports it; UNMOUNT clears it again."
  (with-aesp-server (m srv s)
    (let ((path (%aesp-mount-test-path "atr"))
          (bridge (atari800-cl.machine:atari-machine-hostdev m)))
      (write-binary-file path (%make-sd-atr-bytes 4))
      (unwind-protect
           (progn
             (is-false (atari800-cl.hostdev:mounted-disk bridge 3))
             (is (= atari800-cl.aesp:+aesp-ack+
                    (%aesp-request s atari800-cl.aesp:+aesp-mount+
                                   (%mount-payload 3 t path))))
             (is-true (atari800-cl.hostdev:mounted-disk bridge 3))
             (is (= atari800-cl.aesp:+aesp-ack+
                    (%aesp-request s atari800-cl.aesp:+aesp-unmount+ (%octets 3))))
             (is-false (atari800-cl.hostdev:mounted-disk bridge 3)))
        (ignore-errors (delete-file path))))))

(test aesp-server-mount-missing-file-errors
  "MOUNT against a nonexistent path replies ERROR/+AESP-ERR-MOUNT-FAILED+
rather than dropping the connection."
  (with-aesp-server (m srv s)
    (multiple-value-bind (ty pl)
        (%aesp-request s atari800-cl.aesp:+aesp-mount+
                       (%mount-payload 1 t "/nonexistent/does-not-exist.atr"))
      (is (= atari800-cl.aesp:+aesp-error+ ty))
      (is (equalp (%octets atari800-cl.aesp:+aesp-err-mount-failed+) pl)))
    ;; connection still usable afterward
    (is (= atari800-cl.aesp:+aesp-pong+ (%aesp-request s atari800-cl.aesp:+aesp-ping+)))))

(test aesp-server-load-xex-mounts-synthesized-atr
  "LOAD_XEX synthesizes a bootable ATR from an XEX file in memory and
mounts it at the given unit, exactly like MOUNT does for a real .atr."
  (with-aesp-server (m srv s)
    (let ((path (%aesp-mount-test-path "xex"))
          (bridge (atari800-cl.machine:atari-machine-hostdev m)))
      (write-binary-file path (%make-synthetic-xex
                                :segments (list (cons #x600 '(#xA9 #x2A #x60)))))
      (unwind-protect
           (progn
             (is (= atari800-cl.aesp:+aesp-ack+
                    (%aesp-request s atari800-cl.aesp:+aesp-load-xex+
                                   (%mount-payload 1 t path))))
             (is-true (atari800-cl.hostdev:mounted-disk bridge 1)))
        (ignore-errors (delete-file path))))))
