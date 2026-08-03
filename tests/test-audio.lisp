;;;; tests/test-audio.lisp --- POKEY audio synthesis tests.

(in-package #:atari800-cl/tests)

(def-suite audio-suite
  :description "POKEY audio synthesis: poly tables, distortion, mixing, PCM."
  :in atari800-cl-suite)

(in-suite audio-suite)

;;; ---------------------------------------------------------------------------
;;; Fixture

(defun %make-audio-fixture (&key (audctl #x40))
  "Return (VALUES AUDIO POKEY CPU BUS) with a fresh audio unit attached.
AUDCTL defaults to #x40 (channel 1 on the 1.79 MHz clock), so channel
1's timer ticks once per CPU cycle."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl audctl)
    (let ((audio (atari800-cl.audio:make-audio-unit)))
      (atari800-cl.audio:attach-audio pok audio)
      (values audio pok cpu bus))))

(defun %collect-samples (audio pokey cpu cycles)
  "Tick POKEY for CYCLES cycles and return the drained samples."
  (dotimes (i cycles)
    (atari800-cl.pokey:pokey-tick pokey cpu))
  (atari800-cl.audio:audio-drain audio))

;;; ---------------------------------------------------------------------------
;;; Polynomial tables
;;;
;;; The 4- and 5-bit distortion polys are new in ROADMAP.md Phase 9 (the
;;; RANDOM register only ever used the 17- and 9-bit ones).  Their taps
;;; must be maximal-length for the same reason the others' are: the poly
;;; counters advance by MOD of the period.

(test audio-poly4-and-poly5-taps-are-maximal-length
  "The 4- and 5-bit polys return to their start state after exactly
2^N - 1 steps and no sooner."
  (dolist (spec (list (list 4 atari800-cl.pokey:+poly4-tap+ 15)
                      (list 5 atari800-cl.pokey:+poly5-tap+ 31)))
    (destructuring-bind (width tap period) spec
      (let* ((start (1- (ash 1 width)))
             (state start)
             (first-return nil))
        (loop for i from 1 to period
              do (setf state (atari800-cl.pokey:step-lfsr state width tap))
              when (and (null first-return) (= state start))
                do (setf first-return i))
        (is (eql period first-return)
            "poly~D period must be ~D; first return at ~S"
            width period first-return)))))

(test audio-poly-tables-have-full-period-lengths
  "Each distortion table holds exactly one full period of output bits,
and none of them is a constant sequence."
  (dolist (spec (list (cons atari800-cl.audio::*poly4-table*  15)
                      (cons atari800-cl.audio::*poly5-table*  31)
                      (cons atari800-cl.audio::*poly9-table*  511)
                      (cons atari800-cl.audio::*poly17-table* 131071)))
    (destructuring-bind (table . period) spec
      (is (= period (length table)))
      (is (find 0 table) "table of period ~D must contain a 0 bit" period)
      (is (find 1 table) "table of period ~D must contain a 1 bit" period))))

(test audio-step-lfsr-matches-pokey-rng-stepping
  "STEP-LFSR is the same primitive POKEY's RANDOM register uses: driving
a bare 17-bit state through it tracks POKEY-POLY17-STATE exactly."
  (let ((pok (atari800-cl.pokey:make-pokey))
        (state #x1FFFF))
    (dotimes (i 1000)
      (atari800-cl.pokey::%step-poly17 pok)
      (setf state (atari800-cl.pokey:step-lfsr
                   state 17 atari800-cl.pokey:+poly17-tap+)))
    (is (= state (atari800-cl.pokey:pokey-poly17-state pok)))))

;;; ---------------------------------------------------------------------------
;;; Sample rate and buffering

(test audio-frame-yields-746-or-747-samples
  "One MACHINE-RUN-FRAME with audio attached yields 29,868 / 40 = 746 or
747 samples (the fractional remainder alternates)."
  (let* ((m (make-test-machine))
         (audio (atari800-cl.machine:machine-attach-audio m)))
    (declare (ignore audio))
    (atari800-cl.machine:machine-run-frame m)
    (let ((samples (atari800-cl.machine:machine-audio-drain m)))
      (is (<= 746 (length samples) 747)
          "expected 746-747 samples per frame, got ~D" (length samples)))
    ;; And the next frame keeps producing them (the remainder carries).
    (atari800-cl.machine:machine-run-frame m)
    (let ((samples (atari800-cl.machine:machine-audio-drain m)))
      (is (<= 746 (length samples) 747)
          "second frame: expected 746-747 samples, got ~D" (length samples)))))

(test audio-drain-empties-the-buffer
  "Draining returns the pending samples and leaves the buffer empty."
  (let ((m (make-test-machine)))
    (atari800-cl.machine:machine-attach-audio m)
    (atari800-cl.machine:machine-run-frame m)
    (is (plusp (length (atari800-cl.machine:machine-audio-drain m))))
    (is (zerop (length (atari800-cl.machine:machine-audio-drain m)))
        "a second drain with no frame in between must be empty")))

(test audio-detached-machine-drains-empty
  "With no audio unit attached, draining yields an empty vector and
running frames costs no samples."
  (let ((m (make-test-machine)))
    (atari800-cl.machine:machine-run-frame m)
    (is (zerop (length (atari800-cl.machine:machine-audio-drain m))))
    ;; Attach, run, detach, run: the detached frame adds nothing.
    (atari800-cl.machine:machine-attach-audio m)
    (atari800-cl.machine:machine-run-frame m)
    (is (plusp (length (atari800-cl.machine:machine-audio-drain m))))
    (atari800-cl.machine:machine-attach-audio m nil)
    (atari800-cl.machine:machine-run-frame m)
    (is (zerop (length (atari800-cl.machine:machine-audio-drain m)))
        "a detached machine must not accumulate samples")))

;;; ---------------------------------------------------------------------------
;;; Mixing

(test audio-silence-is-constant-centre-level
  "With every volume at 0 the output is a constant 128 — the timers still
run and toggle their flip-flops, but contribute no deflection."
  (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture)
    (atari800-cl.bus:bus-write bus #xD200 5)          ; AUDF1 (timer runs)
    (atari800-cl.bus:bus-write bus #xD201 #xA0)       ; AUDC1: pure tone, vol 0
    (atari800-cl.bus:bus-write bus #xD209 0)          ; STIMER
    (let ((samples (%collect-samples audio pok cpu 4000)))
      (is (plusp (length samples)))
      (is (every (lambda (s) (= s 128)) samples)
          "expected all-128 silence; distinct values were ~S"
          (remove-duplicates (coerce samples 'list))))))

(test audio-volume-only-is-constant-dc
  "AUDC bit 4 (volume-only) emits the volume as DC regardless of the
timer: volume 10 on one channel gives 128 + 2*10 = 148."
  (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture)
    (atari800-cl.bus:bus-write bus #xD201 (logior #x10 10))   ; AUDC1
    (atari800-cl.bus:bus-write bus #xD209 0)
    (let ((samples (%collect-samples audio pok cpu 4000)))
      (is (plusp (length samples)))
      (is (every (lambda (s) (= s 148)) samples)
          "expected constant 148; distinct values were ~S"
          (remove-duplicates (coerce samples 'list))))))

(test audio-volume-only-channels-sum
  "Two volume-only channels add: volumes 10 and 5 give 128 + 2*15 = 158."
  (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture)
    (atari800-cl.bus:bus-write bus #xD201 (logior #x10 10))   ; AUDC1
    (atari800-cl.bus:bus-write bus #xD203 (logior #x10 5))    ; AUDC2
    (atari800-cl.bus:bus-write bus #xD209 0)
    (let ((samples (%collect-samples audio pok cpu 4000)))
      (is (every (lambda (s) (= s 158)) samples)
          "expected constant 158; distinct values were ~S"
          (remove-duplicates (coerce samples 'list))))))

;;; ---------------------------------------------------------------------------
;;; Pure tone
;;;
;;; AUDF1 = 76 at 1.79 MHz gives a timer period of 76 + 4 = 80 cycles
;;; (ROADMAP.md Phase 8's reload offset), i.e. the output flip-flop
;;; toggles every 80 cycles = every 2 samples.  POKEY advances the audio
;;; unit for a cycle BEFORE processing that cycle's expiry, so the
;;; sample emitted on the toggle cycle still shows the old level and the
;;; waveform is exactly two samples per half-period.

(test audio-pure-tone-has-the-expected-flip-period
  "A pure-tone channel at full volume produces a square wave alternating
every 2 samples between 128-2*15 = 98 and 128+2*15 = 158."
  (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture)
    (atari800-cl.bus:bus-write bus #xD200 76)         ; AUDF1: 80-cycle period
    (atari800-cl.bus:bus-write bus #xD201 (logior #xA0 15))  ; pure tone, vol 15
    (atari800-cl.bus:bus-write bus #xD209 0)          ; STIMER
    (let ((samples (%collect-samples audio pok cpu (* 8 40))))
      (is (= 8 (length samples)))
      (is (equal '(98 98 158 158 98 98 158 158)
                 (coerce samples 'list))
          "unexpected pure-tone waveform: ~S" (coerce samples 'list)))))

(test audio-pure-tone-frequency-scales-with-audf
  "Doubling the timer period halves the tone frequency: AUDF1 = 156
(160-cycle period) flips every 4 samples instead of every 2."
  (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture)
    (atari800-cl.bus:bus-write bus #xD200 156)        ; 160-cycle period
    (atari800-cl.bus:bus-write bus #xD201 (logior #xA0 15))
    (atari800-cl.bus:bus-write bus #xD209 0)
    (let ((samples (%collect-samples audio pok cpu (* 8 40))))
      (is (equal '(98 98 98 98 158 158 158 158)
                 (coerce samples 'list))
          "unexpected waveform: ~S" (coerce samples 'list)))))

;;; ---------------------------------------------------------------------------
;;; Distortion

(test audio-distortion-changes-the-waveform
  "The distortion field really selects different generators: pure tone
($A0), poly4 ($C0), and poly17 noise ($80) produce three different
waveforms from identical timer settings."
  (flet ((run (audc)
           (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture)
             (atari800-cl.bus:bus-write bus #xD200 36)      ; 40-cycle period
             (atari800-cl.bus:bus-write bus #xD201 (logior audc 15))
             (atari800-cl.bus:bus-write bus #xD209 0)
             (coerce (%collect-samples audio pok cpu (* 200 40)) 'list))))
    (let ((tone  (run #xA0))
          (poly4 (run #xC0))
          (noise (run #x80)))
      (is (not (equal tone poly4))
          "poly4 distortion must differ from a pure tone")
      (is (not (equal tone noise))
          "poly17 noise must differ from a pure tone")
      (is (not (equal poly4 noise))
          "poly4 and poly17 must differ from each other")
      ;; A pure tone at a 40-cycle period alternates every sample.
      (is (equal '(98 158 98 158) (subseq tone 0 4))
          "pure tone at a 1-sample half-period must alternate: ~S"
          (subseq tone 0 4)))))

(test audio-poly5-gate-swallows-clocks
  "With the poly5 gate active (AUDC bit 7 clear) some clocks are
swallowed, so $20 (poly5-gated toggle) differs from $A0 (ungated
toggle) at the same frequency."
  (flet ((run (audc)
           (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture)
             (atari800-cl.bus:bus-write bus #xD200 36)
             (atari800-cl.bus:bus-write bus #xD201 (logior audc 15))
             (atari800-cl.bus:bus-write bus #xD209 0)
             (coerce (%collect-samples audio pok cpu (* 200 40)) 'list))))
    (is (not (equal (run #xA0) (run #x20)))
        "the poly5 gate must change which clocks reach the flip-flop")))

(test audio-audctl-poly9-selects-the-short-poly
  "AUDCTL bit 7 swaps the 17-bit noise poly for the 9-bit one, giving a
different noise waveform."
  (flet ((run (audctl)
           (multiple-value-bind (audio pok cpu bus)
               (%make-audio-fixture :audctl audctl)
             (atari800-cl.bus:bus-write bus #xD200 36)
             (atari800-cl.bus:bus-write bus #xD201 (logior #x80 15))
             (atari800-cl.bus:bus-write bus #xD209 0)
             (coerce (%collect-samples audio pok cpu (* 600 40)) 'list))))
    (is (not (equal (run #x40) (run #xC0)))
        "poly9 noise must differ from poly17 noise")))

;;; ---------------------------------------------------------------------------
;;; Linked 16-bit pairs (ROADMAP.md Phase 8 interaction)

(test audio-linked-pair-is-voiced-by-the-high-channel
  "A linked 16-bit pair's audio comes from the HIGH channel's AUDC — the
same channel that owns the pair's IRQ — so setting the volume on
channel 2 voices the pair while channel 1 stays silent."
  ;; AUDCTL #x50: channel 1 at 1.79 MHz + link 1+2.  Period is
  ;; 256*AUDF2 + AUDF1 + 7 = 0 + 33 + 7 = 40 cycles: one sample per
  ;; half-period, so the pair alternates every sample.
  (multiple-value-bind (audio pok cpu bus) (%make-audio-fixture :audctl #x50)
    (atari800-cl.bus:bus-write bus #xD200 33)         ; AUDF1 (low byte)
    (atari800-cl.bus:bus-write bus #xD202 0)          ; AUDF2 (high byte)
    (atari800-cl.bus:bus-write bus #xD201 0)          ; AUDC1: silent
    (atari800-cl.bus:bus-write bus #xD203 (logior #xA0 15))  ; AUDC2 voices it
    (atari800-cl.bus:bus-write bus #xD209 0)          ; STIMER
    (let ((samples (%collect-samples audio pok cpu (* 6 40))))
      (is (equal '(98 158 98 158 98 158) (coerce samples 'list))
          "the high channel must voice the pair: ~S" (coerce samples 'list)))))
