;;;; src/bus.lisp --- Atari 800 XL system bus and memory map dispatch.
;;;;
;;;; The CPU talks to the outside world through BUS-READ and BUS-WRITE.
;;;; This file owns the memory map and routes every address either to
;;;; RAM, to one of the ROM images, or to one of the four memory-mapped
;;;; chip ranges.
;;;;
;;;; Memory map (Atari 800 XL):
;;;;
;;;;   $0000-$7FFF  RAM (always)
;;;;   $5000-$57FF  Self-test ROM overlay when PORTB bit 7 = 0 AND OS on
;;;;   $8000-$9FFF  Cartridge right slot or RAM (no cart -> RAM)
;;;;   $A000-$BFFF  BASIC ROM (PORTB bit 1 = 0) or RAM
;;;;   $C000-$CFFF  OS ROM low (PORTB bit 0 = 1) or RAM
;;;;   $D000-$D0FF  GTIA
;;;;   $D100-$D1FF  Host disk bridge (ROADMAP.md Phase 16) when attached,
;;;;                else open bus (reads = $FF)
;;;;   $D200-$D2FF  POKEY
;;;;   $D300-$D3FF  PIA
;;;;   $D400-$D4FF  ANTIC
;;;;   $D500-$D7FF  Open bus
;;;;   $D800-$FFFF  OS ROM high (PORTB bit 0 = 1) or RAM
;;;;
;;;; The OS ROM is a 16 KiB image laid out so the I/O hole between
;;;; $D000-$D7FF still lives at offsets $1000-$17FF of the image — that
;;;; same range is what gets mapped into $5000-$57FF when the self-test
;;;; is enabled.
;;;;
;;;; ---- Chip dispatch (avoiding package circular dependencies) ----
;;;;
;;;; Each chip (GTIA, POKEY, PIA, ANTIC) registers two closures into the
;;;; bus when it is attached: one for reads, one for writes.  The bus
;;;; only invokes those closures — it never references the chip-package
;;;; symbols directly.  That keeps src/bus.lisp compile-time-independent
;;;; of the chip implementations.  The host disk bridge (ROADMAP.md Phase
;;;; 16, revised; src/hostdev.lisp) at $D100-$D1FF follows the identical
;;;; pattern even though it isn't one of the four real chips.

