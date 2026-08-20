;;;; src/xex.lisp --- XEX/OBX loading: wrap a DOS binary in a bootable ATR.
;;;;
;;;; ROADMAP.md Phase 16 (revised), stage 16d.  A Common Lisp port of
;;;; minimal-xl's tools/xex2atr.py: prepend the assembled xexboot boot-
;;;; sector loader (fixtures/xexboot.bin -- see fixtures/README.md for its
;;;; provenance) to a raw Atari DOS binary (XEX; OBX is MADS's extension of
;;;; the identical format), patch the loader's FSEC word (offsets 9/10, the
;;;; word right after the boot-continuation JMP) with the last sector
;;;; number the file's data occupies, pad both the loader and the payload
;;;; to whole 128-byte sectors, and wrap the result in a 16-byte ATR
;;;; header -- entirely in memory.  MAKE-XEX-ATR hands the synthesized
;;;; bytes to PARSE-ATR-BYTES (src/hostdev.lisp) so the result is an
;;;; ordinary ATR-IMAGE, mountable exactly like one loaded from a file.
;;;;
;;;; xexboot.asm (minimal-xl/tools/xexboot.asm) streams the file through
;;;; DSKINV sector-by-sector, processing DOS binary-load segments the way
;;;; the real OS would: a leading $FFFF marker is skipped, each segment
;;;; loads at its own start address, INITAD is invoked after any segment
;;;; that sets it, and control passes through DOSVEC to RUNAD at end of
;;;; file (defaulting to the first segment's start when the file never
;;;; sets RUNAD, e.g. plain MADS output with no .run directive).  Because
;;;; the loader does this work, LOAD-XEX costs zero new 6502 code and
;;;; needs no segment-parsing logic of its own -- it only has to get the
;;;; bytes onto a disk image the loader can read.

