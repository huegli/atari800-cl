;;;; tests/test-antic.lisp --- ANTIC scanline/DMA-engine tests.

(in-package #:atari800-cl/tests)

(def-suite antic-suite
  :description "ANTIC scanline DMA engine — DL parsing, cycle steals, DLI/VBI."
  :in atari800-cl-suite)

(in-suite antic-suite)

;;; ---------------------------------------------------------------------------
;;; Test harness: build a CPU + bus + ANTIC, plant a DL in RAM.

(defun %make-antic-fixture (&key (dlist-addr #x4000) (dl-bytes nil)
                                 (dmactl #x22) (nmien 0))
  "Return (VALUES ANTIC CPU BUS) wired together, with optional DL bytes
loaded at DLIST-ADDR and ANTIC registers programmed.

Defaults: DMACTL = $22 (normal playfield + instructions DMA enabled),
          NMIEN  = 0 (no interrupts)."
  (let* ((bus (atari800-cl.bus:make-bus))
         (cpu (atari800-cl.cpu:make-cpu))
         (antic (atari800-cl.antic:make-antic)))
    (atari800-cl.antic:attach-antic bus antic cpu)
    ;; Plant the display list bytes via the bypass helper.
    (loop for b in dl-bytes for off from 0
          do (atari800-cl.bus:bus-poke-ram bus
                                           (+ dlist-addr off)
                                           (logand b #xFF)))
    ;; Program ANTIC registers via the bus (so we exercise the write path).
    (atari800-cl.bus:bus-write bus #xD402 (logand dlist-addr #xFF))         ; DLISTL
    (atari800-cl.bus:bus-write bus #xD403 (logand (ash dlist-addr -8) #xFF)) ; DLISTH
    (atari800-cl.bus:bus-write bus #xD400 dmactl)                           ; DMACTL
    (atari800-cl.bus:bus-write bus #xD40E nmien)                            ; NMIEN
    (values antic cpu bus)))

(defun %tick-n (antic cpu bus n)
  "Tick ANTIC N times and return the total cycles stolen across those ticks."
  (let ((total 0))
    (dotimes (i n)
      (incf total (atari800-cl.antic:antic-tick antic cpu bus)))
    total))

(defun %tick-scanlines (antic cpu bus n)
  "Tick ANTIC enough CPU cycles to advance N full scanlines."
  (%tick-n antic cpu bus
           (* n atari800-cl.antic:+cpu-cycles-per-scanline+)))

;;; ---------------------------------------------------------------------------
;;; Mode-line scanline lookup

(test mode-line-scanlines-table
  "Mode lookup gives correct scanline counts for the common modes."
  (is (= 1 (atari800-cl.antic:mode-line-scanlines #x00))
      "blank-line: bits 4-6 = 0 → 1 scanline")
  (is (= 8 (atari800-cl.antic:mode-line-scanlines #x70))
      "blank-line: bits 4-6 = 7 → 8 scanlines")
  (is (= 8  (atari800-cl.antic:mode-line-scanlines #x02)))  ; char mode 2
  (is (= 10 (atari800-cl.antic:mode-line-scanlines #x03)))  ; char mode 3
  (is (= 16 (atari800-cl.antic:mode-line-scanlines #x05)))  ; mode 5
  (is (= 8  (atari800-cl.antic:mode-line-scanlines #x08)))  ; gfx mode 8
  (is (= 1  (atari800-cl.antic:mode-line-scanlines #x0F)))) ; gfx mode F

;;; ---------------------------------------------------------------------------
;;; Line-cycle and scanline wraparound

(test line-cycle-wraps-at-114-and-bumps-scanline
  "After 114 ticks, line-cycle returns to 0 and scanline increments."
  (multiple-value-bind (antic cpu bus) (%make-antic-fixture :dmactl 0)
    (%tick-n antic cpu bus 114)
    (is (zerop (atari800-cl.antic:antic-line-cycle antic)))
    (is (= 1 (atari800-cl.antic:antic-scanline antic)))))

(test frame-wraparound-resets-scanline-counter
  "After 262 × 114 ticks, scanline returns to 0 and FRAME-COUNT increments."
  (multiple-value-bind (antic cpu bus) (%make-antic-fixture :dmactl 0)
    (%tick-scanlines antic cpu bus 262)
    (is (zerop (atari800-cl.antic:antic-scanline antic)))
    (is (= 1 (atari800-cl.antic:antic-frame-count antic)))))

;;; ---------------------------------------------------------------------------
;;; DRAM refresh + P/M DMA steal accounting

(test dram-refresh-steals-9-cycles-with-dmactl-zero
  "With no DMA enabled, ANTIC still steals 9 cycles per scanline (refresh)."
  (multiple-value-bind (antic cpu bus) (%make-antic-fixture :dmactl 0)
    (let ((stolen (%tick-scanlines antic cpu bus 1)))
      (is (= atari800-cl.antic:+dram-refresh-cycles+ stolen)
          "Refresh-only steal must be ~A; got ~A"
          atari800-cl.antic:+dram-refresh-cycles+ stolen))))

(test pm-dma-missile-only-adds-one-cycle
  "DMACTL bit 2 (missile DMA) adds +1 cycle per scanline."
  (multiple-value-bind (antic cpu bus) (%make-antic-fixture :dmactl #x04)
    (let ((stolen (%tick-scanlines antic cpu bus 1)))
      (is (= 10 stolen) "9 (refresh) + 1 (missile DMA) = 10; got ~A" stolen))))

(test pm-dma-players-only-adds-four-cycles
  "DMACTL bit 3 (player DMA) adds +4 cycles (one per player) per scanline."
  (multiple-value-bind (antic cpu bus) (%make-antic-fixture :dmactl #x08)
    (let ((stolen (%tick-scanlines antic cpu bus 1)))
      (is (= 13 stolen) "9 + 4 = 13; got ~A" stolen))))

(test pm-dma-both-add-five-cycles
  "Missile + Player DMA combined adds +5 cycles per scanline."
  (multiple-value-bind (antic cpu bus) (%make-antic-fixture :dmactl #x0C)
    (let ((stolen (%tick-scanlines antic cpu bus 1)))
      (is (= 14 stolen) "9 + 5 = 14; got ~A" stolen))))

;;; ---------------------------------------------------------------------------
;;; PLAYFIELD-DMA-CYCLES (ROADMAP.md Phase 5)
;;;
;;; DMACTL widths: 0 = off, 1 = narrow, 2 = normal, 3 = wide.

(test playfield-dma-cycles-blank-and-jmp-steal-nothing
  "Mode 0 (blank) and mode 1 (JMP/JVB) never steal playfield cycles,
regardless of width or FIRST-LINE-P."
  (dolist (mode '(0 1))
    (dolist (width '(0 1 2 3))
      (dolist (first '(t nil))
        (is (zerop (atari800-cl.antic:playfield-dma-cycles mode width first))
            "mode ~D width ~D first ~A: expected 0" mode width first)))))

(test playfield-dma-cycles-width-off-steals-nothing
  "DMACTL width 0 (off) steals nothing regardless of mode."
  (dolist (mode '(2 6 8 9 15))
    (is (zerop (atari800-cl.antic:playfield-dma-cycles mode 0 t)))
    (is (zerop (atari800-cl.antic:playfield-dma-cycles mode 0 nil)))))

(test playfield-dma-cycles-char-modes-2-5-normal-width
  "Modes 2-5: 40 bytes/fetch at normal width; first line doubles it
(NAME + FONT), later lines charge FONT only."
  (dolist (mode '(2 3 4 5))
    (is (= 80 (atari800-cl.antic:playfield-dma-cycles mode 2 t))
        "mode ~D first-line normal: expected 80 (NAME+FONT)" mode)
    (is (= 40 (atari800-cl.antic:playfield-dma-cycles mode 2 nil))
        "mode ~D later-line normal: expected 40 (FONT only)" mode)))

(test playfield-dma-cycles-char-modes-2-5-narrow-and-wide
  "Modes 2-5 scale by width: narrow = 4/5, wide = 6/5 of normal (40)."
  (is (= 32 (atari800-cl.antic:playfield-dma-cycles 2 1 nil)) "narrow FONT-only")
  (is (= 64 (atari800-cl.antic:playfield-dma-cycles 2 1 t))   "narrow NAME+FONT")
  (is (= 48 (atari800-cl.antic:playfield-dma-cycles 2 3 nil)) "wide FONT-only")
  (is (= 96 (atari800-cl.antic:playfield-dma-cycles 2 3 t))   "wide NAME+FONT"))

(test playfield-dma-cycles-char-modes-6-7
  "Modes 6-7: 20 bytes/fetch at normal width."
  (dolist (mode '(6 7))
    (is (= 40 (atari800-cl.antic:playfield-dma-cycles mode 2 t))
        "mode ~D first-line normal: expected 40 (NAME+FONT)" mode)
    (is (= 20 (atari800-cl.antic:playfield-dma-cycles mode 2 nil))
        "mode ~D later-line normal: expected 20 (FONT only)" mode)))

(test playfield-dma-cycles-map-modes-fetch-first-line-only
  "Map modes 8-F fetch their screen bytes on the FIRST scanline of the
mode line only; ANTIC's line buffer replays them on the remaining
scanlines (0 cycles).  Byte counts are the hardware values: width in
logical pixels x bits per pixel / 8."
  ;; Modes 8, 9: 10 bytes (40px 2bpp / 80px 1bpp).
  (dolist (mode '(8 9))
    (is (= 10 (atari800-cl.antic:playfield-dma-cycles mode 2 t))
        "mode ~D first line normal: expected 10" mode)
    (is (zerop (atari800-cl.antic:playfield-dma-cycles mode 2 nil))
        "mode ~D later line: line buffer replay must steal 0" mode))
  ;; Modes A(10), B(11), C(12): 20 bytes.
  (dolist (mode '(10 11 12))
    (is (= 20 (atari800-cl.antic:playfield-dma-cycles mode 2 t))
        "mode ~D first line normal: expected 20" mode)
    (is (zerop (atari800-cl.antic:playfield-dma-cycles mode 2 nil))
        "mode ~D later line: line buffer replay must steal 0" mode))
  ;; Modes D(13), E(14), F(15): 40 bytes.
  (dolist (mode '(13 14 15))
    (is (= 40 (atari800-cl.antic:playfield-dma-cycles mode 2 t))
        "mode ~D first line normal: expected 40" mode)
    (is (zerop (atari800-cl.antic:playfield-dma-cycles mode 2 nil))
        "mode ~D later line: line buffer replay must steal 0" mode)))

(test playfield-dma-cycles-map-modes-narrow-and-wide
  "Map modes scale their first-line fetch by width like character modes
(narrow = 4/5, wide = 6/5 of normal)."
  (is (= 8  (atari800-cl.antic:playfield-dma-cycles 8 1 t))  "mode 8 narrow")
  (is (= 12 (atari800-cl.antic:playfield-dma-cycles 8 3 t))  "mode 8 wide")
  (is (= 32 (atari800-cl.antic:playfield-dma-cycles 13 1 t)) "mode D narrow")
  (is (= 48 (atari800-cl.antic:playfield-dma-cycles 13 3 t)) "mode D wide")
  ;; Width never matters on buffered-replay lines.
  (is (zerop (atari800-cl.antic:playfield-dma-cycles 8 3 nil)))
  (is (zerop (atari800-cl.antic:playfield-dma-cycles 13 1 nil))))

(test bytes-per-screen-row-hardware-table
  "BYTES-PER-SCREEN-ROW returns the real-hardware bytes per mode line:
each mode's logical-pixel width times bits per pixel, divided by 8."
  (dolist (spec '((2 40) (3 40) (4 40) (5 40)
                  (6 20) (7 20)
                  (8 10) (9 10)
                  (10 20) (11 20) (12 20)
                  (13 40) (14 40) (15 40)))
    (destructuring-bind (mode expected) spec
      (is (= expected (atari800-cl.antic:bytes-per-screen-row mode))
          "mode ~D: expected ~D bytes" mode expected))))

(test map-mode-line-buffer-holds-screen-pointer-across-mode-line
  "A multi-scanline map mode (mode 8, 8 scanlines) keeps
RENDER-SCREEN-DATA-PTR constant across all scanlines of the mode line
(the line buffer replays the same bytes) and advances SCREEN-DATA-PTR
by exactly BYTES-PER-SCREEN-ROW (10) once the mode line completes."
  (multiple-value-bind (antic cpu bus)
      ;; DL: LMS mode 8 -> screen $5000, then JVB back to the DL.
      (%make-antic-fixture :dl-bytes '(#x48 #x00 #x50   ; mode 8 + LMS $5000
                                       #x41 #x00 #x40)) ; JVB $4000
    ;; Advance to the start of the active region (scanline 8).
    (loop until (= (atari800-cl.antic:antic-scanline antic) 8)
          do (atari800-cl.antic:antic-begin-scanline antic cpu bus)
             (atari800-cl.antic:antic-end-scanline antic))
    ;; Run the mode line's 8 scanlines: the render snapshot must stay at
    ;; $5000 for every one of them.
    (dotimes (y 8)
      (atari800-cl.antic:antic-begin-scanline antic cpu bus)
      (is (= #x5000 (atari800-cl.antic:antic-render-screen-data-ptr antic))
          "scanline ~D of the mode-8 line: render pointer must stay $5000, got $~4,'0X"
          y (atari800-cl.antic:antic-render-screen-data-ptr antic))
      (atari800-cl.antic:antic-end-scanline antic))
    (is (= (+ #x5000 10) (atari800-cl.antic:antic-screen-data-ptr antic))
        "after the mode line, the screen pointer must have advanced by 10 bytes, got $~4,'0X"
        (atari800-cl.antic:antic-screen-data-ptr antic))))

(test playfield-dma-cycles-worst-case-under-114
  "The worst-case total scanline steal (refresh + P/M + DL-fetch +
playfield) must stay under the 114-cycle line budget, or the scheduler
could grant a negative CPU budget for the line."
  ;; Worst case: wide 40-column char mode, first line (NAME+FONT), plus
  ;; a 3-byte DL fetch (LMS) and full P/M DMA (5 cycles).
  (let* ((playfield (atari800-cl.antic:playfield-dma-cycles 2 3 t))  ; 96
         (dl-fetch  3)
         (pm-dma    5)
         (refresh   atari800-cl.antic:+dram-refresh-cycles+)         ; 9
         (worst     (+ playfield dl-fetch pm-dma refresh)))
    (is (< worst 114)
        "worst-case steal ~D must be < 114 (the line's total CPU cycles)"
        worst)))

;;; ---------------------------------------------------------------------------
;;; Display-list parsing

(test dl-fetch-advances-offset-on-active-line
  "Once the scanline reaches the active region, a DL byte gets fetched."
  ;; Plant: blank-line $00 (1 line), then mode-2 char line for many lines.
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dlist-addr #x4000
                           :dl-bytes '(#x70 #x02))   ; 8 blank, then mode 2
    ;; Advance to scanline 8 (active region begins): tick 8 * 114.
    (%tick-scanlines antic cpu bus 8)
    ;; One more cycle-0 tick to trigger the fetch.
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is (= 1 (atari800-cl.antic:antic-dl-offset antic))
        "After entering active region, first DL byte must be consumed")
    (is (= #x70 (atari800-cl.antic:antic-current-mode antic))
        "Latched mode byte must match the first DL byte")))

(test blank-line-instruction-spans-multiple-scanlines-without-dl-refetch
  "A blank-line inst with 8 blanks should stretch over 8 scanlines while DL
offset stays at 1."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dlist-addr #x4000
                           :dl-bytes '(#x70 #x02))   ; 8 blank, then mode 2
    (%tick-scanlines antic cpu bus 8)        ; reach scanline 8 cycle 0
    (atari800-cl.antic:antic-tick antic cpu bus)   ; fetch the blank-line inst
    (is (= 1 (atari800-cl.antic:antic-dl-offset antic)))
    ;; Mode lasts 8 scanlines; we've consumed 1 CPU cycle of scanline 8.
    ;; Tick 7 more full scanlines' worth (798 CPU cycles) — by the end
    ;; we're 1 cycle into scanline 15 (the 8th mode-scanline) with
    ;; the blank-line span still in effect.
    (%tick-n antic cpu bus 798)
    (is (= 1 (atari800-cl.antic:antic-dl-offset antic))
        "DL offset must stay at 1 throughout the blank-line span")
    (is (= #x70 (atari800-cl.antic:antic-current-mode antic)))
    ;; 114 more ticks: cross into scanline 16 and let its cycle-0 event
    ;; run, which fetches the next DL byte ($02).
    (%tick-n antic cpu bus 114)
    (is (= 2 (atari800-cl.antic:antic-dl-offset antic))
        "After the blank ends, the next DL byte gets fetched")
    (is (= #x02 (atari800-cl.antic:antic-current-mode antic)))))

(test jmp-instruction-resets-dl-pointer
  "Mode-1 (JMP) consumes 3 DL bytes and loads the DL pointer."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dlist-addr #x4000
                           :dl-bytes '(#x01 #x00 #x60))  ; JMP $6000
    (%tick-scanlines antic cpu bus 8)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is (= #x6000 (atari800-cl.antic:antic-dlist-pointer antic)))
    (is (zerop (atari800-cl.antic:antic-dl-offset antic)))))

(test jvb-instruction-parks-antic-until-vbi
  "Mode-1 + bit 6 (JVB) sets JVB-WAIT until scanline 248 releases it."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dlist-addr #x4000
                           :dl-bytes '(#x41 #x00 #x60))  ; JVB $6000
    (%tick-scanlines antic cpu bus 8)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is-true (atari800-cl.antic:antic-jvb-wait antic)
             "JVB must arm the JVB-WAIT flag")
    ;; Advance to VBI scanline (248) — ticking 240 more scanlines.
    (%tick-scanlines antic cpu bus 240)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is-false (atari800-cl.antic:antic-jvb-wait antic)
              "VBI must release JVB-WAIT")))

;;; ---------------------------------------------------------------------------
;;; DLI

(test dli-fires-on-last-scanline-of-mode-line
  "A mode byte with bit 7 set + NMIEN bit 7 = NMI on the mode's last line.

DLI fires at cycle 0 of the LAST scanline of the mode (when
mode-scanlines-remaining = 1).  For an 8-line mode starting on
scanline 8, that's cycle 0 of scanline 15."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dlist-addr #x4000
                           :dl-bytes '(#x82)        ; mode 2 + DLI bit
                           :nmien atari800-cl.antic:+nmi-dli+)
    (%tick-scanlines antic cpu bus 8)
    (atari800-cl.antic:antic-tick antic cpu bus)            ; fetch DL
    (is-true (atari800-cl.antic:antic-dli-armed antic))
    (is-false (cpu-pending-nmi cpu) "NMI must not fire on the fetch tick")
    ;; State now (8, 1, remaining=8).  Advance to JUST BEFORE cycle 0 of
    ;; scanline 15: 113 ticks (rest of scanline 8) + 6 full scanlines
    ;; (9-14) = 113 + 6*114 = 797 ticks.  Final state (15, 0, 1) — the
    ;; cycle-0 events of scanline 15 have NOT YET run.
    (%tick-n antic cpu bus 797)
    (is-false (cpu-pending-nmi cpu)
              "NMI must not fire before the last mode-scanline's cycle-0 event")
    ;; One more tick: cycle 0 of scanline 15 with remaining=1 → DLI fires.
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is-true (cpu-pending-nmi cpu)
             "DLI must fire at cycle 0 of the last scanline of the mode line")
    (is-true (not (zerop (logand (atari800-cl.antic:antic-nmist antic)
                                 atari800-cl.antic:+nmi-dli+)))
             "NMIST must record the DLI bit")))

(test dli-respects-nmien-mask
  "When NMIEN bit 7 is clear, the DLI doesn't raise NMI even if armed."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dlist-addr #x4000
                           :dl-bytes '(#x82)
                           :nmien 0)         ; NMIEN disabled
    (%tick-scanlines antic cpu bus 8)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (%tick-n antic cpu bus 797)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is-false (cpu-pending-nmi cpu)
              "CPU must NOT see an NMI when NMIEN bit 7 is clear")
    ;; NMIST still latches the event regardless of NMIEN.
    (is-true (not (zerop (logand (atari800-cl.antic:antic-nmist antic)
                                 atari800-cl.antic:+nmi-dli+)))
             "NMIST latches the event regardless of NMIEN")))

;;; ---------------------------------------------------------------------------
;;; VBI

(test vbi-fires-on-scanline-248-when-enabled
  "On entry to scanline 248, NMIEN bit 6 set must raise NMI."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0 :nmien atari800-cl.antic:+nmi-vbi+)
    (%tick-scanlines antic cpu bus 248)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is-true (cpu-pending-nmi cpu) "VBI must raise CPU-PENDING-NMI")
    (is-true (not (zerop (logand (atari800-cl.antic:antic-nmist antic)
                                 atari800-cl.antic:+nmi-vbi+))))))

(test vbi-suppressed-without-nmien
  "VBI doesn't raise CPU NMI when NMIEN bit 6 is clear (but still latches)."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0 :nmien 0)
    (%tick-scanlines antic cpu bus 248)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is-false (cpu-pending-nmi cpu))
    (is-true (not (zerop (logand (atari800-cl.antic:antic-nmist antic)
                                 atari800-cl.antic:+nmi-vbi+))))))

(test nmires-write-clears-nmist
  "Writing $D40F (NMIRES) resets NMIST to zero."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0 :nmien atari800-cl.antic:+nmi-vbi+)
    (%tick-scanlines antic cpu bus 248)
    (atari800-cl.antic:antic-tick antic cpu bus)
    (is (not (zerop (atari800-cl.antic:antic-nmist antic))))
    (atari800-cl.bus:bus-write bus #xD40F 0)
    (is (zerop (atari800-cl.antic:antic-nmist antic)))))

;;; ---------------------------------------------------------------------------
;;; Register access via the bus

(test antic-register-write-via-bus-updates-shadow
  "Writing $D400 updates the DMACTL shadow."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0)
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD400 #x3F)
    (is (= #x3F (atari800-cl.antic:antic-dmactl antic)))))

;;; ---------------------------------------------------------------------------
;;; WSYNC ($D40A)

(test wsync-write-arms-pending-flag
  "Writing $D40A sets WSYNC-PENDING."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0)
    (declare (ignore cpu))
    (is-false (atari800-cl.antic:antic-wsync-pending antic))
    (atari800-cl.bus:bus-write bus #xD40A #x00)
    (is-true (atari800-cl.antic:antic-wsync-pending antic))))

(test antic-consume-wsync-reads-and-clears
  "ANTIC-CONSUME-WSYNC returns the old value, then NIL on the next call."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0)
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD40A #x00)
    (is-true (atari800-cl.antic:antic-consume-wsync antic))
    (is-false (atari800-cl.antic:antic-wsync-pending antic))
    (is-false (atari800-cl.antic:antic-consume-wsync antic))))

(test reset-antic-clears-wsync-pending
  "RESET-ANTIC clears a pending WSYNC flag."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0)
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD40A #x00)
    (atari800-cl.antic:reset-antic antic)
    (is-false (atari800-cl.antic:antic-wsync-pending antic))))

(test vcount-read-returns-scanline-shifted-right
  "Reading $D40B returns scanline >> 1."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0)
    (declare (ignore cpu))
    (%tick-scanlines antic nil bus 50)
    (is (= 25 (atari800-cl.bus:bus-read bus #xD40B)))))

(test unbacked-register-offsets-float-to-ff
  "$D406 and $D408 have no backing ANTIC register (only 4 offset bits are
decoded, mirrored every 16 bytes) and read as $FF regardless of any
earlier write -- CONFIRMED (ROADMAP.md Phase 24) against Acid800's
antic_default test, which asserts exactly this for $D406."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl 0)
    (declare (ignore cpu))
    (is (= #xFF (atari800-cl.bus:bus-read bus #xD406)))
    (is (= #xFF (atari800-cl.bus:bus-read bus #xD408)))
    (atari800-cl.bus:bus-write bus #xD406 #x42)
    (is (= #xFF (atari800-cl.bus:bus-read bus #xD406))
        "a write must not make the unbacked offset stick")))

;;; ---------------------------------------------------------------------------
;;; P/M graphics DMA (ROADMAP.md Phase 6a)
;;;
;;; ANTIC fetches one byte per enabled object per scanline from P/M RAM
;;; (PMBASE) and delivers it through PM-WRITE-FN (players 0-3, missiles
;;; as object 4).  The GRACTL receive gate lives in the machine-wired
;;; closure and is tested at machine level in tests/test-gtia.lisp.

(defun %pm-fetch-calls (antic &key scanline)
  "Set ANTIC's scanline, capture one ANTIC-BEGIN-SCANLINE's PM-WRITE-FN
deliveries, and return them as an alist of (object . byte)."
  (let ((calls '()))
    (setf (atari800-cl.antic:antic-pm-write-fn antic)
          (lambda (obj byte) (push (cons obj byte) calls)))
    (setf (atari800-cl.antic:antic-scanline antic) scanline)
    (atari800-cl.antic:antic-begin-scanline antic nil nil)
    calls))

(test pm-dma-single-line-addressing
  "Single-line resolution (DMACTL bit 4): base = (PMBASE & #xF8) << 8;
missiles at base+$300+scanline, player p at base+$400+$100*p+scanline."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl #x1C)    ; players + missiles + single-line
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD407 #x38)          ; PMBASE -> base $3800
    ;; Scanline 20: missile byte and four distinct player bytes.
    (atari800-cl.bus:bus-poke-ram bus (+ #x3800 #x300 20) #xAA)
    (dotimes (p 4)
      (atari800-cl.bus:bus-poke-ram bus (+ #x3800 #x400 (* #x100 p) 20)
                                    (+ #x10 p)))
    (let ((calls (%pm-fetch-calls antic :scanline 20)))
      (is (= #xAA (cdr (assoc 4 calls))) "missile byte from base+$300+20")
      (dotimes (p 4)
        (is (= (+ #x10 p) (cdr (assoc p calls)))
            "player ~D byte from base+$400+$100*~D+20" p p)))))

(test pm-dma-double-line-addressing
  "Double-line resolution (DMACTL bit 4 clear): base = (PMBASE & #xFC) << 8
(1K boundary — bit 2 participates, unlike single-line); missiles at
base+$180+(scanline>>1), player p at base+$200+$80*p+(scanline>>1)."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl #x0C)    ; players + missiles, double-line
    (declare (ignore cpu))
    ;; PMBASE $34: bit 2 is set, so the double-line base is $3400 — a
    ;; single-line-style #xF8 mask would wrongly give $3000.
    (atari800-cl.bus:bus-write bus #xD407 #x34)          ; PMBASE -> base $3400
    ;; Scanline 21 -> index 10.
    (atari800-cl.bus:bus-poke-ram bus (+ #x3400 #x180 10) #xBB)
    (atari800-cl.bus:bus-poke-ram bus (+ #x3400 #x200 (* #x80 2) 10) #xC2)
    (let ((calls (%pm-fetch-calls antic :scanline 21)))
      (is (= #xBB (cdr (assoc 4 calls))) "missile byte from base+$180+10")
      (is (= #xC2 (cdr (assoc 2 calls))) "player 2 byte from base+$200+$100+10"))))

(test pm-dma-only-enabled-objects-fetch
  "DMACTL bit 3 alone fetches players only; bit 2 alone missiles only."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl #x08)    ; players only
    (declare (ignore cpu bus))
    (let ((calls (%pm-fetch-calls antic :scanline 30)))
      (is (null (assoc 4 calls)) "no missile fetch without DMACTL bit 2")
      (is (assoc 0 calls) "player fetch with DMACTL bit 3")))
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl #x04)    ; missiles only
    (declare (ignore cpu bus))
    (let ((calls (%pm-fetch-calls antic :scanline 30)))
      (is (assoc 4 calls) "missile fetch with DMACTL bit 2")
      (is (null (assoc 0 calls)) "no player fetch without DMACTL bit 3"))))

(test pm-dma-fetches-only-in-visible-region
  "No P/M delivery outside scanlines 8-247."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dmactl #x0C)
    (declare (ignore cpu bus))
    (is (null (%pm-fetch-calls antic :scanline 2))
        "no fetch before the active region")
    (is (null (%pm-fetch-calls antic :scanline 250))
        "no fetch during VBLANK")))

;;; ---------------------------------------------------------------------------
;;; ANTIC-COLLECT-WATCHED-PAGES (ROADMAP.md Phase 29c)

(defun %make-watched-out-vector ()
  "Return a fresh 256-entry zeroed OUT-VECTOR for
ANTIC-COLLECT-WATCHED-PAGES."
  (make-array 256 :element-type '(unsigned-byte 8) :initial-element 0))

(defun %watched-pages (out-vector)
  "Return the sorted list of page numbers OUT-VECTOR has marked (1)."
  (loop for page from 0 below 256
        when (= 1 (aref out-vector page))
          collect page))

(test watched-pages-24-line-mode-2-display-list
  "The bench.lisp %SETUP-DISPLAY-WORKLOAD shape: DL at $4000 (mode 2 +
LMS -> $5000, 23 more mode-2 lines, JVB back to $4000), CHBASE $60.
Expected: DL page $40; screen pages $50-$53 (24 rows x 40 cols = 960
bytes, $5000-$53BF); charset window $60-$61 (mode 2 is a 64-glyph mode,
512-byte window at CHBASE*256); no P/M pages (DMACTL has neither bit
set)."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture
       :dl-bytes (append '(#x42 #x00 #x50)              ; mode 2 + LMS $5000
                          (make-list 23 :initial-element #x02)
                          '(#x41 #x00 #x40))             ; JVB -> $4000
       :dmactl #x22)
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD409 #x60)          ; CHBASE
    (let ((out (%make-watched-out-vector)))
      (is-true (atari800-cl.antic:antic-collect-watched-pages antic bus out))
      (is (equal '(#x40 #x50 #x51 #x52 #x53 #x60 #x61)
                 (%watched-pages out))))))

(test watched-pages-lms-mid-list-marks-two-screen-regions
  "Two LMS mode-8 (map mode, no charset) lines pointing at different
screen addresses must both show up, each in its own page, plus the DL's
own page -- and nothing else (no charset window, since mode 8 is a
bitmap mode; no P/M window, since DMACTL has no missile/player bits)."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture
       :dl-bytes '(#x48 #x00 #x60          ; mode 8 + LMS $6000 (region A)
                   #x48 #x00 #x70          ; mode 8 + LMS $7000 (region B)
                   #x41 #x00 #x40)         ; JVB -> $4000
       :dmactl #x22)
    (declare (ignore cpu))
    (let ((out (%make-watched-out-vector)))
      (is-true (atari800-cl.antic:antic-collect-watched-pages antic bus out))
      (is (equal '(#x40 #x60 #x70) (%watched-pages out))))))

(test watched-pages-pm-dma-window-tracks-enable-and-resolution
  "PMBASE window is marked only when DMACTL enables missile and/or
player DMA, sized by the single-line/double-line resolution bit."
  ;; Single-line (bit 4 set): 8 pages (2K) from PMBASE & $F8.
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dl-bytes '(#x41 #x00 #x40)    ; lone JVB -> self
                            :dmactl #x3C)                  ; missile+player+hires+DL
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD407 #x38)            ; PMBASE
    (let ((out (%make-watched-out-vector)))
      (is-true (atari800-cl.antic:antic-collect-watched-pages antic bus out))
      (is (equal '(#x38 #x39 #x3A #x3B #x3C #x3D #x3E #x3F #x40)
                 (%watched-pages out))
          "DL page $40 plus the 8-page single-line PMBASE window at $38")))
  ;; Double-line (bit 4 clear): 4 pages (1K) from PMBASE & $FC.
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dl-bytes '(#x41 #x00 #x40)
                            :dmactl #x2C)                  ; missile+player, no hires
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD407 #x34)            ; PMBASE
    (let ((out (%make-watched-out-vector)))
      (is-true (atari800-cl.antic:antic-collect-watched-pages antic bus out))
      (is (equal '(#x34 #x35 #x36 #x37 #x40) (%watched-pages out))
          "DL page $40 plus the 4-page double-line PMBASE window at $34")))
  ;; Disabled: DMACTL has neither missile nor player bit -> no PM pages.
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dl-bytes '(#x41 #x00 #x40)
                            :dmactl #x20)                  ; DL fetch only
    (declare (ignore cpu))
    (atari800-cl.bus:bus-write bus #xD407 #x38)            ; PMBASE (ignored)
    (let ((out (%make-watched-out-vector)))
      (is-true (atari800-cl.antic:antic-collect-watched-pages antic bus out))
      (is (equal '(#x40) (%watched-pages out))
          "no PM window when DMACTL enables neither missile nor player DMA"))))

(test watched-pages-runaway-jmp-returns-nil
  "A plain JMP (bit 6 clear -- not JVB) back to itself never reaches a
terminator; the walk must give up and return NIL once
+WATCHED-PAGES-MAX-DL-ENTRIES+ is exceeded, rather than looping forever."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dl-bytes '(#x01 #x00 #x40)    ; JMP -> $4000 (itself)
                            :dmactl #x22)
    (declare (ignore cpu))
    (let ((out (%make-watched-out-vector)))
      (is (null (atari800-cl.antic:antic-collect-watched-pages antic bus out))))))

(test watched-pages-dl-in-io-range-returns-nil
  "A display-list pointer landing in $D000-$D7FF must never be read
through the bus (register reads can have side effects); the walk
returns NIL instead of guessing."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dlist-addr #xD040 :dmactl #x22)
    (declare (ignore cpu))
    (let ((out (%make-watched-out-vector)))
      (is (null (atari800-cl.antic:antic-collect-watched-pages antic bus out))))))

(test watched-pages-dmactl-zero-returns-t-with-empty-set
  "With DMACTL entirely zero, ANTIC fetches no display list at all
(matching %DISPLAY-ACTIVE-P); the analysis is trivially trustworthy and
OUT-VECTOR stays all zero."
  (multiple-value-bind (antic cpu bus)
      (%make-antic-fixture :dl-bytes '(#x42 #x00 #x50) :dmactl 0)
    (declare (ignore cpu))
    (let ((out (%make-watched-out-vector)))
      (is-true (atari800-cl.antic:antic-collect-watched-pages antic bus out))
      (is (null (%watched-pages out))))))
