;;;; src/hostdev.lisp --- Host disk bridge: a memory-mapped $D1xx device.
;;;;
;;;; ROADMAP.md Phase 16 (revised): "Host disk bridge: ATR/XEX/OBX via
;;;; minimal-xl", stages 16a (bridge device) and 16b (ATR disk images).
;;;;
;;;; Real Atari XL hardware used the $D1xx page ("Parallel Bus Interface
;;;; Circuit" range) for exactly this class of add-on: a parallel-bus disk
;;;; controller (the Black Box and similar).  This device is a plausible
;;;; peripheral, not an emulator escape hatch -- it registers ordinary
;;;; read/write closures into the bus, like the four real chips do, and a
;;;; machine that never attaches one behaves exactly as before (every
;;;; $D1xx read already falls through to the bus's open-bus default of
;;;; $FF when no closure is installed).
;;;;
;;;; ---- Wire protocol (fixed contract with minimal-xl's stage 16c) ----
;;;;
;;;;   Read  $D1FE — signature byte +SIGNATURE+ ($A8) when a bridge is
;;;;                 attached.  (Every other $D1xx read, including $D1FE
;;;;                 with no bridge attached, is open bus: $FF.)
;;;;   Read  $D1FF — status byte of the most recently executed operation;
;;;;                 $00 ("none yet") before the first write.
;;;;   Write $D1FF — (any value) execute the SIO operation described by
;;;;                 the standard DCB in RAM at $0300 (see the DCB-*
;;;;                 offset constants below), transferring data through
;;;;                 BUS-READ/BUS-WRITE (never by poking the RAM array
;;;;                 directly, so the operation is indistinguishable from
;;;;                 one the CPU could have done itself one byte at a
;;;;                 time), then store the resulting status byte into
;;;;                 DSTATS ($0303) AND latch it for the next $D1FF read.
;;;;   Write other — ignored.
;;;;
;;;; Status codes follow SIO convention: $01 success; $8A (138, "device
;;;; timeout") for an unknown device id, an unmounted unit, or an
;;;; out-of-range sector; $8B (139, NAK) for an unsupported command; $90
;;;; (144, "device done" error) for a write to a read-only image.
;;;;
;;;; ---- Device model ----
;;;;
;;;; The bridge holds up to +MAX-DRIVES+ (8) disk-drive slots, addressed
;;;; by DUNIT 1-8 on DDEVIC +DEVICE-DISK+ ($31, the standard Atari disk
;;;; device id).  STATUS ($53) and READ ($52) are implemented; WRITE
;;;; ($50/$57) always answers $90 for now -- every MOUNT-* function below
;;;; defaults an image to read-only, and no code path here ever performs
;;;; a write, so that is the correct answer regardless of the flag until
;;;; a later stage actually implements one.
;;;;
;;;; ---- ATR disk images ----
;;;;
;;;; PARSE-ATR-BYTES / LOAD-ATR-FILE parse the 16-byte ATR header
;;;; (little-endian magic $0296 at offset 0, sector size at offset 4,
;;;; and an image size in 16-byte "paragraphs" split across offsets 2-3
;;;; and 6-7) into an ATR-IMAGE, and ATR-READ-SECTOR maps a 1-based
;;;; sector number to file bytes -- remembering that the first three
;;;; sectors are always 128 bytes, even on a double-density (256-byte)
;;;; image, per the ATR format's boot-sector convention.

(in-package #:atari800-cl.hostdev)

(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Protocol constants

(defconstant +signature+ #xA8
  "Signature byte returned by a $D1FE read when a bridge is attached.")
(defconstant +sig-offset+ #xFE
  "Low byte of the $D1xx signature register address ($D1FE).")
(defconstant +go-offset+  #xFF
  "Low byte of the $D1xx go/status register address ($D1FF).")

(defconstant +max-drives+ 8
  "Number of disk-drive slots a HOST-BRIDGE exposes (DUNIT 1-8).")

;;; Standard DCB (Device Control Block) field addresses, per the Atari OS's
;;; SIO calling convention (see e.g. minimal-xl's DSKINV/SIOV).
(defconstant +dcb-ddevic+ #x0300 "Device id ($31 for disk).")
(defconstant +dcb-dunit+  #x0301 "Unit number, 1-based.")
(defconstant +dcb-dcomnd+ #x0302 "Command byte.")
(defconstant +dcb-dstats+ #x0303 "Result status byte (written back).")
(defconstant +dcb-dbuflo+ #x0304 "Data buffer address, low byte.")
(defconstant +dcb-dbufhi+ #x0305 "Data buffer address, high byte.")
(defconstant +dcb-dtimlo+ #x0306 "Device timeout in seconds (unused here).")
(defconstant +dcb-dbytlo+ #x0308 "Requested byte count, low byte (unused here).")
(defconstant +dcb-dbythi+ #x0309 "Requested byte count, high byte (unused here).")
(defconstant +dcb-daux1+  #x030A "Auxiliary 1: sector number, low byte.")
(defconstant +dcb-daux2+  #x030B "Auxiliary 2: sector number, high byte.")

(defconstant +device-disk+ #x31 "Standard Atari disk-drive DDEVIC id.")

(defconstant +cmd-status+       #x53 "'S' -- get drive status.")
(defconstant +cmd-read+         #x52 "'R' -- read a sector.")
(defconstant +cmd-write+        #x50 "'P' -- write a sector, no verify.")
(defconstant +cmd-write-verify+ #x57 "'W' -- write a sector, with verify.")

(defconstant +status-success+       #x01 "SIO: operation completed OK.")
(defconstant +status-none-yet+      #x00 "$D1FF default before any 'go' write.")
(defconstant +status-timeout+       #x8A
  "SIO device-timeout ($138): unknown device id, unmounted unit, or an
out-of-range sector.")
(defconstant +status-nak+           #x8B
  "SIO NAK ($139): the addressed drive doesn't understand this command.")
(defconstant +status-write-protect+ #x90
  "SIO device-done error ($144): a write was rejected (read-only image, or
-- for now -- any write at all, since write support isn't implemented yet).")

;;; ---------------------------------------------------------------------------
;;; ATR disk images

(define-condition atr-format-error (error)
  ((reason :initarg :reason :reader atr-format-error-reason))
  (:report (lambda (c s) (format s "Malformed ATR image: ~A" (atr-format-error-reason c))))
  (:documentation "Signalled by PARSE-ATR-BYTES / LOAD-ATR-FILE when the
16-byte ATR header fails validation: a bad magic word, an unsupported
sector size, a file shorter than the header claims, or a data length that
isn't a whole number of sectors."))

(defconstant +atr-magic+            #x0296 "Little-endian ATR magic word.")
(defconstant +atr-header-size+      16      "Size of the ATR header in bytes.")
(defconstant +atr-boot-sector-size+ 128
  "Sectors 1-3 are always 128 bytes, even on a double-density image --
the ATR format's boot-sector convention (the OS's boot loader reads the
first three sectors before it knows the image's real sector size).")
(defconstant +atr-boot-sector-count+ 3)

(defstruct atr-image
  "A parsed ATR disk image, ready to be mounted into a HOST-BRIDGE drive
slot via MOUNT-DISK.

Slots:
  DATA         — sector payload bytes: the file's contents AFTER its
                 16-byte header, a (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*)).
  SECTOR-SIZE  — the image's declared sector size from the header (128 or
                 256).  Sectors 1-3 are always 128 bytes regardless of
                 this value; see +ATR-BOOT-SECTOR-SIZE+.
  SECTOR-COUNT — total addressable 1-based sector count, computed from
                 DATA's length and SECTOR-SIZE by PARSE-ATR-BYTES.
  READ-ONLY    — when true (every MOUNT-* function's default), WRITE
                 commands are rejected with SIO status $90."
  (data (make-array 0 :element-type '(unsigned-byte 8))
        :type (simple-array (unsigned-byte 8) (*)))
  (sector-size 128 :type u16)
  (sector-count 0 :type fixnum)
  (read-only t))

(declaim (inline %u16-le))
(defun %u16-le (bytes offset)
  "Read a little-endian 16-bit word from BYTES at OFFSET."
  (declare (type (vector (unsigned-byte 8)) bytes) (type fixnum offset))
  (logior (aref bytes offset) (ash (aref bytes (1+ offset)) 8)))

(defun parse-atr-bytes (bytes &key (read-only t))
  "Parse BYTES (a complete ATR file image, 16-byte header included) into an
ATR-IMAGE.  Validates the little-endian magic word $0296 at offset 0, the
sector size at offset 4 (must be 128 or 256), and the image's paragraph
count (offsets 2-3 low 16 bits, 6-7 high 16 bits; each paragraph is 16
bytes and the header itself is not counted) against BYTES's actual length.
Signals ATR-FORMAT-ERROR on any of those failing, or on a data length that
is not a whole number of sectors under the header's own sector size.
READ-ONLY defaults to true, matching every MOUNT-* function's default;
pass NIL only once write support exists upstream of this parser."
  (declare (type (vector (unsigned-byte 8)) bytes))
  (unless (>= (length bytes) +atr-header-size+)
    (error 'atr-format-error
           :reason (format nil "file is only ~D byte~:P, shorter than the ~
                                 16-byte ATR header" (length bytes))))
  (let ((magic (%u16-le bytes 0)))
    (unless (= magic +atr-magic+)
      (error 'atr-format-error
             :reason (format nil "bad magic $~4,'0X (expected $~4,'0X)"
                             magic +atr-magic+))))
  (let* ((paragraphs-lo (%u16-le bytes 2))
         (sector-size   (%u16-le bytes 4))
         (paragraphs-hi (%u16-le bytes 6))
         (paragraphs    (logior paragraphs-lo (ash paragraphs-hi 16)))
         (data-length   (* paragraphs 16)))
    (unless (member sector-size '(128 256))
      (error 'atr-format-error
             :reason (format nil "unsupported sector size ~D (expected 128 ~
                                   or 256)" sector-size)))
    (unless (<= (+ +atr-header-size+ data-length) (length bytes))
      (error 'atr-format-error
             :reason (format nil "header declares ~D data bytes but the ~
                                   file has only ~D after its header"
                             data-length (- (length bytes) +atr-header-size+))))
    (let ((boot-bytes (* +atr-boot-sector-count+ +atr-boot-sector-size+))
          (data (make-array data-length :element-type '(unsigned-byte 8))))
      (replace data bytes :start2 +atr-header-size+
                          :end2 (+ +atr-header-size+ data-length))
      (let ((sector-count
              (if (= sector-size +atr-boot-sector-size+)
                  (progn
                    (unless (zerop (mod data-length +atr-boot-sector-size+))
                      (error 'atr-format-error
                             :reason "data length is not a whole number of ~
                                      128-byte sectors"))
                    (truncate data-length +atr-boot-sector-size+))
                  (progn
                    (unless (>= data-length boot-bytes)
                      (error 'atr-format-error
                             :reason "double-density image is too short to ~
                                      hold its three 128-byte boot sectors"))
                    (let ((rest (- data-length boot-bytes)))
                      (unless (zerop (mod rest sector-size))
                        (error 'atr-format-error
                               :reason "data length past the boot sectors is ~
                                        not a whole number of sectors"))
                      (+ +atr-boot-sector-count+ (truncate rest sector-size)))))))
        (make-atr-image :data data :sector-size sector-size
                         :sector-count sector-count :read-only read-only)))))

(defun load-atr-file (path &key (read-only t))
  "Read PATH from disk and parse it as an ATR image; see PARSE-ATR-BYTES."
  (parse-atr-bytes (read-binary-file path) :read-only read-only))

(declaim (inline %atr-sector-size-at %atr-sector-offset))

(defun %atr-sector-size-at (image sector)
  "The byte size of SECTOR (1-based) within IMAGE: always 128 for the
first three (boot) sectors, IMAGE's declared SECTOR-SIZE thereafter."
  (declare (type atr-image image) (type fixnum sector))
  (if (<= sector +atr-boot-sector-count+)
      +atr-boot-sector-size+
      (atr-image-sector-size image)))

(defun %atr-sector-offset (image sector)
  "Byte offset of SECTOR (1-based) within IMAGE's DATA array."
  (declare (type atr-image image) (type fixnum sector))
  (if (<= sector +atr-boot-sector-count+)
      (* (1- sector) +atr-boot-sector-size+)
      (+ (* +atr-boot-sector-count+ +atr-boot-sector-size+)
         (* (- sector +atr-boot-sector-count+ 1) (atr-image-sector-size image)))))

(defun atr-read-sector (image sector)
  "Return a fresh (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*)) holding SECTOR
(1-based) of IMAGE, or NIL when SECTOR is out of range (< 1 or >
SECTOR-COUNT)."
  (declare (type atr-image image) (type fixnum sector))
  (when (<= 1 sector (atr-image-sector-count image))
    (let ((offset (%atr-sector-offset image sector))
          (size   (%atr-sector-size-at image sector)))
      (subseq (atr-image-data image) offset (+ offset size)))))

;;; ---------------------------------------------------------------------------
;;; Host bridge device

(defstruct host-bridge
  "Host disk bridge: a $D1xx memory-mapped peripheral (ROADMAP.md Phase
16, revised) standing in for a parallel-bus disk controller.

Slots:
  DRIVES      — a length-+MAX-DRIVES+ simple-vector; index (UNIT - 1) holds
                the ATR-IMAGE mounted at DUNIT UNIT, or NIL if empty.
  LAST-STATUS — the SIO status byte of the most recently executed 'go'
                operation ($D1FF read); $00 before the first one."
  (drives (make-array +max-drives+ :initial-element nil) :type simple-vector)
  (last-status +status-none-yet+ :type u8))

(defun %check-unit (unit)
  (unless (<= 1 unit +max-drives+)
    (error "drive unit ~D out of range (DUNIT must be 1-~D)" unit +max-drives+)))

(defun mount-disk (bridge unit image)
  "Install ATR-IMAGE into BRIDGE's drive UNIT (1-8), replacing whatever was
mounted there.  Returns BRIDGE."
  (declare (type host-bridge bridge) (type fixnum unit) (type atr-image image))
  (%check-unit unit)
  (setf (aref (host-bridge-drives bridge) (1- unit)) image)
  bridge)

(defun mount-disk-file (bridge unit path &key (read-only t))
  "Load PATH as an ATR image (LOAD-ATR-FILE) and mount it into BRIDGE's
drive UNIT (1-8).  Returns the mounted ATR-IMAGE."
  (declare (type host-bridge bridge) (type fixnum unit))
  (let ((image (load-atr-file path :read-only read-only)))
    (mount-disk bridge unit image)
    image))

(defun unmount-disk (bridge unit)
  "Remove whatever ATR-IMAGE is mounted at BRIDGE's drive UNIT (1-8), if
any.  Returns BRIDGE."
  (declare (type host-bridge bridge) (type fixnum unit))
  (%check-unit unit)
  (setf (aref (host-bridge-drives bridge) (1- unit)) nil)
  bridge)

(defun mounted-disk (bridge unit)
  "Return the ATR-IMAGE mounted at BRIDGE's drive UNIT (1-8), or NIL."
  (declare (type host-bridge bridge) (type fixnum unit))
  (%check-unit unit)
  (aref (host-bridge-drives bridge) (1- unit)))

;;; ---------------------------------------------------------------------------
;;; DCB dispatch

(declaim (inline %dcb-word))
(defun %dcb-word (bus lo-addr hi-addr)
  "Read a little-endian 16-bit DCB field spanning LO-ADDR/HI-ADDR through
BUS-READ."
  (declare (type bus bus) (type u16 lo-addr hi-addr))
  (logior (bus-read bus lo-addr) (ash (bus-read bus hi-addr) 8)))

(defun %status-drive-block (image)
  "Build the standard 4-byte 'S' (get status) command response for IMAGE.
Byte 0 bit 0 is write-protect, bit 3 is double density (256-byte sectors);
byte 1 is the controller hardware-status byte ($FF = no error, the
inverted-active-low convention real WD177x-based controllers use); byte 2
is a format-timeout placeholder ($E0, the value a real single-density
810/1050 controller returns); byte 3 is unused.  Only the success/error
codes documented at the top of this file are part of the fixed 16a/16c
contract -- these exact bits are this file's own reasonable choice of 'a
standard status block', not something the parallel minimal-xl agent's
SIOV probe depends on bit-for-bit."
  (declare (type atr-image image))
  (list (logior (if (atr-image-read-only image) #x01 #x00)
                (if (= (atr-image-sector-size image) 256) #x08 #x00))
        #xFF #xE0 #x00))

(defun %hostdev-execute (bridge bus)
  "Perform the SIO operation described by the DCB at $0300-$030B (see the
package-level docstring at the top of this file): read DDEVIC/DUNIT/
DCOMND, look up the addressed drive, dispatch on the command, transfer any
data through BUS-READ/BUS-WRITE, and return the resulting SIO status byte.
Does not itself touch DSTATS or LAST-STATUS -- HOST-BRIDGE-WRITE does that
once, from this function's return value, so there is exactly one place the
two could ever go out of sync."
  (declare (type host-bridge bridge) (type bus bus))
  (let ((ddevic (bus-read bus +dcb-ddevic+))
        (dunit  (bus-read bus +dcb-dunit+))
        (dcomnd (bus-read bus +dcb-dcomnd+))
        (dbuf   (%dcb-word bus +dcb-dbuflo+ +dcb-dbufhi+))
        (daux   (%dcb-word bus +dcb-daux1+  +dcb-daux2+)))
    (cond
      ((/= ddevic +device-disk+) +status-timeout+)
      ((not (<= 1 dunit +max-drives+)) +status-timeout+)
      (t (let ((image (aref (host-bridge-drives bridge) (1- dunit))))
           (cond
             ((null image) +status-timeout+)
             ((= dcomnd +cmd-status+)
              (loop for byte in (%status-drive-block image)
                    for addr from dbuf
                    do (bus-write bus (logand addr #xFFFF) byte))
              +status-success+)
             ((= dcomnd +cmd-read+)
              (let ((sector-bytes (atr-read-sector image daux)))
                (if (null sector-bytes)
                    +status-timeout+
                    (progn
                      (loop for byte across sector-bytes
                            for addr from dbuf
                            do (bus-write bus (logand addr #xFFFF) byte))
                      +status-success+))))
             ((or (= dcomnd +cmd-write+) (= dcomnd +cmd-write-verify+))
              ;; Read-only default and no write-execution path exist yet
              ;; (ROADMAP.md 16a); this is deliberately unconditional.
              +status-write-protect+)
             (t +status-nak+)))))))

(defun host-bridge-read (bridge address)
  "Handle a bus read from the $D1xx range.  $D1FE returns +SIGNATURE+;
$D1FF returns LAST-STATUS.  Every other offset returns $FF (open bus) --
exactly what an unattached bridge already returns via the bus's own
default fallthrough, so a probe of any other $D1xx address cannot
distinguish 'bridge present, unused offset' from 'no bridge'."
  (declare (type host-bridge bridge) (type u16 address))
  (let ((offset (logand address #xFF)))
    (cond ((= offset +sig-offset+) +signature+)
          ((= offset +go-offset+) (host-bridge-last-status bridge))
          (t #xFF))))

(defun host-bridge-write (bridge bus address value)
  "Handle a bus write into the $D1xx range.  Only $D1FF (the 'go'
register) has any effect: writing any VALUE there executes the DCB-
described SIO operation (see %HOSTDEV-EXECUTE) and latches the resulting
status both into LAST-STATUS (for the next $D1FF read) and into DSTATS
($0303, so the DCB itself carries the result exactly like a real SIOV
call leaves it).  Every other $D1xx address is ignored."
  (declare (type host-bridge bridge) (type bus bus) (type u16 address)
           (ignore value))
  (when (= (logand address #xFF) +go-offset+)
    (let ((status (%hostdev-execute bridge bus)))
      (setf (host-bridge-last-status bridge) status)
      (bus-write bus +dcb-dstats+ status))))

(defun attach-hostdev (bus bridge)
  "Wire BRIDGE's read/write dispatch closures into BUS at the $D1xx page.
Returns BUS.  A machine built without ever calling this behaves exactly as
before: the bus's default I/O fallthrough already returns $FF for reads
and drops writes when no closure is installed at a sub-page."
  (declare (type bus bus) (type host-bridge bridge))
  (setf (bus-hostdev-read-fn bus)  (lambda (addr) (host-bridge-read bridge addr))
        (bus-hostdev-write-fn bus) (lambda (addr val) (host-bridge-write bridge bus addr val)))
  bus)
