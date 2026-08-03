;;;; tests/test-gtia.lisp --- GTIA chip tests.

(in-package #:atari800-cl/tests)

(def-suite gtia-suite
  :description "GTIA register window split, collision recording, HITCLR."
  :in atari800-cl-suite)

(in-suite gtia-suite)

;;; ---------------------------------------------------------------------------
;;; Defaults

(test gtia-cold-reset-defaults
  "After construction, TRIG0..3 = 1, PAL = $0F (NTSC), CONSOL = 7 (no keys)."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (dotimes (i 4)
      (is (= 1 (atari800-cl.gtia:gtia-read g
                                          (+ #xD010 i)))
          "TRIG~D must default to 1 (released)" i))
    (is (= #x0F (atari800-cl.gtia:gtia-read g #xD014))
        "PAL register must default to $0F (NTSC for this 800XL)")
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
    (is (= #x0F (atari800-cl.gtia:gtia-read g #xD014)))
    (is (= 7 (atari800-cl.gtia:gtia-read g #xD01F)))))

;;; ---------------------------------------------------------------------------
;;; Bus integration

(test gtia-attach-installs-bus-dispatch
  "ATTACH-GTIA puts read/write closures into the bus and reads go through it."
  (let ((bus (atari800-cl.bus:make-bus))
        (g   (atari800-cl.gtia:make-gtia)))
    (atari800-cl.gtia:attach-gtia bus g)
    (is (eq g (atari800-cl.bus:bus-gtia bus)))
    ;; Bus read $D014 (PAL) → $0F (NTSC pattern)
    (is (= #x0F (atari800-cl.bus:bus-read bus #xD014)))
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

;;; ---------------------------------------------------------------------------
;;; Host input delegation (Stage 2)

(test gtia-trig-and-consol-reflect-attached-input
  "With an INPUT-STATE attached, TRIG0/TRIG1 (offsets 16/17) and CONSOL
(offset 31) reads come from live input; collision latches are unaffected."
  (let ((g  (atari800-cl.gtia:make-gtia))
        (in (make-input-state)))
    ;; Defaults before attaching: TRIG0 = 1 (released), CONSOL = $07.
    (is (= 1 (atari800-cl.gtia:gtia-read g #xD010)) "TRIG0 idle = 1")
    (is (= #x07 (atari800-cl.gtia:gtia-read g #xD01F)) "CONSOL idle = $07")
    (atari800-cl.gtia:attach-gtia-input g in)
    (input-set-joystick in 0 :trigger t) ; fire on stick 0 -> TRIG0 = 0
    (input-set-console in :select t)     ; SELECT -> CONSOL bit1 clear -> $05
    (is (= 0 (atari800-cl.gtia:gtia-read g #xD010)) "TRIG0 live = 0")
    (is (= 1 (atari800-cl.gtia:gtia-read g #xD011)) "TRIG1 still released")
    (is (= #x05 (atari800-cl.gtia:gtia-read g #xD01F)) "CONSOL live = $05")
    ;; A collision latch (offset 0) is not an input register: still from read-regs.
    (is (= 0 (atari800-cl.gtia:gtia-read g #xD000)) "M0PF latch untouched")))

;;; ---------------------------------------------------------------------------
;;; P/M graphics DMA delivery (ROADMAP.md Phase 6a — machine wiring)
;;;
;;; ANTIC fetches the bytes whenever DMACTL enables P/M DMA; whether
;;; GTIA LATCHES them into GRAFP0-3/GRAFM is gated on GRACTL inside the
;;; closure MAKE-ATARI-MACHINE wires.  The ANTIC-side addressing tests
;;; live in tests/test-antic.lisp.

(defun %pm-dma-machine (&key (gractl 3))
  "Machine with single-line P/M DMA enabled (PMBASE $3800), a
recognizable byte pattern poked at scanline 8's P/M addresses, and
GRACTL set as given.  Runs 9 scanlines so scanline 8 has begun."
  (let* ((m   (make-test-machine))
         (bus (atari800-cl.machine:atari-machine-bus m)))
    (atari800-cl.bus:bus-poke-ram bus (+ #x3800 #x300 8) #xA5)   ; missiles
    (dotimes (p 4)
      (atari800-cl.bus:bus-poke-ram bus (+ #x3800 #x400 (* #x100 p) 8)
                                    (+ #x50 p)))                  ; players
    (atari800-cl.bus:bus-write bus #xD407 #x38)                   ; PMBASE
    (atari800-cl.bus:bus-write bus #xD01D gractl)                 ; GRACTL
    (atari800-cl.bus:bus-write bus #xD400 #x1C)                   ; DMACTL: P+M, single-line
    (atari800-cl.machine:%run-clocks m (* 9 114))
    m))

(test pm-dma-delivers-graf-bytes-when-gractl-enables
  "With DMACTL P/M DMA on and GRACTL = 3, scanline 8's P/M RAM bytes
land in GTIA's GRAFP0-3 and GRAFM write registers."
  (let* ((m  (%pm-dma-machine :gractl 3))
         (wr (atari800-cl.gtia:gtia-write-regs
              (atari800-cl.machine:atari-machine-gtia m))))
    (is (= #xA5 (aref wr atari800-cl.gtia:+w-grafm+))
        "GRAFM must hold the fetched missile byte")
    (dotimes (p 4)
      (is (= (+ #x50 p) (aref wr (+ atari800-cl.gtia:+w-grafp0+ p)))
          "GRAFP~D must hold the fetched player byte" p))))

(test pm-dma-gractl-clear-blocks-delivery-but-cycles-still-stolen
  "GRACTL = 0 blocks GRAF delivery entirely -- but the DMA cycles are
still stolen (that is DMACTL's job, checked via the ANTIC steal
counter)."
  (let* ((m     (%pm-dma-machine :gractl 0))
         (gtia  (atari800-cl.machine:atari-machine-gtia m))
         (antic (atari800-cl.machine:atari-machine-antic m))
         (wr    (atari800-cl.gtia:gtia-write-regs gtia)))
    (is (zerop (aref wr atari800-cl.gtia:+w-grafm+))
        "GRAFM must stay 0 with GRACTL clear")
    (dotimes (p 4)
      (is (zerop (aref wr (+ atari800-cl.gtia:+w-grafp0+ p)))
          "GRAFP~D must stay 0 with GRACTL clear" p))
    ;; 9 lines x (9 refresh + 5 P/M) = at least 126 stolen cycles.
    (is (>= (atari800-cl.antic:antic-stolen-cycles antic) (* 9 14))
        "P/M DMA cycles must be stolen regardless of GRACTL")))

(test pm-dma-gractl-selects-players-and-missiles-independently
  "GRACTL bit 1 alone latches players only; bit 0 alone missiles only."
  (let* ((m  (%pm-dma-machine :gractl 2))     ; players only
         (wr (atari800-cl.gtia:gtia-write-regs
              (atari800-cl.machine:atari-machine-gtia m))))
    (is (zerop (aref wr atari800-cl.gtia:+w-grafm+)))
    (is (= #x50 (aref wr atari800-cl.gtia:+w-grafp0+))))
  (let* ((m  (%pm-dma-machine :gractl 1))     ; missiles only
         (wr (atari800-cl.gtia:gtia-write-regs
              (atari800-cl.machine:atari-machine-gtia m))))
    (is (= #xA5 (aref wr atari800-cl.gtia:+w-grafm+)))
    (is (zerop (aref wr atari800-cl.gtia:+w-grafp0+)))))

;;; ---------------------------------------------------------------------------
;;; PAL register encoding (MISC_IMPROVEMENTS_PLAN.md item 6)

(test pal-register-reads-documented-ntsc-pattern
  "The PAL register ($D014) is a bit pattern, not a flag: bits 1-3 read
all-ones on NTSC (atari800 gtia.c returns $0F; PAL machines return
$01-style all-zeros in bits 1-3).  Software does AND #$0E and branches
on zero for PAL -- the old value of 1 failed that test.  Also covers
the RESET-GTIA path (defaults deduped into %INIT-READ-REGS)."
  (let ((g (atari800-cl.gtia:make-gtia)))
    (is (= atari800-cl.gtia:+pal-register-ntsc+
           (atari800-cl.gtia:gtia-read g #xD014)))
    (is (plusp (logand (atari800-cl.gtia:gtia-read g #xD014) #x0E))
        "AND #$0E must be non-zero on NTSC")
    (atari800-cl.gtia:reset-gtia g)
    (is (= atari800-cl.gtia:+pal-register-ntsc+
           (atari800-cl.gtia:gtia-read g #xD014))
        "reset must restore the same NTSC pattern")))
