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
;;;;   FRAME_CONFIG   : width(u16) height(u16) bytes-per-pixel(u8) fps(u8)
;;;;                    = 336,240,4,60 (see +AESP-FRAME-RAW-WIDTH+).
;;;;   FRAME_RAW      : width*height*4 bytes of BGRA8888 pixel data
;;;;                    (row-major, top scanline first, no padding, no
;;;;                    frame-number prefix) — converted per push from the
;;;;                    renderer's internal 24-bit RGB framebuffer to match
;;;;                    the Attic project's PROTOCOL.md exactly.
;;;;   AUDIO_CONFIG   : sample-rate(u32) bits(u8) channels(u8) = 44744,8,1.
;;;;   AUDIO_PCM      : raw mono unsigned-8 samples; the payload length IS
;;;;                    the sample count (746-747 per NTSC frame at
;;;;                    44,744 Hz).  Pushed once per emulated frame from
;;;;                    the same post-frame hook as FRAME_RAW, so the
;;;;                    Nth AUDIO_PCM and the Nth FRAME_RAW describe the
;;;;                    same frame — that 1:1 pairing is what A/V capture
;;;;                    relies on for sync, since neither payload carries a
;;;;                    frame number of its own.
;;;;   MOUNT          : [unit(u8)][read-only(u8: 0/1)][path, UTF-8, rest of
;;;;                    payload] — mounts PATH (an .atr file the SERVER
;;;;                    reads from its own filesystem) into the host disk
;;;;                    bridge at drive UNIT (ROADMAP.md Phase 16, revised;
;;;;                    src/hostdev.lisp).  ACK on success, else ERROR with
;;;;                    +AESP-ERR-MOUNT-FAILED+.
;;;;   UNMOUNT        : [unit(u8)] — clears whatever is mounted at UNIT.
;;;;                    ACK always (no error path: unmounting an empty
;;;;                    unit is a no-op, per ATARI800-CL.HOSTDEV:UNMOUNT-DISK).
;;;;   LOAD_XEX       : [unit(u8)][read-only(u8: 0/1)][path, UTF-8, rest of
;;;;                    payload] — synthesizes a bootable ATR in memory
;;;;                    from the XEX/OBX binary at PATH (ATARI800-CL.
;;;;                    HOSTDEV:LOAD-XEX) and mounts it at UNIT.  Same
;;;;                    reply convention as MOUNT.

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
  ;; Host disk bridge (ROADMAP.md Phase 16, revised; stage 16e).  Distinct
  ;; from the still-deferred BOOT_FILE above: these name a PATH the SERVER
  ;; reads from its own filesystem (like the CLI's mount/loadxex verbs),
  ;; not a stream of file bytes the client uploads.
  (defconstant +aesp-mount+             #x08)
  (defconstant +aesp-unmount+           #x09)
  (defconstant +aesp-load-xex+          #x0A)
  (defconstant +aesp-ack+               #x0F)
  (defconstant +aesp-error+             #x3F)
  (defconstant +aesp-key-down+          #x40)
  (defconstant +aesp-key-up+            #x41)
  (defconstant +aesp-joystick+          #x42)
  (defconstant +aesp-console-keys+      #x43)
  (defconstant +aesp-paddle+            #x44)
  ;; FRAME_RAW's code (0x60) is the protocol's own, per
  ;; tools/protocol-comparison/protocol_spec.py's AESP_MESSAGES table and
  ;; the Attic project's docs/PROTOCOL.md -- this used to be a locally
  ;; invented 0x65 "VIDEO_FRAME" carrying 24-bit RGB, which an actual
  ;; Attic client cannot decode (unknown message type).  See CHANGES.md.
  (defconstant +aesp-frame-raw+         #x60)  ; server-push: completed BGRA frame
  (defconstant +aesp-frame-config+      #x62)
  (defconstant +aesp-video-subscribe+   #x63)
  (defconstant +aesp-video-unsubscribe+ #x64)
  ;; AUDIO_PCM is the protocol's own code for a PCM push (0x80 in
  ;; tools/protocol-comparison/protocol_spec.py's AESP_MESSAGES table);
  ;; ROADMAP.md Phase 10 offered #x85 only as a fallback for the case
  ;; where the protocol did NOT define one, so the spec's code wins.
  (defconstant +aesp-audio-pcm+         #x80)  ; server-push: mono u8 samples
  (defconstant +aesp-audio-config+      #x81)
  (defconstant +aesp-audio-subscribe+   #x83)
  (defconstant +aesp-audio-unsubscribe+ #x84)

  ;; FRAME_RAW geometry.  The renderer's framebuffer is 384 wide (320-pixel
  ;; playfield + border), but the Attic project's own client code -- not
  ;; just its docs -- hard-codes a 336-pixel visible width, cropping 24
  ;; columns off each edge before ever touching the network (see
  ;; Sources/AtticCore/LibAtari800Wrapper.swift's AtariScreen: "atari800
  ;; source screen.h -- Screen_visible_x1=24, Screen_visible_x2=360").
  ;; AtticGUI's MetalRenderer rejects any FRAME_RAW payload whose byte
  ;; count isn't exactly width*height*4, silently dropping the frame, so
  ;; matching this crop is required for interop, not optional -- pushing
  ;; the full 384 columns (matching docs/PROTOCOL.md's literal "384x240"
  ;; example) fails against the real client.  We crop analogously: 24
  ;; columns off each side of our own 384-wide buffer.
  (defconstant +aesp-frame-raw-x1+      24)
  (defconstant +aesp-frame-raw-width+   336)

  ;; ERROR payload codes.
  (defconstant +aesp-err-server-busy+     #x04)
  (defconstant +aesp-err-not-implemented+ #x05)
  (defconstant +aesp-err-mount-failed+    #x06))

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
  "FRAME_CONFIG: width(u16) height(u16) bytes-per-pixel(u8) fps(u8)
= 336,240,4,60 -- the cropped width FRAME_RAW actually sends (see
+AESP-FRAME-RAW-WIDTH+), not the renderer's internal 384.  Byte 4 is
bytes per pixel (matching FRAME_RAW's BGRA payload), not bits."
  (let ((b (%make-octets 6)))
    (%u16-be b 0 +aesp-frame-raw-width+) (%u16-be b 2 240)
    (setf (aref b 4) 4 (aref b 5) 60)
    b))

(defun %audio-config-payload ()
  "AUDIO_CONFIG: sample-rate(u32) bits(u8) channels(u8) = 44744,8,1.
The rate is the synthesiser's actual output rate (ATARI800-CL.AUDIO's
+AUDIO-SAMPLE-RATE+ — the 1.79 MHz CPU clock / 40), not the 44,100 this
declared before there were samples to describe.  Wire layout is
unchanged."
  (let ((b (%make-octets 6)))
    (%u32-be b 0 atari800-cl.audio:+audio-sample-rate+)
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
the bound port numbers (useful when started on ephemeral port 0).

Extra slots for rendering:
  FRAMEBUFFER   — 384×240 24-bit RGB pixel array written by the scanline
                  callback; converted to BGRA8888 and pushed to
                  VIDEO-CLIENTS as FRAME_RAW after each frame (see
                  %RGB24->BGRA32-CROPPED).
  VIDEO-CLIENTS — connections on the video port; frame data is pushed here.
  AUDIO-CLIENTS — connections on the audio port; PCM is pushed here.
  AUDIO-UNIT    — the AUDIO-UNIT attached to the machine while at least
                  one audio client is connected, else NIL.  Only the
                  emulator thread reads or writes it (see
                  %SYNC-AUDIO-ATTACHMENT).
  VIDEO-ACTIVE-P      — true while VIDEO-CLIENTS is non-empty; maintained
                        under LOCK by %REGISTER-/%UNREGISTER-VIDEO-CLIENT.
                        The scanline-fn closure reads this once per
                        scanline (unlocked — a stale read costs at most
                        one scanline's rendering either way, and the
                        write side already serializes through LOCK) to
                        skip rendering entirely when nobody is watching
                        (ROADMAP.md Phase 28a).
  NEEDS-FULL-RENDER-P — set whenever a video client registers; a client
                        connecting mid-frame would otherwise see a torn
                        frame (some rows rendered under the old gate
                        state, some not, once the gate was previously
                        closed). %PUSH-VIDEO-FRAME skips pushing while
                        this is set; the scanline-fn closure clears it at
                        row 0 of the next frame rendered with the gate
                        open, guaranteeing the following push is a clean
                        top-to-bottom render.  Mirrors the shape of
                        %SYNC-AUDIO-ATTACHMENT's connect/disconnect fix
                        for audio.
  PAYLOAD-BUFFER      — a preallocated BGRA8888 scratch buffer
                        ((* +AESP-FRAME-RAW-WIDTH+ 240 4) bytes), reused
                        by every push instead of allocating a fresh
                        ~322 KB vector per frame (Phase 28b; see
                        %RGB24->BGRA32-INTO and the 28b commit message
                        for why reuse is safe).
  PREV-FRAME          — a copy of the FRAMEBUFFER contents at the time
                        PAYLOAD-BUFFER was last (re)converted, used by
                        %FRAME-UNCHANGED-P to detect an unchanged screen
                        (Phase 28c) so an idle machine's push can resend
                        PAYLOAD-BUFFER unchanged instead of reconverting.
  PAYLOAD-VALID-P     — true when PREV-FRAME/PAYLOAD-BUFFER describe a
                        frame that was genuinely converted and sent, and
                        can therefore be trusted as the comparison base
                        and resent verbatim on a match.  Invalidation
                        rule: %UNREGISTER-VIDEO-CLIENT clears this the
                        moment the LAST video client leaves (VIDEO-
                        ACTIVE-P goes false), because that is exactly
                        when the scanline-fn gate stops keeping
                        FRAMEBUFFER current -- while the gate is closed,
                        FRAMEBUFFER is frozen at whatever it last held
                        and no longer reflects live machine state, so
                        PREV-FRAME/PAYLOAD-BUFFER (a snapshot of some
                        earlier, still-current frame) can no longer be
                        trusted as a valid comparison base or resend
                        candidate for whatever FRAMEBUFFER will contain
                        after a future reconnect.  Clearing PAYLOAD-
                        VALID-P forces the first push after any reconnect
                        to always take the copy+convert+send path (never
                        the cached-resend path), and that push is
                        guaranteed to see a freshly, completely rendered
                        FRAMEBUFFER courtesy of NEEDS-FULL-RENDER-P
                        above -- so a reconnecting client can never be
                        handed a cached payload of unknown vintage.
  RENDER-THIS-FRAME-P — ROADMAP.md Phase 29c's row-0 decision, remembered
                        for the rest of the frame's scanlines.  The
                        scanline-fn closure sets this at row 0 of every
                        frame it renders at all (VIDEO-ACTIVE-P true):
                        T when NEEDS-FULL-RENDER-P was set or
                        ATARI800-CL.MACHINE:MACHINE-DISPLAY-CHANGED-
                        SINCE-RENDER-P said the frame must render (in
                        which case it also calls ATARI800-CL.MACHINE:
                        MACHINE-NOTE-FULL-RENDER before rendering row 0),
                        NIL when the frame is clean and every row 0-239
                        this frame is skipped entirely (ATARI-MACHINE-
                        RENDER-SKIP-COUNT is bumped once, at that same
                        row-0 decision point).  %PUSH-VIDEO-FRAME reads
                        this same flag after the frame ends to decide
                        whether %FRAME-UNCHANGED-P's byte compare can be
                        skipped too -- see its docstring for how the two
                        flags (this one and PAYLOAD-VALID-P) interact.
                        Starts T: harmless, since VIDEO-ACTIVE-P gates
                        every read of it and the very first frame with a
                        client attached always forces NEEDS-FULL-
                        RENDER-P anyway."
  machine
  host
  control-listener video-listener audio-listener
  control-port video-port audio-port
  (lock          (make-lock "aesp-server"))
  (threads       '())
  (clients       '())
  (running       t)
  (framebuffer   nil)
  (video-clients '())
  (audio-clients '())
  (audio-unit    nil)
  (video-active-p      nil)
  (needs-full-render-p nil)
  (payload-buffer nil)
  (prev-frame      nil)
  (payload-valid-p nil)
  (render-this-frame-p t))

(defun %add-thread (server th)
  (with-lock ((aesp-server-lock server)) (push th (aesp-server-threads server)))
  th)

(defun %register-client (server conn)
  (with-lock ((aesp-server-lock server)) (push conn (aesp-server-clients server))))

(defun %unregister-client (server conn)
  (with-lock ((aesp-server-lock server))
    (setf (aesp-server-clients server) (remove conn (aesp-server-clients server)))))

(defun %register-video-client (server conn)
  "Register a video-port connection.  Sets VIDEO-ACTIVE-P (opening the
scanline-fn rendering gate, Phase 28a) and NEEDS-FULL-RENDER-P (so the
first frame pushed after this connect is guaranteed to be a complete
top-to-bottom render rather than whatever was mid-flight when the gate
opened -- see the AESP-SERVER docstring)."
  (with-lock ((aesp-server-lock server))
    (push conn (aesp-server-video-clients server))
    (setf (aesp-server-video-active-p server) t)
    (setf (aesp-server-needs-full-render-p server) t)))

(defun %unregister-video-client (server conn)
  "Unregister a video-port connection.  Clears VIDEO-ACTIVE-P (closing the
scanline-fn rendering gate) once the last video client is gone, and along
with it PAYLOAD-VALID-P (Phase 28c's invalidation rule -- see the
AESP-SERVER docstring's PAYLOAD-VALID-P entry: once the gate closes,
FRAMEBUFFER stops tracking live machine state, so PREV-FRAME/
PAYLOAD-BUFFER can no longer be trusted once it reopens)."
  (with-lock ((aesp-server-lock server))
    (setf (aesp-server-video-clients server)
          (remove conn (aesp-server-video-clients server)))
    (unless (aesp-server-video-clients server)
      (setf (aesp-server-payload-valid-p server) nil))
    (setf (aesp-server-video-active-p server)
          (and (aesp-server-video-clients server) t))))

(defun %register-audio-client (server conn)
  (with-lock ((aesp-server-lock server))
    (push conn (aesp-server-audio-clients server))))

(defun %unregister-audio-client (server conn)
  (with-lock ((aesp-server-lock server))
    (setf (aesp-server-audio-clients server)
          (remove conn (aesp-server-audio-clients server)))))

(defun %sync-audio-attachment (server machine have-clients-p)
  "Attach an audio unit to MACHINE while audio clients are connected and
detach it when the last one leaves, so machines nobody is listening to
do not pay for synthesis.

Called ONLY from the post-frame hook, i.e. on the emulator thread.
ROADMAP.md Phase 10 sketched doing this in the subscribe/unsubscribe
path under the server lock, but the acceptor and reader threads must
never touch the machine directly — that is the whole point of the
command mailbox — and a MACHINE-SUBMIT from an acceptor would deadlock
whenever no run loop is draining.  Deferring the decision to the
emulator thread is race-free and needs no lock at all; the cost is that
synthesis starts at the end of the frame during which the first client
connected, so that client's first PCM push arrives one frame later."
  (let ((unit (aesp-server-audio-unit server)))
    (cond
      ((and have-clients-p (null unit))
       (setf (aesp-server-audio-unit server) (machine-attach-audio machine)))
      ((and (not have-clients-p) unit)
       (machine-attach-audio machine nil)
       (setf (aesp-server-audio-unit server) nil)))))

(defun %push-audio-frame (server machine)
  "Drain the machine's accumulated PCM and send it to every audio-port
client as one AUDIO_PCM message (payload = the raw mono u8 samples).
Called on the emulator thread from ATARI-MACHINE-POST-FRAME-FN, right
after %PUSH-VIDEO-FRAME, so the Nth AUDIO_PCM pairs with the Nth
FRAME_RAW.  Clients that error during the write are silently dropped."
  (let ((clients (with-lock ((aesp-server-lock server))
                   (copy-list (aesp-server-audio-clients server)))))
    (%sync-audio-attachment server machine (and clients t))
    (when clients
      (let ((samples (machine-audio-drain machine)))
        ;; Empty on the frame synthesis was switched on: nothing to send.
        (when (plusp (length samples))
          (dolist (conn clients)
            (handler-case
                (write-aesp-message (tcp-stream conn) +aesp-audio-pcm+ samples)
              (error ()
                (%unregister-audio-client server conn)
                (ignore-errors (tcp-close conn))))))))))

(defun %rgb24->bgra32-into (rgb full-width height out)
  "Crop RGB (row-major, FULL-WIDTH x HEIGHT x 3 bytes/pixel) to the
Attic-compatible +AESP-FRAME-RAW-WIDTH+-column visible area (dropping
+AESP-FRAME-RAW-X1+ columns off each edge), convert to BGRA8888
(4 bytes/pixel, alpha 0xFF), and write the result into the caller-
supplied OUT buffer (sized (* +AESP-FRAME-RAW-WIDTH+ HEIGHT 4)) instead
of allocating a fresh one -- Phase 28b, so a push can reuse one scratch
buffer across frames rather than consing ~322 KB per push.  The
renderer's internal framebuffer stays full-width 24-bit RGB; both the
crop and the channel conversion happen only at this AESP push boundary.
Returns OUT.

RGB and OUT are declared (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*)): OUT
arrives as a parameter (the reused PAYLOAD-BUFFER), so without the
declaration the compiler cannot infer its element type the way it could
when the buffer was allocated locally, and SBCL falls back to generic
AREF dispatch across the ~322K writes per frame (measured -26% on the
serve workload before the declaration was added)."
  (declare (type (simple-array (unsigned-byte 8) (*)) rgb out)
           (type fixnum full-width height))
  (let ((out-width +aesp-frame-raw-width+))
    (dotimes (y height)
      (let ((row-src (* y full-width 3))
            (row-dst (* y out-width 4)))
        (dotimes (x out-width)
          (let ((si (+ row-src (* (+ x +aesp-frame-raw-x1+) 3)))
                (di (+ row-dst (* x 4))))
            (setf (aref out di)       (aref rgb (+ si 2))    ; B
                  (aref out (1+ di))  (aref rgb (1+ si))      ; G
                  (aref out (+ di 2)) (aref rgb si)            ; R
                  (aref out (+ di 3)) 255)))))                 ; A
    out))

(defun %rgb24->bgra32-cropped (rgb full-width height)
  "Like %RGB24->BGRA32-INTO but allocates and returns a fresh output
buffer.  Kept for callers (tests, tools) that want a one-off conversion;
%PUSH-VIDEO-FRAME itself uses %RGB24->BGRA32-INTO with AESP-SERVER's
reused PAYLOAD-BUFFER instead."
  (%rgb24->bgra32-into rgb full-width height
                       (%make-octets (* +aesp-frame-raw-width+ height 4))))

(defun %frame-unchanged-p (fb prev-frame)
  "T if FB (the live 24-bit RGB framebuffer) is byte-identical to
PREV-FRAME (a same-size snapshot).  Plain AREF -- this was Phase 28c's
single comparison seam, kept as the fallback path.  ROADMAP.md Phase 29c
adds a free alternative ahead of it at the call site in
%PUSH-VIDEO-FRAME: when the scanline-fn gate skipped rendering the whole
frame, FB provably still equals PREV-FRAME (nothing wrote to FB), so
that caller substitutes AESP-SERVER-RENDER-THIS-FRAME-P for a call to
this function instead of paying for the byte compare -- see
%PUSH-VIDEO-FRAME's docstring for the exact condition and the state
machine where the two flags meet.  This function itself is unchanged and
still the correct fallback whenever a frame WAS rendered and might or
might not have redrawn identical pixels (e.g. a static screen with the
skip's own analysis erring toward NIL from ANTIC-COLLECT-WATCHED-PAGES)."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb prev-frame))
  (dotimes (i (length fb) t)
    (unless (= (aref fb i) (aref prev-frame i))
      (return-from %frame-unchanged-p nil))))

(defun %push-video-frame (server machine)
  "Encode and send the current framebuffer to all video-port clients as
FRAME_RAW (BGRA8888, no frame-number prefix -- see docs/PROTOCOL.md in
the Attic project).  Called on the emulator thread (from
ATARI-MACHINE-POST-FRAME-FN).  Clients that error during the write are
silently dropped.

Snapshots the client list FIRST and returns before doing any conversion
work when it is empty (Phase 28a) -- with no video subscribers, the
scanline-fn gate already skipped rendering, so there is nothing correct
to convert anyway.  Also holds off pushing while NEEDS-FULL-RENDER-P is
set: a client that just connected mid-frame would otherwise receive a
torn frame (see AESP-SERVER's docstring and %REGISTER-VIDEO-CLIENT).

Dedup (Phase 28c, extended by Phase 29c): resending the existing
PAYLOAD-BUFFER verbatim -- no copy, no conversion -- requires
PAYLOAD-VALID-P, and then either of two ways to know FRAMEBUFFER equals
PREV-FRAME: RENDER-THIS-FRAME-P NIL (Phase 29c -- the scanline-fn gate
skipped every row this frame, so FRAMEBUFFER provably still holds
whatever it held when PREV-FRAME was last copied from it, no byte
compare needed), or failing that, %FRAME-UNCHANGED-P's byte compare
against PREV-FRAME (Phase 28c's original path -- still needed for a
frame that WAS rendered but happened to redraw identical pixels).  Every
OTHER case (changed; or PAYLOAD-VALID-P false, which happens right after
a reconnect invalidates it -- see %UNREGISTER-VIDEO-CLIENT) copies
FRAMEBUFFER into PREV-FRAME, converts once via %RGB24->BGRA32-INTO into
AESP-SERVER's preallocated PAYLOAD-BUFFER (Phase 28b -- reused across
pushes rather than consing a fresh ~322 KB buffer each time; safe
because WRITE-AESP-MESSAGE writes it out synchronously via
WRITE-SEQUENCE + FORCE-OUTPUT and retains no reference to it after
returning, see the 28b commit message), and sets PAYLOAD-VALID-P.  A
frame is NEVER suppressed outright -- every call that gets past the
gates above sends exactly one FRAME_RAW to every client, dedup only
skips the WORK, because %PUSH-AUDIO-FRAME's docstring pins the Nth
AUDIO_PCM to the Nth FRAME_RAW and A/V capture depends on that cadence.

Where the flags meet -- the state machine PAYLOAD-VALID-P /
RENDER-THIS-FRAME-P / NEEDS-FULL-RENDER-P form together:

  - NEEDS-FULL-RENDER-P set (client just connected/reconnected) ->
    the scanline-fn's row-0 decision is forced to render (it ORs this
    in), so RENDER-THIS-FRAME-P is T for this frame; this function's own
    NEEDS-FULL-RENDER-P check above still holds off the push entirely
    until row 0 has run and cleared it, so this branch of the dedup
    logic never actually observes NEEDS-FULL-RENDER-P set.
  - PAYLOAD-VALID-P false (no video client has ever gotten a real push
    since the gate last opened) with RENDER-THIS-FRAME-P T -> always
    takes the copy+convert+send path; a skip can't have produced this
    combination (see below), so this is the ordinary post-reconnect
    first-frame case.
  - PAYLOAD-VALID-P false with RENDER-THIS-FRAME-P NIL -> defensive
    case only, believed unreachable (a skip requires NEEDS-FULL-RENDER-P
    clear, which requires at least one prior render since reconnect,
    which sets PAYLOAD-VALID-P) but handled safely anyway: falls through
    to copy+convert+send, which is always correct (FRAMEBUFFER is
    genuinely current even on a skipped frame) even if the skip's
    freebie was missed.
  - PAYLOAD-VALID-P T with RENDER-THIS-FRAME-P NIL -> the free path:
    resend PAYLOAD-BUFFER, no byte compare, no conversion.
  - PAYLOAD-VALID-P T with RENDER-THIS-FRAME-P T -> Phase 28c's
    original path: %FRAME-UNCHANGED-P decides."
  (declare (ignore machine))
  ;; Snapshot the list under lock, then write outside the lock so a slow
  ;; client doesn't block the emulator thread indefinitely.
  (let ((clients (with-lock ((aesp-server-lock server))
                   (copy-list (aesp-server-video-clients server)))))
    (when (null clients) (return-from %push-video-frame nil))
    (when (aesp-server-needs-full-render-p server)
      (return-from %push-video-frame nil))
    (let ((fb (aesp-server-framebuffer server)))
      (when (null fb) (return-from %push-video-frame nil))
      (let* ((prev (aesp-server-prev-frame server))
             (unchanged-p
               (and (aesp-server-payload-valid-p server)
                    prev
                    (or (not (aesp-server-render-this-frame-p server))
                        (%frame-unchanged-p fb prev))))
             (payload
               (if unchanged-p
                   (aesp-server-payload-buffer server)
                   (progn
                     (replace prev fb)
                     (%rgb24->bgra32-into
                      fb atari800-cl.renderer:+framebuffer-width+
                      atari800-cl.renderer:+framebuffer-height+
                      (aesp-server-payload-buffer server))
                     (setf (aesp-server-payload-valid-p server) t)
                     (aesp-server-payload-buffer server)))))
        (dolist (conn clients)
          (handler-case
              (write-aesp-message (tcp-stream conn) +aesp-frame-raw+ payload)
            (error ()
              (%unregister-video-client server conn)
              (ignore-errors (tcp-close conn)))))))))

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

;;; ---------------------------------------------------------------------------
;;; Host disk bridge (ROADMAP.md Phase 16, revised; stage 16e)

(defun %decode-mount-path (payload)
  "Decode the UTF-8 path bytes following MOUNT/LOAD_XEX's leading
[unit][read-only] pair."
  (flexi-streams:octets-to-string payload :start 2 :external-format :utf-8))

(defun %submit-hostdev-op (server stream thunk)
  "Like %SUBMIT-OR-BUSY, but also maps any other error (bad unit, missing
file, malformed ATR/XEX) to ERROR/+AESP-ERR-MOUNT-FAILED+ instead of
letting it escape the reader loop and drop the connection.  THUNK is
called with the machine's HOST-BRIDGE (not the machine itself) as its
only argument, since every hostdev entry point takes a bridge."
  (handler-case
      (progn (machine-submit (aesp-server-machine server)
                             (lambda (m) (funcall thunk (atari-machine-hostdev m)))
                             :priority t)
             (%ack stream))
    (mailbox-full ()
      (write-aesp-message stream +aesp-error+ (%octets-of +aesp-err-server-busy+)))
    (error ()
      (write-aesp-message stream +aesp-error+ (%octets-of +aesp-err-mount-failed+)))))

(defun %handle-mount (server stream payload)
  "MOUNT: [unit][read-only][path...] -> ATARI800-CL.HOSTDEV:MOUNT-DISK-FILE."
  (if (< (length payload) 3)
      (write-aesp-message stream +aesp-error+ (%octets-of +aesp-err-mount-failed+))
      (let ((unit (aref payload 0))
            (read-only (/= 0 (aref payload 1)))
            (path (%decode-mount-path payload)))
        (%submit-hostdev-op server stream
          (lambda (bridge)
            (atari800-cl.hostdev:mount-disk-file bridge unit path :read-only read-only))))))

(defun %handle-unmount (server stream payload)
  "UNMOUNT: [unit] -> ATARI800-CL.HOSTDEV:UNMOUNT-DISK."
  (if (< (length payload) 1)
      (write-aesp-message stream +aesp-error+ (%octets-of +aesp-err-mount-failed+))
      (let ((unit (aref payload 0)))
        (%submit-hostdev-op server stream
          (lambda (bridge) (atari800-cl.hostdev:unmount-disk bridge unit))))))

(defun %handle-load-xex (server stream payload)
  "LOAD_XEX: [unit][read-only][path...] -> ATARI800-CL.HOSTDEV:LOAD-XEX."
  (if (< (length payload) 3)
      (write-aesp-message stream +aesp-error+ (%octets-of +aesp-err-mount-failed+))
      (let ((unit (aref payload 0))
            (read-only (/= 0 (aref payload 1)))
            (path (%decode-mount-path payload)))
        (%submit-hostdev-op server stream
          (lambda (bridge)
            (atari800-cl.hostdev:load-xex bridge unit path :read-only read-only))))))

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
      (#.+aesp-mount+     (%handle-mount server stream payload))
      (#.+aesp-unmount+   (%handle-unmount server stream payload))
      (#.+aesp-load-xex+  (%handle-load-xex server stream payload))
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
    (case kind
      (:video (%unregister-video-client server conn))
      (:audio (%unregister-audio-client server conn))
      (t      (%unregister-client server conn)))
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
        (t (case kind
             (:video (%register-video-client server conn))
             (:audio (%register-audio-client server conn))
             (t      (%register-client server conn)))
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
                         :audio-port   (tcp-listener-port al)
                         :framebuffer  (atari800-cl.renderer:make-framebuffer)
                         :payload-buffer (%make-octets
                                          (* +aesp-frame-raw-width+ 240 4))
                         :prev-frame   (atari800-cl.renderer:make-framebuffer))))
            ;; Wire the scanline and post-frame callbacks into the machine.
            ;; The scanline-fn early-returns when no video client is
            ;; connected (Phase 28a): rendering to a framebuffer nobody
            ;; will ever read is pure waste, and %PUSH-VIDEO-FRAME already
            ;; refuses to push with an empty client list.  When the gate
            ;; is open again after being closed, row 0 clears
            ;; NEEDS-FULL-RENDER-P so the frame that just started
            ;; rendering top-to-bottom is the one %PUSH-VIDEO-FRAME will
            ;; accept as complete.
            ;;
            ;; ROADMAP.md Phase 29c: the decision to render THIS frame at
            ;; all is made exactly once, at row 0, and remembered in
            ;; RENDER-THIS-FRAME-P for the rest of the frame's rows -- not
            ;; recomputed per scanline.  Row 0 either forces a render
            ;; (NEEDS-FULL-RENDER-P set, or ATARI800-CL.MACHINE:MACHINE-
            ;; DISPLAY-CHANGED-SINCE-RENDER-P says something the frame
            ;; depends on changed) -- in which case ATARI800-CL.MACHINE:
            ;; MACHINE-NOTE-FULL-RENDER is called BEFORE rendering row 0,
            ;; so writes racing the beam during this very frame correctly
            ;; accumulate toward the NEXT decision instead of being
            ;; swallowed by a clear that already happened -- or it skips,
            ;; bumping ATARI-MACHINE-RENDER-SKIP-COUNT once and leaving
            ;; every row this frame unrendered (FRAMEBUFFER keeps
            ;; whatever it held after the last real render, which is
            ;; exactly correct: nothing that could change it did).
            (setf (atari-machine-scanline-fn machine)
                  (let ((fb (aesp-server-framebuffer server)))
                    (lambda (m)
                      (when (aesp-server-video-active-p server)
                        (let* ((a   (atari-machine-antic m))
                               (sl  (mod (1- (atari800-cl.antic:antic-scanline a))
                                         atari800-cl.antic:+scanlines-per-frame+))
                               (row (- sl atari800-cl.antic:+active-start-scanline+)))
                          (when (and (>= row 0) (< row 240))
                            (when (zerop row)
                              (let ((render-p
                                      (or (aesp-server-needs-full-render-p server)
                                          (machine-display-changed-since-render-p m))))
                                (setf (aesp-server-needs-full-render-p server) nil)
                                (if render-p
                                    (machine-note-full-render m)
                                    (incf (atari-machine-render-skip-count m)))
                                (setf (aesp-server-render-this-frame-p server) render-p)))
                            (when (aesp-server-render-this-frame-p server)
                              (atari800-cl.renderer:render-scanline
                               fb row a
                               (atari-machine-gtia m)
                               (atari-machine-bus  m)))))))))
            (setf (atari-machine-post-frame-fn machine)
                  (lambda (m)
                    (%push-video-frame server m)
                    (%push-audio-frame server m)))
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
  ;; Clear machine callbacks so the server struct is no longer referenced
  ;; from the machine after stop.  Detach audio too: nothing will drain it
  ;; once the post-frame hook is gone, so leaving it attached would make
  ;; the machine synthesise into a buffer that only grows.  Both happen
  ;; here rather than on the emulator thread because the callbacks are
  ;; already cleared, so no frame can be mid-push.
  (setf (atari-machine-scanline-fn   (aesp-server-machine server)) nil
        (atari-machine-post-frame-fn (aesp-server-machine server)) nil)
  (when (aesp-server-audio-unit server)
    (machine-attach-audio (aesp-server-machine server) nil)
    (setf (aesp-server-audio-unit server) nil))
  (tcp-close (aesp-server-control-listener server))
  (tcp-close (aesp-server-video-listener server))
  (tcp-close (aesp-server-audio-listener server))
  (dolist (conn (copy-list (aesp-server-clients server)))
    (tcp-close conn))
  (dolist (conn (copy-list (aesp-server-video-clients server)))
    (ignore-errors (tcp-close conn)))
  (dolist (conn (copy-list (aesp-server-audio-clients server)))
    (ignore-errors (tcp-close conn)))
  (let ((deadline (+ (get-internal-real-time)
                     (truncate (* timeout internal-time-units-per-second)))))
    (dolist (th (copy-list (aesp-server-threads server)))
      (loop while (and (thread-alive-p th) (< (get-internal-real-time) deadline))
            do (sleep 0.005))
      (when (thread-alive-p th) (destroy-thread th))))
  server)
