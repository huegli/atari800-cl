;;;; src/audio.lisp --- POKEY audio synthesis (four-channel PCM).
;;;;
;;;; Turns POKEY's register state into mono 8-bit PCM.  POKEY itself
;;;; owns the timers (src/pokey.lisp); this file owns everything
;;;; downstream of a counter underflow: the output flip-flops, the
;;;; polynomial distortion generators, and the mixer.
;;;;
;;;; Output format (ROADMAP.md Phase 9):
;;;;   mono, unsigned 8-bit, one sample every +AUDIO-CYCLES-PER-SAMPLE+
;;;;   (40) CPU cycles -> 1,789,772.5 / 40 = 44,744 Hz nominal, i.e.
;;;;   746 or 747 samples per NTSC frame (29,868 / 40 = 746.7).
;;;;
;;;; Synthesis model, per channel:
;;;;   A channel has a one-bit output flip-flop, clocked by its timer's
;;;;   underflow (POKEY calls AUDIO-CHANNEL-UNDERFLOW).  What the clock
;;;;   does to the flip-flop is set by AUDC bits 7-5 (the distortion
;;;;   field), gated through two polynomial counters that free-run at
;;;;   1.79 MHz:
;;;;
;;;;     bit 7 set  -> the 5-bit poly gate is BYPASSED (always passes)
;;;;     bit 7 clear-> the clock is swallowed unless poly5's current bit
;;;;                   is 1
;;;;     then, if the gate passed:
;;;;       bit 5 set   -> TOGGLE the flip-flop  (square wave)
;;;;       bit 6 set   -> load it from poly4's current bit
;;;;       otherwise   -> load it from poly17 (or poly9 when AUDCTL
;;;;                      bit 7 selects the short poly)
;;;;
;;;;   which yields the eight documented distortions:
;;;;     $00 poly5+poly17   $20 poly5        $40 poly5+poly4  $60 poly5
;;;;     $80 poly17         $A0 pure tone    $C0 poly4        $E0 pure tone
;;;;
;;;;   AUDC bit 4 (volume-only) bypasses the flip-flop entirely: the
;;;;   channel emits its volume as a constant, which is how software
;;;;   plays sampled audio by rewriting AUDC.
;;;;
;;;; Mixing: each channel contributes +volume when its output is high
;;;; (or it is in volume-only mode) and -volume when low; the sum is
;;;; doubled and centred on 128.  Four channels x volume 15 x 2 = 120 of
;;;; swing each way, so the 0-255 range is never actually clipped (the
;;;; clamp is belt-and-braces).
;;;;
;;;; Out of scope for this phase, documented rather than approximated:
;;;;   - AUDCTL bits 1-2, the two high-pass filters (channel 1 filtered
;;;;     by channel 3, channel 2 by channel 4).
;;;;   - Two-tone serial mode (SKCTL bit 3).
;;;;   - The exact analogue output curve: real POKEY's mixer is neither
;;;;     linear nor bipolar, and its volume steps are not evenly spaced.
;;;;
;;;; Cost when no audio unit is attached: POKEY does one NIL test per
;;;; advance (see the AUDIO slot on the POKEY struct).  Machines without
;;;; audio must not pay for this file — PERFORMANCE_LOG.md carries
;;;; detached and attached benchmark rows for exactly that reason.

