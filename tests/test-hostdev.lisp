;;;; tests/test-hostdev.lisp --- Host disk bridge ($D1xx) + ATR image tests.
;;;;
;;;; ROADMAP.md Phase 16 (revised), stages 16a (bridge device) and 16b
;;;; (ATR disk images).  Covers the bare bus-dispatch protocol (signature,
;;;; status latch), the DCB dispatch for READ/STATUS/WRITE against a small
;;;; synthetic in-memory ATR image, every documented error status code, the
;;;; double-density boot-sector rule, and malformed-image rejection.

(in-package #:atari800-cl/tests)

(def-suite hostdev-suite
  :description "Atari 800 XL host disk bridge ($D1xx) and ATR disk images."
  :in atari800-cl-suite)

(in-suite hostdev-suite)

;;; ---------------------------------------------------------------------------
;;; Synthetic ATR builders
;;;
;;; %MAKE-SD-ATR-BYTES builds a single-density (128-byte sector) image with
;;; NSECTORS sectors, each filled entirely with its own 1-based sector
;;; number -- so reading sector N back and checking every byte equals N is
;;; a complete round-trip check, not just a first-byte spot check.
;;;
;;; %MAKE-DD-ATR-BYTES builds a double-density (256-byte declared sector
;;; size) image with the ATR boot-sector rule: sectors 1-3 are still 128
;;; bytes, sector 4 onward are 256.  Boot sectors are filled with $11,
;;; $22, $33; 256-byte sectors are filled with their own sector number.

(defun %u16-le-bytes (value)
  (values (logand value #xFF) (ash value -8)))

(defun %make-sd-atr-bytes (nsectors &key (sector-size 128))
  (let* ((data-len (* sector-size nsectors))
         (paragraphs (/ data-len 16))
         (bytes (make-array (+ 16 data-len) :element-type '(unsigned-byte 8)
                                            :initial-element 0)))
    (multiple-value-bind (plo phi) (%u16-le-bytes paragraphs)
      (setf (aref bytes 0) #x96 (aref bytes 1) #x02
            (aref bytes 2) plo  (aref bytes 3) phi
            (aref bytes 4) (logand sector-size #xFF)
            (aref bytes 5) (ash sector-size -8)
            (aref bytes 6) 0    (aref bytes 7) 0))
    (dotimes (s nsectors)
      (dotimes (i sector-size)
        (setf (aref bytes (+ 16 (* s sector-size) i)) (logand (1+ s) #xFF))))
    bytes))

(defun %make-dd-atr-bytes (extra-256-sectors)
  (let* ((boot-bytes (* 3 128))
         (data-len (+ boot-bytes (* extra-256-sectors 256)))
         (paragraphs (/ data-len 16))
         (bytes (make-array (+ 16 data-len) :element-type '(unsigned-byte 8)
                                            :initial-element 0)))
    (multiple-value-bind (plo phi) (%u16-le-bytes paragraphs)
      (setf (aref bytes 0) #x96 (aref bytes 1) #x02
            (aref bytes 2) plo  (aref bytes 3) phi
            (aref bytes 4) 0    (aref bytes 5) 1     ; sector-size = 256
            (aref bytes 6) 0    (aref bytes 7) 0))
    ;; Boot sectors: $11, $22, $33.
    (dotimes (i 128) (setf (aref bytes (+ 16 i))           #x11))
    (dotimes (i 128) (setf (aref bytes (+ 16 128 i))       #x22))
    (dotimes (i 128) (setf (aref bytes (+ 16 256 i))       #x33))
    ;; 256-byte sectors, each filled with its own 1-based sector number.
    (dotimes (s extra-256-sectors)
      (dotimes (i 256)
        (setf (aref bytes (+ 16 boot-bytes (* s 256) i)) (logand (+ s 4) #xFF))))
    bytes))

;;; ---------------------------------------------------------------------------
;;; ATR parsing

(test parse-atr-bytes-single-density-round-trips
  "A single-density synthetic ATR reports the right sector count/size and
each sector reads back exactly the bytes written."
  (let ((img (atari800-cl.hostdev:parse-atr-bytes (%make-sd-atr-bytes 10))))
    (is (= 10  (atari800-cl.hostdev:atr-image-sector-count img)))
    (is (= 128 (atari800-cl.hostdev:atr-image-sector-size img)))
    (is-true (atari800-cl.hostdev:atr-image-read-only img)
             "PARSE-ATR-BYTES defaults to read-only")
    (dotimes (s 10)
      (let ((sector (1+ s))
            (bytes (atari800-cl.hostdev:atr-read-sector img (1+ s))))
        (is (= 128 (length bytes)))
        (is-true (every (lambda (b) (= b (logand sector #xFF))) bytes)
                 "sector ~D must be filled with its own number" sector)))))

(test parse-atr-bytes-read-only-override
  "READ-ONLY NIL is honoured by PARSE-ATR-BYTES."
  (let ((img (atari800-cl.hostdev:parse-atr-bytes (%make-sd-atr-bytes 4)
                                                   :read-only nil)))
    (is-false (atari800-cl.hostdev:atr-image-read-only img))))

(test parse-atr-bytes-boot-sector-128-byte-rule
  "On a double-density (256-byte) image, sectors 1-3 are still 128 bytes;
sector 4 onward are the declared 256."
  (let ((img (atari800-cl.hostdev:parse-atr-bytes (%make-dd-atr-bytes 5))))
    (is (= 256 (atari800-cl.hostdev:atr-image-sector-size img)))
    (is (= 8   (atari800-cl.hostdev:atr-image-sector-count img))
        "3 boot sectors + 5 double-density sectors = 8")
    (dolist (spec '((1 128 #x11) (2 128 #x22) (3 128 #x33)))
      (destructuring-bind (sector size fill) spec
        (let ((bytes (atari800-cl.hostdev:atr-read-sector img sector)))
          (is (= size (length bytes)) "boot sector ~D length" sector)
          (is-true (every (lambda (b) (= b fill)) bytes)
                   "boot sector ~D contents" sector))))
    (let ((bytes (atari800-cl.hostdev:atr-read-sector img 4)))
      (is (= 256 (length bytes)) "first double-density sector length")
      (is-true (every (lambda (b) (= b 4)) bytes)
               "first double-density sector contents"))))

(test parse-atr-bytes-rejects-bad-magic
  "A file whose first two bytes aren't the ATR magic $0296 signals
ATR-FORMAT-ERROR with a descriptive reason."
  (let ((bytes (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)))
    (signals atari800-cl.hostdev:atr-format-error
      (atari800-cl.hostdev:parse-atr-bytes bytes))))

(test parse-atr-bytes-rejects-short-file
  "A file shorter than the 16-byte header signals ATR-FORMAT-ERROR."
  (let ((bytes (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0)))
    (signals atari800-cl.hostdev:atr-format-error
      (atari800-cl.hostdev:parse-atr-bytes bytes))))

(test parse-atr-bytes-rejects-truncated-data
  "A header that declares more data than the file actually has signals
ATR-FORMAT-ERROR rather than reading past the end of the array."
  (let ((bytes (%make-sd-atr-bytes 4)))
    ;; Claim double the paragraphs the file actually has.
    (let ((paragraphs (logior (aref bytes 2) (ash (aref bytes 3) 8))))
      (multiple-value-bind (plo phi) (%u16-le-bytes (* paragraphs 2))
        (setf (aref bytes 2) plo (aref bytes 3) phi)))
    (signals atari800-cl.hostdev:atr-format-error
      (atari800-cl.hostdev:parse-atr-bytes bytes))))

;;; ---------------------------------------------------------------------------
;;; Mounting

(test mount-disk-and-unmount-disk-round-trip
  "MOUNT-DISK installs an image at the given unit; MOUNTED-DISK reads it
back; UNMOUNT-DISK clears the slot."
  (let ((bridge (atari800-cl.hostdev:make-host-bridge))
        (img (atari800-cl.hostdev:parse-atr-bytes (%make-sd-atr-bytes 4))))
    (is-false (atari800-cl.hostdev:mounted-disk bridge 3))
    (atari800-cl.hostdev:mount-disk bridge 3 img)
    (is (eq img (atari800-cl.hostdev:mounted-disk bridge 3)))
    (atari800-cl.hostdev:unmount-disk bridge 3)
    (is-false (atari800-cl.hostdev:mounted-disk bridge 3))))

;;; ---------------------------------------------------------------------------
;;; Bare bus-dispatch protocol

(test signature-read-without-bridge-is-open-bus
  "With no bridge attached, $D1FE (and every other $D1xx address) reads
back $FF, exactly like any other unmapped I/O sub-page."
  (let ((bus (atari800-cl.bus:make-bus)))
    (is (= #xFF (atari800-cl.bus:bus-read bus #xD1FE)))
    (is (= #xFF (atari800-cl.bus:bus-read bus #xD1FF)))
    (is (= #xFF (atari800-cl.bus:bus-read bus #xD150)))))

(test signature-read-with-bridge-attached
  "ATTACH-HOSTDEV installs the dispatch closures: $D1FE now returns
+SIGNATURE+ ($A8); every other $D1xx offset besides $D1FF still reads $FF."
  (let* ((bus (atari800-cl.bus:make-bus))
         (bridge (atari800-cl.hostdev:make-host-bridge)))
    (atari800-cl.hostdev:attach-hostdev bus bridge)
    (is (functionp (atari800-cl.bus:bus-hostdev-read-fn bus)))
    (is (functionp (atari800-cl.bus:bus-hostdev-write-fn bus)))
    (is (= atari800-cl.hostdev:+signature+ (atari800-cl.bus:bus-read bus #xD1FE)))
    (is (= #xFF (atari800-cl.bus:bus-read bus #xD150)))))

(test d1ff-status-defaults-to-zero-then-latches
  "$D1FF reads $00 before any 'go' write, and latches the operation's
status byte after one -- even for a failing operation."
  (let* ((bus (atari800-cl.bus:make-bus))
         (bridge (atari800-cl.hostdev:make-host-bridge)))
    (atari800-cl.hostdev:attach-hostdev bus bridge)
    (is (= 0 (atari800-cl.bus:bus-read bus #xD1FF)))
    ;; No device mounted anywhere -> unmounted-unit timeout, but the
    ;; important thing here is only that SOME status got latched.
    (atari800-cl.bus:bus-write bus #x0300 atari800-cl.hostdev:+device-disk+)
    (atari800-cl.bus:bus-write bus #x0301 1)
    (atari800-cl.bus:bus-write bus #x0302 atari800-cl.hostdev:+cmd-status+)
    (atari800-cl.bus:bus-write bus #xD1FF #xFF)
    (is (= atari800-cl.hostdev:+status-timeout+ (atari800-cl.bus:bus-read bus #xD1FF)))))

(test writes-to-other-d1xx-addresses-are-ignored
  "A write anywhere in $D1xx besides $D1FF has no effect: it neither
changes LAST-STATUS nor executes a DCB operation."
  (let* ((bus (atari800-cl.bus:make-bus))
         (bridge (atari800-cl.hostdev:make-host-bridge)))
    (atari800-cl.hostdev:attach-hostdev bus bridge)
    (atari800-cl.bus:bus-write bus #xD100 #x42)
    (atari800-cl.bus:bus-write bus #xD1FE #x42)
    (is (= 0 (atari800-cl.bus:bus-read bus #xD1FF))
        "no 'go' write happened, so LAST-STATUS must still be the default")))

;;; ---------------------------------------------------------------------------
;;; DCB dispatch: helper that pokes a DCB and fires the 'go' write

(defun %dcb-execute (bus &key (ddevic atari800-cl.hostdev:+device-disk+)
                              (dunit 1) dcomnd (dbuf #x0600) (daux 0))
  "Poke a standard DCB at $0300 and write the 'go' register.  Returns the
resulting $D1FF status byte."
  (atari800-cl.bus:bus-write bus #x0300 ddevic)
  (atari800-cl.bus:bus-write bus #x0301 dunit)
  (atari800-cl.bus:bus-write bus #x0302 dcomnd)
  (atari800-cl.bus:bus-write bus #x0304 (logand dbuf #xFF))
  (atari800-cl.bus:bus-write bus #x0305 (ash dbuf -8))
  (atari800-cl.bus:bus-write bus #x030A (logand daux #xFF))
  (atari800-cl.bus:bus-write bus #x030B (ash daux -8))
  (atari800-cl.bus:bus-write bus #xD1FF 1)
  (atari800-cl.bus:bus-read bus #xD1FF))

(defun %make-bus-with-mounted-disk (nsectors &key (unit 1))
  "Return (VALUES BUS BRIDGE IMAGE) with a fresh single-density synthetic
ATR mounted at UNIT."
  (let* ((bus (atari800-cl.bus:make-bus))
         (bridge (atari800-cl.hostdev:make-host-bridge))
         (img (atari800-cl.hostdev:parse-atr-bytes (%make-sd-atr-bytes nsectors))))
    (atari800-cl.hostdev:attach-hostdev bus bridge)
    (atari800-cl.hostdev:mount-disk bridge unit img)
    (values bus bridge img)))

(test dcb-dispatch-read-copies-sector-through-bus
  "A READ command copies the addressed sector's bytes into the DCB buffer
via BUS-WRITE (not a raw RAM poke)."
  (let ((bus (%make-bus-with-mounted-disk 10)))
    (let ((status (%dcb-execute bus :dcomnd atari800-cl.hostdev:+cmd-read+
                                     :dbuf #x0600 :daux 7)))
      (is (= atari800-cl.hostdev:+status-success+ status))
      (is (= atari800-cl.hostdev:+status-success+ (atari800-cl.bus:bus-read bus #x0303))
          "DSTATS must also carry the status")
      (dotimes (i 128)
        (is (= 7 (atari800-cl.bus:bus-read bus (+ #x0600 i)))
            "buffer byte ~D must equal sector 7's fill value" i)))))

(test dcb-dispatch-status-writes-four-byte-block
  "A STATUS command writes a 4-byte drive-status block to the DCB buffer
and returns success."
  (let ((bus (%make-bus-with-mounted-disk 10)))
    (let ((status (%dcb-execute bus :dcomnd atari800-cl.hostdev:+cmd-status+
                                     :dbuf #x0700)))
      (is (= atari800-cl.hostdev:+status-success+ status))
      ;; Exactly 4 bytes are meaningful; just confirm they were written
      ;; (not left at RAM's zero default) and are self-consistent with a
      ;; read-only, single-density image (bit 0 set, bit 3 clear).
      (is (logbitp 0 (atari800-cl.bus:bus-read bus #x0700))
          "bit 0 (write-protected) must be set for a read-only image")
      (is-false (logbitp 3 (atari800-cl.bus:bus-read bus #x0700))
                "bit 3 (double density) must be clear for a 128-byte-sector image"))))

;;; ---------------------------------------------------------------------------
;;; Error status codes

(test dcb-dispatch-unknown-device-times-out
  "A DDEVIC other than the disk id ($31) returns the device-timeout status."
  (let ((bus (%make-bus-with-mounted-disk 4)))
    (is (= atari800-cl.hostdev:+status-timeout+
           (%dcb-execute bus :ddevic #x99 :dcomnd atari800-cl.hostdev:+cmd-status+)))))

(test dcb-dispatch-unmounted-unit-times-out
  "A DUNIT with nothing mounted returns the device-timeout status."
  (let ((bus (%make-bus-with-mounted-disk 4 :unit 1)))
    (is (= atari800-cl.hostdev:+status-timeout+
           (%dcb-execute bus :dunit 2 :dcomnd atari800-cl.hostdev:+cmd-status+)))))

(test dcb-dispatch-out-of-range-sector-times-out
  "A READ with a sector number past SECTOR-COUNT returns the
device-timeout status, and never touches the buffer."
  (let ((bus (%make-bus-with-mounted-disk 4)))
    (atari800-cl.bus:bus-write bus #x0600 #xAA)
    (is (= atari800-cl.hostdev:+status-timeout+
           (%dcb-execute bus :dcomnd atari800-cl.hostdev:+cmd-read+
                              :dbuf #x0600 :daux 99)))
    (is (= #xAA (atari800-cl.bus:bus-read bus #x0600))
        "buffer must be untouched by an out-of-range READ")))

(test dcb-dispatch-unsupported-command-naks
  "A command byte that isn't STATUS/READ/WRITE/WRITE-VERIFY returns NAK."
  (let ((bus (%make-bus-with-mounted-disk 4)))
    (is (= atari800-cl.hostdev:+status-nak+
           (%dcb-execute bus :dcomnd #x21)))))

(test dcb-dispatch-write-rejected-read-only
  "WRITE ($50) and WRITE-VERIFY ($57) both return the write-protect status
against a (default) read-only image."
  (let ((bus (%make-bus-with-mounted-disk 4)))
    (is (= atari800-cl.hostdev:+status-write-protect+
           (%dcb-execute bus :dcomnd atari800-cl.hostdev:+cmd-write+)))
    (is (= atari800-cl.hostdev:+status-write-protect+
           (%dcb-execute bus :dcomnd atari800-cl.hostdev:+cmd-write-verify+)))))

;;; ---------------------------------------------------------------------------
;;; Machine integration

(test atari-machine-has-a-hostdev-and-it-answers-the-signature
  "MAKE-ATARI-MACHINE always builds and attaches a HOST-BRIDGE, so a fresh
machine's bus already answers the $D1FE signature probe."
  (let ((m (make-test-machine)))
    (is-true (atari800-cl.hostdev:host-bridge-p
              (atari800-cl.machine:atari-machine-hostdev m)))
    (is (= atari800-cl.hostdev:+signature+
           (atari800-cl.bus:bus-read (atari800-cl.machine:atari-machine-bus m) #xD1FE)))))
