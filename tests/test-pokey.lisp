;;;; tests/test-pokey.lisp --- POKEY timer + RNG + IRQ tests.

(in-package #:atari800-cl/tests)

(def-suite pokey-suite
  :description "POKEY timer IRQs, IRQEN/IRQST latch, STIMER reload, RNG."
  :in atari800-cl-suite)

(in-suite pokey-suite)

;;; ---------------------------------------------------------------------------
;;; Test fixture

(defun %make-pokey-fixture (&key (audctl #x40))
  "Build CPU + bus + POKEY wired together.  Default AUDCTL = #x40 selects
1.79 MHz directly for channel 1, so each POKEY-TICK = one timer tick
(divisor 1) and the IRQ countdown is in raw CPU cycles."
  (let* ((bus (atari800-cl.bus:make-bus))
         (cpu (atari800-cl.cpu:make-cpu))
         (pok (atari800-cl.pokey:make-pokey)))
    (atari800-cl.pokey:attach-pokey bus pok cpu)
    (atari800-cl.bus:bus-write bus #xD208 audctl)
    (values pok cpu bus)))

(defun %tick-n-pokey (pokey cpu n)
  "Tick POKEY N times.  Returns T iff any tick raised an IRQ."
  (let ((any nil))
    (dotimes (i n)
      (when (atari800-cl.pokey:pokey-tick pokey cpu)
        (setf any t)))
    any))

;;; ---------------------------------------------------------------------------
;;; Timer 1: fires after (AUDF1 + 4) ticks at the 1.79 MHz base.
;;;
;;; This test asserted AUDF1 + 1 before ROADMAP.md Phase 8.  POKEY's
;;; counter reload costs extra cycles at 1.79 MHz, so hardware's period
;;; is AUDF + 4 CPU cycles (MISC_IMPROVEMENTS_PLAN.md item 5, quoting
;;; the Altirra Hardware Reference; see the reload-offset note in
;;; src/pokey.lisp's header for the CONFIRM status of that figure).

(test pokey-timer1-fires-irq-after-audf1+4-ticks
  "With AUDF1 = N and AUDCTL bit 6 set (1.79 MHz), POKEY-TICK raises an
IRQ after exactly (N + 4) CPU-clock ticks following STIMER."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (atari800-cl.bus:bus-write bus #xD200 3)               ; AUDF1 = 3
    (atari800-cl.bus:bus-write bus #xD20E #x01)            ; IRQEN bit 0
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER reload
    ;; Ticks 1..6: no IRQ yet.
    (dotimes (i 6)
      (is-false (atari800-cl.pokey:pokey-tick pok cpu)
                "Tick ~D must not fire (timer still > 0)" (1+ i)))
    (is-false (cpu-pending-irq cpu))
    ;; Tick 7 = AUDF1 + 4: counter goes 0 → -1 → underflow → IRQ.
    (is-true (atari800-cl.pokey:pokey-tick pok cpu)
             "Tick 7 (AUDF1 + 4) must raise the IRQ")
    (is-true (cpu-pending-irq cpu))
    ;; IRQST bit 0 cleared (active-low = pending).
    (is (zerop (logand (atari800-cl.pokey:pokey-irqst pok) #x01))
        "IRQST bit 0 (timer 1) must be cleared after firing")))

;;; ---------------------------------------------------------------------------
;;; Timer 2: independent of timer 1.

(test pokey-timer2-fires-independently
  "Channel 2 on the default 64 kHz clock keeps hardware's AUDF+1 period
in units of the DIVIDED clock — the +4 reload offset applies only at
1.79 MHz — so AUDF2 = 5 fires after exactly (5+1)*28 = 168 CPU cycles."
  ;; For test simplicity we drive ALL channels at 1.79 MHz by using a
  ;; custom AUDCTL — bit 6 (ch1) + a synthetic config.  The cleanest way
  ;; to fully linearise timing for channels 2 & 4 is to read them through
  ;; the linked-channel mode, but for an isolated test we just force
  ;; divisor=1 by setting AUDCTL bit 5 (would normally be ch 3) AND
  ;; treating ch 2 manually.  In practice, ch 2 at the default 64 kHz
  ;; divisor (28) is fine; we just tick (5+1)*28 = 168 times.
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl 0)
    (atari800-cl.bus:bus-write bus #xD202 5)               ; AUDF2 = 5
    (atari800-cl.bus:bus-write bus #xD20E #x02)            ; IRQEN bit 1
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER
    ;; Tick (5+1)*28 - 1 = 167 cycles — IRQ not yet.
    (%tick-n-pokey pok cpu 167)
    (is-false (cpu-pending-irq cpu)
              "Timer 2 must not fire until exactly (AUDF2+1)*28 CPU cycles")
    ;; The 168th tick fires.
    (is-true (atari800-cl.pokey:pokey-tick pok cpu))
    (is-true (cpu-pending-irq cpu))
    (is (zerop (logand (atari800-cl.pokey:pokey-irqst pok) #x02))
        "IRQST bit 1 must be cleared by Timer 2 underflow")))

;;; ---------------------------------------------------------------------------
;;; IRQEN masking

(test pokey-timer1-without-irqen-bit-does-not-raise-cpu-irq
  "With IRQEN bit 0 clear, the timer still underflows but doesn't raise CPU IRQ."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (atari800-cl.bus:bus-write bus #xD200 3)               ; AUDF1
    (atari800-cl.bus:bus-write bus #xD20E 0)               ; IRQEN = 0
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER
    (%tick-n-pokey pok cpu 4)
    (is-false (cpu-pending-irq cpu)
              "CPU must not see an IRQ when IRQEN bit 0 is clear")
    (is (= #xFF (atari800-cl.pokey:pokey-irqst pok))
        "IRQST must remain $FF when IRQ source is masked")))

;;; ---------------------------------------------------------------------------
;;; IRQST acknowledge via IRQEN write

(test pokey-irqen-write-restores-irqst-bits
  "Writing IRQEN restores IRQST bits for disabled IRQs (acknowledge)."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (atari800-cl.bus:bus-write bus #xD200 0)               ; AUDF1 = 0 — shortest period
    (atari800-cl.bus:bus-write bus #xD20E #x01)
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER
    (%tick-n-pokey pok cpu 4)                              ; AUDF1 + 4 → underflow
    (is (zerop (logand (atari800-cl.pokey:pokey-irqst pok) #x01))
        "Timer 1 underflow should clear IRQST bit 0")
    ;; Acknowledge: write IRQEN = 0 → restore latch.
    (atari800-cl.bus:bus-write bus #xD20E 0)
    (is (= 1 (logand (atari800-cl.pokey:pokey-irqst pok) #x01))
        "IRQST bit 0 must be restored to 1 after IRQEN write that disables it")))

;;; ---------------------------------------------------------------------------
;;; STIMER reload

(test pokey-stimer-reloads-counters-from-audf
  "Writing $D209 reloads every timer counter from its AUDF value.  On
the divided clocks (AUDCTL = 0 here) the reload is AUDF exactly — the
1.79 MHz offset does not apply."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl 0)
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD200 10)
    (atari800-cl.bus:bus-write bus #xD202 20)
    (atari800-cl.bus:bus-write bus #xD204 30)
    (atari800-cl.bus:bus-write bus #xD206 40)
    ;; STIMER
    (atari800-cl.bus:bus-write bus #xD209 0)
    (is (= 10 (aref (atari800-cl.pokey:pokey-timer-counts pok) 0)))
    (is (= 20 (aref (atari800-cl.pokey:pokey-timer-counts pok) 1)))
    (is (= 30 (aref (atari800-cl.pokey:pokey-timer-counts pok) 2)))
    (is (= 40 (aref (atari800-cl.pokey:pokey-timer-counts pok) 3)))))

(test pokey-stimer-reload-carries-the-fast-clock-offset
  "At 1.79 MHz the reload carries the +3 offset (period AUDF+4), so
STIMER leaves channel 1's countdown at AUDF1+3 while channel 2, still on
the 64 kHz clock, reloads with AUDF2 exactly."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD200 10)            ; AUDF1 (1.79 MHz)
    (atari800-cl.bus:bus-write bus #xD202 20)            ; AUDF2 (64 kHz)
    (atari800-cl.bus:bus-write bus #xD209 0)             ; STIMER
    (is (= 13 (aref (atari800-cl.pokey:pokey-timer-counts pok) 0))
        "channel 1 at 1.79 MHz must reload with AUDF1 + 3")
    (is (= 20 (aref (atari800-cl.pokey:pokey-timer-counts pok) 1))
        "channel 2 on the divided clock must reload with AUDF2")))

;;; ---------------------------------------------------------------------------
;;; Linked 16-bit channel pairs (AUDCTL bits 4 and 3)
;;;
;;; A linked pair is ONE 16-bit counter: the low byte borrows from the
;;; high byte instead of reloading independently, so the period is
;;; 256*AUDF_high + AUDF_low + offset — not the product of two periods.
;;; The IRQ comes from the HIGH channel's IRQEN bit.

(test pokey-linked-16bit-pair-period-at-179mhz
  "Channels 1+2 linked (AUDCTL bit 4) with channel 1 at 1.79 MHz (bit 6):
the pair fires after exactly 256*AUDF2 + AUDF1 + 7 CPU cycles."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x50)
    (atari800-cl.bus:bus-write bus #xD200 20)              ; AUDF1 = low byte
    (atari800-cl.bus:bus-write bus #xD202 1)               ; AUDF2 = high byte
    (atari800-cl.bus:bus-write bus #xD20E #x02)            ; IRQEN: timer 2
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER
    (let ((period (+ (* 256 1) 20 7)))                     ; = 283
      (%tick-n-pokey pok cpu (1- period))
      (is-false (cpu-pending-irq cpu)
                "the pair must not fire before 256*AUDF2 + AUDF1 + 7 = ~D cycles"
                period)
      (is-true (atari800-cl.pokey:pokey-tick pok cpu)
               "cycle ~D must raise the linked pair's IRQ" period)
      (is (zerop (logand (atari800-cl.pokey:pokey-irqst pok) #x02))
          "IRQST bit 1 (timer 2) must be cleared by the pair's underflow"))))

(test pokey-linked-pair-composes-16bit-reload
  "STIMER loads the pair's whole 16-bit value (plus the 1.79 MHz offset)
into the LOW channel's countdown; the high channel's own counter is
inert while linked."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x50)
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD200 20)
    (atari800-cl.bus:bus-write bus #xD202 1)
    (atari800-cl.bus:bus-write bus #xD209 0)
    (is (= (+ 256 20 6) (aref (atari800-cl.pokey:pokey-timer-counts pok) 0))
        "channel 1 holds 256*AUDF2 + AUDF1 + 6 (period - 1)")))

(test pokey-linked-pair-irq-comes-from-high-channel
  "A linked pair's IRQ is gated by the HIGH channel's IRQEN bit (timer 2
for 1+2), not the low channel's."
  ;; IRQEN = timer 1 only: the pair underflows but raises nothing.
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x50)
    (atari800-cl.bus:bus-write bus #xD200 5)
    (atari800-cl.bus:bus-write bus #xD202 0)
    (atari800-cl.bus:bus-write bus #xD20E #x01)            ; IRQEN: timer 1
    (atari800-cl.bus:bus-write bus #xD209 0)
    (%tick-n-pokey pok cpu 100)                            ; period = 12
    (is-false (cpu-pending-irq cpu)
              "timer 1's IRQEN bit must not gate a linked pair")
    (is (= #xFF (atari800-cl.pokey:pokey-irqst pok))
        "no IRQST bit may latch when only timer 1 is enabled"))
  ;; IRQEN = timer 2: the same configuration fires.
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x50)
    (atari800-cl.bus:bus-write bus #xD200 5)
    (atari800-cl.bus:bus-write bus #xD202 0)
    (atari800-cl.bus:bus-write bus #xD20E #x02)            ; IRQEN: timer 2
    (atari800-cl.bus:bus-write bus #xD209 0)
    (%tick-n-pokey pok cpu 12)                             ; 0*256 + 5 + 7
    (is-true (cpu-pending-irq cpu)
             "timer 2's IRQEN bit gates the linked pair")))

(test pokey-linked-pair-3-4-uses-timer4-irq
  "Channels 3+4 link via AUDCTL bit 3 with channel 3's clock select
(bit 5), and the pair's IRQ comes from timer 4."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x28)
    (atari800-cl.bus:bus-write bus #xD204 10)              ; AUDF3 = low byte
    (atari800-cl.bus:bus-write bus #xD206 2)               ; AUDF4 = high byte
    (atari800-cl.bus:bus-write bus #xD20E #x08)            ; IRQEN: timer 4
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER
    (let ((period (+ (* 256 2) 10 7)))                     ; = 529
      (%tick-n-pokey pok cpu (1- period))
      (is-false (cpu-pending-irq cpu)
                "pair 3+4 must not fire before ~D cycles" period)
      (is-true (atari800-cl.pokey:pokey-tick pok cpu))
      (is (zerop (logand (atari800-cl.pokey:pokey-irqst pok) #x08))
          "IRQST bit 3 (timer 4) must be cleared by the pair's underflow"))))

(test pokey-linked-pair-at-64khz-has-no-fast-offset
  "A pair linked on the 64 kHz clock keeps the divided-clock period
256*AUDF_high + AUDF_low + 1, in units of that clock."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x10)
    (atari800-cl.bus:bus-write bus #xD200 2)               ; AUDF1
    (atari800-cl.bus:bus-write bus #xD202 0)               ; AUDF2
    (atari800-cl.bus:bus-write bus #xD20E #x02)            ; IRQEN: timer 2
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER
    (let ((period (* (+ 2 1) 28)))                         ; (AUDF+1) * 28 = 84
      (%tick-n-pokey pok cpu (1- period))
      (is-false (cpu-pending-irq cpu)
                "no fast offset applies on the divided clock (expected ~D cycles)"
                period)
      (is-true (atari800-cl.pokey:pokey-tick pok cpu)))))

(test pokey-channels-independent-when-link-bits-clear
  "With AUDCTL bits 3/4 clear the channels stay independent: channel 2
runs its own AUDF2 period and answers to its own timer-2 IRQ."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (atari800-cl.bus:bus-write bus #xD200 200)             ; AUDF1 (1.79 MHz)
    (atari800-cl.bus:bus-write bus #xD202 1)               ; AUDF2 (64 kHz)
    (atari800-cl.bus:bus-write bus #xD20E #x02)            ; IRQEN: timer 2
    (atari800-cl.bus:bus-write bus #xD209 0)               ; STIMER
    ;; Unlinked, channel 2 fires at (1+1)*28 = 56 — far sooner than the
    ;; 256*1 + 200 + 7 = 463 a linked pair would take.
    (%tick-n-pokey pok cpu 56)
    (is-true (cpu-pending-irq cpu)
             "channel 2 must run its own period when the link bit is clear")))

;;; ---------------------------------------------------------------------------
;;; Polynomial RNG

(test pokey-random-changes-and-is-nonzero
  "The RANDOM register returns non-zero and varies across ticks."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl 0)
    (declare (ignore bus))
    (let ((samples '()))
      (dotimes (i 16)
        (atari800-cl.pokey:pokey-tick pok cpu)
        (push (atari800-cl.pokey:pokey-random pok) samples))
      (is-true (some (lambda (v) (not (zerop v))) samples)
               "At least one RANDOM sample must be non-zero")
      (is (> (length (remove-duplicates samples)) 1)
          "RANDOM must take at least two distinct values across 16 ticks"))))

(test pokey-random-poly-selector
  "AUDCTL bit 7 swaps RANDOM between 17-bit and 9-bit LFSR outputs."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl 0)
    (declare (ignore cpu bus))
    (let ((r17 (atari800-cl.pokey:pokey-random pok)))
      (setf (atari800-cl.pokey:pokey-audctl pok) #x80)
      (let ((r9 (atari800-cl.pokey:pokey-random pok)))
        ;; The two LFSRs share no state, so initial outputs are very
        ;; likely to differ; we don't insist on it, but at least one of
        ;; them must be non-zero.
        (is-true (or (not (zerop r17)) (not (zerop r9))))))))

;;; ---------------------------------------------------------------------------
;;; Lazy RNG + batched advance (PERFORMANCE_PLAN.md Phase 3)
;;;
;;; POKEY-ADVANCE batches N cycles with event skipping, and the LFSRs are
;;; stepped lazily (only when RANDOM is read), reducing large lags with
;;; MOD by each poly's period.  These tests pin the two assumptions that
;;; make that bit-identical to the old per-cycle loop: the polys really
;;; are maximal-length (so the MOD is sound), and chunked advancement
;;; matches single-cycle ticking through register writes and IRQs.

(test pokey-poly-lfsr-periods-are-maximal
  "Both LFSRs return to their reset state after exactly 2^N - 1 steps and
no sooner.  %SYNC-RNG's MOD-by-period shortcut silently diverges if the
tap configuration ever stops being maximal-length — this test fails first."
  (let ((pok (atari800-cl.pokey:make-pokey)))
    (let ((start (atari800-cl.pokey:pokey-poly17-state pok))
          (first-return nil))
      (loop for i from 1 to 131071
            do (atari800-cl.pokey::%step-poly17 pok)
            when (and (null first-return)
                      (= start (atari800-cl.pokey:pokey-poly17-state pok)))
              do (setf first-return i))
      (is (eql 131071 first-return)
          "poly17 period must be 2^17-1 = 131071; first return at ~S"
          first-return))
    (let ((start (atari800-cl.pokey:pokey-poly9-state pok))
          (first-return nil))
      (loop for i from 1 to 511
            do (atari800-cl.pokey::%step-poly9 pok)
            when (and (null first-return)
                      (= start (atari800-cl.pokey:pokey-poly9-state pok)))
              do (setf first-return i))
      (is (eql 511 first-return)
          "poly9 period must be 2^9-1 = 511; first return at ~S"
          first-return))))

(test pokey-lazy-rng-sync-matches-direct-stepping
  "A lazy sync after a large batched advance (larger than the poly17
period, so the MOD shortcut actually engages) yields exactly the LFSR
states that per-cycle stepping produces."
  (let ((eager (atari800-cl.pokey:make-pokey))
        (lazy  (atari800-cl.pokey:make-pokey))
        (n 150000))                     ; > 131071: exercises the MOD path
    (dotimes (i n)
      (atari800-cl.pokey::%step-poly17 eager)
      (atari800-cl.pokey::%step-poly9  eager))
    (atari800-cl.pokey:pokey-advance lazy nil n)
    (atari800-cl.pokey:pokey-random lazy)    ; forces the sync
    (is (= (atari800-cl.pokey:pokey-poly17-state eager)
           (atari800-cl.pokey:pokey-poly17-state lazy))
        "poly17 state after lazy sync must match direct stepping")
    (is (= (atari800-cl.pokey:pokey-poly9-state eager)
           (atari800-cl.pokey:pokey-poly9-state lazy))
        "poly9 state after lazy sync must match direct stepping")))

(defparameter *pokey-equivalence-script*
  '((0     #xD200 6)                    ; AUDF1 = 6
    (0     #xD20E #x01)                 ; IRQEN: timer 1
    (0     #xD209 0)                    ; STIMER
    (100   #xD202 3)                    ; AUDF2 = 3
    (100   #xD20E #x03)                 ; IRQEN: timers 1 + 2
    (1000  #xD208 #x00)                 ; AUDCTL: everything to 64 kHz
    (2500  #xD209 0)                    ; STIMER reload mid-run
    (5000  #xD20E #x00)                 ; IRQEN: ack/disable everything
    (5001  #xD20E #x0B)                 ; IRQEN: timers 1 + 2 + 4
    (12345 #xD208 #x01)                 ; AUDCTL: 15 kHz base clock
    (12345 #xD206 10)                   ; AUDF4 = 10
    (30000 #xD200 0)                    ; AUDF1 = 0 (fires every expiry)
    (30000 #xD208 #x60)                 ; AUDCTL: ch1 + ch3 at 1.79 MHz
    (30000 #xD209 0)                    ; STIMER
    ;; Linked 16-bit pairs (ROADMAP.md Phase 8): the event-skipping in
    ;; POKEY-ADVANCE has to honour the composed 16-bit reload, the
    ;; inert high channel, and the high channel's IRQ bit.
    (35000 #xD208 #x50)                 ; AUDCTL: ch1 fast + link 1+2
    (35000 #xD200 20)                   ; AUDF1 = low byte
    (35000 #xD202 1)                    ; AUDF2 = high byte
    (35000 #xD20E #x02)                 ; IRQEN: timer 2 (the pair's IRQ)
    (35000 #xD209 0)                    ; STIMER
    (41000 #xD208 #x10)                 ; link 1+2 on the 64 kHz clock
    (41000 #xD209 0)                    ; STIMER
    (45000 #xD208 #x28)                 ; AUDCTL: ch3 fast + link 3+4
    (45000 #xD204 3)                    ; AUDF3 = low byte
    (45000 #xD206 5)                    ; AUDF4 = high byte
    (45000 #xD20E #x0A)                 ; IRQEN: timers 2 + 4
    (45000 #xD209 0)                    ; STIMER
    (48000 #xD208 #x00))                ; unlink everything again
  "Register-write schedule for POKEY-TICK-VS-ADVANCE-EQUIVALENCE:
each entry is (CYCLE ADDRESS VALUE), applied to both POKEYs after
exactly CYCLE cycles have elapsed.  Sorted by cycle.")

(defparameter *pokey-equivalence-chunks*
  #(1 3 7 114 2 28 500 13 1 999 114 5 250 4 57)
  "Fixed chunk-size sequence (cycled) for the batched POKEY in the
equivalence test.  A literal vector, not RANDOM, so runs are deterministic.")

(test pokey-tick-vs-advance-equivalence
  "Drives two POKEYs through 50,000 cycles and a scripted sequence of
register writes: one via single-cycle POKEY-TICK, one via POKEY-ADVANCE
in fixed odd-sized chunks.  After every chunk, the complete observable
state — IRQST, all timer counts, all sub-counters, RANDOM, the chunk's
IRQ-raised result, and the CPU's pending-IRQ line — must agree.  This is
the test that licenses the event-skipping implementation."
  (multiple-value-bind (pok-a cpu-a bus-a) (%make-pokey-fixture :audctl #x40)
    (multiple-value-bind (pok-b cpu-b bus-b) (%make-pokey-fixture :audctl #x40)
      (let ((script (copy-list *pokey-equivalence-script*))
            (chunks *pokey-equivalence-chunks*)
            (seed-i 0)
            (pos 0)
            (total 50000)
            (divergence nil))
        (flet ((compare (cycle irq-a irq-b)
                 (unless divergence
                   (setf divergence
                         (cond
                           ((/= (atari800-cl.pokey:pokey-irqst pok-a)
                                (atari800-cl.pokey:pokey-irqst pok-b))
                            (list cycle :irqst))
                           ((loop for ch below 4
                                  thereis (/= (aref (atari800-cl.pokey:pokey-timer-counts pok-a) ch)
                                              (aref (atari800-cl.pokey:pokey-timer-counts pok-b) ch)))
                            (list cycle :timer-counts))
                           ((loop for ch below 4
                                  thereis (/= (aref (atari800-cl.pokey:pokey-sub-counters pok-a) ch)
                                              (aref (atari800-cl.pokey:pokey-sub-counters pok-b) ch)))
                            (list cycle :sub-counters))
                           ((/= (atari800-cl.pokey:pokey-random pok-a)
                                (atari800-cl.pokey:pokey-random pok-b))
                            (list cycle :random))
                           ((not (eq (and irq-a t) (and irq-b t)))
                            (list cycle :irq-raised-result))
                           ((not (eq (cpu-pending-irq cpu-a)
                                     (cpu-pending-irq cpu-b)))
                            (list cycle :cpu-pending-irq)))))))
          (loop while (< pos total)
                do ;; Apply every register write scheduled at POS, to both.
                   (loop while (and script (= (first (car script)) pos))
                         do (destructuring-bind (cyc addr val) (pop script)
                              (declare (ignore cyc))
                              (atari800-cl.bus:bus-write bus-a addr val)
                              (atari800-cl.bus:bus-write bus-b addr val)))
                   ;; Advance both to the next script event (or the end),
                   ;; chunk by chunk, comparing after every chunk.
                   (let ((limit (if script
                                    (min total (first (car script)))
                                    total)))
                     (loop while (< pos limit)
                           do (let ((c (min (- limit pos)
                                            (aref chunks (mod seed-i (length chunks)))))
                                    (irq-a nil))
                                (incf seed-i)
                                (dotimes (i c)
                                  (when (atari800-cl.pokey:pokey-tick pok-a cpu-a)
                                    (setf irq-a t)))
                                (let ((irq-b (atari800-cl.pokey:pokey-advance pok-b cpu-b c)))
                                  (incf pos c)
                                  (compare pos irq-a irq-b)))))))
        (is (null divergence)
            "POKEY state diverged between tick and batched advance at ~
             cycle ~S in field ~S" (first divergence) (second divergence))))))

;;; ---------------------------------------------------------------------------
;;; Read of IRQST through the bus

(test pokey-read-irqst-via-bus
  "Reading $D20E returns the IRQST byte."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (declare (ignore cpu))
    (setf (atari800-cl.pokey:pokey-irqst pok) #xAB)
    (is (= #xAB (atari800-cl.bus:bus-read bus #xD20E)))))

;;; ---------------------------------------------------------------------------
;;; Host input delegation (Stage 2)

(test pokey-pot-kbcode-skstat-reflect-attached-input
  "With an INPUT-STATE attached, POT0-3 (offsets 0-3), KBCODE (9), and
SKSTAT (15) reads come from live input; RANDOM/IRQST are unaffected."
  (let ((pok (atari800-cl.pokey:make-pokey))
        (in  (make-input-state)))
    ;; Without input attached, POT reads are the $FF stub.
    (is (= #xFF (atari800-cl.pokey:pokey-read pok #xD200)) "POT0 stub = $FF")
    (atari800-cl.pokey:attach-pokey-input pok in)
    (input-set-paddle in 0 123)
    (input-set-key in #x2A)               ; pressed
    (is (= 123 (atari800-cl.pokey:pokey-read pok #xD200)) "POT0 live = 123")
    (is (= #xFF (atari800-cl.pokey:pokey-read pok #xD204)) "POT4 still stub")
    (is (= #x2A (atari800-cl.pokey:pokey-read pok #xD209)) "KBCODE live")
    (is (= #xFB (atari800-cl.pokey:pokey-read pok #xD20F)) "SKSTAT bit2 clear")
    ;; IRQST (offset 14) is not an input register; still the POKEY latch.
    (is (= #xFF (atari800-cl.pokey:pokey-read pok #xD20E)) "IRQST untouched")))
