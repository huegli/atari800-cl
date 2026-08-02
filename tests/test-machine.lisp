;;;; tests/test-machine.lisp --- top-level machine + scheduler tests.

(in-package #:atari800-cl/tests)

(def-suite machine-suite
  :description "Atari 800 XL machine wiring, frame scheduler, cold reset."
  :in atari800-cl-suite)

(in-suite machine-suite)

;;; Synthetic ROM fixtures (%MAKE-SYNTHETIC-OS-ROM / %MAKE-SYNTHETIC-BASIC-ROM
;;; / %POKE) and MAKE-TEST-MACHINE / WITH-CPU-STATE come from
;;; tests/test-helpers.lisp.

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
;;; Scanline-granular scheduler (SCANLINE_ACCURACY_PLAN.md Phase 1)

(test machine-vbi-nmi-serviced-exactly-once-per-frame
  "With NMIEN bit 6 set, the VBI NMI is raised — and serviced — exactly
once per frame.  Counts services with a synthetic NMI handler that
increments RAM $80 and RTIs."
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000 :nmi-pc #xFE00)))
    ;; Main program at $C000: JMP $C000 — a tight loop, so the PC never
    ;; marches down the NOP filler into the handler bytes below.
    (%poke os #x0000 #x4C)                               ; JMP abs
    (%poke os #x0001 #x00)
    (%poke os #x0002 #xC0)
    ;; NMI handler at $FE00 (ROM offset $3E00): INC $80, RTI.
    (%poke os #x3E00 #xE6)                               ; INC zp
    (%poke os #x3E01 #x80)
    (%poke os #x3E02 #x40)                               ; RTI
    (let* ((m   (make-test-machine :os-rom os))
           (bus (atari800-cl.machine:atari-machine-bus m)))
      ;; Enable only the VBI NMI source (DMACTL stays 0, so no DLIs).
      (atari800-cl.bus:bus-write bus #xD40E atari800-cl.antic:+nmi-vbi+)
      (atari800-cl.machine:machine-run-frame m)
      (is (= 1 (atari800-cl.bus:bus-peek-ram bus #x0080))
          "VBI handler must run exactly once in frame 1; counter = ~D"
          (atari800-cl.bus:bus-peek-ram bus #x0080))
      (atari800-cl.machine:machine-run-frame m)
      (is (= 2 (atari800-cl.bus:bus-peek-ram bus #x0080))
          "Frame 2 must add exactly one more VBI service; counter = ~D"
          (atari800-cl.bus:bus-peek-ram bus #x0080)))))

(test machine-pokey-irq-serviced-within-same-scanline
  "A POKEY timer IRQ that fires mid-line must be serviced within the same
scanline it fires on.  Guards the scheduler's interleaving requirement:
POKEY advances instruction-by-instruction alongside the CPU, not in one
line-sized batch at the end of the line (which would delay IRQ delivery
to the NEXT line and leave RAM $81 still 0 after one line here)."
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000 :irq-pc #xFE10)))
    ;; Main program at $C000: JMP $C000 — a tight loop, so the PC never
    ;; marches down the NOP filler into the handler bytes below.
    (%poke os #x0000 #x4C)                               ; JMP abs
    (%poke os #x0001 #x00)
    (%poke os #x0002 #xC0)
    ;; IRQ handler at $FE10 (ROM offset $3E10): INC $81, RTI.
    (%poke os #x3E10 #xE6)                               ; INC zp
    (%poke os #x3E11 #x81)
    (%poke os #x3E12 #x40)                               ; RTI
    (let* ((m   (make-test-machine :os-rom os))
           (cpu (atari800-cl.machine:atari-machine-cpu m))
           (bus (atari800-cl.machine:atari-machine-bus m)))
      ;; POKEY timer 1 at the 1.79 MHz clock (divisor 1), AUDF1 = 30:
      ;; underflow + IRQ after 31 POKEY cycles — mid-line.
      (atari800-cl.bus:bus-write bus #xD208 #x40)        ; AUDCTL: ch1 fast
      (atari800-cl.bus:bus-write bus #xD200 30)          ; AUDF1
      (atari800-cl.bus:bus-write bus #xD20E #x01)        ; IRQEN: timer 1
      (atari800-cl.bus:bus-write bus #xD209 0)           ; STIMER
      ;; Cold reset leaves I=1; unmask IRQs.
      (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-i+)
      ;; Run exactly ONE scanline.
      (atari800-cl.machine:%run-clocks m 114)
      (is (plusp (atari800-cl.bus:bus-peek-ram bus #x0081))
          "IRQ handler must have run within the same 114-cycle scanline; ~
           RAM $81 = ~D" (atari800-cl.bus:bus-peek-ram bus #x0081)))))

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
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-i+)
             "service-irq must set the I flag to mask further IRQs")))

;;; ---------------------------------------------------------------------------
;;; Debug instrumentation (Prompt 11)

(test machine-trace-step-returns-n-snapshots
  "MACHINE-TRACE-STEP returns the requested number of snapshots."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (let ((snaps (atari800-cl.machine:machine-trace-step m 10)))
      (is (= 10 (length snaps))
          "Asked for 10 snapshots; got ~A" (length snaps))
      (let ((first (first snaps)))
        (is-true (getf first :pc))
        (is-true (member :opcode first))
        (is-true (member :a first))
        (is-true (member :p first))))))

(test machine-trace-step-decodes-nop-mnemonic
  "The synthetic ROM is full of $EA (NOP); snapshots must show \"NOP\"."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (let ((snaps (atari800-cl.machine:machine-trace-step m 3)))
      (dolist (s snaps)
        (is (= #xEA (getf s :opcode))
            "Each opcode byte must be #xEA (NOP filler); got #x~2,'0X"
            (getf s :opcode))
        (is (string= "NOP" (getf s :mnemonic))
            "Mnemonic for $EA must decode to \"NOP\"; got ~S"
            (getf s :mnemonic))))))

(test machine-portb-state-after-cold-reset
  "PORTB-STATE plist after cold reset: OS mapped, BASIC off, self-test off."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (let ((p (atari800-cl.machine:machine-portb-state m)))
      (is (= #xFF (getf p :portb)))
      (is-true (getf p :os-rom-mapped))
      (is-false (getf p :basic-rom-mapped))
      (is-false (getf p :selftest-mapped)))))

(test machine-pending-interrupts-shape
  "MACHINE-PENDING-INTERRUPTS returns a plist with three known keys."
  (let* ((m (atari800-cl.machine:make-atari-machine))
         (info (progn
                 (atari800-cl.machine:machine-cold-reset
                  m :os-rom (%make-synthetic-os-rom))
                 (atari800-cl.machine:machine-pending-interrupts m))))
    (is (member :irq-pending info))
    (is (member :nmi-pending info))
    (is (member :i-flag-masked info))
    (is-false (getf info :irq-pending))
    (is-false (getf info :nmi-pending))
    (is-true  (getf info :i-flag-masked) "I flag should be set after cold reset")))

(test machine-scanline-progresses-and-resets
  "MACHINE-SCANLINE reports an integer 0..261 and wraps after each frame."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset m :os-rom (%make-synthetic-os-rom))
    (is (zerop (atari800-cl.machine:machine-scanline m))
        "Scanline starts at 0 after cold reset")
    (atari800-cl.machine:machine-run-frame m)
    (is (zerop (atari800-cl.machine:machine-scanline m))
        "Scanline wraps back to 0 after one full frame")))

(test machine-run-frame-survives-five-frames
  "Five frames in a row run without raising any condition."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset
     m :os-rom (%make-synthetic-os-rom) :basic-rom (%make-synthetic-basic-rom))
    (finishes
     (dotimes (i 5)
       (atari800-cl.machine:machine-run-frame m)))
    (is (= 5 (atari800-cl.machine:atari-machine-frame-count m)))))

(test machine-cold-reset-portb-maps-os-and-basic-correctly
  "With PORTB=$FF after cold reset, reading at $C100 returns the OS ROM
byte; toggling bit 1 to 0 then reading $A100 returns the BASIC ROM byte."
  (let* ((m (atari800-cl.machine:make-atari-machine))
         (os (%make-synthetic-os-rom))
         (basic (%make-synthetic-basic-rom)))
    ;; Mark sentinel bytes in the synthetic ROMs.
    (%poke os #x0100 #xAB)            ; OS ROM offset $0100 → $C100
    (%poke basic #x0100 #xCD)         ; BASIC ROM offset $0100 → $A100
    (atari800-cl.machine:machine-cold-reset m :os-rom os :basic-rom basic)
    (let ((bus (atari800-cl.machine:atari-machine-bus m))
          (mmu (atari800-cl.machine:atari-machine-mmu m)))
      ;; OS visible at $C100.
      (is (= #xAB (atari800-cl.bus:bus-read bus #xC100))
          "OS ROM byte must be visible at $C100 after cold reset")
      ;; BASIC requires bit 1 clear; cold reset leaves it set.  Clear it.
      (atari800-cl.mmu:mmu-write-portb mmu #xFD)              ; OS on, BASIC on
      (is (= #xCD (atari800-cl.bus:bus-read bus #xA100))))))

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

;;; ---------------------------------------------------------------------------
;;; Concurrency core: mailbox, run loop, attach-input (Stage 3)

(defmacro with-running-machine ((mvar) &body body)
  "Bind MVAR to a fresh machine driven by a background MACHINE-RUN-LOOP
thread (initially paused).  Stops the thread and joins it on exit."
  (let ((stop (gensym "STOP")) (th (gensym "TH")))
    `(let* ((,mvar (atari800-cl.machine:make-atari-machine))
            (,stop (list nil))
            (,th (make-thread
                  (lambda ()
                    (atari800-cl.machine:machine-run-loop
                     ,mvar :stop-flag (lambda () (car ,stop))))
                  :name "test-run-loop")))
       (unwind-protect (progn ,@body)
         (setf (car ,stop) t)
         (join-thread ,th)))))

(defun %wait-until (predicate &key (timeout 2.0) (step 0.005))
  "Poll PREDICATE until it returns true or TIMEOUT seconds elapse.  Returns
PREDICATE's last value (so tests assert on it without depending on a fixed
sleep — robust against scheduler jitter on either implementation)."
  (let ((deadline (+ (get-internal-real-time)
                     (truncate (* timeout internal-time-units-per-second)))))
    (loop for v = (funcall predicate)
          when v return v
          when (> (get-internal-real-time) deadline) return v
          do (sleep step))))

(test machine-run-frame-unchanged-signature
  "After the %run-clocks refactor, MACHINE-RUN-FRAME still runs exactly one
frame and bumps FRAME-COUNT by one."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-run-frame m)
    (is (= 1 (atari800-cl.machine:atari-machine-frame-count m)))))

(test run-clocks-abort-pred-stops-at-scanline
  "%RUN-CLOCKS with a truthy ABORT-PRED stops at the first scanline check
(clock 114); with no predicate it runs the full count."
  (let ((m (atari800-cl.machine:make-atari-machine)))
    (is (= 114 (atari800-cl.machine:%run-clocks
                m atari800-cl.machine:+clocks-per-frame+
                :abort-pred (constantly t))))
    (is (= atari800-cl.machine:+clocks-per-frame+
           (atari800-cl.machine:%run-clocks
            m atari800-cl.machine:+clocks-per-frame+)))))

(test mailbox-soft-cap-replies-busy
  "MAILBOX-ENQUEUE returns :OK until the soft cap, then :BUSY."
  (let ((mb (atari800-cl.machine:make-command-mailbox :soft-cap 2)))
    (flet ((dummy () (atari800-cl.machine::%make-machine-command
                      :thunk (lambda (m) (declare (ignore m)) nil))))
      (is (eq :ok   (atari800-cl.machine:mailbox-enqueue mb (dummy))))
      (is (eq :ok   (atari800-cl.machine:mailbox-enqueue mb (dummy))))
      (is (eq :busy (atari800-cl.machine:mailbox-enqueue mb (dummy)))))))

(test machine-submit-runs-on-loop-and-returns-value
  "A submitted command runs on the emulator thread and its value comes back."
  (with-running-machine (m)
    (is (= 42 (atari800-cl.machine:machine-submit
               m (lambda (mach) (declare (ignore mach)) (+ 40 2)))))))

(test machine-submit-propagates-errors
  "An error signalled inside a command thunk is re-signalled to the
submitter (so a server can turn it into an error reply)."
  (with-running-machine (m)
    (signals error
      (atari800-cl.machine:machine-submit
       m (lambda (mach) (declare (ignore mach)) (error "boom"))))))

(test machine-run-loop-pause-resume-advances-frames
  "A paused loop runs no frames; resuming (running-p t) advances FRAME-COUNT;
pausing again stops it.  Timing-robust: polls for the first frame rather
than sleeping a fixed interval."
  (with-running-machine (m)
    (is (= 0 (atari800-cl.machine:atari-machine-frame-count m))
        "paused machine runs no frames")
    ;; Resume; wait (bounded) for at least one frame to land.
    (atari800-cl.machine:machine-submit
     m (lambda (mach) (setf (atari800-cl.machine:atari-machine-running-p mach) t))
     :priority t)
    (let ((advanced (%wait-until
                     (lambda () (plusp (atari800-cl.machine:atari-machine-frame-count m)))
                     :timeout 5.0)))
      (atari800-cl.machine:machine-submit
       m (lambda (mach) (setf (atari800-cl.machine:atari-machine-running-p mach) nil))
       :priority t)
      (is-true advanced "running advanced the frame count within 5s"))))

(test attach-input-wires-all-chips
  "ATTACH-INPUT stores the input-state on the machine and every input chip;
detaching with NIL clears them."
  (let ((m  (atari800-cl.machine:make-atari-machine))
        (in (make-input-state)))
    (atari800-cl.machine:attach-input m in)
    (is (eq in (atari800-cl.machine:atari-machine-input m)))
    (is (eq in (atari800-cl.pia:pia-input     (atari800-cl.machine:atari-machine-pia   m))))
    (is (eq in (atari800-cl.gtia:gtia-input   (atari800-cl.machine:atari-machine-gtia  m))))
    (is (eq in (atari800-cl.pokey:pokey-input (atari800-cl.machine:atari-machine-pokey m))))
    (atari800-cl.machine:attach-input m nil)
    (is (null (atari800-cl.machine:atari-machine-input m)))
    (is (null (atari800-cl.pia:pia-input (atari800-cl.machine:atari-machine-pia m))))))
