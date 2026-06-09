;;;; tests/test-input.lisp --- Host input-state tests.
;;;;
;;;; Covers defaults, every setter/getter, the PORTA nibble packing, and a
;;;; concurrent-writers smoke test (the struct is shared between socket
;;;; reader threads and the emulator thread).

(in-package #:atari800-cl/tests)

(def-suite input-suite
  :description "Thread-safe host input state (keyboard/joystick/console/paddles)."
  :in atari800-cl-suite)

(in-suite input-suite)

;;; ---------------------------------------------------------------------------
;;; Defaults

(test input-defaults-are-idle
  "A fresh INPUT-STATE reads as 'nothing pressed' on every register."
  (let ((in (make-input-state)))
    (is (= #xFF (input-pia-porta in)) "PORTA idle = $FF")
    (is (= 1 (input-gtia-trig in 0)) "TRIG0 idle = 1")
    (is (= 1 (input-gtia-trig in 1)) "TRIG1 idle = 1")
    (is (= #x07 (input-gtia-consol in)) "CONSOL idle = $07")
    (is (= 228 (input-pokey-pot in 0)) "POT0 idle = 228")
    (is (= 0 (input-pokey-kbcode in)) "KBCODE idle = 0")
    (is (= #xFF (input-pokey-skstat in)) "SKSTAT idle = $FF")))

;;; ---------------------------------------------------------------------------
;;; Joystick + PORTA packing

(test input-joystick-port0-packs-low-nibble
  "Stick 0 directions land in PORTA bits 0-3 (active-low) and TRIG0."
  (let ((in (make-input-state)))
    (input-set-joystick in 0 :up t :trigger t)
    ;; up pressed -> bit0 = 0; everything else released -> 1.  Low nibble
    ;; = 1110 = $E; high nibble (stick 1, untouched) = $F.
    (is (= #xFE (input-pia-porta in)) "PORTA = $FE after stick-0 up")
    (is (= 0 (input-gtia-trig in 0)) "TRIG0 = 0 while fire held")
    (is (= 1 (input-gtia-trig in 1)) "TRIG1 unaffected")))

(test input-joystick-port1-packs-high-nibble
  "Stick 1 directions land in PORTA bits 4-7 and TRIG1."
  (let ((in (make-input-state)))
    (input-set-joystick in 1 :right t :trigger t)
    ;; right -> bit3 of stick-1 nibble = 0 -> nibble 0111 = $7; shifted high
    ;; = $70; low nibble (stick 0) idle = $F.  => $7F.
    (is (= #x7F (input-pia-porta in)) "PORTA = $7F after stick-1 right")
    (is (= 0 (input-gtia-trig in 1)) "TRIG1 = 0 while fire held")
    (is (= 1 (input-gtia-trig in 0)) "TRIG0 unaffected")))

(test input-joystick-release-restores-idle
  "Re-setting a stick with no directions returns its nibble to idle."
  (let ((in (make-input-state)))
    (input-set-joystick in 0 :down t :left t :trigger t)
    (input-set-joystick in 0)            ; all released
    (is (= #xFF (input-pia-porta in)) "PORTA back to $FF")
    (is (= 1 (input-gtia-trig in 0)) "TRIG0 released")))

;;; ---------------------------------------------------------------------------
;;; Console keys

(test input-console-keys-active-low
  "START/SELECT/OPTION clear bits 0/1/2 of CONSOL when held."
  (let ((in (make-input-state)))
    (input-set-console in :start t)
    (is (= #x06 (input-gtia-consol in)) "START held -> bit0 clear ($06)")
    (input-set-console in :select t :option t)
    (is (= #x01 (input-gtia-consol in)) "SELECT+OPTION held -> $01")
    (input-set-console in)
    (is (= #x07 (input-gtia-consol in)) "all released -> $07")))

;;; ---------------------------------------------------------------------------
;;; Paddles

(test input-paddle-sets-pot
  "INPUT-SET-PADDLE writes the matching POT register; others unchanged."
  (let ((in (make-input-state)))
    (input-set-paddle in 2 100)
    (is (= 100 (input-pokey-pot in 2)) "POT2 = 100")
    (is (= 228 (input-pokey-pot in 0)) "POT0 still idle")
    (input-set-paddle in 2 999)          ; clamped to a byte
    (is (= (logand 999 #xFF) (input-pokey-pot in 2)) "POT2 masked to a byte")))

;;; ---------------------------------------------------------------------------
;;; Keyboard

(test input-key-sets-kbcode-and-skstat
  "INPUT-SET-KEY latches KBCODE and toggles the SKSTAT key-down line."
  (let ((in (make-input-state)))
    (input-set-key in #x3F)              ; pressed (default)
    (is (= #x3F (input-pokey-kbcode in)) "KBCODE latched")
    (is (= #xFB (input-pokey-skstat in)) "SKSTAT bit2 clear while key down")
    (input-set-key in #x3F nil)          ; released
    (is (= #xFF (input-pokey-skstat in)) "SKSTAT back to $FF on release")
    (is (= #x3F (input-pokey-kbcode in)) "KBCODE keeps last code")))

;;; ---------------------------------------------------------------------------
;;; Concurrency smoke test

(test input-concurrent-writers-do-not-crash
  "Many threads hammering the setters while a reader polls must not error
or tear (the lock serialises all access).  Final state is well-formed."
  (let ((in (make-input-state))
        (threads '()))
    (dotimes (i 8)
      (push (make-thread
             (lambda ()
               (dotimes (j 500)
                 (input-set-joystick in (mod j 2) :up (oddp j) :trigger (evenp j))
                 (input-set-console in :start (zerop (mod j 3)))
                 (input-set-paddle in (mod j 4) (mod (* i j) 229))
                 (input-set-key in (mod j 256) (oddp j))))
             :name (format nil "input-writer-~D" i))
            threads))
    ;; Reader polls concurrently.
    (dotimes (k 2000)
      (input-pia-porta in)
      (input-gtia-consol in)
      (input-pokey-pot in (mod k 4))
      (input-pokey-skstat in))
    (mapc #'join-thread threads)
    ;; PORTA is always a byte; that's the invariant we can assert post-hoc.
    (is (typep (input-pia-porta in) '(unsigned-byte 8))
        "PORTA is a valid byte after concurrent writers")
    (pass)))
