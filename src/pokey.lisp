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
;;;;   13        SEROUT        serial output data (drives the transmitter)
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
;;;;   On underflow the counter reloads and, for channels 1, 2, and 4
;;;;   with the matching IRQEN bit (0, 1, or 2) set, the chip raises a
;;;;   CPU IRQ and clears that bit in IRQST.
;;;;
;;;;   Writing IRQEN restores any IRQST latch bits cleared by past
;;;;   underflows ("acknowledge" semantics).
;;;;
;;;; Serial output (IRQEN bits 3-4):
;;;;   SEROUT feeds a double-buffered transmitter clocked by channel 4.
;;;;   SEROR (bit 4) fires when the holding register empties and the next
;;;;   byte is wanted; SEROC (bit 3) fires when the last byte has shifted
;;;;   out.  No bits actually leave the chip and nothing is received —
;;;;   see the transmitter section below for what that does and does not
;;;;   buy.
;;;;
;;;; Reload offsets (ROADMAP.md Phase 8 / MISC_IMPROVEMENTS_PLAN.md item 5):
;;;;   The period is NOT simply AUDF+1 in every configuration — POKEY's
;;;;   counter reload costs extra cycles that depend on the clock:
;;;;     - 1.79 MHz, unlinked:      AUDF + 4 CPU cycles
;;;;     - 1.79 MHz, 16-bit linked: 256*AUDF_hi + AUDF_lo + 7 CPU cycles
;;;;     - 64 kHz / 15 kHz:         AUDF + 1 of the DIVIDED clock
;;;;   Implemented by loading the countdown with %TIMER-RELOAD-VALUE
;;;;   (the period minus one divided-clock tick, since the counter
;;;;   underflows on the transition past zero).  These figures are
;;;;   stated by MISC_IMPROVEMENTS_PLAN.md item 5 from the Altirra
;;;;   Hardware Reference; they are **CONFIRM**-flagged there and were
;;;;   implemented as stated — no independent source was available in
;;;;   this environment to re-derive them.
;;;;
;;;; Linked 16-bit channels (AUDCTL bits 4 and 3):
;;;;   Bit 4 joins channels 1+2, bit 3 joins 3+4.  The pair behaves as
;;;;   ONE 16-bit counter clocked by the LOW channel's clock select:
;;;;   the low byte borrows from the high byte rather than reloading
;;;;   independently, so the period is 256*AUDF_hi + AUDF_lo + offset
;;;;   (NOT the product of two independent periods).  We model that
;;;;   directly — the pair's whole countdown lives in the LOW channel's
;;;;   TIMER-COUNTS slot, and the high channel's own divided clock
;;;;   drives nothing (its TIMER-COUNTS entry is inert while linked).
;;;;   The IRQ for a linked pair comes from the HIGH channel's IRQEN
;;;;   bit: timer 2 ($02) for channels 1+2, timer 4 ($04) for 3+4.
;;;;
;;;; RNG model:
;;;;   Two LFSRs are conceptually clocked once per CPU cycle.  AUDCTL
;;;;   bit 7 selects which one feeds RANDOM: clear = 17-bit, set = 9-bit.
;;;;   As an optimization they are stepped LAZILY: advancing the chip
;;;;   only records how far behind they are (RNG-LAG), and reading
;;;;   RANDOM catches them up first — observably identical, since
;;;;   nothing but the RANDOM register exposes LFSR state.

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

;;; Countdown reload offsets (see the file header).  The counter
;;; underflows one tick after reaching zero, so a reload of R yields a
;;; period of R+1 divided-clock ticks: the +4 / +7 hardware periods at
;;; 1.79 MHz are reload offsets of +3 / +6, and the divided clocks'
;;; AUDF+1 period needs no offset at all.
(defconstant +timer-reload-offset-fast+       3)   ; 1.79 MHz, unlinked
(defconstant +timer-reload-offset-fast-16bit+ 6)   ; 1.79 MHz, linked pair

