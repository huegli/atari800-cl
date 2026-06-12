;;;; tests/test-regressions.lisp --- Known-edge-case regression tests.
;;;;
;;;; Each test in this file pins down a real bug or subtle behaviour
;;;; that was discovered during development.  If one of these regresses,
;;;; we want a single-line failure that names the issue.

(in-package #:atari800-cl/tests)

(def-suite regression-suite
  :description "Regressions for bugs and edge cases discovered during development."
  :in atari800-cl-suite)

(in-suite regression-suite)

;;; ---------------------------------------------------------------------------
;;; Regression #1 — SBCL/arm64 codegen bug bypassed by BUS-PEEK-RAM.
;;;
;;; Triggering condition: AREF on the bus's typed RAM slot with a
;;; constant index >= 4096.  Before BUS-PEEK-RAM (NOTINLINE), SBCL's
;;; arm64 backend tried to emit a STR with a 16384-byte immediate offset
;;; and aborted file compilation with "Invalid STR/LDR arguments".
;;; This test ensures the bypass helper survives high-offset reads.

(test bus-peek-ram-handles-high-addresses
  "BUS-PEEK-RAM works across the full 64K range — particularly at the
top of memory where the SBCL/arm64 immediate-offset bug used to fire."
  (let ((bus (atari800-cl.bus:make-bus)))
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x11)
    (atari800-cl.bus:bus-poke-ram bus #xC000 #x22)
    (atari800-cl.bus:bus-poke-ram bus #xFFFE #x33)
    (atari800-cl.bus:bus-poke-ram bus #xFFFF #x44)
    (is (= #x11 (atari800-cl.bus:bus-peek-ram bus #x4000)))
    (is (= #x22 (atari800-cl.bus:bus-peek-ram bus #xC000)))
    (is (= #x33 (atari800-cl.bus:bus-peek-ram bus #xFFFE)))
    (is (= #x44 (atari800-cl.bus:bus-peek-ram bus #xFFFF)))))

;;; ---------------------------------------------------------------------------
;;; Regression #2 — KIL halts the machine but doesn't crash run-frame.
;;;
;;; The KIL/JAM/STP family of illegal opcodes is documented to set
;;; CPU-HALTED and signal ILLEGAL-OPCODE.  The machine scheduler must
;;; catch that condition gracefully so MACHINE-RUN-FRAME doesn't bubble
;;; the error out of an entire-frame loop.

(test machine-run-frame-survives-kil
  "Placing a KIL opcode under the reset vector must not crash run-frame;
the CPU should end the frame in CPU-HALTED state."
  (let* ((os (%make-synthetic-os-rom :reset-pc #xC000))
         (m  (make-test-machine :os-rom os)))
    ;; Patch the byte at $C000 (which the reset vector points to) to KIL ($02).
    (%poke os 0 #x02)
    ;; Re-install the rom so the patch takes effect AFTER cold-reset already ran.
    (atari800-cl.bus:install-os-rom (atari800-cl.machine:atari-machine-bus m) os)
    (finishes (atari800-cl.machine:machine-run-frame m))
    (is-true (cpu-halted (atari800-cl.machine:atari-machine-cpu m))
             "CPU must be in HALTED state after running into a KIL")))

;;; ---------------------------------------------------------------------------
;;; Regression #3 — I/O writes do not leak into RAM.
;;;
;;; The bus dispatcher must NEVER route writes in $D000-$D7FF to the
;;; underlying RAM array, even if no chip is attached to the targeted
;;; sub-page.  An earlier sketch of bus.lisp accidentally fell through
;;; to (setf (aref ram addr) val) for unmapped I/O addresses.

(test io-writes-never-leak-to-ram
  "Every page of the I/O window must drop unhandled writes; RAM stays clean."
  (let ((bus (atari800-cl.bus:make-bus)))
    (dolist (addr '(#xD000 #xD0FF
                    #xD100 #xD1FF       ; open-bus page
                    #xD200 #xD2FF
                    #xD300 #xD3FF
                    #xD400 #xD4FF
                    #xD500 #xD7FF))     ; more open-bus pages
      (atari800-cl.bus:bus-write bus addr #x77)
      (is (zerop (atari800-cl.bus:bus-peek-ram bus addr))
          "Write at $~4,'0X must NOT have landed in RAM" addr))))

;;; ---------------------------------------------------------------------------
;;; Regression #4 — ANTIC fires DLI EXACTLY once per mode line, not on
;;; every color clock at the boundary.
;;;
;;; An earlier ANTIC sketch fired DLI any time mode-scanlines-remaining
;;; was 1, every color clock for the whole final scanline.

(test antic-dli-fires-exactly-once-per-mode-line
  "DLI bit set on the mode byte must raise CPU NMI exactly once, then
clear DLI-ARMED, regardless of how many color clocks we tick after."
  (let* ((bus (atari800-cl.bus:make-bus))
         (cpu (atari800-cl.cpu:make-cpu))
         (antic (atari800-cl.antic:make-antic))
         (dlist 16384))                                  ; #x4000
    (atari800-cl.antic:attach-antic bus antic cpu)
    (atari800-cl.bus:bus-poke-ram bus dlist #x82)        ; mode 2 + DLI bit
    (atari800-cl.bus:bus-write bus #xD402 (logand dlist #xFF))
    (atari800-cl.bus:bus-write bus #xD403 (logand (ash dlist -8) #xFF))
    (atari800-cl.bus:bus-write bus #xD400 #x22)           ; DMACTL with inst DMA
    (atari800-cl.bus:bus-write bus #xD40E atari800-cl.antic:+nmi-dli+)
    ;; Run ~10 scanlines worth of ticks; DLI must fire at most once.
    (dotimes (i (* 16 atari800-cl.antic:+color-clocks-per-scanline+))
      (atari800-cl.antic:antic-tick antic cpu bus))
    (is-false (atari800-cl.antic:antic-dli-armed antic)
              "DLI-ARMED must be cleared after the mode line fires")
    (is-true (cpu-pending-nmi cpu) "DLI must have raised exactly one NMI")))

;;; ---------------------------------------------------------------------------
;;; Regression #5 — PORTB write propagates immediately through the bus.
;;;
;;; The PIA closure stored in the bus must call MMU-WRITE-PORTB during
;;; the same BUS-WRITE so bank-switching is visible on the very next
;;; read.

(test portb-write-changes-rom-mapping-immediately
  "A BUS-WRITE to $D302 must flip ROM visibility for the very next read."
  (let* ((m (make-test-machine)))
    ;; Cold reset leaves OS on.  $C000 reads from the synthetic OS ROM ($EA).
    (is (= #xEA (atari800-cl.bus:bus-read
                  (atari800-cl.machine:atari-machine-bus m) #xC000)))
    ;; Software writes PORTB = 0 → OS off.  RAM (initialised to 0) shows.
    (atari800-cl.bus:bus-write
      (atari800-cl.machine:atari-machine-bus m) #xD302 #x00)
    (is (zerop (atari800-cl.bus:bus-read
                 (atari800-cl.machine:atari-machine-bus m) #xC000)))))

;;; ---------------------------------------------------------------------------
;;; Regression #6 — Acknowledging the last pending POKEY IRQ de-asserts
;;; the CPU's IRQ line.
;;;
;;; %FIRE-TIMER-IRQ set CPU-PENDING-IRQ but nothing ever cleared it:
;;; after the first timer IRQ the level-sensitive line stayed asserted
;;; forever, so the CPU re-serviced a phantom interrupt every time the
;;; I flag cleared — even though IRQST read back as "nothing pending".
;;; The fix re-derives the line from (IRQEN AND (NOT IRQST)) on every
;;; IRQEN write and on RESET-POKEY.

(test pokey-irq-ack-deasserts-cpu-irq-line
  "Writing IRQEN = 0 after a timer IRQ must drop CPU-PENDING-IRQ, and
re-enabling the (now acknowledged) source must not re-assert it."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (atari800-cl.bus:bus-write bus #xD200 0)       ; AUDF1 = 0 — fires on first tick
    (atari800-cl.bus:bus-write bus #xD20E #x01)    ; IRQEN: timer 1
    (atari800-cl.bus:bus-write bus #xD209 0)       ; STIMER
    (atari800-cl.pokey:pokey-tick pok cpu)
    (is-true (cpu-pending-irq cpu)
             "Timer 1 underflow must assert the IRQ line")
    ;; Acknowledge by disabling the source.
    (atari800-cl.bus:bus-write bus #xD20E 0)
    (is-false (cpu-pending-irq cpu)
              "Acknowledging the only pending source must de-assert the IRQ line")
    ;; Re-enabling after the ack must NOT resurrect the old interrupt.
    (atari800-cl.bus:bus-write bus #xD20E #x01)
    (is-false (cpu-pending-irq cpu)
              "Re-enabling an acknowledged source must not re-assert the line")))

(test pokey-irq-line-stays-asserted-while-another-source-pending
  "With two timers pending, acknowledging one must keep the line
asserted; acknowledging the second must finally drop it."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (atari800-cl.bus:bus-write bus #xD200 0)       ; AUDF1 = 0 (1.79 MHz, divisor 1)
    (atari800-cl.bus:bus-write bus #xD202 0)       ; AUDF2 = 0 (64 kHz, divisor 28)
    (atari800-cl.bus:bus-write bus #xD20E #x03)    ; IRQEN: timers 1 + 2
    (atari800-cl.bus:bus-write bus #xD209 0)       ; STIMER
    (%tick-n-pokey pok cpu 28)                     ; tick 1 fires ch1; tick 28 fires ch2
    (is (zerop (logand (atari800-cl.pokey:pokey-irqst pok) #x03))
        "Both timer IRQST bits must be pending (low) before the acks")
    ;; Disable timer 2 only — timer 1 is still enabled AND pending.
    (atari800-cl.bus:bus-write bus #xD20E #x01)
    (is-true (cpu-pending-irq cpu)
             "Line must stay asserted while timer 1 is still enabled + pending")
    ;; Disable timer 1 as well — nothing enabled remains pending.
    (atari800-cl.bus:bus-write bus #xD20E 0)
    (is-false (cpu-pending-irq cpu)
              "Line must drop once the last pending source is acknowledged")))

(test pokey-reset-deasserts-cpu-irq-line
  "RESET-POKEY clears IRQEN, so any IRQ POKEY was holding must drop."
  (multiple-value-bind (pok cpu bus) (%make-pokey-fixture :audctl #x40)
    (atari800-cl.bus:bus-write bus #xD200 0)
    (atari800-cl.bus:bus-write bus #xD20E #x01)
    (atari800-cl.bus:bus-write bus #xD209 0)
    (atari800-cl.pokey:pokey-tick pok cpu)
    (is-true (cpu-pending-irq cpu))
    (atari800-cl.pokey:reset-pokey pok)
    (is-false (cpu-pending-irq cpu)
              "RESET-POKEY must release the IRQ line it was driving")))

;;; ---------------------------------------------------------------------------
;;; Regression #7 — Interrupt-entry cycles count against the frame budget.
;;;
;;; %RUN-CLOCKS used to call CHECK-AND-DISPATCH-NMI/IRQ at every clock
;;; in addition to STEP-CPU's own dispatch.  SERVICE-NMI/IRQ increment
;;; CPU-CYCLES by 7, but that path never charged CPU-BUDGET, so each
;;; interrupt entry was free wall-clock time and the CPU ran ahead of
;;; the machine clock.  Under an IRQ storm (line held asserted, handler
;;; is a bare RTI) the CPU consumed roughly twice as many cycles as
;;; clocks elapsed.  Interrupts are now serviced exclusively by
;;; STEP-CPU, whose 7-cycle return value is debited like any
;;; instruction.

(test interrupt-entry-cycles-count-against-frame-budget
  "Under a continuous IRQ storm, the CPU must not consume more cycles
than color clocks elapsed (the budget can overdraw by at most one
instruction)."
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000 :irq-pc #xFE00)))
    ;; Main program at $C000: CLI, then NOP filler.  IRQ handler at
    ;; $FE00 (ROM offset $3E00): bare RTI, so the still-asserted line
    ;; re-enters the handler immediately — a worst-case IRQ storm.
    (%poke os #x0000 #x58)                               ; CLI
    (%poke os #x3E00 #x40)                               ; RTI
    (let* ((m   (make-test-machine :os-rom os))
           (cpu (atari800-cl.machine:atari-machine-cpu m))
           (clocks (* 4 114)))                           ; 4 scanlines
      ;; Hold the IRQ line asserted for the whole run (stuck device).
      (setf (cpu-pending-irq cpu) t)
      (atari800-cl.machine:%run-clocks m clocks)
      (let ((consumed (cpu-cycles cpu)))
        (is (> consumed 300)
            "Sanity: the IRQ storm must actually have run (~D cycles in ~D clocks)"
            consumed clocks)
        (is (<= consumed clocks)
            "CPU consumed ~D cycles in ~D clocks — interrupt entries must ~
             be charged against the budget, not run for free"
            consumed clocks)))))
