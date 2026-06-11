;;;; src/pia.lisp --- Atari 800 XL PIA (6520-compatible).
;;;;
;;;; The PIA on the 800 XL is wired as follows:
;;;;
;;;;   PORTA ($D300) — input from the joystick and keyboard column lines.
;;;;                   Programs read this byte; writes are silently dropped
;;;;                   in our model because PORTA is wired as an input.
;;;;   DDRA  ($D301) — data direction register for PORTA.  Bit n = 1 → pin
;;;;                   is an output, bit n = 0 → pin is an input.
;;;;   PORTB ($D302) — output that drives the MMU bank-switching bits
;;;;                   (and several other signals we don't model: cassette
;;;;                   motor, serial I/O direction, etc.).
;;;;   DDRB  ($D303) — data direction register for PORTB.
;;;;
;;;; Each register's address decode is just (addr & $03), so the four
;;;; registers mirror across the entire $D300-$D3FF range.
;;;;
;;;; This file additionally exposes ATTACH-PIA, which installs the PIA's
;;;; read/write dispatch closures into a bus.  The closures funnel back
;;;; into PIA-READ / PIA-WRITE so the bus stays chip-agnostic.

(in-package #:atari800-cl.pia)

(defstruct pia
  "PIA (6520) shadow state for the Atari 800 XL.

Slots:
  PORTA — joystick / keyboard column input latch (default $FF = no buttons)
  DDRA  — direction register for PORTA bits (1 = output)
  PORTB — output to the MMU + console hardware (default $FF = cold-reset)
  DDRB  — direction register for PORTB bits
  MMU   — optional back-pointer to the MMU; if non-NIL, PORTB writes
          propagate to MMU-WRITE-PORTB immediately."
  (porta #xFF :type u8)
  (ddra  #x00 :type u8)
  (portb #xFF :type u8)
  (ddrb  #x00 :type u8)
  (mmu   nil)
  ;; Optional host INPUT-STATE (atari800-cl.input).  When non-NIL, PORTA
  ;; reads reflect live joystick input instead of the static latch.
  (input nil))

(defun reset-pia (pia)
  "Reset all PIA latches to their cold-reset defaults.  Returns PIA."
  (declare (type pia pia))
  (setf (pia-porta pia) #xFF
        (pia-ddra  pia) #x00
        (pia-portb pia) #xFF
        (pia-ddrb  pia) #x00)
  pia)

(declaim (inline %offset))

(defun %offset (address)
  "Decode the two-bit PIA register selector from a bus address."
  (declare (type u16 address))
  (logand address #x03))

(defun pia-read (pia address)
  "Read one of the four PIA registers selected by (ADDRESS AND $03).
The chip mirrors across the entire $D300-$D3FF range, so any address
in that page is valid."
  (declare (type pia pia) (type u16 address))
  (ecase (%offset address)
    (0 (let ((input (pia-input pia)))
         (if input
             (atari800-cl.input:input-pia-porta input)
             (pia-porta pia))))
    (1 (pia-ddra  pia))
    (2 (pia-portb pia))
    (3 (pia-ddrb  pia))))

(defun pia-write (pia address value)
  "Write one of the four PIA registers.  A PORTB write (offset 2)
propagates to the MMU via MMU-WRITE-PORTB so the new bank mapping
takes effect on the next bus access."
  (declare (type pia pia) (type u16 address) (type u8 value))
  (let ((v (logand value #xFF)))
    (ecase (%offset address)
      ;; PORTA is an input on the 800 XL; we update the latch anyway
      ;; (so a debugger can inspect it) but it has no external effect.
      (0 (setf (pia-porta pia) v))
      (1 (setf (pia-ddra  pia) v))
      (2 (setf (pia-portb pia) v)
         (when (pia-mmu pia)
           (mmu-write-portb (pia-mmu pia) v)))
      (3 (setf (pia-ddrb  pia) v)))))

(defun attach-pia (bus pia &optional mmu)
  "Wire PIA into BUS.  When MMU is supplied (or already present in PIA),
PORTB writes propagate there immediately.  Returns BUS."
  (declare (type pia pia))
  (when mmu (setf (pia-mmu pia) mmu))
  (setf (bus-pia bus) pia
        (bus-pia-read-fn  bus) (lambda (addr) (pia-read pia addr))
        (bus-pia-write-fn bus) (lambda (addr val) (pia-write pia addr val)))
  bus)

(defun attach-pia-input (pia input)
  "Attach a host INPUT-STATE to PIA so PORTA reads reflect live joystick
input.  Pass NIL to detach.  Returns PIA."
  (declare (type pia pia))
  (setf (pia-input pia) input)
  pia)
