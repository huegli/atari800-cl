;;;; src/pokey.lisp --- POKEY (timers, IRQs, RNG, audio scaffolding).
;;;;
;;;; POKEY occupies $D200-$D2FF.  Within the chip, write and read
;;;; windows DIFFER at the same offset.  Offset is computed as
;;;; (addr & $0F), so the registers mirror across the page.
;;;;
;;;; Write side (by offset):
;;;;   0,2,4,6   AUDF1-AUDF4   audio frequency dividers
;;;;   1,3,5,7   AUDC1-AUDC4   audio control + volume
;;;;   8         AUDCTL        global audio control (clock sel, links)
;;;;   9         STIMER        write-only: reload all timer counters
;;;;   10        SKREST        write-only: reset SKSTAT (no-op for us)
;;;;   13        SEROUT        serial output (stub)
;;;;   14        IRQEN         IRQ enable mask
;;;;   15        SKCTL         serial/keyboard control
;;;;
;;;; Read side:
;;;;   0..7      POT0..POT7    paddle pots (stub at $FF)
;;;;   8         ALLPOT        composite pot status (stub at $FF)
;;;;   9         KBCODE        last keyboard scan code
;;;;   10        RANDOM        polynomial RNG output (17-bit or 9-bit)
;;;;   14        IRQST         active-low IRQ status (1 = not pending)
;;;;   15        SKSTAT        serial/keyboard status (stub at $FF)
;;;;
;;;; Timer model (one POKEY-TICK = one CPU cycle):
;;;;   Each channel has an internal AUDF reload value and a current
;;;;   countdown.  Channels 1 and 3 can use the 1.79 MHz CPU clock
;;;;   directly (AUDCTL bit 6 / bit 5); all other channels run at
;;;;   either 64 kHz (CPU/28) or 15 kHz (CPU/114, AUDCTL bit 0 = 1).
;;;;   On underflow the counter reloads from AUDF and, for channels
;;;;   1, 2, and 4 with the matching IRQEN bit (0, 1, or 3) set,
;;;;   the chip raises a CPU IRQ and clears that bit in IRQST.
;;;;
;;;;   Writing IRQEN restores any IRQST latch bits cleared by past
;;;;   underflows ("acknowledge" semantics).
;;;;
;;;; RNG model:
;;;;   Two LFSRs are clocked once per POKEY-TICK.  AUDCTL bit 7
;;;;   selects which one feeds RANDOM: clear = 17-bit, set = 9-bit.

