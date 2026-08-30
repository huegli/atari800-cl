;;;; src/sio.lisp --- SIO serial-wire device dispatch (ROADMAP.md Phase 25b).
;;;;
;;;; Where src/hostdev.lisp is a memory-mapped shortcut (the OS never
;;;; touches it), this file is the real thing: a device layer on the SIO
;;;; serial wire.  POKEY hands every byte the OS finishes transmitting to
;;;; the SERIAL-OUT-FN hook (Phase 25a); an attached SIO-BUS watches that
;;;; stream, accumulates 5-byte command frames, verifies the checksum,
;;;; and answers through POKEY-QUEUE-SERIAL-IN with the ACK / COMPLETE /
;;;; data-frame sequence and the inter-frame delays the OS expects.  With
;;;; a disk image mounted and the real OS ROM, the machine boots DOS over
;;;; the wire -- every sector load crossing the emulated serial port.
;;;;
;;;; Wire protocol (verified against the XL OS Rev. 2 source in the
;;;; minimal-xl/ submodule -- the SIO, WCA, and SID routines -- and
;;;; against atari800's src/sio.c):
;;;;
;;;;   command frame, computer -> device, 5 bytes:
;;;;     id, command, aux1, aux2, checksum
;;;;     where id = DDEVIC + DUNIT - 1 ($31 + unit - 1 for disks), the
;;;;     checksum is the fold-sum of the first four bytes (add each byte,
;;;;     subtract 255 whenever the sum carries: the OS's own CHKSUM loop),
;;;;     and the device compares byte-for-byte -- a mismatch means the
;;;;     frame is corrupt.
;;;;   device -> computer:
;;;;     ACK $41 'A'       -- command frame received, ~44 scanlines after
;;;;                          its checksum byte finished shifting out
;;;;     COMPLETE $43 'C'  -- operation succeeded; for read/status commands
;;;;                          the data frame follows: the payload bytes,
;;;;                          back-to-back at the wire's own byte time,
;;;;                          then the payload's fold-sum checksum
;;;;     ERROR $45 'E'     -- operation failed
;;;;     NAK $4E 'N'       -- frame refused outright; the OS sends no data
;;;;                          frame afterwards (this is what lets the
;;;;                          accumulator stay frame-aligned without
;;;;                          implementing an incoming-data phase)
;;;;
;;;; Device dispatch is by id byte: REGISTER-SIO-DEVICE installs a handler
;;;; at an id, REGISTER-SIO-DISK installs one disk handler at every drive
;;;; id $31-$38 at once.  A handler is consulted live on each command
;;;; frame, so mounting or unmounting through the host bridge (whose
;;;; drives vector the disk handler reads -- one source of truth for
;;;; mounted images, shared with the $D1xx bridge) takes effect on the
;;;; next command frame.
;;;;
;;;; Writes are refused at the command frame with NAK: the project has no
;;;; ATR write support (the host bridge rejects writes the same way), and
;;;; refusing before the data phase means the byte stream stays command-
;;;; frame aligned.  A real write-protected 810 ACKs and then errors only
;;;; after swallowing the data frame; that dance buys nothing here.

;;; The DEFPACKAGE lives in src/package.lisp with every other package
;;; (load order: package.lisp runs before this file, and
;;; atari800-cl.machine's DEFPACKAGE :USEs this one).

(in-package #:atari800-cl.sio)

;;; ---------------------------------------------------------------------------
;;; Protocol constants

(defconstant +sio-ack+      #x41 "Wire byte 'A': command frame acknowledged.")
(defconstant +sio-complete+ #x43 "Wire byte 'C': operation succeeded.")
(defconstant +sio-error+    #x45 "Wire byte 'E': operation failed.")
(defconstant +sio-nak+      #x4E "Wire byte 'N': frame refused; the sender
follows with no data frame.")

(defconstant +sio-command-frame-length+ 5
  "Bytes in a SIO command frame: id, command, aux1, aux2, checksum.")

(defconstant +sio-ack-delay+ 5016
  "CPU cycles from the command frame's checksum byte finishing on the wire
to the device's ACK: 44 scanlines x 114 cycles, the figure atari800's
src/sio.c uses (the OS's own timeout is far longer, so a constant here is
safe).")

(defconstant +sio-complete-delay+ 3648
  "CPU cycles from the ACK byte landing to COMPLETE (or ERROR): 32
scanlines x 114 cycles, as in atari800's serial read path.")

(declaim (inline %sio-checksum))

(defun %sio-checksum (bytes)
  "The SIO fold-sum of BYTES: add each byte, and whenever the sum exceeds
255 subtract 255 -- carry folded back, exactly the OS's own CHKSUM loop
('ADC CHKSUM / ADC #0').  Returned as the wire checksum byte: the sender
transmits this value, the receiver recomputes and compares equal."
  (declare (type list bytes))
  (let ((sum 0))
    (declare (type fixnum sum))
    (dolist (b bytes sum)
      (declare (type u8 b))
      (incf sum b)
      (when (> sum 255)
        (decf sum 255)))))

;;; ---------------------------------------------------------------------------
;;; The SIO bus

(defstruct sio-bus
  "Serial-wire SIO device layer: watches the bytes POKEY finishes
transmitting (via the SERIAL-OUT-FN hook ATTACH-SIO-BUS installs),
accumulates command frames, and queues the device replies into POKEY's
serial input receiver.

Slots:
  DEVICES      -- 256-entry simple-vector indexed by the command frame's
                  device-id byte; each entry is a handler function or NIL
                  (NIL = no device at that id: the frame is met with
                  silence, and the OS times out, exactly like addressing a
                  drive that is not there).
  POKEY        -- the chip this bus is attached to (set by ATTACH-SIO-BUS);
                  replies are queued through POKEY-QUEUE-SERIAL-IN, so the
                  turnaround delays land as (GAP . BYTE) wire schedule
                  entries.
  FRAME        -- the 5-byte command-frame accumulator.
  FRAME-COUNT   -- bytes accumulated in FRAME so far (0-4).

A handler is called as (FUNCALL HANDLER UNIT COMMAND AUX1 AUX2) -- no
sio-bus argument, because replies are declarative, not imperative: the
handler returns (VALUES PLAN DATA) where PLAN is

  NIL         -- silence: no reply at all (the OS times out).
  :COMPLETE   -- ACK, then COMPLETE, then DATA (a list of u8) followed by
                 its fold-sum checksum.  DATA may be NIL for a bare
                 COMPLETE.
  :ERROR      -- ACK, then ERROR.
  :NAK        -- NAK only, immediately: the command is refused and the
                 sender follows with no data frame, so the accumulator
                 stays aligned (see the write-refusal note above).

UNIT is derived from the frame's id byte ($31 -> 1: the OS sends DDEVIC +
DUNIT - 1)."

  (devices (make-array 256 :initial-element nil) :type simple-vector)
  (pokey nil)
  (frame (make-array +sio-command-frame-length+
                     :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (5)))
  (frame-count 0 :type fixnum))

(defun %sio-queue-reply (sio entries)
  "Queue ENTRIES ((GAP . BYTE) pairs, in wire order) into the attached
POKEY's serial input receiver.  The receiver adds its own byte time per
entry, so back-to-back bytes take gap 0."
  (let ((pokey (sio-bus-pokey sio)))
    (when pokey
      (pokey-queue-serial-in pokey entries)))
  (values))

(defun %sio-data-entries (data)
  "Wire-schedule entries for the data frame: each payload byte with gap 0
(the receiver's own byte time provides the baud-rate spacing), then the
fold-sum checksum byte."
  (declare (type list data))
  (let ((entries (loop for b in data
                       collect (cons 0 (the u8 b)))))
    (if (null entries)
        nil
        (nconc entries (list (cons 0 (%sio-checksum data)))))))

(defun %sio-dispatch (sio)
  "Handle the complete command frame sitting in SIO's FRAME accumulator:
verify the checksum, find the addressed device's handler, and queue the
reply the handler's plan describes.  The accumulator is reset first, so a
silence path leaves the bus ready for the OS's next frame.

The checksum is verified byte-for-byte (unlike atari800, which skips
command-frame verification): a corrupt frame gets a NAK -- what a real
drive answers -- and the OS's retry then starts a fresh frame, which the
reset accumulator is aligned to."
  (let* ((frame (sio-bus-frame sio))
         (id    (aref frame 0))
         (cmd   (aref frame 1))
         (aux1  (aref frame 2))
         (aux2  (aref frame 3))
         (cksum (aref frame 4)))
    (setf (sio-bus-frame-count sio) 0)
    (cond
      ((/= cksum (%sio-checksum (list id cmd aux1 aux2)))
       ;; Corrupt frame: NAK it, aligned to the retry's fresh frame.
       (%sio-queue-reply sio (list (cons +sio-ack-delay+ +sio-nak+))))
      (t
       (let ((handler (svref (sio-bus-devices sio) id)))
         (when handler
           (multiple-value-bind (plan data) (funcall handler
                                                      (- id #x30) ; unit = id - $30
                                                      cmd aux1 aux2)
             (ecase plan
               ((nil) (values))     ; silence: no device answer
               (:complete
                (%sio-queue-reply
                 sio (nconc (list (cons +sio-ack-delay+ +sio-ack+)
                                  (cons +sio-complete-delay+ +sio-complete+))
                            (%sio-data-entries data))))
               (:error
                (%sio-queue-reply
                 sio (list (cons +sio-ack-delay+ +sio-ack+)
                           (cons +sio-complete-delay+ +sio-error+))))
               (:nak
                (%sio-queue-reply
                 sio (list (cons +sio-ack-delay+ +sio-nak+))))))))))))

(defun sio-wire-byte (sio byte)
  "Absorb one byte the OS just finished transmitting (the SERIAL-OUT-FN
hook body).  Bytes accumulate into the command-frame buffer until the
fifth arrives, then %SIO-DISPATCH runs.  Called from inside
%SERIAL-OUT-ADVANCE, so anything it queues (via POKEY-QUEUE-SERIAL-IN)
starts on the next POKEY-TICK / POKEY-ADVANCE's receiver charge at the
earliest -- a skew of at most one advance, invisible next to the
~5000-cycle inter-frame gaps."
  (declare (type sio-bus sio) (type u8 byte))
  (let ((frame (sio-bus-frame sio))
        (count (sio-bus-frame-count sio)))
    (setf (aref frame count) byte
          (sio-bus-frame-count sio) (1+ count))
    (when (= (sio-bus-frame-count sio) +sio-command-frame-length+)
      (%sio-dispatch sio)))
  (values))

(defun attach-sio-bus (sio pokey)
  "Install SIO as POKEY's serial-wire watcher: every byte the transmitter
finishes shifting reaches SIO-WIRE-BYTE, and SIO remembers POKEY so its
replies queue into the receiver.  Returns SIO.  A machine built without
this call leaves POKEY's SERIAL-OUT-FN NIL: transmitted bytes are simply
dropped, and the OS times out waiting for devices -- pre-Phase-25
behavior, byte for byte."
  (declare (type sio-bus sio) (type pokey pokey))
  (setf (sio-bus-pokey sio) pokey
        (pokey-serial-out-fn pokey) (lambda (byte) (sio-wire-byte sio byte)))
  sio)

(defun reset-sio-bus (sio)
  "Reset the command-frame accumulator (a cold reset mid-frame must not
leave the bus swallowing the OS's next frame at the wrong offset).
Registered devices and the POKEY attachment survive, like every other
emulator-level attachment.  Returns SIO."
  (declare (type sio-bus sio))
  (setf (sio-bus-frame-count sio) 0)
  sio)

(defun register-sio-device (sio id handler)
  "Install HANDLER as the device at command-frame id byte ID (for disks,
$31 = D1:, $32 = D2:, ...).  Returns SIO."
  (declare (type sio-bus sio) (type u8 id))
  (setf (svref (sio-bus-devices sio) id) handler)
  sio)

;;; ---------------------------------------------------------------------------
;;; The disk device
;;;
;;; One handler serves all eight drive ids: the frame's id byte already
;;; encodes the unit ($31 + unit - 1), so a single closure parameterized by
;;; the host bridge covers D1:-D8:.  The handler reads the bridge's drives
;;; vector live, so the same MOUNT-DISK / MOUNT-DISK-FILE / UNMOUNT-DISK
;;; API serves both the $D1xx bridge and the wire.

(defun make-sio-disk-device (bridge)
  "Return a serial-wire disk-drive handler backed by BRIDGE's mounted ATR
images (the same HOST-BRIDGE the $D1xx device reads: one mount API, two
transports).  The handler answers:

  'S' (status)  -- COMPLETE + the 4-byte status block (STATUS-DRIVE-
                   BLOCK: write-protect and density bits the OS's DOS
                   logic keys on).
  'R' (read)    -- COMPLETE + the sector's bytes + checksum; aux1/aux2
                   are the little-endian sector number.  Out-of-range
                   sectors get ERROR (the drive is there, the sector is
                   not -- not the silence of an absent drive).
  'P'/'W' (write/put) -- NAK: this project supports no ATR writes (the
                   host bridge rejects them identically), and refusing
                   before the data phase keeps the accumulator aligned.
  anything else -- ERROR, as an unknown-but-present drive answers.

An empty drive slot answers NIL (silence): addressing a drive with no
disk in it times out, exactly like real hardware with the drive off."
  (declare (type host-bridge bridge))
  (lambda (unit command aux1 aux2)
    (declare (type fixnum unit) (type u8 command aux1 aux2))
    (let ((image (and (<= 1 unit +max-drives+)
                      (mounted-disk bridge unit))))
      (cond
        ((null image) nil)
        ((= command +cmd-status+)
         (values :complete (status-drive-block image)))
        ((= command +cmd-read+)
         (let ((sector (logior aux1 (ash aux2 8))))
           (let ((bytes (atr-read-sector image sector)))
             (if (null bytes)
                 (values :error nil)
                 (values :complete (coerce bytes 'list))))))
        ((or (= command +cmd-write+) (= command +cmd-write-verify+))
         (values :nak nil))
        (t (values :error nil))))))

(defun register-sio-disk (sio bridge)
  "Install BRIDGE-backed disk handlers at every drive id $31-$38 (D1:-D8:)
at once.  Returns SIO.  Call after ATTACH-SIO-BUS or before -- the
handlers are consulted per frame either way."
  (declare (type sio-bus sio) (type host-bridge bridge))
  (let ((handler (make-sio-disk-device bridge)))
    (dotimes (i +max-drives+)
      (register-sio-device sio (+ +device-disk+ i) handler))
    sio))