;;;; tests/test-sio.lisp --- SIO serial-wire device dispatch tests.
;;;;
;;;; ROADMAP.md Phase 25b: the command-frame accumulator, checksum
;;;; verification, device dispatch by id, and the reply wire schedules
;;;; (ACK / COMPLETE / data frame with the inter-frame delays the OS
;;;; expects) -- plus one end-to-end pass where the OS's half of the wire
;;;; is played through real SEROUT writes and the reply is collected from
;;;; real SERIN reads, POKEY carrying every byte in both directions.

(in-package #:atari800-cl/tests)

(def-suite sio-suite
  :description "SIO serial-wire device dispatch (ROADMAP.md Phase 25b)."
  :in atari800-cl-suite)

(in-suite sio-suite)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;;
;;; %MAKE-SERIAL-FIXTURE (tests/test-pokey.lisp) supplies POKEY wired the
;;; way SIO uses it -- channels 3+4 linked at 1.79 MHz, SKCTL send mode --
;;; with a byte time of 200 cycles at its default AUDF3/AUDF4.  The SIO
;;; fixture attaches a SIO-BUS whose disk handlers read a HOST-BRIDGE with
;;; a 4-sector synthetic single-density ATR (from %MAKE-SD-ATR-BYTES,
;;; tests/test-hostdev.lisp: sector N is filled entirely with its own
;;; 1-based sector number) mounted at drive 1.

(defun %make-sio-fixture (&key (mounted t))
  "Returns (values pokey cpu bus sio bridge).  When MOUNTED, drive 1 has
the standard synthetic ATR; otherwise the bridge starts empty (mount it
in the test with MOUNT-DISK)."
  (multiple-value-bind (pok cpu bus) (%make-serial-fixture :irqen 0)
    (let* ((bridge (atari800-cl.hostdev:make-host-bridge))
           (sio    (atari800-cl.sio:make-sio-bus)))
      (when mounted
        (atari800-cl.hostdev:mount-disk
         bridge 1 (atari800-cl.hostdev:parse-atr-bytes (%make-sd-atr-bytes 4))))
      (atari800-cl.sio:register-sio-disk sio bridge)
      (atari800-cl.sio:attach-sio-bus sio pok)
      (values pok cpu bus sio bridge))))

(defun %fold (bytes)
  "The SIO fold-sum, mirrored here from the OS's own CHKSUM loop so the
tests check the wire bytes against an independent statement of the
algorithm: add each byte, subtract 255 whenever the sum carries."
  (let ((sum 0))
    (dolist (b bytes sum)
      (incf sum b)
      (when (> sum 255) (decf sum 255)))))

(defun %feed-frame (sio id command aux1 aux2 &key (checksum (atari800-cl.sio::%sio-checksum
                                                              (list id command aux1 aux2))))
  "Feed SIO a 5-byte command frame through the SERIAL-OUT-FN hook body,
exactly as the transmitter's completions would.  CHECKSUM defaults to the
correct fold-sum; pass another value to test corruption."
  (dolist (b (list id command aux1 aux2 checksum))
    (atari800-cl.sio::sio-wire-byte sio b)))

(defun %queued-reply (pokey)
  "The wire schedule currently loaded in POKEY's serial input receiver:
(GAP . BYTE) pairs in wire order.  POKEY-QUEUE-SERIAL-IN starts the head
the moment it is queued (the byte and its countdown move into
SERIAL-IN-BYTE / SERIAL-IN-CYCLES), so the head has to be reassembled:
its gap is the countdown minus the shift time, exact because these
structure tests never tick the receiver.  NIL when nothing is queued."
  (let ((cycles (atari800-cl.pokey:pokey-serial-in-cycles pokey)))
    (if (and (zerop cycles) (null (atari800-cl.pokey:pokey-serial-in-queue pokey)))
        nil
        (cons (cons (- cycles (atari800-cl.pokey::%serial-byte-cycles pokey))
                    (atari800-cl.pokey:pokey-serial-in-byte pokey))
              (atari800-cl.pokey:pokey-serial-in-queue pokey)))))

;;; ---------------------------------------------------------------------------
;;; Command frame handling

(test sio-status-command-answers-ack-complete-status-block
  "'S' (status) at drive 1: ACK after +SIO-ACK-DELAY+, COMPLETE
+SIO-COMPLETE-DELAY+ later, then the 4-byte status block and its fold-sum
checksum, back-to-back.  The status block is the same one the $D1xx
bridge reports for the same image (STATUS-DRIVE-BLOCK): read-only single
density, so byte 0 carries only the write-protect bit."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (%feed-frame sio #x31 #x53 0 0)
    (let ((queue (%queued-reply pok)))
      (is (= 7 (length queue)) "ACK + COMPLETE + 4 data + 1 checksum")
      (is (equal (nth 0 queue) (cons atari800-cl.sio:+sio-ack-delay+ #x41)))
      (is (equal (nth 1 queue) (cons atari800-cl.sio:+sio-complete-delay+ #x43)))
      ;; Status block: $01 $FF $E0 $00, then its fold-sum.
      (is (equal (mapcar #'cdr (subseq queue 2 6)) '(#x01 #xFF #xE0 #x00)))
      (is (= (cdr (nth 6 queue)) (%fold '(#x01 #xFF #xE0 #x00)))
          "the trailing checksum byte must be the payload's fold-sum")
      (is (equal (mapcar #'car (subseq queue 2))
                 '(0 0 0 0 0))
          "data-frame bytes ride back-to-back: the receiver's own byte
           time is the baud-rate spacing"))))

(test sio-read-command-answers-sector-contents
  "'R' (read) of sector 2 (aux1/aux2 little-endian): ACK, COMPLETE, the
sector's 128 bytes, checksum.  The synthetic image fills sector N with N,
so the payload is 128 copies of 2."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (%feed-frame sio #x31 #x52 2 0)
    (let ((queue (%queued-reply pok)))
      (is (= 131 (length queue)) "ACK + COMPLETE + 128 data + 1 checksum")
      (is (equal (mapcar #'cdr (subseq queue 2 130))
                 (make-list 128 :initial-element 2)))
      (is (= (cdr (nth 130 queue)) (%fold (make-list 128 :initial-element 2)))))))

(test sio-drive-unit-comes-from-the-id-byte
  "The id byte encodes the unit ($31 = D1:, $32 = D2:): a read addressed
to $32 with no disk in drive 2 meets silence, and mounting into drive 2
through the ordinary bridge API turns the same command into a reply --
the mount API serves both transports."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus))
    (%feed-frame sio #x32 #x53 0 0)
    (is-false (%queued-reply pok) "drive 2 is empty: silence")
    (atari800-cl.hostdev:mount-disk
     bridge 2 (atari800-cl.hostdev:parse-atr-bytes (%make-sd-atr-bytes 1)))
    (%feed-frame sio #x32 #x53 0 0)
    (is-true (%queued-reply pok) "mounting into drive 2 answers on the wire")))

(test sio-bad-checksum-gets-nak
  "A corrupt command frame is NAKed after the ACK delay and nothing else:
the OS treats that as an immediate error and retries with a fresh frame,
and the accumulator has already reset, so the retry aligns."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (%feed-frame sio #x31 #x53 0 0 :checksum #x00)
    (let ((queue (%queued-reply pok)))
      (is (= 1 (length queue)))
      (is (equal (first queue)
                 (cons atari800-cl.sio:+sio-ack-delay+ atari800-cl.sio:+sio-nak+))))))

(test sio-unknown-device-id-and-empty-drive-are-silence
  "No handler at the id, or no disk in the addressed drive: no reply at
all -- the OS times out, exactly like hardware with nothing listening.
This is the path that keeps a drive-less machine booting to BASIC."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (%feed-frame sio #x50 #x53 0 0)            ; id $50: nothing there
    (is-false (%queued-reply pok))
    (%feed-frame sio #x38 #x53 0 0)            ; drive 8: registered, empty
    (is-false (%queued-reply pok))))

(test sio-write-commands-are-refused-with-nak
  "'P' (put) and 'W' (put with verify) are NAKed immediately: this
project supports no ATR writes (the $D1xx bridge rejects them the same
way), and refusing at the command frame means the OS never sends the
data frame, so the accumulator cannot desync on it."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (%feed-frame sio #x31 #x50 1 0)
    (let ((queue (%queued-reply pok)))
      (is (= 1 (length queue)))
      (is (eq (cdr (first queue)) atari800-cl.sio:+sio-nak+)))
    (setf (atari800-cl.pokey:pokey-serial-in-queue pok) nil)
    (%feed-frame sio #x31 #x57 1 0)
    (is (eq (cdr (first (%queued-reply pok))) atari800-cl.sio:+sio-nak+))))

(test sio-out-of-range-sector-gets-error
  "A read of a sector the image does not have: the drive is present (it
ACKed) but the operation failed -- ACK then ERROR, no data frame."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (%feed-frame sio #x31 #x52 99 0)
    (let ((queue (%queued-reply pok)))
      (is (= 2 (length queue)))
      (is (= (cdr (first queue)) atari800-cl.sio:+sio-ack+))
      (is (= (cdr (second queue)) atari800-cl.sio:+sio-error+)))))

(test sio-unknown-command-gets-error
  "A command the drive does not implement: ACK then ERROR, the answer of
a present-but-baffled device."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (%feed-frame sio #x31 #x21 0 0)            ; format: not implemented
    (let ((queue (%queued-reply pok)))
      (is (= 2 (length queue)))
      (is (= (cdr (second queue)) atari800-cl.sio:+sio-error+)))))

(test sio-reset-clears-a-partial-frame
  "RESET-SIO-BUS drops a half-accumulated frame, so a cold reset mid-frame
cannot leave the bus swallowing the OS's next frame at the wrong offset."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore cpu bus bridge))
    (dolist (b (list #x31 #x53 #x00))
      (atari800-cl.sio::sio-wire-byte sio b))
    (atari800-cl.sio:reset-sio-bus sio)
    (is-false (%queued-reply pok) "three bytes never dispatched")
    ;; The next five bytes are treated as a fresh frame from byte 0.
    (%feed-frame sio #x31 #x53 0 0)
    (is (= 7 (length (%queued-reply pok))))))

;;; ---------------------------------------------------------------------------
;;; End to end over the emulated wire
;;;
;;; The OS's half played for real: five SEROUT writes (SKCTL already in
;;; send mode from the fixture), POKEY shifting each byte out at its byte
;;; time, the SIO hook firing at each completion, and the reply collected
;;; from SERIN reads as the receiver lands each byte.

(defun %wire-round-trip (pok cpu bus command-frame n-reply
                         &key (max-cycles 60000))
  "Play one full SIO transaction over the emulated wire.  The command
frame is transmitted the way the OS transmits it: SEROUT writes paced on
the holding register freeing up (SEROR), because the holding register
holds only one queued byte -- five back-to-back writes would lose three.
The reply is collected from SERIN reads as the receiver lands each byte;
POKEY is ticked once per CPU cycle throughout.  Returns the reply bytes
in arrival order."
  (declare (type atari800-cl.pokey:pokey pok))
  (let ((to-send command-frame)
        (collected nil))
    (dotimes (i max-cycles)
      ;; Feed the next command byte once SEROUT's holding register is
      ;; free: byte 1 goes straight into the shift register (holding
      ;; still empty, so byte 2 follows immediately into holding), and
      ;; each later byte waits for the one in flight to complete.
      (when (and to-send
                 (null (atari800-cl.pokey:pokey-serial-out-holding pok)))
        (atari800-cl.bus:bus-write bus #xD20D (pop to-send)))
      (atari800-cl.pokey:pokey-tick pok cpu)
      (when (atari800-cl.pokey:pokey-serial-in-unread pok)
        (push (atari800-cl.bus:bus-read bus #xD20D) collected)
        ;; RETURN, not RETURN-FROM a wrapping block: only the DOTIMES
        ;; ends here, so the NREVERSE below still runs.
        (when (>= (length collected) n-reply)
          (return))))
    (nreverse collected)))

(defun %frame (id command aux1 aux2)
  "The 5-byte command frame for id/command/aux1/aux2, checksum included."
  (let ((body (list id command aux1 aux2)))
    (nconc body (list (atari800-cl.sio::%sio-checksum body)))))

(test sio-end-to-end-status-over-the-wire
  "A full 'S' transaction through POKEY both ways: the command frame is
transmitted (paced on SEROR, shifted out at the fixture's 200-cycle byte
time), the drive replies, and SERIN delivers ACK, COMPLETE, the 4-byte
status block, and the checksum -- every byte crossing the emulated
serial port."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore sio bridge))
    (let ((bytes (%wire-round-trip pok cpu bus (%frame #x31 #x53 0 0) 7)))
      (is (= 7 (length bytes))
          "the whole reply must arrive (got ~A bytes)" (length bytes))
      (is (equal bytes (list #x41 #x43 #x01 #xFF #xE0 #x00
                             (%fold '(#x01 #xFF #xE0 #x00))))
          "ACK, COMPLETE, status block, checksum -- in wire order"))))

(test sio-end-to-end-read-over-the-wire
  "A full 'R' transaction: sector 3 of the synthetic image (128 copies of
3) arrives byte-by-byte through SERIN with its checksum."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture)
    (declare (ignore sio bridge))
    (let ((bytes (%wire-round-trip pok cpu bus (%frame #x31 #x52 3 0) 131)))
      (is (= 131 (length bytes)))
      (is (= (first bytes) #x41))
      (is (= (second bytes) #x43))
      (is (equal (subseq bytes 2 130) (make-list 128 :initial-element 3)))
      (is (= (nth 130 bytes) (%fold (make-list 128 :initial-element 3)))))))

(test sio-end-to-end-silence-when-no-disk
  "With no disk mounted the same transmitted command frame produces no
SERIN traffic at all: the receiver never gains an unread byte across a
generous window, which is the drive-less-machine path the OS times out
on before falling through to BASIC."
  (multiple-value-bind (pok cpu bus sio bridge)
      (%make-sio-fixture :mounted nil)
    (declare (ignore sio bridge))
    (%wire-round-trip pok cpu bus (%frame #x31 #x53 0 0) 1 :max-cycles 10000)
    (is-false (atari800-cl.pokey:pokey-serial-in-unread pok))
    (is (zerop (atari800-cl.pokey:pokey-serin pok)))))