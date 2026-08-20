;;;; src/input.lisp --- Thread-safe host input state.
;;;;
;;;; A single INPUT-STATE struct models everything an external front-end can
;;;; inject: keyboard, two joystick ports, the three console keys, and four
;;;; paddles.  Socket reader threads call the INPUT-SET-* setters; the
;;;; emulator thread calls the INPUT-* getters when the PIA / GTIA / POKEY
;;;; register-read paths are exercised.  A single lock guards all access.
;;;;
;;;; Register encodings (Atari 800 XL):
;;;;
;;;;   PORTA ($D300, PIA)  — joystick directions, ACTIVE-LOW (0 = pressed).
;;;;     Stick 0 in the low nibble, stick 1 in the high nibble; within each
;;;;     nibble: bit0 up, bit1 down, bit2 left, bit3 right.  Idle = $FF.
;;;;   TRIG0..3 ($D010-$D013, GTIA) — one bit each, ACTIVE-LOW (0 = pressed).
;;;;     Joystick fire buttons; idle = 1.
;;;;   CONSOL ($D01F, GTIA) — bit0 START, bit1 SELECT, bit2 OPTION,
;;;;     ACTIVE-LOW.  Idle = $07 (none held).
;;;;   POT0..7 ($D200-$D207, POKEY) — paddle positions 0..228.  We model the
;;;;     four the 800 XL exposes; idle = 228 (fully clockwise).
;;;;   KBCODE ($D209, POKEY) — last key scan code.
;;;;   SKSTAT ($D20F, POKEY) — bit2 is the "last key still pressed" line,
;;;;     ACTIVE-LOW; idle = $FF.
;;;;
;;;; Keyboard / BREAK IRQ arming (ROADMAP.md Phase 13): a key press or a
;;;; BREAK press each arm a one-shot flag here, read-and-cleared by POKEY
;;;; on its next advance (INPUT-CONSUME-KEY-IRQ / INPUT-CONSUME-BREAK-IRQ)
;;;; to raise IRQEN bit 6 / bit 7.  BREAK is a dedicated physical switch on
;;;; real hardware, not part of the 64-key scan matrix, so it gets its own
;;;; setter (INPUT-SET-BREAK) and does not touch KBCODE or the SKSTAT
;;;; key-down line at all.

