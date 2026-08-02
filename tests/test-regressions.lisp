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
;;; every CPU cycle at the boundary.
;;;
;;; An earlier ANTIC sketch fired DLI any time mode-scanlines-remaining
;;; was 1, every cycle for the whole final scanline.

(test antic-dli-fires-exactly-once-per-mode-line
  "DLI bit set on the mode byte must raise CPU NMI exactly once, then
clear DLI-ARMED, regardless of how many CPU cycles we tick after."
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
    (dotimes (i (* 16 atari800-cl.antic:+cpu-cycles-per-scanline+))
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
than CPU-clock cycles elapsed (the budget can overdraw by at most one
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

;;; ---------------------------------------------------------------------------
;;; Regression #8 — WSYNC stalls the CPU to the end of the scanline.

(test wsync-stalls-cpu-to-end-of-scanline
  "STA WSYNC halts instruction execution for the rest of the current
scanline; the next instruction only runs once the following scanline
begins."
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000)))
    ;; Main program at $C000: LDA #$FF ; STA $D40A ; STA $00 (marker).
    (%poke os #x0000 #xA9)  (%poke os #x0001 #xFF)       ; LDA #$FF
    (%poke os #x0002 #x8D)  (%poke os #x0003 #x0A)       ; STA $D40A
    (%poke os #x0004 #xD4)
    (%poke os #x0005 #x85)  (%poke os #x0006 #x00)       ; STA $00
    (let* ((m   (make-test-machine :os-rom os))
           (bus (atari800-cl.machine:atari-machine-bus m)))
      (atari800-cl.machine:%run-clocks m 114)   ; one full scanline
      (is (zerop (atari800-cl.bus:bus-peek-ram bus #x00))
          "STA $00 must NOT have executed yet — the CPU stalled at WSYNC ~
           partway through the first scanline")
      (atari800-cl.machine:%run-clocks m 114)   ; the next scanline
      (is (= #xFF (atari800-cl.bus:bus-peek-ram bus #x00))
          "STA $00 must have executed once the next scanline began"))))

;;; ---------------------------------------------------------------------------
;;; Regression #9 — back-to-back WSYNC writes stall a full extra scanline.

(test back-to-back-wsync-stalls-two-scanlines
  "Two consecutive STA WSYNC writes stall the CPU across TWO scanline
boundaries: the first write stalls out the rest of the current line, and
the second write -- executed as the first instruction of the next line
-- immediately stalls that line too."
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000)))
    ;; LDA #$FF ; STA $D40A ; STA $D40A ; STA $00 (marker).
    (%poke os #x0000 #xA9)  (%poke os #x0001 #xFF)       ; LDA #$FF
    (%poke os #x0002 #x8D)  (%poke os #x0003 #x0A)       ; STA $D40A (1st)
    (%poke os #x0004 #xD4)
    (%poke os #x0005 #x8D)  (%poke os #x0006 #x0A)       ; STA $D40A (2nd)
    (%poke os #x0007 #xD4)
    (%poke os #x0008 #x85)  (%poke os #x0009 #x00)       ; STA $00
    (let* ((m   (make-test-machine :os-rom os))
           (bus (atari800-cl.machine:atari-machine-bus m)))
      (atari800-cl.machine:%run-clocks m 114)   ; scanline 1: 1st WSYNC stalls it
      (is (zerop (atari800-cl.bus:bus-peek-ram bus #x00))
          "marker must not be written after the first scanline")
      (atari800-cl.machine:%run-clocks m 114)   ; scanline 2: 2nd WSYNC stalls it too
      (is (zerop (atari800-cl.bus:bus-peek-ram bus #x00))
          "marker must STILL not be written after the second scanline -- ~
           back-to-back WSYNC eats a whole extra line")
      (atari800-cl.machine:%run-clocks m 114)   ; scanline 3: marker finally runs
      (is (= #xFF (atari800-cl.bus:bus-peek-ram bus #x00))
          "marker must be written once the third scanline runs"))))

;;; ---------------------------------------------------------------------------
;;; Regression #10 — WSYNC raster bars render as distinct per-line colors.
;;;
;;; End-to-end acceptance test for ROADMAP.md Phase 4: the machine-code
;;; equivalent of asm/edvent02_rasterbars.asm's inner loop (WSYNC then
;;; increment COLBK, repeated) must produce a run of consecutive
;;; rendered rows whose background color differs from the row above,
;;; through the REAL renderer wired up exactly as the AESP server wires
;;; it (ATARI-MACHINE-SCANLINE-FN calling RENDER-SCANLINE after each
;;; closed active line).  This fails if WSYNC stops stalling, if the
;;; scanline callback fires at the wrong point, or if per-line register
;;; latching breaks.

(test wsync-raster-bars-render-as-distinct-rows
  "A WSYNC + COLBK-increment loop paints >= 32 consecutive active rows
with strictly different colors, rendered through the real renderer."
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000)))
    ;; LDX #$40 ; LDA #$00
    ;; bars: STA WSYNC ; STA COLBK ; CLC ; ADC #$10 ; DEX ; BNE bars
    (%poke os #x0000 #xA2) (%poke os #x0001 #x40)         ; LDX #$40
    (%poke os #x0002 #xA9) (%poke os #x0003 #x00)         ; LDA #$00
    (%poke os #x0004 #x8D) (%poke os #x0005 #x0A)         ; STA $D40A (WSYNC)
    (%poke os #x0006 #xD4)
    (%poke os #x0007 #x8D) (%poke os #x0008 #x1A)         ; STA $D01A (COLBK)
    (%poke os #x0009 #xD0)
    (%poke os #x000A #x18)                                ; CLC
    (%poke os #x000B #x69) (%poke os #x000C #x10)         ; ADC #$10
    (%poke os #x000D #xCA)                                ; DEX
    (%poke os #x000E #xD0) (%poke os #x000F #xF4)         ; BNE bars (-12)
    (let* ((m   (make-test-machine :os-rom os))
           (gtia (atari800-cl.machine:atari-machine-gtia m))
           (bus  (atari800-cl.machine:atari-machine-bus  m))
           (fb   (atari800-cl.renderer:make-framebuffer)))
      ;; Wire the scanline-fn callback exactly as the AESP server does
      ;; (src/aesp.lisp start-aesp-server).
      (setf (atari800-cl.machine:atari-machine-scanline-fn m)
            (lambda (mach)
              (let* ((a   (atari800-cl.machine:atari-machine-antic mach))
                     (sl  (mod (1- (atari800-cl.antic:antic-scanline a))
                               atari800-cl.antic:+scanlines-per-frame+))
                     (row (- sl atari800-cl.antic:+active-start-scanline+)))
                (when (and (>= row 0) (< row 240))
                  (atari800-cl.renderer:render-scanline fb row a gtia bus)))))
      (atari800-cl.machine:%run-clocks m (* 70 114))
      ;; Longest run of consecutive rows whose sampled pixel (column 0,
      ;; part of the border -- filled with COLBK across the whole row)
      ;; differs from the row immediately above it.
      (flet ((row-rgb (row)
               (let ((base (* row 384 3)))
                 (list (aref fb base) (aref fb (1+ base)) (aref fb (+ base 2))))))
        (let ((run 0) (best 0))
          (loop for row from 1 below 64
                do (if (equal (row-rgb row) (row-rgb (1- row)))
                       (setf run 0)
                       (progn (incf run) (setf best (max best run)))))
          (is (>= best 32)
              "Expected >= 32 consecutive rows with a color change; longest run was ~D"
              best))))))

;;; ---------------------------------------------------------------------------
;;; Regression #11 — playfield DMA steal, frame-level budget check.
;;;
;;; ROADMAP.md Phase 5 acceptance test: a display list of 24 mode-2
;;; lines (192 scanlines) + JVB, DMACTL = $22 (instructions + normal
;;; playfield width, no P/M DMA), run for one full frame. Pins the
;;; whole steal model (refresh + DL-fetch + playfield) end to end: the
;;; expected total steal is computed here scanline-type by
;;; scanline-type using the SAME building-block functions
;;; %BEGIN-SCANLINE-EVENTS calls (PLAYFIELD-DMA-CYCLES,
;;; +DRAM-REFRESH-CYCLES+), traced by hand against this exact DL:
;;;   scanlines 0-7     (8):   pre-active region, refresh only
;;;   scanlines 8-199 (192):  24x mode-2 entries, 8 scanlines each --
;;;                           1 first line (DL-fetch=1, NAME+FONT
;;;                           playfield) + 7 later lines (FONT-only)
;;;   scanline 200      (1):  JVB fetch (DL-fetch=3), no playfield
;;;   scanlines 201-247(47):  JVB-parked, refresh only
;;;   scanlines 248-261(14):  VBI + post-VBI, still outside active region

(test playfield-dma-steal-matches-frame-budget
  "Running a 24-line mode-2 display list for one frame consumes CPU
cycles within one instruction of (262*114 - total-steal), where
total-steal is computed scanline-by-scanline from the same
steal-model functions ANTIC-BEGIN-SCANLINE uses."
  (let* ((m   (make-test-machine))           ; default synthetic ROM: all NOPs
         (cpu (atari800-cl.machine:atari-machine-cpu m))
         (bus (atari800-cl.machine:atari-machine-bus m)))
    ;; Display list at $4000: 24x mode-2 (no LMS, no DLI), then JVB $4000.
    (dotimes (i 24)
      (atari800-cl.bus:bus-poke-ram bus (+ #x4000 i) #x02))
    (atari800-cl.bus:bus-poke-ram bus (+ #x4000 24) #x41)   ; JVB
    (atari800-cl.bus:bus-poke-ram bus (+ #x4000 25) #x00)   ; addr lo
    (atari800-cl.bus:bus-poke-ram bus (+ #x4000 26) #x40)   ; addr hi -> $4000
    (atari800-cl.bus:bus-write bus #xD402 #x00)              ; DLISTL
    (atari800-cl.bus:bus-write bus #xD403 #x40)              ; DLISTH
    (atari800-cl.bus:bus-write bus #xD400 #x22)              ; DMACTL
    (atari800-cl.machine:machine-run-frame m)
    (let* ((refresh  atari800-cl.antic:+dram-refresh-cycles+)
           (pm       0)                       ; DMACTL bits 2-3 clear: no P/M DMA
           (pf-first (atari800-cl.antic:playfield-dma-cycles 2 2 t))
           (pf-later (atari800-cl.antic:playfield-dma-cycles 2 2 nil))
           (idle-line   (+ refresh pm))
           (mode2-entry (+ (+ idle-line 1 pf-first)          ; first line: DL-fetch=1
                            (* 7 (+ idle-line pf-later))))    ; 7 later lines
           (pre-active  (* 8 idle-line))
           (mode2-total (* 24 mode2-entry))
           (jvb-fetch   (+ idle-line 3))       ; DL-fetch=3 (mode + 2 addr bytes)
           (parked      (* 47 idle-line))
           (post-vbi    (* 14 idle-line))
           (expected-steal (+ pre-active mode2-total jvb-fetch parked post-vbi))
           (expected-budget (- (* 262 114) expected-steal)))
      (is (<= (- expected-budget 2) (cpu-cycles cpu) expected-budget)
          "CPU cycles consumed (~D) should be within one instruction of the ~
           expected granted budget ~D (expected steal ~D)"
          (cpu-cycles cpu) expected-budget expected-steal))))

;;; ---------------------------------------------------------------------------
;;; Regression #12 — a WSYNC budget deficit carries through the stall.
;;;
;;; When the STA WSYNC instruction itself overshoots the line's remaining
;;; CPU budget, the overshoot is a debt of already-executed cycles.  The
;;; stall clamp must be (MIN CPU-BUDGET 0), not plain 0: forgiving the
;;; debt hands the CPU free cycles on the next line.

(test wsync-budget-deficit-carries-through-stall
  "STA WSYNC executed with 2 cycles of budget left (a 4-cycle store, so
budget lands at -2) must charge those 2 borrowed cycles against the next
line: across exactly two scanlines the CPU consumes 209 cycles, not 211.

Cycle ledger (DMACTL = 0, so every line grants 114 - 9 = 105):
  line 1: LDA $00 (3) + 50 NOP (100) + STA $D40A (4) = 107; budget -2
  line 2: budget -2 + 105 = 103 -> 51 NOP (102) run, 1 cycle left over
  total: 209.  (A clamp that forgives the deficit grants 105 on line 2:
  52 NOPs, total 211.)"
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000)))
    ;; LDA $00, then offsets 2-51 stay the ROM's NOP fill (50 NOPs),
    ;; then STA $D40A at offset 52.  Everything after is NOPs again.
    (%poke os #x0000 #xA5) (%poke os #x0001 #x00)         ; LDA $00 (3 cyc)
    (%poke os #x0034 #x8D) (%poke os #x0035 #x0A)         ; STA $D40A
    (%poke os #x0036 #xD4)
    (let* ((m   (make-test-machine :os-rom os))
           (cpu (atari800-cl.machine:atari-machine-cpu m)))
      (atari800-cl.machine:%run-clocks m (* 2 114))
      (is (= 209 (cpu-cycles cpu))
          "expected exactly 209 CPU cycles across the two lines ~
           (211 means the WSYNC clamp forgave the 2-cycle deficit); got ~D"
          (cpu-cycles cpu)))))

;;; ---------------------------------------------------------------------------
;;; Regression #13 — a stale out-of-band WSYNC write must not stall.
;;;
;;; Only the scheduler's per-instruction check gives WSYNC meaning; a
;;; $D40A write arriving outside %RUN-CLOCKS (a debugger poke, or
;;; MACHINE-TRACE-STEP executing a store) has no scanline context and
;;; must be discarded on entry, not stall the next run's first line.

(test stale-wsync-flag-does-not-stall-next-run
  "Arming WSYNC via a direct bus write (outside the scheduler) must not
stall the first instructions of the next %RUN-CLOCKS call."
  (let ((os (%make-synthetic-os-rom :reset-pc #xC000)))
    ;; LDA #$FF ; STA $00 (marker).
    (%poke os #x0000 #xA9) (%poke os #x0001 #xFF)         ; LDA #$FF
    (%poke os #x0002 #x85) (%poke os #x0003 #x00)         ; STA $00
    (let* ((m   (make-test-machine :os-rom os))
           (bus (atari800-cl.machine:atari-machine-bus m)))
      ;; Out-of-band arm: this write happens with no scheduler running.
      (atari800-cl.bus:bus-write bus #xD40A #x00)
      (atari800-cl.machine:%run-clocks m 114)
      (is (= #xFF (atari800-cl.bus:bus-peek-ram bus #x00))
          "the marker must be written in the first line -- a stale WSYNC ~
           flag stalled the scheduler"))))