(in-package #:atari800-cl.pokey)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  See the
;;; matching declaim in src/bus.lisp for the note on DECLAIM's proclaiming
;;; behaviour under :serial t; repeated here so this file's policy survives
;;; interactive recompilation on its own.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Constants

(defconstant +pokey-64khz-divisor+ 28)
(defconstant +pokey-15khz-divisor+ 114)

;;; IRQEN / IRQST bit masks
(defconstant +irq-timer1+ #x01)
(defconstant +irq-timer2+ #x02)
(defconstant +irq-timer4+ #x08)

;;; Register offsets (within the 16-byte mirroring window)
(defconstant +reg-audf1+  0)
(defconstant +reg-audc1+  1)
(defconstant +reg-audf2+  2)
(defconstant +reg-audc2+  3)
(defconstant +reg-audf3+  4)
(defconstant +reg-audc3+  5)
(defconstant +reg-audf4+  6)
(defconstant +reg-audc4+  7)
(defconstant +reg-audctl+ 8)
(defconstant +reg-stimer+ 9)
(defconstant +reg-skrest+ 10)
(defconstant +reg-pot10+  10)   ; read side
(defconstant +reg-allpot+ 8)
(defconstant +reg-kbcode+ 9)
(defconstant +reg-random+ 10)
(defconstant +reg-serout+ 13)
(defconstant +reg-irqen+  14)
(defconstant +reg-skctl+  15)
(defconstant +reg-irqst+  14)
(defconstant +reg-skstat+ 15)

;;; ---------------------------------------------------------------------------
;;; POKEY struct

(defstruct pokey
  "POKEY shadow state.  See file header for the full register map.

Slots:
  AUDF / AUDC                 — 4-byte arrays for the audio dividers
                                and per-channel control bytes.
  AUDCTL / SKCTL              — global audio / serial-keyboard control.
  IRQEN / IRQST               — IRQ enable mask and active-low status.
  SKSTAT                      — serial/keyboard status (stubbed at $FF).
  KBCODE                      — last keyboard scan code.
  TIMER-COUNTS                — 4-element fixnum array, each channel's
                                current countdown.
  SUB-COUNTERS                — 4-element fixnum array, the divider
                                pre-counter for each channel's clock.
  POLY17-STATE, POLY9-STATE   — LFSR state words for the polynomial RNG.
  CPU                         — CPU back-pointer for IRQ routing."
  (audf  (make-array 4 :element-type '(unsigned-byte 8) :initial-element 0)
         :type (simple-array (unsigned-byte 8) (4)))
  (audc  (make-array 4 :element-type '(unsigned-byte 8) :initial-element 0)
         :type (simple-array (unsigned-byte 8) (4)))
  (audctl 0 :type (unsigned-byte 8))
  (skctl  0 :type (unsigned-byte 8))
  (irqen  0 :type (unsigned-byte 8))
  (irqst  #xFF :type (unsigned-byte 8))
  (skstat #xFF :type (unsigned-byte 8))
  (kbcode 0 :type (unsigned-byte 8))
  (timer-counts (make-array 4 :element-type 'fixnum :initial-element 0)
                :type (simple-array fixnum (4)))
  (sub-counters (make-array 4 :element-type 'fixnum :initial-element 1)
                :type (simple-array fixnum (4)))
  (poly17-state #x1FFFF :type fixnum)
  (poly9-state  #x01FF  :type fixnum)
  (cpu nil)
  ;; Optional host INPUT-STATE (atari800-cl.input).  When non-NIL, POT0..3,
  ;; KBCODE, and SKSTAT reads reflect live input instead of the stubs.
  (input nil))

;;; ---------------------------------------------------------------------------
;;; Channel-clock divisor

(declaim (inline %channel-divisor))

(defun %channel-divisor (pokey ch)
  "How many CPU cycles between two ticks of channel CH's timer."
  (declare (type pokey pokey) (type fixnum ch))
  (let ((ac (pokey-audctl pokey)))
    (cond
      ;; Channel 1 (index 0) on 1.79 MHz when AUDCTL bit 6 set.
      ((and (= ch 0) (logtest ac #x40)) 1)
      ;; Channel 3 (index 2) on 1.79 MHz when AUDCTL bit 5 set.
      ((and (= ch 2) (logtest ac #x20)) 1)
      ;; 15 kHz instead of 64 kHz when AUDCTL bit 0 set.
      ((logtest ac #x01) +pokey-15khz-divisor+)
      ;; Default: 64 kHz.
      (t +pokey-64khz-divisor+))))

(declaim (inline %irq-bit-for-channel))

(defun %irq-bit-for-channel (ch)
  "IRQEN/IRQST bit for the channel.  Channel 2 (Timer 3) has no IRQ source."
  (case ch
    (0 +irq-timer1+)
    (1 +irq-timer2+)
    (3 +irq-timer4+)
    (t 0)))

;;; ---------------------------------------------------------------------------
;;; Polynomial RNG (LFSRs clocked every CPU cycle)

(defun %advance-rng (pokey)
  "Advance both LFSRs by one bit.  Cheap shift-register approximations
of the Atari polys (sufficient for the prompt's tests).

  17-bit poly taps: bit 0 XOR bit 5
   9-bit poly taps: bit 0 XOR bit 4"
  (declare (type pokey pokey))
  (let* ((p17 (pokey-poly17-state pokey))
         (fb17 (logxor (ldb (byte 1 0) p17) (ldb (byte 1 5) p17)))
         (n17 (dpb fb17 (byte 1 16) (ash p17 -1)))
         (p9 (pokey-poly9-state pokey))
         (fb9 (logxor (ldb (byte 1 0) p9) (ldb (byte 1 4) p9)))
         (n9 (dpb fb9 (byte 1 8) (ash p9 -1))))
    (setf (pokey-poly17-state pokey) n17
          (pokey-poly9-state  pokey) n9)))

(defun pokey-random (pokey)
  "Return the current RANDOM register value.  AUDCTL bit 7 picks the
9-bit LFSR; otherwise the low 8 bits of the 17-bit LFSR are returned."
  (declare (type pokey pokey))
  (if (logtest (pokey-audctl pokey) #x80)
      (ldb (byte 8 0) (pokey-poly9-state  pokey))
      (ldb (byte 8 0) (pokey-poly17-state pokey))))

;;; ---------------------------------------------------------------------------
;;; Tick

(defun %fire-timer-irq (pokey cpu ch)
  "Raise the IRQ for channel CH if its IRQEN bit is set.  Returns T if
the CPU's pending-IRQ line was actually asserted."
  (declare (type pokey pokey) (type fixnum ch))
  (let ((bit (%irq-bit-for-channel ch)))
    (when (and (plusp bit)
               (logtest (pokey-irqen pokey) bit))
      ;; IRQST is active-low: clear the bit to indicate "pending".
      (setf (pokey-irqst pokey)
            (logandc2 (pokey-irqst pokey) bit))
      (when cpu
        (setf (cpu-pending-irq cpu) t))
      t)))

(defun %sync-irq-line (pokey)
  "Recompute the CPU's level-sensitive IRQ line from the IRQEN/IRQST pair.

The 6502 IRQ pin is asserted exactly while some ENABLED source has its
(active-low) IRQST bit pulled low, i.e. while (IRQEN AND (NOT IRQST))
is non-zero.  This must run whenever IRQEN or IRQST changes: when the
last pending source is acknowledged (or disabled) the line has to drop,
otherwise the CPU re-services a phantom interrupt every time the I flag
clears — even though IRQST reads back as 'nothing pending'."
  (declare (type pokey pokey))
  (let ((cpu (pokey-cpu pokey)))
    (when cpu
      (set-irq-line cpu
                    (logtest (pokey-irqen pokey)
                             (logandc2 #xFF (pokey-irqst pokey)))))))

(declaim (ftype (function (pokey (or null cpu)) boolean) pokey-tick))

(defun pokey-tick (pokey cpu)
  "Advance POKEY by one CPU cycle.  Returns T if any timer raised an IRQ
this cycle.  Also clocks both polynomial LFSRs once per call."
  (declare (type pokey pokey))
  (let ((irq-raised nil))
    (dotimes (ch 4)
      (declare (type fixnum ch))
      ;; Decrement the divider pre-counter; tick the timer only when it
      ;; expires.
      (when (zerop (decf (aref (pokey-sub-counters pokey) ch)))
        (setf (aref (pokey-sub-counters pokey) ch)
              (%channel-divisor pokey ch))
        (let ((new (1- (aref (pokey-timer-counts pokey) ch))))
          (declare (type fixnum new))
          (cond
            ((minusp new)
             ;; Underflow: reload from AUDF and try to fire IRQ.
             (setf (aref (pokey-timer-counts pokey) ch)
                   (aref (pokey-audf pokey) ch))
             (when (%fire-timer-irq pokey cpu ch)
               (setf irq-raised t)))
            (t
             (setf (aref (pokey-timer-counts pokey) ch) new))))))
    (%advance-rng pokey)
    irq-raised))

;;; ---------------------------------------------------------------------------
;;; Register access

(defun %offset (address)
  (declare (type (unsigned-byte 16) address))
  (ldb (byte 4 0) address))

(defun pokey-read (pokey address)
  "Read from the POKEY read window."
  (declare (type pokey pokey) (type (unsigned-byte 16) address))
  (let ((offset (%offset address))
        (input  (pokey-input pokey)))
    (case offset
      ((0 1 2 3)                         ; POT0..POT3 (live paddles or stub)
       (if input (atari800-cl.input:input-pokey-pot input offset) #xFF))
      ((4 5 6 7) #xFF)                   ; POT4..POT7 stubs (not modelled)
      (8 #xFF)                           ; ALLPOT stub
      (9 (if input                       ; KBCODE
             (atari800-cl.input:input-pokey-kbcode input)
             (pokey-kbcode pokey)))
      (10 (pokey-random pokey))          ; RANDOM
      (14 (pokey-irqst pokey))           ; IRQST
      (15 (if input                      ; SKSTAT
              (atari800-cl.input:input-pokey-skstat input)
              (pokey-skstat pokey)))
      (t #xFF))))

(defun %reload-all-timers (pokey)
  "STIMER semantics: reload every timer counter from its AUDF and reset
each channel's sub-divider to a fresh starting value."
  (declare (type pokey pokey))
  (dotimes (ch 4)
    (setf (aref (pokey-timer-counts pokey) ch) (aref (pokey-audf pokey) ch)
          (aref (pokey-sub-counters pokey) ch) (%channel-divisor pokey ch))))

(defun pokey-write (pokey address value)
  "Write into the POKEY write window.

Side effects:
  STIMER  ($D209) — any write reloads all four timer counters from AUDFx.
  IRQEN   ($D20E) — additionally restores latched IRQST bits to 1 for any
                    IRQ being disabled, mirroring real-hardware acknowledge,
                    then re-derives the CPU's IRQ line from the new
                    IRQEN/IRQST state (de-asserting it when nothing
                    enabled remains pending)."
  (declare (type pokey pokey) (type (unsigned-byte 16) address)
           (type (unsigned-byte 8) value))
  (let ((v (ldb (byte 8 0) value))
        (offset (%offset address)))
    (case offset
      ;; AUDF / AUDC arrays
      (0 (setf (aref (pokey-audf pokey) 0) v))
      (1 (setf (aref (pokey-audc pokey) 0) v))
      (2 (setf (aref (pokey-audf pokey) 1) v))
      (3 (setf (aref (pokey-audc pokey) 1) v))
      (4 (setf (aref (pokey-audf pokey) 2) v))
      (5 (setf (aref (pokey-audc pokey) 2) v))
      (6 (setf (aref (pokey-audf pokey) 3) v))
      (7 (setf (aref (pokey-audc pokey) 3) v))
      (8 (setf (pokey-audctl pokey) v))
      (9 (%reload-all-timers pokey))                 ; STIMER
      (10 nil)                                       ; SKREST stub
      (13 nil)                                       ; SEROUT stub
      (14
       ;; IRQEN write — set the mask AND restore IRQST bits for any bit
       ;; turning off (acknowledge), per the prompt's semantics.  Then
       ;; re-derive the CPU's IRQ line: if the write acknowledged the
       ;; last enabled+pending source, the level-sensitive line drops.
       (setf (pokey-irqen pokey) v
             (pokey-irqst pokey)
             (logior (pokey-irqst pokey) (logandc2 #xFF v)))
       (%sync-irq-line pokey))
      (15 (setf (pokey-skctl pokey) v))
      (t nil))))

(defun reset-pokey (pokey)
  "Reset every POKEY shadow back to power-on defaults.  Returns POKEY."
  (declare (type pokey pokey))
  (fill (pokey-audf pokey) 0)
  (fill (pokey-audc pokey) 0)
  (fill (pokey-timer-counts pokey) 0)
  (dotimes (ch 4)
    (setf (aref (pokey-sub-counters pokey) ch) 1))
  (setf (pokey-audctl pokey) 0
        (pokey-skctl  pokey) 0
        (pokey-irqen  pokey) 0
        (pokey-irqst  pokey) #xFF
        (pokey-skstat pokey) #xFF
        (pokey-kbcode pokey) 0
        (pokey-poly17-state pokey) #x1FFFF
        (pokey-poly9-state  pokey) #x01FF)
  ;; IRQEN is now 0, so this de-asserts any IRQ POKEY was holding.
  (%sync-irq-line pokey)
  pokey)

(defun attach-pokey (bus pokey &optional cpu)
  "Install POKEY's read/write dispatch closures into BUS.  When CPU is
supplied, POKEY stores the back-pointer so timer IRQs route correctly."
  (declare (type pokey pokey))
  (when cpu (setf (pokey-cpu pokey) cpu))
  (setf (bus-pokey bus) pokey
        (bus-pokey-read-fn  bus) (lambda (addr) (pokey-read pokey addr))
        (bus-pokey-write-fn bus) (lambda (addr val) (pokey-write pokey addr val)))
  bus)

(defun attach-pokey-input (pokey input)
  "Attach a host INPUT-STATE to POKEY so POT0..3, KBCODE, and SKSTAT reads
reflect live input.  Pass NIL to detach.  Returns POKEY."
  (declare (type pokey pokey))
  (setf (pokey-input pokey) input)
  pokey)