;;; AUDCTL bits.
(defconstant +audctl-15khz+        #x01)   ; slow base clock
(defconstant +audctl-link-34+      #x08)   ; join channels 3+4 (16-bit)
(defconstant +audctl-link-12+      #x10)   ; join channels 1+2 (16-bit)
(defconstant +audctl-ch3-fast+     #x20)   ; channel 3 at 1.79 MHz
(defconstant +audctl-ch1-fast+     #x40)   ; channel 1 at 1.79 MHz
(defconstant +audctl-poly9+        #x80)   ; RANDOM uses the 9-bit poly

;;; IRQEN / IRQST bit masks.  Bit assignment per the XL OS's own interrupt
;;; dispatch table (TIRQ in Atari_XL_OS_Rev.2.asm): timer 4 is bit 2, and
;;; bits 3-4 are the two serial-output interrupts.
(defconstant +irq-timer1+ #x01)
(defconstant +irq-timer2+ #x02)
(defconstant +irq-timer4+ #x04)
(defconstant +irq-serial-out-done+   #x08)  ; SEROC — transmission complete
(defconstant +irq-serial-out-needed+ #x10)  ; SEROR — output data needed

;;; SKCTL serial mode.  Bits 4-6 select the serial mode; every transmit
;;; mode has bit 5 set (the OS's ESS does ORA #$20 for SIO SEND, plus #$08
;;; for the cassette's FSK output).  We only distinguish "transmitting or
;;; not", so bit 5 alone gates the shift register.
(defconstant +skctl-transmit-mode+ #x20)

;;; Serial output frame: one start bit, eight data bits, one stop bit.
;;; The transmit clock is channel 4's OUTPUT, i.e. one bit per TWO channel-4
;;; underflows (its output flip-flop toggles on each underflow).  Check:
;;; the OS programs AUDCTL $28 (channel 3 at 1.79 MHz, 3+4 linked) and
;;; AUDF3/4 = $0028 for 19200 baud; our linked reload is 40 + 7 = 47 cycles,
;;; and 1.79 MHz / (47 * 2 * 1) = 19,047 bit/s — 19200 baud to 0.8%.
(defconstant +serial-frame-bits+ 10)
(defconstant +serial-half-bits-per-byte+ (* 2 +serial-frame-bits+))

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
  POLY17-STATE, POLY9-STATE   — LFSR state words for the polynomial RNG,
                                as of the last RNG sync (the LFSRs are
                                stepped lazily; see RNG-LAG and %SYNC-RNG).
  RNG-LAG                     — CPU cycles the LFSRs are behind the
                                timers.  POKEY-ADVANCE only accumulates
                                this; %SYNC-RNG catches the LFSRs up when
                                the RANDOM register is actually read.
  AUDIO                       — optional audio unit (an opaque object to
                                this package; see src/audio.lisp, which
                                loads later and installs itself with
                                ATTACH-AUDIO).  NIL means no synthesis,
                                and the whole audio path then costs one
                                NIL test per advance.
  AUDIO-ADVANCE-FN            — (lambda (audio n)) called with the cycles
                                elapsed, before their expiries are
                                processed.
  AUDIO-UNDERFLOW-FN          — (lambda (audio ch)) called when channel
                                CH's counter underflows, CH being the
                                channel that OWNS the underflow (the high
                                channel of a linked pair).
  SERIAL-OUT-SHIFT            — byte currently shifting out of the serial
                                transmitter, or NIL when it is idle.
  SERIAL-OUT-HOLDING          — byte written to SEROUT while the shift
                                register was busy (POKEY is double
                                buffered), or NIL when the holding
                                register is empty.
  SERIAL-OUT-CYCLES           — CPU cycles left in the byte being shifted;
                                0 means the transmitter is idle.  Counted
                                down by POKEY-TICK / POKEY-ADVANCE; the
                                per-byte duration comes from the channel-4
                                timer (see %SERIAL-BYTE-CYCLES).
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
  (rng-lag      0       :type fixnum)
  (audio nil)
  (audio-advance-fn   nil :type (or null function))
  (audio-underflow-fn nil :type (or null function))
  (serial-out-shift   nil :type (or null (unsigned-byte 8)))
  (serial-out-holding nil :type (or null (unsigned-byte 8)))
  (serial-out-cycles  0   :type fixnum)
  (cpu nil)
  ;; Optional host INPUT-STATE (atari800-cl.input).  When non-NIL, POT0..3,
  ;; KBCODE, and SKSTAT reads reflect live input instead of the stubs.
  (input nil))

;;; ---------------------------------------------------------------------------
;;; Channel-clock divisor

(declaim (inline %channel-divisor))

(defun %channel-divisor (pokey ch)
  "How many CPU cycles between two ticks of channel CH's timer.
For a linked 16-bit pair this is consulted for the LOW channel, whose
clock select drives the whole pair."
  (declare (type pokey pokey) (type fixnum ch))
  (let ((ac (pokey-audctl pokey)))
    (cond
      ;; Channel 1 (index 0) on 1.79 MHz when AUDCTL bit 6 set.
      ((and (= ch 0) (logtest ac +audctl-ch1-fast+)) 1)
      ;; Channel 3 (index 2) on 1.79 MHz when AUDCTL bit 5 set.
      ((and (= ch 2) (logtest ac +audctl-ch3-fast+)) 1)
      ;; 15 kHz instead of 64 kHz when AUDCTL bit 0 set.
      ((logtest ac +audctl-15khz+) +pokey-15khz-divisor+)
      ;; Default: 64 kHz.
      (t +pokey-64khz-divisor+))))

;;; ---------------------------------------------------------------------------
;;; Linked 16-bit pairs + countdown reload

(declaim (inline %linked-low-p %linked-high-p))

(defun %linked-low-p (pokey ch)
  "T when CH is the LOW byte of a linked 16-bit pair: channel 1 with
AUDCTL bit 4 set, or channel 3 with bit 3 set.  The pair's entire
countdown lives in this channel's TIMER-COUNTS slot."
  (declare (type pokey pokey) (type fixnum ch))
  (let ((ac (pokey-audctl pokey)))
    (or (and (= ch 0) (logtest ac +audctl-link-12+))
        (and (= ch 2) (logtest ac +audctl-link-34+)))))

(defun %linked-high-p (pokey ch)
  "T when CH is the HIGH byte of a linked 16-bit pair (channel 2 or 4).
Such a channel is clocked by its partner's borrow rather than by its own
divided clock, so its timer does not run independently."
  (declare (type pokey pokey) (type fixnum ch))
  (let ((ac (pokey-audctl pokey)))
    (or (and (= ch 1) (logtest ac +audctl-link-12+))
        (and (= ch 3) (logtest ac +audctl-link-34+)))))

(defun %timer-reload-value (pokey ch)
  "The value loaded into channel CH's countdown on underflow or STIMER.

Unlinked: AUDF, plus +TIMER-RELOAD-OFFSET-FAST+ when the channel runs at
1.79 MHz, giving hardware's AUDF+4 cycle period (the divided clocks keep
their AUDF+1 period and need no offset).  Linked low channel: the full
16-bit value 256*AUDF_high + AUDF_low, plus
+TIMER-RELOAD-OFFSET-FAST-16BIT+ at 1.79 MHz for the N+7 period.  See
the file header for provenance."
  (declare (type pokey pokey) (type fixnum ch))
  (let* ((audf   (pokey-audf pokey))
         (fast-p (= 1 (%channel-divisor pokey ch))))
    (if (%linked-low-p pokey ch)
        (+ (ash (aref audf (1+ ch)) 8)
           (aref audf ch)
           (if fast-p +timer-reload-offset-fast-16bit+ 0))
        (+ (aref audf ch)
           (if fast-p +timer-reload-offset-fast+ 0)))))

(declaim (inline %underflow-owner-channel))

(defun %underflow-owner-channel (pokey ch)
  "The channel that OWNS the effects of CH's underflow — both the IRQEN
bit that gates its interrupt and the AUDC that shapes its audio output.
Normally CH itself; for a linked pair both belong to the HIGH channel
(timer 2 / AUDC2 for channels 1+2, timer 4 / AUDC4 for 3+4), which is
why 16-bit software leaves the low channel's volume at zero."
  (declare (type pokey pokey) (type fixnum ch))
  (if (%linked-low-p pokey ch) (1+ ch) ch))

(declaim (inline %irq-bit-for-channel))

(defun %irq-bit-for-channel (ch)
  "IRQEN/IRQST bit for the channel.  Channel 2 (Timer 3) has no IRQ source."
  (case ch
    (0 +irq-timer1+)
    (1 +irq-timer2+)
    (3 +irq-timer4+)
    (t 0)))

;;; ---------------------------------------------------------------------------
;;; Polynomial RNG (LFSRs — conceptually clocked every CPU cycle, but
;;; stepped LAZILY: POKEY-ADVANCE only counts how far behind the LFSRs are
;;; in RNG-LAG, and %SYNC-RNG catches them up when RANDOM is actually read.
;;; That is observably identical to per-cycle stepping because nothing but
;;; the RANDOM register (and RESET-POKEY) reads the LFSR state.)

;;; LFSR taps and periods.  All four tap configurations are
;;; maximal-length, so an N-bit register cycles through all 2^N - 1
;;; non-zero states — which is what lets %SYNC-RNG reduce a large lag
;;; with MOD instead of stepping the full count.  Pinned by the
;;; pokey-poly*-period tests in tests/test-pokey.lisp and the
;;; audio-poly*-maximal test in tests/test-audio.lisp; if the taps ever
;;; change, those tests fail before the MOD shortcut can silently
;;; diverge.
;;;
;;; The 4- and 5-bit polys are not used by the RANDOM register at all —
;;; they are POKEY's audio distortion generators (src/audio.lisp builds
;;; its bit tables from them).  Their constants live here so every poly
;;; in the chip is defined in one place, alongside the shared STEP-LFSR.
(defconstant +poly4-tap+   1)
(defconstant +poly5-tap+   2)
(defconstant +poly9-tap+   4)
(defconstant +poly17-tap+  5)

(defconstant +poly4-period+  (1- (expt 2 4)))    ; 15
(defconstant +poly5-period+  (1- (expt 2 5)))    ; 31
(defconstant +poly9-period+  (1- (expt 2 9)))    ; 511
(defconstant +poly17-period+ (1- (expt 2 17)))   ; 131071

(declaim (inline step-lfsr %step-poly17 %step-poly9))

(defun step-lfsr (state width tap)
  "Advance a right-shifting LFSR by one bit and return the new state.
STATE is WIDTH bits wide; the feedback bit is (bit 0 XOR bit TAP) and is
shifted into the top bit.  The single shared stepping primitive for
every POKEY polynomial counter — the RANDOM register's 17/9-bit polys
here, and src/audio.lisp's 4/5/9/17-bit distortion tables — so the tap
logic is never spelled twice."
  (declare (type fixnum state width tap))
  (let ((fb (logxor (ldb (byte 1 0) state) (ldb (byte 1 tap) state))))
    (logior (ash fb (1- width)) (ash state -1))))

(defun %step-poly17 (pokey)
  "Advance the 17-bit LFSR by one bit (see STEP-LFSR)."
  (declare (type pokey pokey))
  (setf (pokey-poly17-state pokey)
        (step-lfsr (pokey-poly17-state pokey) 17 +poly17-tap+)))

(defun %step-poly9 (pokey)
  "Advance the 9-bit LFSR by one bit (see STEP-LFSR)."
  (declare (type pokey pokey))
  (setf (pokey-poly9-state pokey)
        (step-lfsr (pokey-poly9-state pokey) 9 +poly9-tap+)))

(defun %sync-rng (pokey)
  "Catch both LFSRs up to real time.  Steps each poly (RNG-LAG mod its
period) times — valid because both polys are maximal-length (see the
period constants above) — then clears RNG-LAG.  Bounded work per call
regardless of how long the RNG went unread.  Returns POKEY."
  (declare (type pokey pokey))
  (let ((lag (pokey-rng-lag pokey)))
    (when (plusp lag)
      (dotimes (i (mod lag +poly17-period+))
        (%step-poly17 pokey))
      (dotimes (i (mod lag +poly9-period+))
        (%step-poly9 pokey))
      (setf (pokey-rng-lag pokey) 0)))
  pokey)

(defun pokey-random (pokey)
  "Return the current RANDOM register value.  AUDCTL bit 7 picks the
9-bit LFSR; otherwise the low 8 bits of the 17-bit LFSR are returned.
Syncs the lazily-stepped LFSRs before reading (see %SYNC-RNG)."
  (declare (type pokey pokey))
  (%sync-rng pokey)
  (if (logtest (pokey-audctl pokey) #x80)
      (ldb (byte 8 0) (pokey-poly9-state  pokey))
      (ldb (byte 8 0) (pokey-poly17-state pokey))))

;;; ---------------------------------------------------------------------------
;;; Tick

;;; Inline: this sits on the underflow path, which runs constantly even
;;; when nothing is enabled in IRQEN.  Left out of line it cost 4-9% of
;;; frame rate on the nop/klaus workloads.
(declaim (inline %raise-irq))

(defun %raise-irq (pokey cpu bit)
  "Raise the IRQ source BIT if it is enabled in IRQEN.  Returns T if the
CPU's pending-IRQ line was actually asserted.  Disabled sources latch
nothing: IRQST only ever shows an ENABLED source as pending, matching
the acknowledge semantics of the IRQEN write path."
  (declare (type pokey pokey) (type fixnum bit))
  (when (and (plusp bit)
             (logtest (pokey-irqen pokey) bit))
    ;; IRQST is active-low: clear the bit to indicate "pending".
    (setf (pokey-irqst pokey)
          (logandc2 (pokey-irqst pokey) bit))
    (when cpu
      (setf (cpu-pending-irq cpu) t))
    t))

(defun %fire-timer-irq (pokey cpu ch)
  "Raise the IRQ for channel CH if its IRQEN bit is set.  Returns T if
the CPU's pending-IRQ line was actually asserted."
  (declare (type pokey pokey) (type fixnum ch))
  (%raise-irq pokey cpu (%irq-bit-for-channel ch)))

;;; ---------------------------------------------------------------------------
;;; Serial output transmitter
;;;
;;; POKEY's transmitter is double buffered: SEROUT feeds a holding
;;; register, and the byte moves into the shift register as soon as that
;;; is free.  Two interrupts report its progress, and SIO is built on
;;; them: SEROR ("output data needed", bit 4) says the holding register
;;; has emptied and the next byte is wanted, SEROC ("transmission
;;; complete", bit 3) says the shift register finished with nothing
;;; queued behind it.  The XL OS sends a command frame by enabling SEROR,
;;; writing the first byte, and letting its ORIR handler feed the rest;
;;; after the last byte it swaps SEROR for SEROC and waits for XMTDON.
;;;
;;; What is modelled: the two interrupts and their timing, clocked by
;;; channel 4 at two underflows per bit.  What is NOT: the actual serial
;;; line — no bits leave the chip, nothing is received, and SKSTAT's
;;; framing/overrun bits are still the $FF stub.  That is enough for the
;;; OS to complete a transfer and then time out waiting for a device
;;; that is not there, which is exactly what a real 800 XL with no disk
;;; drive does before it falls through to BASIC.

(defun %serial-transmitting-p (pokey)
  "True while SKCTL selects a transmit mode."
  (declare (type pokey pokey))
  (logtest (pokey-skctl pokey) +skctl-transmit-mode+))

(defun %serial-byte-cycles (pokey)
  "CPU cycles one transmitted byte occupies, from the channel-4 timer as
it is programmed right now.

The transmit clock is channel 4's output, so a half-bit is one channel-4
underflow: (reload + 1) * divisor cycles, taken from the LOW channel of
a linked 3+4 pair (whose clock select drives the pair) or from channel 4
itself when unlinked.  A byte is +SERIAL-HALF-BITS-PER-BYTE+ of those.

The figure is snapshotted when the byte starts shifting rather than
tracked live: software sets its baud rate before a transfer, not during
one.  Guarded to at least one cycle so a degenerate AUDF/divisor cannot
stall the transmitter forever."
  (declare (type pokey pokey))
  (let* ((clock-ch (if (%linked-high-p pokey 3) 2 3))
         (period (* (1+ (%timer-reload-value pokey clock-ch))
                    (%channel-divisor pokey clock-ch))))
    (declare (type fixnum period))
    (max 1 (* +serial-half-bits-per-byte+ period))))

(defun %serial-out-write (pokey cpu value)
  "SEROUT write: hand VALUE to the transmitter.

If the shift register is idle the byte starts shifting immediately and
SEROR fires, because the holding register is free again the instant the
byte moves on — that is what lets the OS's handler queue the next byte
one transfer ahead.  If a byte is already shifting, VALUE waits in the
holding register and the interrupt comes when that byte completes.

With SKCTL in a non-transmit mode the write only latches: no shifting,
no interrupts."
  (declare (type pokey pokey) (type (unsigned-byte 8) value))
  (cond
    ((or (not (%serial-transmitting-p pokey))
         (plusp (pokey-serial-out-cycles pokey)))
     (setf (pokey-serial-out-holding pokey) value)
     nil)
    (t
     (setf (pokey-serial-out-shift pokey)   value
           (pokey-serial-out-holding pokey) nil
           (pokey-serial-out-cycles pokey)  (%serial-byte-cycles pokey))
     (%raise-irq pokey cpu +irq-serial-out-needed+))))

(defun %serial-out-advance (pokey cpu n)
  "Advance the transmitter by N CPU cycles.  Returns T if an IRQ was raised.

Called only when the transmitter is busy — POKEY-TICK / POKEY-ADVANCE
test SERIAL-OUT-CYCLES first — so an idle chip pays a single slot read
per advance and the whole transmitter stays out of the timer loop.

When the byte in the shift register finishes, either the queued byte
takes its place (and SEROR asks for the next one) or the transmitter
goes idle and SEROC reports the frame complete.  The countdown carries
its remainder into the following byte, so a long advance cannot drift
the bit clock, and the loop handles the (unreachable in practice, since
a byte is ~940 cycles) case of several bytes completing in one call."
  (declare (type pokey pokey) (type fixnum n))
  (let ((irq nil))
    (decf (pokey-serial-out-cycles pokey) n)
    (loop
      (when (plusp (pokey-serial-out-cycles pokey))
        (return))
      (let ((next (pokey-serial-out-holding pokey)))
        (cond
          (next
           (setf (pokey-serial-out-shift pokey)   next
                 (pokey-serial-out-holding pokey) nil)
           (incf (pokey-serial-out-cycles pokey) (%serial-byte-cycles pokey))
           (when (%raise-irq pokey cpu +irq-serial-out-needed+)
             (setf irq t)))
          (t
           (setf (pokey-serial-out-shift pokey)  nil
                 (pokey-serial-out-cycles pokey) 0)
           (when (%raise-irq pokey cpu +irq-serial-out-done+)
             (setf irq t))
           (return)))))
    irq))

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

(declaim (inline %expire-channel))

(defun %expire-channel (pokey cpu ch audio)
  "Process channel CH's sub-counter expiry: reload the sub-counter from
%CHANNEL-DIVISOR, then decrement the timer count — or, on underflow,
reload it via %TIMER-RELOAD-VALUE, clock AUDIO's output flip-flop, and
try to fire the IRQ belonging to this underflow (both belong to the
pair's HIGH channel when CH is a linked low byte).  Returns T if an IRQ
was actually raised.  This is the single shared expiry path for both
POKEY-TICK and POKEY-ADVANCE, so the two cannot drift apart.

AUDIO is passed in rather than read from POKEY so callers that have
already tested the slot can pass a literal NIL: this function is
inlined, so the audio branch then folds away completely and a machine
without audio attached executes exactly the code it did before
synthesis existed.

A linked pair's HIGH channel takes its clock from the low byte's borrow,
which the pair's single 16-bit countdown already accounts for, so its
own divided-clock expiry does nothing but reload the sub-counter."
  (declare (type pokey pokey) (type fixnum ch))
  (setf (aref (pokey-sub-counters pokey) ch)
        (%channel-divisor pokey ch))
  (cond
    ((%linked-high-p pokey ch) nil)
    (t
     (let ((new (1- (aref (pokey-timer-counts pokey) ch))))
       (declare (type fixnum new))
       (cond
         ((minusp new)
          ;; Underflow: reload, clock the audio output flip-flop, and try
          ;; to fire the responsible IRQ.
          (setf (aref (pokey-timer-counts pokey) ch)
                (%timer-reload-value pokey ch))
          (let ((owner (%underflow-owner-channel pokey ch)))
            (when audio
              (funcall (the function (pokey-audio-underflow-fn pokey))
                       audio owner))
            (%fire-timer-irq pokey cpu owner)))
         (t
          (setf (aref (pokey-timer-counts pokey) ch) new)
          nil))))))

(declaim (ftype (function (pokey (or null cpu) fixnum) boolean) pokey-advance)
         (ftype (function (pokey (or null cpu)) boolean) pokey-tick))

(defun pokey-tick (pokey cpu)
  "Advance POKEY by one CPU cycle.  Returns T if any timer raised an IRQ
this cycle.  The LFSRs are stepped lazily (RNG-LAG accrues one cycle; see
%SYNC-RNG).

Deliberately keeps its own simple per-cycle loop instead of delegating to
(POKEY-ADVANCE pokey cpu 1): POKEY-ADVANCE's event-skipping bookkeeping
costs more than it saves at N = 1 (measured, back when this was the
scheduler's entry point: LispWorks lost ~20% frame rate through the
general path).  The machine scheduler now drives POKEY through
POKEY-ADVANCE instead — one call per instruction — leaving this the
per-cycle reference path used by tests and by any caller stepping a
cycle at a time.  Both paths share %EXPIRE-CHANNEL and are pinned
equivalent by pokey-tick-vs-advance-equivalence in
tests/test-pokey.lisp."
  (declare (type pokey pokey))
  (incf (pokey-rng-lag pokey))
  (let ((irq-raised nil)
        (audio (pokey-audio pokey)))
    (when (plusp (pokey-serial-out-cycles pokey))
      (when (%serial-out-advance pokey cpu 1)
        (setf irq-raised t)))
    ;; The audio test happens ONCE, here, and each branch then runs a
    ;; loop with no audio bookkeeping in it: passing a literal NIL to the
    ;; inlined %EXPIRE-CHANNEL folds its audio branch away entirely, so
    ;; the detached path is the code that existed before synthesis did.
    (macrolet ((tick-body (audio-form)
                 ;; Deliberately unhygienic: expands inside the LET above
                 ;; so it can drive IRQ-RAISED.
                 `(dotimes (ch 4)
                    (declare (type fixnum ch))
                    ;; Decrement the divider pre-counter; tick the timer
                    ;; only when it expires.
                    (when (zerop (decf (aref (pokey-sub-counters pokey) ch)))
                      (when (%expire-channel pokey cpu ch ,audio-form)
                        (setf irq-raised t))))))
      (cond
        (audio
         ;; This cycle elapses BEFORE any expiry it triggers is processed,
         ;; so the sample(s) it produces reflect the output bits as they
         ;; stood during the cycle.
         (funcall (the function (pokey-audio-advance-fn pokey)) audio 1)
         (tick-body audio))
        (t
         (tick-body nil))))
    irq-raised))

(defun pokey-advance (pokey cpu n)
  "Advance POKEY by N CPU cycles.  Returns T if any timer raised an IRQ
during those cycles.

Uses event skipping rather than a per-cycle loop: between sub-counter
expiries the only per-cycle state change is the sub-counter decrements
themselves (the LFSRs are stepped lazily — see %SYNC-RNG), so each pass
jumps straight to the earliest expiry — (MIN over channels of the
sub-counter, capped at the cycles remaining) — decrements all four
sub-counters by that amount arithmetically, and processes any that
reached zero via %EXPIRE-CHANNEL, exactly as POKEY-TICK does.  Channels
expiring on the same cycle are processed in order 0..3, matching the
per-cycle loop.  Sub-counters are always >= 1 after a reload, so each
pass consumes at least one cycle and the loop terminates.

Bit-identical to N successive POKEY-TICK calls; the equivalence is
pinned by pokey-tick-vs-advance-equivalence in tests/test-pokey.lisp.
The payoff is for multi-cycle N (the scanline scheduler's per-line
advances); for single cycles prefer POKEY-TICK, whose flat loop is
cheaper than this function's chunk bookkeeping."
  (declare (type pokey pokey) (type fixnum n))
  (incf (pokey-rng-lag pokey) n)
  (let ((subs (pokey-sub-counters pokey))
        (audio (pokey-audio pokey))
        (irq-raised nil))
    ;; The serial transmitter is a plain cycle countdown, so the whole
    ;; chunk can be charged against it in one step.  Nothing observes the
    ;; ordering against this call's timer expiries — no CPU runs
    ;; mid-advance to change a register between them — so this stays
    ;; equivalent to N successive POKEY-TICKs.
    (when (plusp (pokey-serial-out-cycles pokey))
      (when (%serial-out-advance pokey cpu n)
        (setf irq-raised t)))
    ;; As in POKEY-TICK: test for audio ONCE and run a loop with no audio
    ;; bookkeeping inside it, so a detached machine executes the same
    ;; per-chunk code it did before synthesis existed.  This is the
    ;; hottest POKEY entry point (the scanline scheduler calls it once
    ;; per instruction), and an inner-loop test measurably cost the
    ;; nop workload ~7% on both implementations.
    (macrolet ((advance-loop (&body audio-hook)
                 ;; Deliberately unhygienic: AUDIO-HOOK is spliced where
                 ;; CHUNK is in scope, and the body drives IRQ-RAISED and
                 ;; N from the enclosing LET.
                 `(loop while (plusp n)
                        do (let ((chunk (min n
                                             (aref subs 0) (aref subs 1)
                                             (aref subs 2) (aref subs 3))))
                             (declare (type fixnum chunk))
                             (decf n chunk)
                             ,@audio-hook
                             (dotimes (ch 4)
                               (declare (type fixnum ch))
                               (when (zerop (decf (aref subs ch) chunk))
                                 (when (%expire-channel pokey cpu ch
                                                        ,(if audio-hook
                                                             'audio
                                                             nil))
                                   (setf irq-raised t))))))))
      (cond
        (audio
         ;; The chunk's cycles elapse before the expiries they trigger,
         ;; matching POKEY-TICK's ordering exactly (the output bits are
         ;; constant across a chunk, since only an expiry changes them).
         (advance-loop
          (funcall (the function (pokey-audio-advance-fn pokey))
                   audio chunk)))
        (t
         (advance-loop))))
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
  "STIMER semantics: reload every timer counter via %TIMER-RELOAD-VALUE
(so the first period after STIMER carries the same hardware offset as
every later one, and a linked pair starts from its composed 16-bit
value) and reset each channel's sub-divider to a fresh starting value."
  (declare (type pokey pokey))
  (dotimes (ch 4)
    (setf (aref (pokey-timer-counts pokey) ch) (%timer-reload-value pokey ch)
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
      (13 (%serial-out-write pokey (pokey-cpu pokey) v))   ; SEROUT
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
        (pokey-serial-out-shift   pokey) nil
        (pokey-serial-out-holding pokey) nil
        (pokey-serial-out-cycles  pokey) 0
        (pokey-poly17-state pokey) #x1FFFF
        (pokey-poly9-state  pokey) #x01FF
        (pokey-rng-lag      pokey) 0)
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
