;;;; src/mmu.lisp --- Atari 800 XL memory management unit (PORTB banking).
;;;;
;;;; The MMU is a tiny model: it owns a single byte (the PORTB shadow)
;;;; and exposes three predicates the bus consults on every read in
;;;; ROM-overlap regions.  Three bits of PORTB drive the banking:
;;;;
;;;;   bit 0 — OS ROM enable        (1 = OS ROM at $C000-$CFFF & $D800-$FFFF;
;;;;                                 0 = RAM under it)
;;;;   bit 1 — BASIC ROM disable    (0 = BASIC at $A000-$BFFF; 1 = RAM)
;;;;   bit 7 — Self-test disable    (0 = self-test ROM at $5000-$57FF;
;;;;                                 1 = RAM.  Self-test requires OS ROM
;;;;                                 enabled because the self-test code
;;;;                                 lives inside the OS ROM image at
;;;;                                 offset $1000.)
;;;;
;;;; Bits 2-6 control other peripherals on real hardware (cassette motor,
;;;; light-pen, serial port direction, etc.); we don't model them.
;;;;
;;;; The PIA chip ($D300-$D303) routes writes to PORTB ($D301, when PBCTL
;;;; bit 2 selects the port rather than DDRB) through MMU-WRITE-PORTB so
;;;; the bank-switching takes effect immediately.

(in-package #:atari800-cl.mmu)

;;; Bit masks for the three banking-control bits.
(defconstant +portb-os-rom-mask+    #x01)
(defconstant +portb-basic-rom-mask+ #x02)
(defconstant +portb-selftest-mask+  #x80)

(defstruct mmu
  "Atari 800 XL bank-switching unit.

Slots:
  PORTB — the latched PORTB output value; only bits 0, 1, and 7 matter
          for banking.  Cold-reset default is $FF, which on the 800 XL
          means OS ROM on, BASIC ROM off, self-test ROM off."
  (portb #xFF :type u8))

(declaim (inline os-rom-mapped-p basic-rom-mapped-p selftest-mapped-p))

(defun os-rom-mapped-p (mmu)
  "Return T if OS ROM is currently mapped at $C000-$CFFF and $D800-$FFFF.
On the 800 XL, PORTB bit 0 = 1 enables the OS ROM overlay."
  (declare (type mmu mmu))
  (logtest (mmu-portb mmu) +portb-os-rom-mask+))

(defun basic-rom-mapped-p (mmu)
  "Return T if BASIC ROM is currently mapped at $A000-$BFFF.
PORTB bit 1 is inverted: BASIC is enabled when the bit is CLEAR."
  (declare (type mmu mmu))
  (not (logtest (mmu-portb mmu) +portb-basic-rom-mask+)))

(defun selftest-mapped-p (mmu)
  "Return T if the self-test ROM is mapped at $5000-$57FF.
PORTB bit 7 is inverted (0 = enabled).  Self-test code is part of the
OS ROM image, so it can only appear when OS ROM is also enabled."
  (declare (type mmu mmu))
  (and (os-rom-mapped-p mmu)
       (not (logtest (mmu-portb mmu) +portb-selftest-mask+))))

(defun mmu-write-portb (mmu value)
  "Update PORTB.  Called by the PIA when software writes PORTB at $D301;
the new banking takes effect on the very next bus access.  Returns MMU."
  (declare (type mmu mmu) (type u8 value))
  (setf (mmu-portb mmu) (ldb (byte 8 0) value))
  mmu)

(defun reset-mmu (mmu)
  "Reset PORTB to its cold-reset default of $FF (OS ROM enabled, BASIC
disabled, self-test disabled).  Returns MMU."
  (declare (type mmu mmu))
  (setf (mmu-portb mmu) #xFF)
  mmu)

(defun portb-decode (mmu)
  "Return a plist describing the current bank mapping — handy for the
debug helpers added in Prompt 11.  Example:
  (:portb #x01 :os-rom-mapped t :basic-rom-mapped t :selftest-mapped t)"
  (declare (type mmu mmu))
  (list :portb              (mmu-portb mmu)
        :os-rom-mapped      (os-rom-mapped-p mmu)
        :basic-rom-mapped   (basic-rom-mapped-p mmu)
        :selftest-mapped    (selftest-mapped-p mmu)))
