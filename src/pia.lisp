;;;; src/pia.lisp --- Atari 800 XL PIA (6520-compatible).
;;;;
;;;; The PIA on the 800 XL is wired as follows:
;;;;
;;;;   $D300 — PORTA or DDRA, selected by bit 2 of PACTL.
;;;;           PORTA is input from the joystick and keyboard column lines;
;;;;           DDRA is its data-direction register (bit n = 1 → pin is an
;;;;           output, 0 → input).
;;;;   $D301 — PORTB or DDRB, selected by bit 2 of PBCTL.
;;;;           PORTB is the output that drives the MMU bank-switching bits
;;;;           (and several other signals we don't model: cassette motor,
;;;;           serial I/O direction, etc.); DDRB is its direction register.
;;;;   $D302 — PACTL, port A control register.  Bit 2 is the PORTA/DDRA
;;;;           select; bit 3 is the cassette motor line (not modelled);
;;;;           bits 0-1 and 4-5 configure the CA1/CA2 peripheral-control
;;;;           lines (not modelled); bits 6-7 are read-only IRQ flags.
;;;;   $D303 — PBCTL, port B control register.  Bit 2 is the PORTB/DDRB
;;;;           select; bit 3 is the SIO command line (not modelled); the
;;;;           remaining bits mirror PACTL's roles for CB1/CB2.
;;;;
;;;; The port/DDR select really matters: the XL OS boot code writes $38 to
;;;; PACTL (select DDRA), programs DDRA, then writes $3C (select PORTA) —
;;;; and does the same dance on PBCTL/DDRB/PORTB.  Decoding $D302 as PORTB
;;;; would push $38 into the MMU, unmapping the OS ROM out from under the
;;;; running boot code.
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
  PACTL — port A control register ($D302).  Bit 2 selects which register
          $D300 addresses: 1 = PORTA, 0 = DDRA.  Cleared at reset, so a
          just-reset chip sees $D300 as DDRA, exactly like the hardware.
  PBCTL — port B control register ($D303).  Bit 2 selects $D301:
          1 = PORTB, 0 = DDRB.
  MMU   — optional back-pointer to the MMU; if non-NIL, PORTB writes
          propagate to MMU-WRITE-PORTB immediately."
  (porta #xFF :type u8)
  (ddra  #x00 :type u8)
  (portb #xFF :type u8)
  (ddrb  #x00 :type u8)
  (pactl #x00 :type u8)
  (pbctl #x00 :type u8)
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
        (pia-ddrb  pia) #x00
        (pia-pactl pia) #x00
        (pia-pbctl pia) #x00)
  pia)

(declaim (inline %offset %port-selected-p))

(defun %offset (address)
  "Decode the two-bit PIA register selector from a bus address."
  (declare (type u16 address))
  (ldb (byte 2 0) address))

(defun %port-selected-p (control)
  "True when CONTROL (PACTL or PBCTL) selects the port register rather than
the data-direction register.  That is bit 2 of the control register."
  (declare (type u8 control))
  (logbitp 2 control))

(defun pia-read (pia address)
  "Read one of the four PIA registers selected by the low two address bits.
Offsets 0 and 1 read PORTA/DDRA and PORTB/DDRB respectively, chosen by
bit 2 of PACTL / PBCTL; offsets 2 and 3 read the control registers
themselves.  The chip mirrors across the entire $D300-$D3FF range, so any
address in that page is valid."
  (declare (type pia pia) (type u16 address))
  (ecase (%offset address)
    (0 (if (%port-selected-p (pia-pactl pia))
           (let ((input (pia-input pia)))
             (if input
                 (atari800-cl.input:input-pia-porta input)
                 (pia-porta pia)))
           (pia-ddra pia)))
    ;; PORTB is all outputs on the 800 XL, so a port read returns the
    ;; output latch; we do not model pin-level readback of input bits.
    (1 (if (%port-selected-p (pia-pbctl pia))
           (pia-portb pia)
           (pia-ddrb pia)))
    (2 (pia-pactl pia))
    (3 (pia-pbctl pia))))

(defun pia-write (pia address value)
  "Write one of the four PIA registers.  Offsets 0 and 1 write PORTA/DDRA
and PORTB/DDRB, chosen by bit 2 of PACTL / PBCTL; offsets 2 and 3 write
the control registers.

A PORTB write propagates to the MMU via MMU-WRITE-PORTB so the new bank
mapping takes effect on the next bus access.  A DDRB write does not: the
MMU tracks the output latch only, which is what the OS drives once it has
set DDRB to $FF."
  (declare (type pia pia) (type u16 address) (type u8 value))
  (let ((v (ldb (byte 8 0) value)))
    (ecase (%offset address)
      ;; PORTA is an input on the 800 XL; we update the latch anyway
      ;; (so a debugger can inspect it) but it has no external effect.
      (0 (if (%port-selected-p (pia-pactl pia))
             (setf (pia-porta pia) v)
             (setf (pia-ddra pia) v)))
      (1 (cond ((%port-selected-p (pia-pbctl pia))
                (setf (pia-portb pia) v)
                (when (pia-mmu pia)
                  (mmu-write-portb (pia-mmu pia) v)))
               (t (setf (pia-ddrb pia) v))))
      ;; Bits 6-7 of a control register are the read-only CA/CB interrupt
      ;; flags; writes to them are ignored by the hardware, and we do not
      ;; model the peripheral-control lines that would set them.
      (2 (setf (pia-pactl pia) (logand v #x3F)))
      (3 (setf (pia-pbctl pia) (logand v #x3F))))))

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
