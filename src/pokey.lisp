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
;;;;   13        SERIN         serial input data (last byte that landed)
;;;;   14        IRQST         active-low IRQ status (1 = not pending)
;;;;   15        SKSTAT        serial/keyboard status
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
;;;;   out.  Each completed byte is also handed to the attached serial-wire
;;;;   hook (POKEY-SERIAL-OUT-FN, installed by src/sio.lisp) — see the
;;;;   transmitter section below.
;;;;
;;;; Serial input (IRQEN bit 5, ROADMAP.md Phase 25a):
;;;;   POKEY-QUEUE-SERIAL-IN hands the receiver a wire schedule —
;;;;   (GAP . BYTE) pairs — and the receiver lands each byte into SERIN
;;;;   after GAP cycles plus one byte-time, raising the serial-input-
;;;;   ready IRQ (bit 5) and setting SKSTAT's overrun bit when a byte
;;;;   lands before the previous one was read.  The XL OS drives SIO
;;;;   entirely through this interrupt (its IRIR handler reads SERIN in
;;;;   IRQ context), so a machine with a serial device attached boots
;;;;   DOS over the wire; without one the OS times out exactly as a
;;;;   drive-less 800 XL does.
;;;;
;;;; Reload offsets (ROADMAP.md Phase 8 / MISC_IMPROVEMENTS_PLAN.md item 5):
;;;;   The period is NOT simply AUDF+1 in every configuration — POKEY's
;;;;   counter reload costs extra cycles that depend on the clock:
;;;;     - 1.79 MHz, unlinked:      AUDF + 4 CPU cycles
;;;;     - 1.79 MHz, 16-bit linked: 256*AUDF_hi + AUDF_lo + 7 CPU cycles
;;;;     - 64 kHz / 15 kHz:         AUDF + 1 of the DIVIDED clock
;;;;   Implemented by loading the countdown with %TIMER-RELOAD-VALUE
;;;;   (the period minus one divided-clock tick, since the counter
;;;;   underflows on the transition past zero).  These figures were
;;;;   originally stated by MISC_IMPROVEMENTS_PLAN.md item 5 from the
;;;;   Altirra Hardware Reference and CONFIRMED (ROADMAP.md Phase 23)
;;;;   against the atari800 emulator's own POKEY_AUDF reload logic
;;;;   (src/pokeysnd.c): `new_val = AUDF + 4` for the 1.79 MHz unlinked
;;;;   case, `AUDF_lo + 256*AUDF_hi + 7` for a linked pair, and
;;;;   `(AUDF + 1) * Base_mult` for the divided clocks -- all three
;;;;   match this file's model exactly.
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
;;; bits 3-4 are the two serial-output interrupts.  +IRQ-OTHER-KEY+ and
;;; +IRQ-BREAK-KEY+ (ROADMAP.md Phase 13) are the same table's entries 1
;;; and 0 -- CONFIRMED by reading TIRQ directly (`.byte $80 ;0 - BREAK key
;;; IRQ` / `.byte $40 ;1 - keyboard IRQ`), not just taken from the plan.
(defconstant +irq-timer1+ #x01)
(defconstant +irq-timer2+ #x02)
(defconstant +irq-timer4+ #x04)
(defconstant +irq-serial-out-done+   #x08)  ; SEROC — transmission complete
(defconstant +irq-serial-out-needed+ #x10)  ; SEROR — output data needed
(defconstant +irq-serial-in-ready+   #x20)  ; SERIN — serial input ready
(defconstant +irq-other-key+  #x40)  ; a (non-BREAK) key was pressed
(defconstant +irq-break-key+  #x80)  ; BREAK was pressed

;;; PENDING bits (ROADMAP.md Phase 22).  A single fixnum consolidating
;;; every "is there per-advance work beyond the plain timer chain"
;;; condition POKEY tracks, so POKEY-TICK / POKEY-ADVANCE pay exactly one
;;; slot read to decide whether anything needs attention, instead of one
;;; independent slot read per feature (which is what the serial
;;; transmitter and audio synthesis each cost on their own, per
;;; PERFORMANCE_LOG.md).  Bits are set/cleared at the transition points
;;; that change the underlying condition -- never polled directly on the
;;; hot path -- so the invariant "bit N set iff condition N holds" must be
;;; maintained at every one of those sites; see the comments where each
;;; bit is touched.
(defconstant +pokey-pending-serial-tx+ #x01)  ; SERIAL-OUT-CYCLES > 0
(defconstant +pokey-pending-audio+     #x02)  ; an AUDIO-UNIT is attached
(defconstant +pokey-pending-key+       #x04)  ; an INPUT-STATE is attached
(defconstant +pokey-pending-serial-rx+ #x08)  ; SERIAL-IN-CYCLES > 0
;;; +POKEY-PENDING-SERIAL-RX+ (ROADMAP.md Phase 25a, reserved by Phase 22)
;;; is a pure event flag like the transmitter's bit: set when a byte is
;;; shifting in, cleared when the queue drains — never an "attachment"
;;; bit, so a machine with a serial device mounted but no traffic in
;;; flight still reads PENDING as zero and pays nothing per advance.
;;; Bytes are queued by POKEY-QUEUE-SERIAL-IN, called from the
;;; serial-wire hook on the emulator thread, so PENDING stays
;;; single-writer (the emulator thread), like every other bit.
;;;
;;; +POKEY-PENDING-KEY+ deliberately mirrors +POKEY-PENDING-AUDIO+'s
;;; shape rather than the plan's literal "a latched key pending" wording:
;;; INPUT-SET-KEY / INPUT-SET-BREAK run on socket reader threads, and the
;;; only OTHER writer of PENDING is the emulator thread, so a bit that
;;; those setters wrote into directly would be a lock-free read-modify-
;;; write race against the emulator thread's own clears of bits 0/1 (a
;;; classic lost-update: whichever write lands last erases the other's
;;; effect). Making the bit mean "INPUT is attached" keeps PENDING
;;; single-writer (ATTACH-POKEY-INPUT, emulator thread only, exactly like
;;; ATTACH-AUDIO's bit) and race-free; the actual per-keystroke event data
;;; lives in INPUT-STATE's own lock (INPUT-CONSUME-KEY-IRQ /
;;; -BREAK-IRQ), drained every advance while the bit is set. Benchmarked
;;; cost is unaffected either way: no bench workload attaches input, so
;;; the bit -- and the lock it gates -- is never touched during a
;;; measured run; see PERFORMANCE_LOG.md's Phase 13 note.

;;; SKCTL serial mode.  Bits 4-6 select the serial mode; every transmit
;;; mode has bit 5 set (the OS's ESS does ORA #$20 for SIO SEND, plus #$08
;;; for the cassette's FSK output).  We only distinguish "transmitting or
;;; not", so bit 5 alone gates the shift register.
(defconstant +skctl-transmit-mode+ #x20)

;;; SKSTAT bits (ROADMAP.md Phase 25a).  Active low like IRQST: a bit
;;; READS AS 1 while its condition is absent and clears when it occurs.
;;; Only the serial-receive-relevant bits are named here; bit 2 (key
;;; down) belongs to src/input.lisp's INPUT-POKEY-SKSTAT.  Assignments
;;; verified against the XL OS's own IRIR handler (Atari_XL_OS_Rev.2.asm:
;;; "LDA SKSTAT / STA SKRES / BMI" tests bit 7 for frame error, then
;;; "AND #$20 / BNE" tests bit 5 for overrun) and the POKEY reference at
;;; oxyron.de — matching atari800's pokey.c, which clears the same bits
;;; and restores them all on SKREST.
(defconstant +skstat-frame-error+     #x80)  ; 0 = serial input framing error
(defconstant +skstat-serial-overrun+ #x20)  ; 0 = SERIN overrun (unread byte
                                            ; overwritten by the next one)
(defconstant +skstat-skrest-mask+     #xE0)  ; bits SKREST restores

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
  PENDING                     — bitmask of per-advance work beyond the
                                plain timer chain (ROADMAP.md Phase 22):
                                +POKEY-PENDING-SERIAL-TX+ while a byte is
                                shifting, +POKEY-PENDING-AUDIO+ while an
                                AUDIO-UNIT is attached.  POKEY-TICK /
                                POKEY-ADVANCE test this ONCE per call
                                instead of reading SERIAL-OUT-CYCLES and
                                AUDIO independently.
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
  SERIAL-OUT-FN               — serial-wire hook (src/sio.lisp): called
                                with each byte as it finishes shifting
                                out, the wire's view of SEROUT.  NIL on
                                a machine with no serial device layer.
  SERIAL-IN-BYTE              — byte currently shifting into the receiver,
                                or 0 when the receiver is idle.
  SERIAL-IN-CYCLES            — CPU cycles until SERIAL-IN-BYTE lands in
                                SERIN; 0 means the receiver is idle.
                                Counted down by POKEY-TICK / POKEY-ADVANCE
                                like the transmitter, and its PENDING
                                bit (+POKEY-PENDING-SERIAL-RX+) is set
                                while it is positive.
  SERIAL-IN-QUEUE             — pending (GAP . BYTE) pairs behind the
                                byte in flight; POKEY-QUEUE-SERIAL-IN
                                appends to it (the serial-wire schedule
                                handed to the receiver).
  SERIN                       — the SERIN register: the last byte that
                                landed, readable at $D20D.
  SERIAL-IN-UNREAD            — T from the moment a byte lands until
                                SERIN is read; a byte landing while T
                                sets SKSTAT's overrun bit.
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
  (pending 0 :type fixnum)
  (audio nil)
  (audio-advance-fn   nil :type (or null function))
  (audio-underflow-fn nil :type (or null function))
  (serial-out-shift   nil :type (or null (unsigned-byte 8)))
  (serial-out-holding nil :type (or null (unsigned-byte 8)))
  (serial-out-cycles  0   :type fixnum)
  (serial-out-fn      nil :type (or null function))
  (serial-in-byte     0   :type (unsigned-byte 8))
  (serial-in-cycles   0   :type fixnum)
  (serial-in-queue    nil)
  (serin              0   :type (unsigned-byte 8))
  (serial-in-unread   nil)
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
    ;; CH arrives 0-3 by construction (channel index) but is not a literal
    ;; constant here; masked explicitly for FAST-AREF per its contract.
    ;; (1+ CH) only happens when %LINKED-LOW-P holds, i.e. CH is 0 or 2, so
    ;; the sum is 1 or 3 -- still masked for the same explicitness.
    (if (%linked-low-p pokey ch)
        (+ (ash (fast-aref (simple-array (unsigned-byte 8) (4)) audf
                            (logand (1+ ch) 3))
                8)
           (fast-aref (simple-array (unsigned-byte 8) (4)) audf (logand ch 3))
           (if fast-p +timer-reload-offset-fast-16bit+ 0))
        (+ (fast-aref (simple-array (unsigned-byte 8) (4)) audf (logand ch 3))
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
;;; channel 4 at two underflows per bit, and — since ROADMAP.md Phase 25 —
;;; the wire itself: each byte that finishes shifting is handed to the
;;; SERIAL-OUT-FN hook (the serial device layer watches the transmitted
;;; stream there), and the receiver below lands whatever the wire sends
;;; back into SERIN.  A machine with no serial device attached leaves
;;; SERIAL-OUT-FN NIL: the transmitter then behaves exactly as it did
;;; before Phase 25 — the OS completes a transfer and times out waiting
;;; for a device that is not there, which is exactly what a real 800 XL
;;; with no disk drive does before it falls through to BASIC.

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
           (pokey-serial-out-cycles pokey)  (%serial-byte-cycles pokey)
           ;; SERIAL-OUT-CYCLES just went positive: set the PENDING bit
           ;; POKEY-TICK / POKEY-ADVANCE test instead of reading it
           ;; directly (see the PENDING bits comment above).
           (pokey-pending pokey) (logior (pokey-pending pokey)
                                         +pokey-pending-serial-tx+))
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
      ;; The byte in the shift register has just finished shifting out.
      ;; Hand it to the serial-wire hook (Phase 25): the device layer
      ;; accumulates these bytes into command frames and answers on the
      ;; receive side.  NIL hook = no device attached, pre-Phase-25
      ;; behavior, and this stays a single slot read per completion.
      (let ((wire (pokey-serial-out-fn pokey)))
        (when wire
          (funcall (the function wire) (pokey-serial-out-shift pokey))))
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
                 (pokey-serial-out-cycles pokey) 0
                 ;; The transmitter just went idle: clear the PENDING bit
                 ;; so the next POKEY-TICK / POKEY-ADVANCE stops charging
                 ;; this check.
                 (pokey-pending pokey) (logandc2 (pokey-pending pokey)
                                                 +pokey-pending-serial-tx+))
           (when (%raise-irq pokey cpu +irq-serial-out-done+)
             (setf irq t))
           (return)))))
    irq))

;;; ---------------------------------------------------------------------------
;;; Serial input receiver (IRQEN bit 5, ROADMAP.md Phase 25a)
;;;
;;; The receive side mirrors the transmitter: a byte takes the same
;;; channel-4-derived byte time to shift in, and the wire's turnaround gap
;;; (device thinking time, ACK delay, inter-frame spacing) is a plain cycle
;;; count the device layer prepends.  POKEY-QUEUE-SERIAL-IN takes a wire
;;; schedule — a list of (GAP . BYTE) pairs, gap first — and %SERIAL-IN-
;;; ADVANCE lands each byte into SERIN after GAP + one byte time, raising
;;; the serial-input-ready IRQ (bit 5, what the OS's IRIR handler serves)
;;; and pulling SKSTAT's overrun bit low when a byte lands before the
;;; previous one was read.
;;;
;;; The XL OS acknowledges the serial-in IRQ in its master IRQ dispatcher
;;; (IIR writes IRQEN twice), so — unlike the timer IRQs — no
;;; restore-on-read is needed here: reading SERIN just clears the unread
;;; flag.  SKREST (a write to $D20A) restores SKSTAT bits 5-7.

(defun %serial-in-start-head (pokey)
  "Start shifting the queue's head byte: pop it, set its gap-plus-byte-time
countdown, and set the PENDING bit so POKEY-TICK / POKEY-ADVANCE keeps
charging the receiver.  Called with a non-empty queue only."
  (declare (type pokey pokey))
  (let* ((head  (pop (pokey-serial-in-queue pokey)))
         (gap   (the fixnum (car head)))
         (byte  (the (unsigned-byte 8) (cdr head))))
    (setf (pokey-serial-in-byte pokey)   byte
          (pokey-serial-in-cycles pokey) (+ gap (%serial-byte-cycles pokey))
          (pokey-pending pokey) (logior (pokey-pending pokey)
                                        +pokey-pending-serial-rx+))))

(defun pokey-queue-serial-in (pokey entries)
  "Append ENTRIES to POKEY's serial input queue and start the receiver if it
is idle.  ENTRIES is a list of (GAP . BYTE) pairs in wire order — GAP is
the turnaround delay in CPU cycles before BYTE begins shifting in, and the
shift itself takes one %SERIAL-BYTE-CYCLES on top.  The device layer builds
these schedules from the inter-frame delays the OS expects.

Queueing while a byte is in flight appends behind it; queueing while the
receiver is idle starts the head immediately.  Bit-identical between
POKEY-TICK and POKEY-ADVANCE when called between advance calls; called
mid-advance (from the SERIAL-OUT-FN hook as the device layer watches a
byte complete) the start can land one chunk later than a tick-by-tick
run — the gaps are thousands of cycles, so the skew is invisible to the
protocol."
  (declare (type pokey pokey) (type list entries))
  (setf (pokey-serial-in-queue pokey)
        (append (pokey-serial-in-queue pokey) entries))
  (when (and entries (zerop (pokey-serial-in-cycles pokey)))
    (%serial-in-start-head pokey))
  (values))

(defun %serial-in-advance (pokey cpu n)
  "Advance the receiver by N CPU cycles.  Returns T if an IRQ was raised.

Called only when the receiver is busy — POKEY-TICK / POKEY-ADVANCE test
SERIAL-IN-CYCLES via the PENDING bit first.  When a byte finishes shifting
in it lands in SERIN: if the previous byte was never read, SKSTAT's
overrun bit goes low (active-low semantics, so 'low' means 'error');
either way the serial-input-ready IRQ (bit 5) fires for the new byte.
The countdown then carries its remainder into the next queued byte's
gap, or the receiver goes idle and clears the PENDING bit."
  (declare (type pokey pokey) (type fixnum n))
  (let ((irq nil))
    (decf (pokey-serial-in-cycles pokey) n)
    (loop
      (when (plusp (pokey-serial-in-cycles pokey))
        (return))
      ;; Land the byte that just finished shifting in.
      (when (pokey-serial-in-unread pokey)
        (setf (pokey-skstat pokey)
              (logandc2 (pokey-skstat pokey) +skstat-serial-overrun+)))
      (setf (pokey-serin pokey)          (pokey-serial-in-byte pokey)
            (pokey-serial-in-unread pokey) t)
      (when (%raise-irq pokey cpu +irq-serial-in-ready+)
        (setf irq t))
      ;; Next byte, or idle.
      (let ((next (pop (pokey-serial-in-queue pokey))))
        (cond
          (next
           (incf (pokey-serial-in-cycles pokey)
                 (+ (the fixnum (car next)) (%serial-byte-cycles pokey)))
           (setf (pokey-serial-in-byte pokey)
                 (the (unsigned-byte 8) (cdr next))))
          (t
           (setf (pokey-serial-in-cycles pokey) 0
                 ;; Receiver drained: clear the PENDING bit so the next
                 ;; POKEY-TICK / POKEY-ADVANCE stops charging this check.
                 (pokey-pending pokey) (logandc2 (pokey-pending pokey)
                                                 +pokey-pending-serial-rx+))
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
  ;; CH arrives as 0-3 from POKEY-TICK/POKEY-ADVANCE's channel loops; not a
  ;; literal constant at this scope, so masked explicitly at each
  ;; channel-array access below per the FAST-AREF contract.
  (setf (fast-aref (simple-array fixnum (4)) (pokey-sub-counters pokey)
                    (logand ch 3))
        (%channel-divisor pokey ch))
  (cond
    ((%linked-high-p pokey ch) nil)
    (t
     (let ((new (1- (fast-aref (simple-array fixnum (4))
                                (pokey-timer-counts pokey) (logand ch 3)))))
       (declare (type fixnum new))
       (cond
         ((minusp new)
          ;; Underflow: reload, clock the audio output flip-flop, and try
          ;; to fire the responsible IRQ.
          (setf (fast-aref (simple-array fixnum (4))
                            (pokey-timer-counts pokey) (logand ch 3))
                (%timer-reload-value pokey ch))
          (let ((owner (%underflow-owner-channel pokey ch)))
            (when audio
              (funcall (the function (pokey-audio-underflow-fn pokey))
                       audio owner))
            (%fire-timer-irq pokey cpu owner)))
         (t
          (setf (fast-aref (simple-array fixnum (4))
                            (pokey-timer-counts pokey) (logand ch 3))
                new)
          nil))))))

;;; ---------------------------------------------------------------------------
;;; Keyboard / BREAK IRQ servicing (ROADMAP.md Phase 13)
;;;
;;; INPUT-SET-KEY / INPUT-SET-BREAK (src/input.lisp) run on socket reader
;;; threads and arm one-shot flags inside INPUT-STATE's own lock; this
;;; drains them from the emulator thread and raises the matching IRQ(s).
;;; Called every advance while POKEY-INPUT is attached (PENDING's key bit
;;; just gates that, per the comment on +POKEY-PENDING-KEY+ above) --
;;; taking INPUT-STATE's lock here is safe because that only happens in
;;; real interactive use, nowhere near the benchmarked hot path (no bench
;;; workload attaches input).

(defun %pokey-service-key-irqs (pokey cpu)
  "Drain INPUT's armed key/BREAK flags and raise the matching POKEY
IRQ(s).  Returns T if either was actually raised (i.e. enabled in
IRQEN)."
  (declare (type pokey pokey))
  (let ((input (pokey-input pokey))
        (irq nil))
    (when input
      (when (atari800-cl.input:input-consume-key-irq input)
        (when (%raise-irq pokey cpu +irq-other-key+) (setf irq t)))
      (when (atari800-cl.input:input-consume-break-irq input)
        (when (%raise-irq pokey cpu +irq-break-key+) (setf irq t))))
    irq))

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
tests/test-pokey.lisp.

PENDING (ROADMAP.md Phase 22) is read ONCE into a local: when it is
zero (the common case — no serial transmission in flight, no audio
attached) the timer chain runs with no further slot reads at all; only
when it is nonzero does this pay the per-feature checks (each one now a
cheap LOGTEST against the already-loaded local rather than an
independent slot read), and only the features whose bit is actually
set."
  (declare (type pokey pokey))
  (incf (pokey-rng-lag pokey))
  (let ((irq-raised nil)
        (pending (pokey-pending pokey)))
    (declare (type fixnum pending))
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
                    ;; only when it expires.  CH is the DOTIMES loop var,
                    ;; 0-3 by trip count; masked explicitly for FAST-AREF
                    ;; per its contract.
                    (when (zerop (decf (fast-aref (simple-array fixnum (4))
                                                   (pokey-sub-counters pokey)
                                                   (logand ch 3))))
                      (when (%expire-channel pokey cpu ch ,audio-form)
                        (setf irq-raised t))))))
      (if (zerop pending)
          (tick-body nil)
          (progn
            (when (logtest pending +pokey-pending-serial-tx+)
              (when (%serial-out-advance pokey cpu 1)
                (setf irq-raised t)))
            (when (logtest pending +pokey-pending-serial-rx+)
              (when (%serial-in-advance pokey cpu 1)
                (setf irq-raised t)))
            (when (logtest pending +pokey-pending-key+)
              (when (%pokey-service-key-irqs pokey cpu)
                (setf irq-raised t)))
            (if (logtest pending +pokey-pending-audio+)
                (let ((audio (pokey-audio pokey)))
                  ;; This cycle elapses BEFORE any expiry it triggers is
                  ;; processed, so the sample(s) it produces reflect the
                  ;; output bits as they stood during the cycle.
                  (funcall (the function (pokey-audio-advance-fn pokey))
                           audio 1)
                  (tick-body audio))
                (tick-body nil)))))
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
cheaper than this function's chunk bookkeeping.

PENDING (ROADMAP.md Phase 22) is read ONCE into a local, as in
POKEY-TICK: this is the hottest POKEY entry point (the scanline
scheduler calls it once per instruction), and when PENDING is zero the
chunk loop runs with no further slot reads at all -- an inner-loop test
measurably cost the nop workload ~7% on both implementations back when
the audio check alone lived in this position."
  (declare (type pokey pokey) (type fixnum n))
  (incf (pokey-rng-lag pokey) n)
  (let ((subs (pokey-sub-counters pokey))
        (pending (pokey-pending pokey))
        (irq-raised nil))
    (declare (type fixnum pending))
    (macrolet ((advance-loop (&body audio-hook)
                 ;; Deliberately unhygienic: AUDIO-HOOK is spliced where
                 ;; CHUNK is in scope, and the body drives IRQ-RAISED and
                 ;; N from the enclosing LET; when non-empty it also
                 ;; refers to AUDIO, which callers below bind before
                 ;; splicing a non-empty hook.
                 `(loop while (plusp n)
                        do (let ((chunk (min n
                                             ;; Literal indices 0-3: in
                                             ;; range by construction, no
                                             ;; mask needed.
                                             (fast-aref (simple-array fixnum (4)) subs 0)
                                             (fast-aref (simple-array fixnum (4)) subs 1)
                                             (fast-aref (simple-array fixnum (4)) subs 2)
                                             (fast-aref (simple-array fixnum (4)) subs 3))))
                             (declare (type fixnum chunk))
                             (decf n chunk)
                             ,@audio-hook
                             (dotimes (ch 4)
                               (declare (type fixnum ch))
                               ;; CH is the DOTIMES loop var, 0-3 by trip
                               ;; count; masked explicitly for FAST-AREF
                               ;; per its contract.
                               (when (zerop (decf (fast-aref (simple-array fixnum (4))
                                                              subs (logand ch 3))
                                                   chunk))
                                 (when (%expire-channel pokey cpu ch
                                                        ,(if audio-hook
                                                             'audio
                                                             nil))
                                   (setf irq-raised t))))))))
      (if (zerop pending)
          (advance-loop)
          (progn
            ;; The serial transmitter is a plain cycle countdown, so the
            ;; whole chunk can be charged against it in one step. Nothing
            ;; observes the ordering against this call's timer expiries
            ;; -- no CPU runs mid-advance to change a register between
            ;; them -- so this stays equivalent to N successive
            ;; POKEY-TICKs.
            (when (logtest pending +pokey-pending-serial-tx+)
              (when (%serial-out-advance pokey cpu n)
                (setf irq-raised t)))
            ;; The receiver is a plain countdown too (gap + byte time per
            ;; queued byte), charged in one step for the same reason.
            (when (logtest pending +pokey-pending-serial-rx+)
              (when (%serial-in-advance pokey cpu n)
                (setf irq-raised t)))
            ;; A key/BREAK IRQ needs no cycle-count reasoning (it isn't
            ;; timed against N the way the transmitter is), so servicing
            ;; it once per chunk-loop entry, same as POKEY-TICK, is exact.
            (when (logtest pending +pokey-pending-key+)
              (when (%pokey-service-key-irqs pokey cpu)
                (setf irq-raised t)))
            (if (logtest pending +pokey-pending-audio+)
                (let ((audio (pokey-audio pokey)))
                  ;; The chunk's cycles elapse before the expiries they
                  ;; trigger, matching POKEY-TICK's ordering exactly (the
                  ;; output bits are constant across a chunk, since only
                  ;; an expiry changes them).
                  (advance-loop
                   (funcall (the function (pokey-audio-advance-fn pokey))
                            audio chunk)))
                (advance-loop)))))
    irq-raised))

(declaim (ftype (function (pokey) boolean) pokey-deferrable-p))

(defun pokey-deferrable-p (pokey)
  "T when POKEY's state cannot change observably between now and the end
of the current scanline, so the machine scheduler may defer per-
instruction POKEY-ADVANCE calls to line end (or to the next $D2xx bus
access, whichever comes first) without altering behavior (ROADMAP.md
Phase 30): no AUDIO-UNIT is attached, PENDING is zero (which already
implies AUDIO is NIL -- ATTACH-AUDIO is what sets its bit -- and also
rules out an in-flight serial transmission or attached host input, both
of which can raise their own IRQs on a schedule this predicate does not
reason about), and no timer IRQ source (bits 0-2 of IRQEN) is enabled --
an enabled timer could otherwise underflow and raise a CPU IRQ mid-line,
which deferral must never delay past the instruction boundary it would
have fired on."
  (declare (type pokey pokey))
  (and (null (pokey-audio pokey))
       (zerop (pokey-pending pokey))
       (zerop (logand (pokey-irqen pokey)
                       (logior +irq-timer1+ +irq-timer2+ +irq-timer4+)))))

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
      (13 (setf (pokey-serial-in-unread pokey) nil)  ; SERIN
          (pokey-serin pokey))
      (14 (pokey-irqst pokey))           ; IRQST
      (15 (if input                      ; SKSTAT
              ;; Both halves are active-low, so combine with LOGAND: the
              ;; input layer's key-down bit contributes its zero, the
              ;; chip's serial error bits (frame, overrun) contribute
              ;; theirs, and neither side's zeros are masked away.
              (logand (atari800-cl.input:input-pokey-skstat input)
                      (pokey-skstat pokey))
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
  SKREST  ($D20A) — restores SKSTAT bits 5-7 (serial frame error and
                    overrun) to their no-error (1) value.
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
      (10 (setf (pokey-skstat pokey)                 ; SKREST
                (logior (pokey-skstat pokey) +skstat-skrest-mask+)))
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
        (pokey-serial-in-byte     pokey) 0
        (pokey-serial-in-cycles   pokey) 0
        (pokey-serial-in-queue    pokey) nil
        (pokey-serin              pokey) 0
        (pokey-serial-in-unread   pokey) nil
        (pokey-poly17-state pokey) #x1FFFF
        (pokey-poly9-state  pokey) #x01FF
        (pokey-rng-lag      pokey) 0
        ;; SERIAL-OUT-CYCLES and SERIAL-IN-CYCLES just went to 0 above, so
        ;; their PENDING bits must go with them; AUDIO and INPUT are
        ;; emulator-level attachments independent of chip reset (see
        ;; ATTACH-AUDIO in src/audio.lisp and ATTACH-POKEY-INPUT above)
        ;; and survive.  SERIAL-OUT-FN / SERIAL-IN hooks are attachments
        ;; of the same kind (the device layer installs them, Phase 25) and
        ;; survive too.
        (pokey-pending      pokey) (logand (pokey-pending pokey)
                                           (logior +pokey-pending-audio+
                                                   +pokey-pending-key+)))
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
reflect live input, and so key/BREAK presses raise POKEY's keyboard IRQs
(ROADMAP.md Phase 13).  Pass NIL to detach.  Returns POKEY."
  (declare (type pokey pokey))
  (setf (pokey-input pokey) input
        ;; Maintain POKEY's PENDING bitmask (ROADMAP.md Phase 22), exactly
        ;; as ATTACH-AUDIO does for its bit -- see the PENDING bits
        ;; comment above for why this bit means "input attached" rather
        ;; than mirroring INPUT-STATE's own per-keystroke flags directly.
        (pokey-pending pokey)
        (if input
            (logior   (pokey-pending pokey) +pokey-pending-key+)
            (logandc2 (pokey-pending pokey) +pokey-pending-key+)))
  pokey)