(in-package #:atari800-cl.bus)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  DECLAIM
;;; PROCLAIMS: under :serial t this also applies to every file compiled
;;; after this one in the same build, which is intentional here (the whole
;;; core wants this policy) — but the same declaim is repeated in each hot
;;; file below so the policy survives recompiling a single file
;;; interactively.  Safety floor stays at 1: no (safety 0) anywhere.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Memory-map constants

(defconstant +ram-size+              #x10000)
(defconstant +selftest-base+         #x5000)
(defconstant +selftest-end+          #x57FF)
(defconstant +selftest-os-offset+    #x1000)
(defconstant +basic-rom-base+        #xA000)
(defconstant +basic-rom-end+         #xBFFF)
(defconstant +os-rom-low-base+       #xC000)
(defconstant +os-rom-low-end+        #xCFFF)
(defconstant +io-base+               #xD000)
(defconstant +io-end+                #xD7FF)
(defconstant +os-rom-high-base+      #xD800)
(defconstant +os-rom-high-end+       #xFFFF)

(deftype bus-ram ()
  `(simple-array (unsigned-byte 8) (,+ram-size+)))

(deftype rom-array ()
  '(simple-array (unsigned-byte 8) (*)))

;;; ---------------------------------------------------------------------------
;;; Bus struct

(defstruct bus
  "Atari 800 XL system bus.

Slots:
  RAM         — flat 64K backing store (writes always land here, even
                under ROM-mapped regions; reads consult the map).
  OS-ROM      — 16K Atari OS image, or NIL when no ROM is loaded.
  BASIC-ROM   — 8K BASIC image, or NIL.
  MMU         — MMU object whose PORTB drives banking, or NIL.
  GTIA / POKEY / PIA / ANTIC — chip object back-pointers, set by
                each chip's attach-to-bus function.
  *-READ-FN / *-WRITE-FN     — per-chip dispatch closures.  Each is
                either NIL (chip not attached) or a function:
                  read closure:  (lambda (address) -> u8)
                  write closure: (lambda (address value) -> *)"
  (ram (make-array +ram-size+ :element-type '(unsigned-byte 8)
                              :initial-element 0)
       :type bus-ram)
  (os-rom    nil :type (or null rom-array))
  (basic-rom nil :type (or null rom-array))
  (mmu       nil :type (or null mmu))
  ;; Per-chip dispatch closures.
  (gtia-read-fn   nil :type (or null function))
  (gtia-write-fn  nil :type (or null function))
  (pokey-read-fn  nil :type (or null function))
  (pokey-write-fn nil :type (or null function))
  (pia-read-fn    nil :type (or null function))
  (pia-write-fn   nil :type (or null function))
  (antic-read-fn  nil :type (or null function))
  (antic-write-fn nil :type (or null function))
  ;; Host disk bridge (ROADMAP.md Phase 16, revised) -- $D100-$D1FF.  Not a
  ;; real Atari chip; NIL on every machine that never calls ATTACH-HOSTDEV,
  ;; which leaves this page's behaviour exactly the open-bus default below.
  (hostdev-read-fn  nil :type (or null function))
  (hostdev-write-fn nil :type (or null function))
  ;; Chip object back-pointers.
  (gtia  nil)
  (pokey nil)
  (pia   nil)
  (antic nil))

;;; ---------------------------------------------------------------------------
;;; RAM peek/poke helpers (bypass the memory map).
;;;
;;; These exist primarily for tests and debugger inspection: they let
;;; callers reach into the underlying 64K backing store directly,
;;; without any ROM-overlay or I/O routing.  Declared NOTINLINE so
;;; SBCL's arm64 backend cannot fold a constant address into an
;;; out-of-range STR/LDR immediate.

(declaim (notinline bus-peek-ram bus-poke-ram))

(defun bus-peek-ram (bus address)
  "Read directly from the 64K RAM backing store, ignoring the memory map."
  (declare (type bus bus) (type u16 address))
  (aref (bus-ram bus) address))

(defun bus-poke-ram (bus address value)
  "Write directly to the 64K RAM backing store, ignoring the memory map."
  (declare (type bus bus) (type u16 address) (type u8 value))
  (setf (aref (bus-ram bus) address) (ldb (byte 8 0) value)))

;;; ---------------------------------------------------------------------------
;;; ROM / MMU wiring helpers

(declaim (inline %byte-at))

(defun %byte-at (rom offset)
  "Read OFFSET from a (possibly shorter than expected) ROM array.
Returns #xFF when the offset is past the end of the image, mimicking
the open-bus / no-pull-up behaviour of unmapped ROM pages."
  (declare (type rom-array rom) (type fixnum offset))
  (if (and (>= offset 0) (< offset (length rom)))
      (aref rom offset)
      #xFF))

(defun attach-mmu (bus mmu)
  "Wire an MMU object into BUS.  Returns BUS for method-chaining."
  (declare (type bus bus) (type mmu mmu))
  (setf (bus-mmu bus) mmu)
  bus)

(defun install-os-rom (bus bytes)
  "Install BYTES (a sequence of u8 values) as the OS ROM image.
The image is coerced into a typed simple-array for fast reads."
  (declare (type bus bus))
  (setf (bus-os-rom bus)
        (coerce bytes '(simple-array (unsigned-byte 8) (*))))
  bus)

(defun install-basic-rom (bus bytes)
  "Install BYTES as the BASIC ROM image."
  (declare (type bus bus))
  (setf (bus-basic-rom bus)
        (coerce bytes '(simple-array (unsigned-byte 8) (*))))
  bus)

;;; ---------------------------------------------------------------------------
;;; Memory-map dispatch
;;;
;;; CL comparison operators take any number of arguments, so the
;;; inclusive range test "is ADDRESS within [LOW, HIGH]?" is spelled
;;; directly as (<= LOW ADDRESS HIGH) — no helper needed.

(declaim (ftype (function (bus u16) (values u8 &optional)) bus-read)
         (ftype (function (bus u16 u8) t) bus-write))

(defun bus-read (bus address)
  "Read one byte from ADDRESS, dispatching through the memory map.

Lookup order — first match wins:
  1. Self-test ROM at $5000-$57FF (when bit 7 = 0 AND OS ROM is on)
  2. BASIC ROM at $A000-$BFFF
  3. OS ROM low at $C000-$CFFF
  4. I/O space at $D000-$D7FF
  5. OS ROM high at $D800-$FFFF
  6. RAM (everywhere else, or anywhere a ROM is not currently mapped)"
  (declare (type bus bus) (type u16 address))
  (let ((mmu (bus-mmu bus)))
    (cond
      ((and mmu (bus-os-rom bus)
            (selftest-mapped-p mmu)
            (<= +selftest-base+ address +selftest-end+))
       (%byte-at (bus-os-rom bus)
                 (+ +selftest-os-offset+ (- address +selftest-base+))))
      ((and mmu (bus-basic-rom bus)
            (basic-rom-mapped-p mmu)
            (<= +basic-rom-base+ address +basic-rom-end+))
       (%byte-at (bus-basic-rom bus) (- address +basic-rom-base+)))
      ((and mmu (bus-os-rom bus)
            (os-rom-mapped-p mmu)
            (<= +os-rom-low-base+ address +os-rom-low-end+))
       (%byte-at (bus-os-rom bus) (- address +os-rom-low-base+)))
      ((<= +io-base+ address +io-end+)
       (io-read bus address))
      ((and mmu (bus-os-rom bus)
            (os-rom-mapped-p mmu)
            (<= +os-rom-high-base+ address +os-rom-high-end+))
       (%byte-at (bus-os-rom bus) (- address +os-rom-low-base+)))
      (t (aref (bus-ram bus) address)))))

(defun bus-write (bus address value)
  "Write VALUE to ADDRESS.  Writes to the I/O range ($D000-$D7FF) go
through the chip dispatch closures; everything else (including the
RAM under any currently-mapped ROM) lands in the 64K RAM array."
  (declare (type bus bus) (type u16 address) (type u8 value))
  (cond
    ((<= +io-base+ address +io-end+)
     (io-write bus address (ldb (byte 8 0) value)))
    (t
     (setf (aref (bus-ram bus) address) (ldb (byte 8 0) value)))))

(defun bus-read16 (bus address)
  "Read a little-endian 16-bit word.  ADDRESS+1 wraps within 64K."
  (declare (type bus bus) (type u16 address))
  (let ((lo (bus-read bus address))
        (hi (bus-read bus (ldb (byte 16 0) (1+ address)))))
    (dpb hi (byte 8 8) lo)))

;;; ---------------------------------------------------------------------------
;;; I/O sub-dispatch (one switch over the high byte of the I/O page).
;;;
;;; If the chip's dispatch closure is NIL (chip not attached), the read
;;; returns #xFF (open bus) and the write is silently dropped.  Crucially,
;;; the write does NOT fall through to RAM — that's what distinguishes
;;; an I/O-range write from a normal memory write.

(defun io-read (bus address)
  (declare (type bus bus) (type u16 address))
  (let ((fn (case (logand address #xFF00)
              (#xD000 (bus-gtia-read-fn bus))
              (#xD100 (bus-hostdev-read-fn bus))
              (#xD200 (bus-pokey-read-fn bus))
              (#xD300 (bus-pia-read-fn bus))
              (#xD400 (bus-antic-read-fn bus)))))
    (if fn (funcall fn address) #xFF)))

(defun io-write (bus address value)
  (declare (type bus bus) (type u16 address) (type u8 value))
  (let ((fn (case (logand address #xFF00)
              (#xD000 (bus-gtia-write-fn bus))
              (#xD100 (bus-hostdev-write-fn bus))
              (#xD200 (bus-pokey-write-fn bus))
              (#xD300 (bus-pia-write-fn bus))
              (#xD400 (bus-antic-write-fn bus)))))
    (when fn (funcall fn address value))))