(in-package #:atari800-cl.input)

;;; Joystick direction bit positions within a PORTA nibble (active-low).
(defconstant +joy-up+    0)
(defconstant +joy-down+  1)
(defconstant +joy-left+  2)
(defconstant +joy-right+ 3)

(defstruct (input-state
            (:constructor make-input-state))
  "Mutable, lock-guarded snapshot of host input devices.

Slots (all integers are register-ready bytes in their native encoding):
  LOCK        — guards every read and write of the slots below.
  JOY         — 2-element array; element P is stick P's 4-bit direction
                nibble (active-low) ready to drop into PORTA.
  TRIG        — 4-element array; TRIG0..3 (active-low, 0 = fire pressed).
  CONSOL      — START/SELECT/OPTION byte (active-low, bits 0/1/2).
  POT         — 4-element array; POT0..3 paddle positions (0..228).
  KBCODE            — last keyboard scan code.
  KEY-PRESSED       — T while a key is held (drives the SKSTAT line).
  KEY-IRQ-PENDING   — one-shot: a key press arrived since POKEY last
                      consumed it (INPUT-CONSUME-KEY-IRQ).
  BREAK-IRQ-PENDING — one-shot: BREAK was pressed since POKEY last
                      consumed it (INPUT-CONSUME-BREAK-IRQ)."
  (lock (make-lock "input-state"))
  (joy    (make-array 2 :element-type 'u8 :initial-element #x0F))
  (trig   (make-array 4 :element-type 'u8 :initial-element 1))
  (consol #x07 :type u8)
  (pot    (make-array 4 :element-type 'u8 :initial-element 228))
  (kbcode 0   :type u8)
  (key-pressed nil)
  (key-irq-pending nil)
  (break-irq-pending nil))

;;; ---------------------------------------------------------------------------
;;; Setters — called from socket reader threads.

(defun input-set-joystick (input port &key up down left right trigger)
  "Set stick PORT (0 or 1).  UP/DOWN/LEFT/RIGHT/TRIGGER are booleans
(T = pressed).  Updates the PORTA nibble and the matching TRIG line."
  (declare (type input-state input) (type (integer 0 1) port))
  (with-lock ((input-state-lock input))
    (setf (aref (input-state-joy input) port)
          (logior (ash (if up    0 1) +joy-up+)
                  (ash (if down  0 1) +joy-down+)
                  (ash (if left  0 1) +joy-left+)
                  (ash (if right 0 1) +joy-right+))
          (aref (input-state-trig input) port)
          (if trigger 0 1)))
  input)

(defun input-set-console (input &key start select option)
  "Set the console keys.  START/SELECT/OPTION are booleans (T = pressed)."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (setf (input-state-consol input)
          (logior (ash (if start  0 1) 0)
                  (ash (if select 0 1) 1)
                  (ash (if option 0 1) 2))))
  input)

(defun input-set-paddle (input n value)
  "Set paddle N (0..3) to VALUE (clamped to a byte, 0..228 meaningful)."
  (declare (type input-state input) (type (integer 0 3) n))
  (with-lock ((input-state-lock input))
    (setf (aref (input-state-pot input) n) (ldb (byte 8 0) value)))
  input)

(defun input-set-key (input kbcode &optional (pressed t))
  "Latch KBCODE as the last key and set the held/released state.  A press
(PRESSED true) also arms the keyboard IRQ POKEY services on its next
advance (see INPUT-CONSUME-KEY-IRQ); a release does not, matching real
hardware, where only a scan-matrix transition into key-down raises the
interrupt."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (setf (input-state-kbcode input) (ldb (byte 8 0) kbcode)
          (input-state-key-pressed input) pressed)
    (when pressed
      (setf (input-state-key-irq-pending input) t)))
  input)

(defun input-set-break (input &optional (pressed t))
  "Signal the BREAK key.  A press (PRESSED true) arms POKEY's BREAK IRQ
\(see INPUT-CONSUME-BREAK-IRQ); a release does nothing.  BREAK is a
dedicated physical switch on real hardware, not part of the 64-key scan
matrix, so unlike INPUT-SET-KEY this does not touch KBCODE or the
SKSTAT key-down line."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (when pressed
      (setf (input-state-break-irq-pending input) t)))
  input)

;;; ---------------------------------------------------------------------------
;;; Getters — called from the emulator thread by PIA / GTIA / POKEY reads.

(defun input-pia-porta (input)
  "PORTA byte: stick 0 in the low nibble, stick 1 in the high nibble."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (dpb (aref (input-state-joy input) 1) (byte 4 4)
         (aref (input-state-joy input) 0))))

(defun input-gtia-trig (input n)
  "TRIG<N> (0 = fire pressed, 1 = released)."
  (declare (type input-state input) (type (integer 0 3) n))
  (with-lock ((input-state-lock input))
    (aref (input-state-trig input) n)))

(defun input-gtia-consol (input)
  "CONSOL byte (active-low START/SELECT/OPTION in bits 0/1/2)."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (input-state-consol input)))

(defun input-pokey-pot (input n)
  "POT<N> paddle position (0..228)."
  (declare (type input-state input) (type (integer 0 3) n))
  (with-lock ((input-state-lock input))
    (aref (input-state-pot input) n)))

(defun input-pokey-kbcode (input)
  "KBCODE — the last key scan code latched via INPUT-SET-KEY."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (input-state-kbcode input)))

(defun input-pokey-skstat (input)
  "SKSTAT — $FF idle; bit2 cleared (active-low) while a key is held."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (if (input-state-key-pressed input)
        #xFB                            ; bit2 = 0 -> key down
        #xFF)))

(defun input-consume-key-irq (input)
  "Read-and-clear the keyboard-IRQ-armed flag.  T if a key press was
latched (via INPUT-SET-KEY) since the last call; POKEY calls this once
per advance while input is attached and raises its keyboard IRQ on T."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (prog1 (input-state-key-irq-pending input)
      (setf (input-state-key-irq-pending input) nil))))

(defun input-consume-break-irq (input)
  "Read-and-clear the BREAK-IRQ-armed flag.  T if BREAK was pressed (via
INPUT-SET-BREAK) since the last call; POKEY calls this once per advance
while input is attached and raises its BREAK IRQ on T."
  (declare (type input-state input))
  (with-lock ((input-state-lock input))
    (prog1 (input-state-break-irq-pending input)
      (setf (input-state-break-irq-pending input) nil))))
