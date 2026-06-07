;;;; tests/test-machine.lisp --- top-level machine + scheduler tests.

(in-package #:atari800-cl/tests)

(def-suite machine-suite
  :description "Atari 800 XL machine wiring, frame scheduler, cold reset."
  :in atari800-cl-suite)

(in-suite machine-suite)

;;; ---------------------------------------------------------------------------
;;; Synthetic ROM fixtures.
;;;
;;; The repo never ships real ROMs, so tests fabricate small images:
;;; a 16 KiB "OS ROM" whose reset vector points to a NOP sled, and an
;;; 8 KiB "BASIC ROM" full of $EA (NOP) so the CPU can walk through it.

(defun %poke (rom i v)
  "Write V to ROM[I].  Wrapped in a separate function (NOTINLINE) so the
SBCL/arm64 backend cannot fold I into a constant STR immediate (which
overflows the 12-bit offset field for offsets >= 4096)."
  (declare (notinline %poke))
  (setf (aref rom i) v))

(declaim (notinline %poke))

(defun %make-synthetic-os-rom (&key (reset-pc #xC000))
  (let ((rom (make-array #x4000 :element-type '(unsigned-byte 8)
                                :initial-element #xEA)))   ; NOPs everywhere
    ;; Reset vector at $FFFC/$FFFD — OS-ROM offset $3FFC/$3FFD.
    (%poke rom #x3FFC (logand reset-pc #xFF))
    (%poke rom #x3FFD (logand (ash reset-pc -8) #xFF))
    ;; NMI vector at $FFFA/$FFFB → $FE00 (a NOP).
    (%poke rom #x3FFA #x00)
    (%poke rom #x3FFB #xFE)
    ;; IRQ vector at $FFFE/$FFFF → $FE00.
    (%poke rom #x3FFE #x00)
    (%poke rom #x3FFF #xFE)
    rom))

(defun %make-synthetic-basic-rom ()
  (make-array #x2000 :element-type '(unsigned-byte 8) :initial-element #xEA))

;;; ---------------------------------------------------------------------------
;;; Wiring and construction

(test machine-make-wires-all-chips
  "MAKE-ATARI-MACHINE builds every chip and installs its dispatch into the bus."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (is-true (atari800-cl.machine:atari-machine-cpu   m))
    (is-true (atari800-cl.machine:atari-machine-bus   m))
    (is-true (atari800-cl.machine:atari-machine-mmu   m))
    (is-true (atari800-cl.machine:atari-machine-pia   m))
    (is-true (atari800-cl.machine:atari-machine-antic m))
    (is-true (atari800-cl.machine:atari-machine-gtia  m))
    (is-true (atari800-cl.machine:atari-machine-pokey m))
    ;; Bus closures for each chip must be installed (non-NIL).
    (let ((bus (atari800-cl.machine:atari-machine-bus m)))
      (is (functionp (atari800-cl.bus:bus-pia-read-fn   bus)))
      (is (functionp (atari800-cl.bus:bus-gtia-read-fn  bus)))
      (is (functionp (atari800-cl.bus:bus-pokey-read-fn bus)))
      (is (functionp (atari800-cl.bus:bus-antic-read-fn bus))))
    ;; CPU bus hooks must point at functions, not NIL.
    (is (functionp (cpu-bus-read  (atari800-cl.machine:atari-machine-cpu m))))
    (is (functionp (cpu-bus-write (atari800-cl.machine:atari-machine-cpu m))))))

;;; ---------------------------------------------------------------------------
;;; Cold reset

(test machine-cold-reset-with-synthetic-rom-sets-pc-from-reset-vector
  "Cold reset reads $FFFC/$FFFD from the OS ROM and loads it into PC."
  (let* ((m   (atari800-cl.machine:make-atari-machine))
         (rom (%make-synthetic-os-rom :reset-pc #xC037)))
    (atari800-cl.machine:machine-cold-reset m :os-rom rom)
    (is (= #xC037 (cpu-pc (atari800-cl.machine:atari-machine-cpu m)))
        "PC after cold reset must equal the reset vector")
    (is (= #xFF (cpu-sp (atari800-cl.machine:atari-machine-cpu m)))
        "SP must be $FF after cold reset")
    (is (= #x34 (cpu-flags (atari800-cl.machine:atari-machine-cpu m)))
        "Flags must be $34 (U=1 I=1 B=1) after cold reset")
    (is (= #xFF (atari800-cl.mmu:mmu-portb
                  (atari800-cl.machine:atari-machine-mmu m)))
        "PORTB must be $FF after cold reset (OS on, BASIC off, selftest off)")))

(test machine-cold-reset-also-loads-basic-rom
  "Supplying :BASIC-ROM puts the BASIC image into bus-basic-rom."
  (let* ((m (atari800-cl.machine:make-atari-machine))
         (os (%make-synthetic-os-rom))
         (basic (%make-synthetic-basic-rom)))
    (atari800-cl.machine:machine-cold-reset m :os-rom os :basic-rom basic)
    (is-true (atari800-cl.bus:bus-basic-rom
              (atari800-cl.machine:atari-machine-bus m)))
    (is (= #x2000 (length (atari800-cl.bus:bus-basic-rom
                            (atari800-cl.machine:atari-machine-bus m)))))))

;;; ---------------------------------------------------------------------------
;;; Frame scheduler

(test machine-run-frame-advances-frame-count
  "After one MACHINE-RUN-FRAME, frame-count is 1."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (atari800-cl.machine:machine-run-frame m)
    (is (= 1 (atari800-cl.machine:atari-machine-frame-count m)))))

(test machine-run-frame-advances-antic-scanline-and-wraps
  "After one full frame, ANTIC's scanline counter wraps back to 0 and its
internal frame counter is exactly 1."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (atari800-cl.machine:machine-run-frame m)
    (let ((antic (atari800-cl.machine:atari-machine-antic m)))
      (is (zerop (atari800-cl.antic:antic-scanline antic))
          "Scanline must wrap back to 0 after a complete frame")
      (is (= 1 (atari800-cl.antic:antic-frame-count antic))
          "ANTIC's internal frame counter must equal 1 after one frame"))))

(test machine-run-frame-advances-cpu-cycles-near-29868
  "Total CPU cycles accumulated in one frame are within the expected
order of magnitude (29,868 clocks minus what ANTIC stole)."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (atari800-cl.machine:machine-run-frame m)
    (let ((cycles (cpu-cycles (atari800-cl.machine:atari-machine-cpu m))))
      (is (and (>= cycles 20000) (<= cycles 35000))
          "CPU cycles after one frame should be ~29,868; got ~A" cycles))))

;;; ---------------------------------------------------------------------------
;;; Interrupt service via the scheduler

(test machine-synthetic-nmi-is-serviced-within-one-frame
  "Setting CPU-PENDING-NMI before MACHINE-RUN-FRAME causes the NMI to be
serviced (PC jumps to the NMI vector, pending-nmi clears)."
  (let* ((m  (atari800-cl.machine:make-atari-machine))
         (cpu (atari800-cl.machine:atari-machine-cpu m)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (setf (cpu-pending-nmi cpu) t)
    ;; Capture PC before run; service-nmi will push the OLD PC and load
    ;; the NMI vector ($FE00 from our synthetic ROM).
    (let ((pre-pc (cpu-pc cpu)))
      (atari800-cl.machine:machine-run-frame m)
      (is-false (cpu-pending-nmi cpu) "pending-nmi must clear after service")
      (is (not (= pre-pc (cpu-pc cpu)))
          "PC must change after NMI vector dispatch (start PC was $~4,'0X)"
          pre-pc))))

(test machine-synthetic-irq-is-serviced-when-i-flag-clear
  "With pending-irq set and the I flag clear, the IRQ is serviced."
  (let* ((m   (atari800-cl.machine:make-atari-machine))
         (cpu (atari800-cl.machine:atari-machine-cpu m)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    ;; Cold reset leaves I=1.  Clear it so IRQs are unmasked.
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-i+)
    (setf (cpu-pending-irq cpu) t)
    (atari800-cl.machine:machine-run-frame m)
    ;; service-irq sets the I flag to disable further IRQs.
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-i+)
             "service-irq must set the I flag to mask further IRQs")))

(test machine-irq-masked-when-i-flag-set
  "With I flag set, pending-irq is NOT serviced (still pending after frame)."
  (let* ((m   (atari800-cl.machine:make-atari-machine))
         (cpu (atari800-cl.machine:atari-machine-cpu m)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    ;; Cold reset sets I=1.  Without external chips poking pending-irq
    ;; mid-frame, the flag should stay asserted across the whole frame.
    (setf (cpu-pending-irq cpu) t)
    (let ((pre-pc (cpu-pc cpu)))
      (declare (ignore pre-pc))
      (atari800-cl.machine:machine-run-frame m)
      (is-true (cpu-pending-irq cpu)
               "pending-irq must stay asserted when I flag is set"))))