(in-package #:atari800-cl.audio)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  See the
;;; matching declaim in src/bus.lisp for the note on DECLAIM's proclaiming
;;; behaviour under :serial t; repeated here so this file's policy survives
;;; interactive recompilation on its own.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Output format

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +audio-cycles-per-sample+ 40
    "CPU cycles between PCM samples.")
  (defconstant +audio-sample-rate+ 44744
    "Nominal sample rate in Hz: the 1.79 MHz CPU clock divided by
+AUDIO-CYCLES-PER-SAMPLE+ (1,789,772.5 / 40 = 44,744.3).")
  (defconstant +audio-centre-level+ 128
    "The silence level: an unsigned-8 sample with no channel deflection.")
  (defconstant +audio-default-capacity+ 2048
    "Initial sample-buffer capacity — comfortably more than the 747
samples one NTSC frame produces, so per-frame draining never grows it."))

;;; ---------------------------------------------------------------------------
;;; Polynomial distortion tables
;;;
;;; The four polys free-run at the 1.79 MHz CPU clock; a channel samples
;;; the current bit of whichever poly its distortion selects at each
;;; underflow.  Precomputing them as byte tables turns that into one
;;; AREF, and reduces advancing the counters to a MOD.
;;;
;;; The tables are generated from POKEY's own STEP-LFSR and tap
;;; constants, so the audio polys and the RANDOM register's polys cannot
;;; drift apart (ROADMAP.md Phase 9 step 2).

(defun %build-poly-table (width tap)
  "Return a byte table of the output bit of a WIDTH-bit LFSR with tap
TAP over one full period (2^WIDTH - 1 entries), starting from the
all-ones state.  Entry I is the poly's output bit I cycles after reset."
  (declare (type fixnum width tap))
  (let* ((period (1- (ash 1 width)))
         (table  (make-array period :element-type '(unsigned-byte 8)))
         (state  (1- (ash 1 width))))
    (declare (type fixnum period state))
    (dotimes (i period)
      (setf (aref table i) (ldb (byte 1 0) state)
            state (step-lfsr state width tap)))
    table))

(defparameter *poly4-table*
  (%build-poly-table 4 +poly4-tap+)
  "15-entry output-bit table of POKEY's 4-bit distortion poly.")

(defparameter *poly5-table*
  (%build-poly-table 5 +poly5-tap+)
  "31-entry output-bit table of POKEY's 5-bit gate poly.")

(defparameter *poly9-table*
  (%build-poly-table 9 +poly9-tap+)
  "511-entry output-bit table of POKEY's 9-bit poly (AUDCTL bit 7).")

(defparameter *poly17-table*
  (%build-poly-table 17 +poly17-tap+)
  "131071-entry output-bit table of POKEY's 17-bit noise poly.")

;;; ---------------------------------------------------------------------------
;;; AUDC / AUDCTL bit masks

(defconstant +audc-volume-mask+   #x0F)   ; bits 0-3: volume
(defconstant +audc-volume-only+   #x10)   ; bit 4: emit volume as DC
(defconstant +audc-toggle+        #x20)   ; bit 5: toggle (square wave)
(defconstant +audc-poly4+         #x40)   ; bit 6: load from poly4
(defconstant +audc-no-poly5+      #x80)   ; bit 7: bypass the poly5 gate
(defconstant +audctl-poly9+       #x80)   ; AUDCTL bit 7: poly9 for poly17

;;; ---------------------------------------------------------------------------
;;; Audio unit

(defstruct audio-unit
  "One POKEY's audio synthesis state and its pending PCM samples.

Slots:
  POKEY       — back-pointer to the POKEY whose AUDC/AUDCTL registers
                shape the output.  Set by ATTACH-AUDIO; NIL renders
                silence (so a detached unit is still safe to advance).
  BUFFER      — sample accumulator; COUNT is the fill index.  Grows by
                doubling if a caller drains less often than once per
                frame.
  CYCLE-ACC   — CPU cycles elapsed since the last sample was emitted.
  OUT-BITS    — the four channels' output flip-flops (0 or 1).
  POLY4-IDX / POLY5-IDX / POLY9-IDX / POLY17-IDX
              — read positions into the distortion tables, advanced one
                step per CPU cycle."
  (pokey nil)
  (buffer (make-array +audio-default-capacity+ :element-type '(unsigned-byte 8))
          :type (simple-array (unsigned-byte 8) (*)))
  (count 0 :type fixnum)
  (cycle-acc 0 :type fixnum)
  (out-bits (make-array 4 :element-type '(unsigned-byte 8) :initial-element 0)
            :type (simple-array (unsigned-byte 8) (4)))
  (poly4-idx  0 :type fixnum)
  (poly5-idx  0 :type fixnum)
  (poly9-idx  0 :type fixnum)
  (poly17-idx 0 :type fixnum))

;;; ---------------------------------------------------------------------------
;;; Sample generation

(defun %push-sample (audio sample)
  "Append SAMPLE to AUDIO's buffer, growing it if full."
  (declare (type audio-unit audio) (type (unsigned-byte 8) sample))
  (let ((buffer (audio-unit-buffer audio))
        (count  (audio-unit-count audio)))
    (declare (type fixnum count))
    (when (>= count (length buffer))
      (let ((bigger (make-array (* 2 (length buffer))
                                :element-type '(unsigned-byte 8))))
        (replace bigger buffer)
        (setf buffer bigger
              (audio-unit-buffer audio) bigger)))
    (setf (aref buffer count) sample
          (audio-unit-count audio) (1+ count))))

(defun %emit-sample (audio)
  "Mix the four channels' current output into one PCM sample and append
it.  A channel deflects the level by +/- its volume (always + in
volume-only mode); the sum is doubled and centred on 128."
  (declare (type audio-unit audio))
  (let ((pokey (audio-unit-pokey audio)))
    (if (null pokey)
        (%push-sample audio +audio-centre-level+)
        (let ((audc (pokey-audc pokey))
              (bits (audio-unit-out-bits audio))
              (sum  0))
          (declare (type fixnum sum))
          (dotimes (ch 4)
            (declare (type fixnum ch))
            (let* ((c   (aref audc ch))
                   (vol (logand c +audc-volume-mask+)))
              (declare (type fixnum vol))
              (unless (zerop vol)
                (if (or (logtest c +audc-volume-only+)
                        (= 1 (aref bits ch)))
                    (incf sum vol)
                    (decf sum vol)))))
          (let ((level (+ +audio-centre-level+ (* 2 sum))))
            (declare (type fixnum level))
            (%push-sample audio (cond ((< level 0) 0)
                                      ((> level 255) 255)
                                      (t level))))))))

;;; ---------------------------------------------------------------------------
;;; The two entry points POKEY calls (installed by ATTACH-AUDIO)

(defun audio-advance (audio n)
  "Advance AUDIO by N elapsed CPU cycles, emitting a sample every
+AUDIO-CYCLES-PER-SAMPLE+ cycles.  POKEY calls this for a run of cycles
BEFORE processing the expiries at their end, so the samples reflect the
output bits as they stood during those cycles, and the poly counters are
already positioned for the underflow that follows.  Returns AUDIO."
  (declare (type audio-unit audio) (type fixnum n))
  ;; The polys free-run at the CPU clock.
  (setf (audio-unit-poly4-idx audio)
        (mod (+ (audio-unit-poly4-idx audio) n) +poly4-period+)
        (audio-unit-poly5-idx audio)
        (mod (+ (audio-unit-poly5-idx audio) n) +poly5-period+)
        (audio-unit-poly9-idx audio)
        (mod (+ (audio-unit-poly9-idx audio) n) +poly9-period+)
        (audio-unit-poly17-idx audio)
        (mod (+ (audio-unit-poly17-idx audio) n) +poly17-period+))
  (let ((acc (+ (audio-unit-cycle-acc audio) n)))
    (declare (type fixnum acc))
    (loop while (>= acc +audio-cycles-per-sample+)
          do (decf acc +audio-cycles-per-sample+)
             (%emit-sample audio))
    (setf (audio-unit-cycle-acc audio) acc))
  audio)

(defun audio-channel-underflow (audio ch)
  "Clock channel CH's output flip-flop — POKEY calls this when the
channel's counter underflows (for a linked 16-bit pair, CH is the high
channel, which owns the pair's AUDC).  The distortion field decides
whether the clock toggles the flip-flop, loads it from a poly, or is
swallowed by the poly5 gate; see the file header.  Returns AUDIO."
  (declare (type audio-unit audio) (type fixnum ch))
  (let* ((pokey (audio-unit-pokey audio))
         (audc  (aref (pokey-audc pokey) ch))
         (bits  (audio-unit-out-bits audio)))
    (when (or (logtest audc +audc-no-poly5+)
              (= 1 (aref (the (simple-array (unsigned-byte 8) (*)) *poly5-table*)
                         (audio-unit-poly5-idx audio))))
      (cond
        ;; Square wave: the clock flips the output.
        ((logtest audc +audc-toggle+)
         (setf (aref bits ch) (logxor 1 (aref bits ch))))
        ;; Otherwise the output is LOADED from a poly's current bit.
        ((logtest audc +audc-poly4+)
         (setf (aref bits ch)
               (aref (the (simple-array (unsigned-byte 8) (*)) *poly4-table*)
                     (audio-unit-poly4-idx audio))))
        ((logtest (pokey-audctl pokey) +audctl-poly9+)
         (setf (aref bits ch)
               (aref (the (simple-array (unsigned-byte 8) (*)) *poly9-table*)
                     (audio-unit-poly9-idx audio))))
        (t
         (setf (aref bits ch)
               (aref (the (simple-array (unsigned-byte 8) (*)) *poly17-table*)
                     (audio-unit-poly17-idx audio)))))))
  audio)

;;; ---------------------------------------------------------------------------
;;; Public API

(defun audio-drain (audio)
  "Return a fresh (SIMPLE-ARRAY (UNSIGNED-BYTE 8)) of every sample
accumulated since the last drain, and empty the buffer.  Callers
typically drain once per frame (746-747 samples)."
  (declare (type audio-unit audio))
  (let* ((count (audio-unit-count audio))
         (out   (make-array count :element-type '(unsigned-byte 8))))
    (replace out (audio-unit-buffer audio) :end2 count)
    (setf (audio-unit-count audio) 0)
    out))

(defun reset-audio-unit (audio)
  "Clear AUDIO's pending samples, output flip-flops, poly positions, and
cycle accumulator.  Returns AUDIO."
  (declare (type audio-unit audio))
  (fill (audio-unit-out-bits audio) 0)
  (setf (audio-unit-count audio) 0
        (audio-unit-cycle-acc audio) 0
        (audio-unit-poly4-idx audio) 0
        (audio-unit-poly5-idx audio) 0
        (audio-unit-poly9-idx audio) 0
        (audio-unit-poly17-idx audio) 0)
  audio)

(defun attach-audio (pokey audio)
  "Attach AUDIO to POKEY so its timer underflows drive synthesis, or
detach with AUDIO = NIL.  Installs this file's two entry points into
POKEY's function slots — POKEY never names this package, mirroring the
closure wiring the bus uses for the chips.  Returns AUDIO."
  (declare (type pokey pokey))
  (when audio
    (setf (audio-unit-pokey audio) pokey))
  (setf (pokey-audio pokey) audio
        (pokey-audio-advance-fn pokey)   (and audio #'audio-advance)
        (pokey-audio-underflow-fn pokey) (and audio #'audio-channel-underflow))
  audio)