(in-package #:atari800-cl.hostdev)

(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------

(defconstant +xex-sector-size+ 128
  "Sector size xexboot's loader and XEX2ATR.PY both assume; unrelated to
an ATR-IMAGE's own (possibly 256-byte) SECTOR-SIZE, which only applies to
sectors past the boot sectors -- see hostdev.lisp's ATR boot-sector rule.")

(define-condition xex-format-error (error)
  ((reason :initarg :reason :reader xex-format-error-reason))
  (:report (lambda (c s) (format s "Malformed XEX/OBX data: ~A" (xex-format-error-reason c))))
  (:documentation "Signalled by MAKE-XEX-ATR when the XEX payload is empty
or the boot-sector loader bytes fail xexboot's own header sanity checks
(wrong sector count at offset 1, no JMP opcode at offset 6) -- the same
two checks xex2atr.py performs before trusting a loader image."))

(declaim (inline %pad-to-sector))
(defun %pad-to-sector (bytes)
  "Return a fresh (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (*)) holding BYTES
followed by however many zero bytes bring its length up to a whole
multiple of +XEX-SECTOR-SIZE+ (none, if it already is one)."
  (declare (type (vector (unsigned-byte 8)) bytes))
  (let* ((len (length bytes))
         (rem (mod len +xex-sector-size+))
         (padded (if (zerop rem) len (+ len (- +xex-sector-size+ rem))))
         (out (make-array padded :element-type '(unsigned-byte 8) :initial-element 0)))
    (replace out bytes)
    out))

(defun %xexboot-fixture-path ()
  "Path to fixtures/xexboot.bin, resolved relative to this system's own
source directory (the same pattern tests/test-machine.lisp's ROM/asset
lookups use), so LOAD-XEX works regardless of the caller's working
directory."
  (merge-pathnames (make-pathname :directory '(:relative "fixtures")
                                   :name "xexboot" :type "bin")
                    (asdf:system-source-directory "atari800-cl")))

(defvar *xexboot-bytes-cache* nil
  "Memoized contents of fixtures/xexboot.bin (%DEFAULT-XEXBOOT-BYTES);
the file never changes at runtime, so re-reading it on every MAKE-XEX-ATR
call would be pure overhead.")

(defun %default-xexboot-bytes ()
  "Return fixtures/xexboot.bin's bytes, reading and caching them on first
use.  Callers that want to test the boot-loader validation itself (rather
than trust the committed fixture) should pass :XEXBOOT-BYTES to
MAKE-XEX-ATR explicitly instead of relying on this."
  (or *xexboot-bytes-cache*
      (setf *xexboot-bytes-cache* (read-binary-file (%xexboot-fixture-path)))))

(defun %build-xex-atr-bytes (xex-bytes xexboot-bytes)
  "Core of the xex2atr.py port: return a fresh in-memory ATR file image
(16-byte header included) wrapping XEXBOOT-BYTES as the boot sectors and
XEX-BYTES as the data that follows.  Signals XEX-FORMAT-ERROR on an empty
XEX-BYTES, a XEXBOOT-BYTES sector count (offset 1) that disagrees with
its own padded length, or a XEXBOOT-BYTES offset 6 that isn't a JMP
opcode ($4C) -- xex2atr.py's own two loader sanity checks, which matter
only if a caller supplies a non-default :XEXBOOT-BYTES."
  (declare (type (vector (unsigned-byte 8)) xex-bytes xexboot-bytes))
  (when (zerop (length xex-bytes))
    (error 'xex-format-error :reason "XEX/OBX data is empty"))
  (let* ((boot (%pad-to-sector xexboot-bytes))
         (nbsec (truncate (length boot) +xex-sector-size+)))
    (unless (= (aref boot 1) nbsec)
      (error 'xex-format-error
             :reason (format nil "boot loader's declared sector count ~D ~
                                   does not match its padded image size ~
                                   (~D sectors) -- not xexboot.bin?"
                             (aref boot 1) nbsec)))
    (unless (= (aref boot 6) #x4C)
      (error 'xex-format-error
             :reason "boot loader byte 6 is not a JMP opcode ($4C) -- not ~
                       the xexboot loader's boot-continuation entry?"))
    (let* ((data (%pad-to-sector xex-bytes))
           (data-sectors (truncate (length data) +xex-sector-size+))
           (fsec (+ nbsec data-sectors)))
      ;; Patch FSEC (offsets 9/10, right after the boot-continuation JMP)
      ;; with the last data sector number -- xexboot's GETBYT treats
      ;; anything past it as end of file.
      (setf (aref boot 9)  (logand fsec #xFF)
            (aref boot 10) (logand (ash fsec -8) #xFF))
      (let* ((image (concatenate '(simple-array (unsigned-byte 8) (*)) boot data))
             (paragraphs (truncate (length image) 16))
             (header (make-array +atr-header-size+ :element-type '(unsigned-byte 8)
                                                    :initial-element 0)))
        (setf (aref header 0) #x96 (aref header 1) #x02       ; ATR magic
              (aref header 2) (logand paragraphs #xFF)
              (aref header 3) (logand (ash paragraphs -8) #xFF)
              (aref header 4) (logand +xex-sector-size+ #xFF) ; sector size
              (aref header 5) (logand (ash +xex-sector-size+ -8) #xFF)
              (aref header 6) (logand (ash paragraphs -16) #xFF))
        (concatenate '(simple-array (unsigned-byte 8) (*)) header image)))))

(defun make-xex-atr (xex-bytes &key (read-only t) xexboot-bytes)
  "Synthesize a bootable ATR-IMAGE in memory from XEX-BYTES, a raw Atari
DOS binary-load file (XEX; OBX is MADS's extension of the identical
format) -- no file of the wrapped image is ever written.  XEXBOOT-BYTES
defaults to fixtures/xexboot.bin's assembled boot-sector loader
(%DEFAULT-XEXBOOT-BYTES); pass an explicit value only to exercise the
loader's own header validation without touching the committed fixture.
READ-ONLY defaults to true, matching every other MOUNT-* path.  Signals
XEX-FORMAT-ERROR on malformed input; see %BUILD-XEX-ATR-BYTES."
  (declare (type (vector (unsigned-byte 8)) xex-bytes))
  (parse-atr-bytes (%build-xex-atr-bytes xex-bytes (or xexboot-bytes (%default-xexboot-bytes)))
                    :read-only read-only))

(defun load-xex (bridge unit path &key (read-only t))
  "Read PATH (an XEX or OBX file) from disk, synthesize a bootable ATR
image in memory via MAKE-XEX-ATR, and mount it into BRIDGE's drive UNIT
(1-8) -- the ATR route xex2atr.py named, exercising the real boot
protocol rather than injecting the program directly the way
scripts/xex-loader.lisp's direct-injection loader does for the test
harness.  Returns the mounted ATR-IMAGE, mirroring MOUNT-DISK-FILE's
shape (PATH in, mount as a side effect, image out)."
  (declare (type host-bridge bridge) (type fixnum unit))
  (let ((image (make-xex-atr (read-binary-file path) :read-only read-only)))
    (mount-disk bridge unit image)
    image))
