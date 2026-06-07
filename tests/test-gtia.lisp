;;;; tests/test-gtia.lisp --- GTIA chip tests.

(in-package #:atari800-cl/tests)

(def-suite gtia-suite
  :description "GTIA register window split, collision recording, HITCLR."
  :in atari800-cl-suite)

(in-suite gtia-suite)

;;; ---------------------------------------------------------------------------
;;; Defaults

(test gtia-cold-reset-defaults
  "After construction, TRIG0..3 = 1, PAL = 1 (NTSC), CONSOL = 7 (no keys)."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (dotimes (i 4)
      (is (= 1 (atari800-cl.gtia:gtia-read g
                                          (+ #xD010 i)))
          "TRIG~D must default to 1 (released)" i))
    (is (= 1 (atari800-cl.gtia:gtia-read g #xD014))
        "PAL register must default to 1 (NTSC for this 800XL)")
    (is (= 7 (atari800-cl.gtia:gtia-read g #xD01F))
        "CONSOL must default to 7 (no console keys pressed)")
    ;; Collision latches start clear.
    (dotimes (i 16)
      (is (zerop (atari800-cl.gtia:gtia-read g (+ #xD000 i)))
          "Collision register $D0~2,'0X must start at 0" i))))

;;; ---------------------------------------------------------------------------
;;; Write-side round-trip (write window stores the value)

(test gtia-write-round-trip-via-write-regs
  "Writing HPOSP0/COLPM0/COLPF0/PRIOR stores into the write-side array."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-write g #xD000 #x42)            ; HPOSP0
    (atari800-cl.gtia:gtia-write g #xD012 #x99)            ; COLPM0
    (atari800-cl.gtia:gtia-write g #xD016 #xAA)            ; COLPF0
    (atari800-cl.gtia:gtia-write g #xD01B #x55)            ; PRIOR
    (let ((wr (atari800-cl.gtia:gtia-write-regs g)))
      (is (= #x42 (aref wr atari800-cl.gtia:+w-hposp0+)))
      (is (= #x99 (aref wr atari800-cl.gtia:+w-colpm0+)))
      (is (= #xAA (aref wr atari800-cl.gtia:+w-colpf0+)))
      (is (= #x55 (aref wr atari800-cl.gtia:+w-prior+))))))

(test gtia-read-does-not-see-write-window
  "A write to $D000 (HPOSP0) does NOT affect the read at $D000 (M0PF)."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-write g #xD000 #xFF)
    ;; M0PF should still be 0 (no collisions recorded).
    (is (zerop (atari800-cl.gtia:gtia-read g #xD000))
        "Read window must remain independent of write window")))

;;; ---------------------------------------------------------------------------
;;; Collision recording

(test gtia-record-m0-vs-pf1-sets-m0pf-bit-1
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-record-collision g :m0 :pf1)
    (is (= #b00000010 (atari800-cl.gtia:gtia-read g #xD000))
        "M0PF must have bit 1 set after M0 hits PF1")))

(test gtia-record-p2-vs-pf3-sets-p2pf-bit-3
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-record-collision g :p2 :pf3)
    (is (= #b00001000 (atari800-cl.gtia:gtia-read g #xD006))
        "P2PF (offset 6) must have bit 3 set after P2 hits PF3")))

(test gtia-record-m1-vs-p3-sets-m1p-bit-3
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-record-collision g :m1 :p3)
    (is (= #b00001000 (atari800-cl.gtia:gtia-read g #xD009))
        "M1P (offset 9) must have bit 3 set after M1 hits P3")))

(test gtia-record-player-player-symmetric
  "P0 vs P2 sets both P0P bit 2 AND P2P bit 0."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-record-collision g :p0 :p2)
    (is (= #b00000100 (atari800-cl.gtia:gtia-read g #xD00C))
        "P0P (offset 12) bit 2 must be set")
    (is (= #b00000001 (atari800-cl.gtia:gtia-read g #xD00E))
        "P2P (offset 14) bit 0 must be set")))

(test gtia-record-argument-order-normalized
  "Passing PF as the first argument is equivalent to passing it second."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-record-collision g :pf2 :m3)
    (is (= #b00000100 (atari800-cl.gtia:gtia-read g #xD003))
        "M3PF (offset 3) bit 2 must be set when PF2 is given first")))

(test gtia-record-self-collision-ignored
  "Recording a player against itself doesn't change anything."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-record-collision g :p1 :p1)
    (is (zerop (atari800-cl.gtia:gtia-read g #xD00D))
        "P1P must remain zero — self-collisions are not modeled")))

(test gtia-multiple-collisions-accumulate
  "Multiple collisions OR into the same register."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:gtia-record-collision g :m0 :pf0)
    (atari800-cl.gtia:gtia-record-collision g :m0 :pf2)
    (is (= #b00000101 (atari800-cl.gtia:gtia-read g #xD000)))))

;;; ---------------------------------------------------------------------------
;;; HITCLR

(test gtia-hitclr-clears-all-collision-registers
  "Any write to HITCLR ($D01E) zeroes M*PF, P*PF, M*P, P*P (16 bytes)."
  (let ((g (atari800-cl.gtia:make-gtia)))
    ;; Plant a handful of collisions.
    (atari800-cl.gtia:gtia-record-collision g :m0 :pf3)
    (atari800-cl.gtia:gtia-record-collision g :p1 :pf2)
    (atari800-cl.gtia:gtia-record-collision g :m2 :p0)
    (atari800-cl.gtia:gtia-record-collision g :p0 :p3)
    ;; Sanity: at least one collision register is non-zero.
    (is (not (zerop (atari800-cl.gtia:gtia-read g #xD000))))
    ;; Trigger HITCLR.
    (atari800-cl.gtia:gtia-write g #xD01E 0)
    (dotimes (i 16)
      (is (zerop (atari800-cl.gtia:gtia-read g (+ #xD000 i)))
          "Collision register at offset ~D must be cleared by HITCLR" i))
    ;; Triggers / PAL / CONSOL must be UNTOUCHED.
    (is (= 1 (atari800-cl.gtia:gtia-read g #xD010)))
    (is (= 1 (atari800-cl.gtia:gtia-read g #xD014)))
    (is (= 7 (atari800-cl.gtia:gtia-read g #xD01F)))))

;;; ---------------------------------------------------------------------------
;;; Bus integration

(test gtia-attach-installs-bus-dispatch
  "ATTACH-GTIA puts read/write closures into the bus and reads go through it."
  (let ((bus (atari800-cl.bus:make-bus))
        (g   (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:attach-gtia bus g)
    (is (eq g (atari800-cl.bus:bus-gtia bus)))
    ;; Bus read $D014 (PAL) → 1
    (is (= 1 (atari800-cl.bus:bus-read bus #xD014)))
    ;; Bus write $D000 lands in the GTIA write window, not RAM.
    (atari800-cl.bus:bus-write bus #xD000 #xCE)
    (is (= #xCE (aref (atari800-cl.gtia:gtia-write-regs g)
                       atari800-cl.gtia:+w-hposp0+)))
    (is (zerop (atari800-cl.bus:bus-peek-ram bus #xD000))
        "$D000 write must not leak to RAM")))

(test gtia-bus-write-to-hitclr-clears-collisions
  "Going through the bus also routes HITCLR correctly."
  (let ((bus (atari800-cl.bus:make-bus))
        (g   (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:attach-gtia bus g)
    (atari800-cl.gtia:gtia-record-collision g :m0 :pf1)
    (is (not (zerop (atari800-cl.bus:bus-read bus #xD000))))
    (atari800-cl.bus:bus-write bus #xD01E 0)
    (is (zerop (atari800-cl.bus:bus-read bus #xD000)))))
