;;;; src/antic.lisp --- ANTIC display-list + DMA engine (NTSC).
;;;;
;;;; The Atari 800 XL's ANTIC chip is a dedicated DMA controller for
;;;; the display.  It walks a "display list" — a small program in main
;;;; memory that tells ANTIC, line by line, what to fetch and display.
;;;; While ANTIC is fetching, it steals CPU cycles on the shared bus.
;;;;
;;;; Timing model (NTSC):
;;;;   262 scanlines / frame
;;;;   114 CPU cycles / scanline   (a real NTSC line is 228 color clocks;
;;;;                                the color clock runs at twice the CPU
;;;;                                rate, so 114 CPU cycles per line is
;;;;                                the correct unit — hardware docs quote
;;;;                                cycle positions 0-113 within a line)
;;;;   scanlines 8-247  — active display region
;;;;   scanline 248     — VBLANK begins; VBI fires here when NMIEN bit 6 set
;;;;
;;;; Cycle-stealing accounting (ROADMAP.md Phase 5 / SCANLINE_ACCURACY_PLAN.md
;;;; Phase 3): we lump all the per-line steals at CPU cycle 0 of each
;;;; scanline, returning that lump from ANTIC-TICK / ANTIC-BEGIN-SCANLINE
;;;; so the machine scheduler can deduct them from the CPU's budget for
;;;; the line.  Four components, summed:
;;;;   - DRAM refresh: +DRAM-REFRESH-CYCLES+ (9), every scanline.
;;;;   - P/M DMA: PM-DMA-CYCLES, every scanline (missile +1, player +4).
;;;;   - DL instruction fetch: 1 cycle per DL byte read (mode byte, +2
;;;;     for an LMS address, +2 for a JMP/JVB address) -- only on the
;;;;     scanline that starts a new mode line.
;;;;   - Playfield data: PLAYFIELD-DMA-CYCLES -- character modes (2-7)
;;;;     fetch NAME bytes (screen memory) on the first scanline of the
;;;;     mode line only (ANTIC line-buffers them) plus FONT bytes
;;;;     (character ROM/RAM lookups) every scanline; map modes (8-F)
;;;;     fetch their screen bytes on the first scanline of the mode
;;;;     line only, and ANTIC's internal line buffer replays them on
;;;;     the remaining scanlines.  See PLAYFIELD-DMA-CYCLES's docstring
;;;;     for the byte-count table (BYTES-PER-SCREEN-ROW).
;;;; Steal cost is 1 CPU cycle per byte fetched, which is what real
;;;; ANTIC charges (each DMA slot transfers one byte).  Still out of
;;;; scope: HSCROL widening the fetch window and the exact cycle
;;;; POSITIONS of each steal within the line -- everything is lumped at
;;;; cycle 0 (SCANLINE_ACCURACY_PLAN.md Phase 4).
;;;;
;;;; Display-list parsing supports:
;;;;   mode 0 (blank lines)  — bits 4-6 specify (N+1) scanlines of blank
;;;;   mode 1 (JMP / JVB)    — bit 6 = JVB (wait for VBLANK after jump);
;;;;                            next two bytes are the new DL address
;;;;   modes 2-F             — character / graphics modes with a known
;;;;                            number of scanlines per mode line
;;;;   bit 7 (DLI)           — fire NMI on the LAST scanline of this mode
;;;;                            line (gated by NMIEN bit 7)
;;;;   bit 6 (LMS on modes 2-F) — next two bytes are a screen-data base
;;;;                              address, latched for the renderer.

(in-package #:atari800-cl.antic)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  See the
;;; matching declaim in src/bus.lisp for the note on DECLAIM's proclaiming
;;; behaviour under :serial t; repeated here so this file's policy survives
;;; interactive recompilation on its own.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; NTSC timing constants
;;;
;;; Wrapped in EVAL-WHEN so the register-offset constants below have values at
;;; compile time.  ANTIC-READ/ANTIC-WRITE use them as CASE keys via the `#.`
;;; read-time-eval reader macro, which requires the value to exist while the
;;; file is being compiled.  SBCL evaluates DEFCONSTANT's value form at compile
;;; time anyway, but LispWorks does not guarantee this, so make it explicit.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +scanlines-per-frame+        262)
  (defconstant +cpu-cycles-per-scanline+    114)
  (defconstant +active-start-scanline+      8)
  (defconstant +vbi-scanline+               248)
  (defconstant +dram-refresh-cycles+        9)

  ;; ANTIC register offsets (within the 32-byte register file).
  (defconstant +reg-dmactl+  #x00)
  (defconstant +reg-chactl+  #x01)
  (defconstant +reg-dlistl+  #x02)
  (defconstant +reg-dlisth+  #x03)
  (defconstant +reg-hscrol+  #x04)
  (defconstant +reg-vscrol+  #x05)
  (defconstant +reg-pmbase+  #x07)
  (defconstant +reg-chbase+  #x09)
  (defconstant +reg-wsync+   #x0A)
  (defconstant +reg-vcount+  #x0B)
  (defconstant +reg-penh+    #x0C)
  (defconstant +reg-penv+    #x0D)
  (defconstant +reg-nmien+   #x0E)
  (defconstant +reg-nmires+  #x0F)

  ;; Offsets $06 and $08 have no backing register on real ANTIC (the chip
  ;; only decodes 4 offset bits, mirrored every 16 bytes across $D400-
  ;; $D4FF): a read there returns a floating-bus $FF rather than any
  ;; latched value.  CONFIRMED (ROADMAP.md Phase 24) against Acid800's
  ;; antic_default test, which asserts exactly $D406 reads $FF.
  (defconstant +reg-unused-6+ #x06)
  (defconstant +reg-unused-8+ #x08)

  ;; NMI status bits — also the masks used in NMIEN.
  (defconstant +nmi-dli+    #x80)
  (defconstant +nmi-vbi+    #x40)
  (defconstant +nmi-reset+  #x20)

  ;; DMACTL bits.
  (defconstant +dmactl-playfield-mask+ #x03)   ; 00=off, 01=narrow, 10=normal, 11=wide
  (defconstant +dmactl-missile-mask+   #x04)
  (defconstant +dmactl-player-mask+    #x08)
  (defconstant +dmactl-pm-hires-mask+  #x10)   ; bit 4: 1=single-line, 0=double-line P/M
  (defconstant +dmactl-instructions+   #x20))  ; bit 5: DL fetching enabled

;;; ---------------------------------------------------------------------------
;;; ANTIC struct

(defstruct antic
  "ANTIC state.

Slots:
  REGISTERS                 — 32-byte register file (raw shadow store).
  DLIST-POINTER             — current display-list address (latched from
                              DLISTL/DLISTH; updated by JMP/JVB).
  DL-OFFSET                 — bytes consumed within the current DL since
                              DLIST-POINTER was last latched.
  SCANLINE                  — vertical line counter, 0-261.
  LINE-CYCLE                — horizontal counter, 0-113 CPU cycles within
                              the current scanline (a real NTSC line is
                              228 color clocks at twice the CPU rate).
  DMACTL                    — shadow of register $D400 (DMA enables).
  NMIEN                     — shadow of register $D40E (NMI enables).
  NMIST                     — NMI status latch (bits 6/7 = VBI/DLI pending).
  CURRENT-MODE              — DL instruction byte currently in flight.
  MODE-SCANLINES-REMAINING  — scanlines left in the current mode line.
  DLI-ARMED                 — T if the current mode line had DLI bit set.
  JVB-WAIT                  — T after a JVB instruction; cleared at VBI.
  FRAME-COUNT               — frames elapsed since reset (debug counter).
  STOLEN-CYCLES             — running total of cycles ANTIC has stolen.
  WSYNC-PENDING             — T after a write to $D40A (WSYNC); consumed
                              (read-and-cleared) by the machine scheduler's
                              per-instruction check, which stalls the CPU
                              to the end of the current scanline.  Only
                              meaningful to the ANTIC-BEGIN-SCANLINE /
                              ANTIC-END-SCANLINE scheduler path — the
                              per-cycle ANTIC-TICK reference path does not
                              consume it.
  PM-WRITE-FN               — NIL, or a function (OBJECT BYTE) that receives
                              the P/M graphics bytes ANTIC fetches each
                              scanline when DMACTL bits 2/3 enable P/M DMA.
                              OBJECT is 0-3 for players, 4 for the missile
                              byte.  MAKE-ATARI-MACHINE wires this to a
                              closure that stores into the GTIA's GRAFP0-3/
                              GRAFM write registers, gated on GRACTL —
                              chips never reference each other's packages
                              directly (see the bus design in CLAUDE.md).
  CPU                       — CPU back-pointer for NMI routing.
  BUS                       — bus back-pointer (currently unused in tick)."
  (registers (make-array 32 :element-type '(unsigned-byte 8)
                            :initial-element 0)
             :type (simple-array (unsigned-byte 8) (32)))
  (dlist-pointer 0 :type (unsigned-byte 16))
  ;; FIXNUM rather than (UNSIGNED-BYTE 16): DL-OFFSET only resets to 0 on a
  ;; JMP/JVB instruction or a fresh DL latch; a malformed display list that
  ;; never contains one lets it grow past 65535 (INCF by 1 or 2 per DL byte
  ;; consumed, unbounded across scanlines).  %DL-CURRENT-ADDRESS already
  ;; masks the derived bus address with (LDB (BYTE 16 0) ...), so the raw
  ;; offset itself never needs to stay within 16 bits — fixnum avoids a
  ;; spurious type error (or, at (safety 1)(speed 3), UB) on overflow
  ;; without changing modelled behaviour for any well-formed DL.
  (dl-offset     0 :type fixnum)
  (scanline      0 :type (unsigned-byte 9))
  (line-cycle    0 :type (unsigned-byte 8))
  (dmactl        0 :type (unsigned-byte 8))
  (nmien         0 :type (unsigned-byte 8))
  (nmist         0 :type (unsigned-byte 8))
  (current-mode  0 :type (unsigned-byte 8))
  (mode-scanlines-remaining 0 :type fixnum)
  (dli-armed     nil :type boolean)
  (jvb-wait      nil :type boolean)
  (frame-count   0 :type fixnum)
  (stolen-cycles 0 :type fixnum)
  (wsync-pending nil :type boolean)
  (pm-write-fn nil :type (or null function))
  (cpu nil)
  (bus nil)
  ;; Rendering support --------------------------------------------------------
  ;; SCREEN-DATA-PTR: base address in screen RAM for the current mode line.
  ;; Set by the LMS modifier; advances after each char row (char modes) or
  ;; every scanline (bitmap modes).
  (screen-data-ptr        0 :type (unsigned-byte 16))
  ;; RENDER-SCREEN-DATA-PTR: snapshot of SCREEN-DATA-PTR taken at CPU cycle
  ;; 0 of each scanline, before any end-of-line advancement.  The renderer
  ;; reads this to avoid an off-by-one on the first scanline of bitmap modes.
  (render-screen-data-ptr 0 :type (unsigned-byte 16))
  ;; SCAN-Y: 0-based row index within the current mode line (for char-ROM
  ;; lookup and bitmap pointer advancement).  Reset to 0 when a new DL
  ;; instruction is fetched; incremented at end of each scanline.
  (scan-y 0 :type (unsigned-byte 8)))

;;; ---------------------------------------------------------------------------
;;; DL parsing helpers

(declaim (inline %dl-current-address))

(defun %dl-current-address (antic)
  "Compute the absolute bus address of the next DL byte to fetch."
  (declare (type antic antic))
  (ldb (byte 16 0) (+ (antic-dlist-pointer antic) (antic-dl-offset antic))))

(defun mode-line-scanlines (mode-byte)
  "Return the number of scanlines a display-list mode line occupies."
  (declare (type (unsigned-byte 8) mode-byte))
  (let ((mode (ldb (byte 4 0) mode-byte)))
    (case mode
      (0  (1+ (ldb (byte 3 4) mode-byte)))        ; mode 0: (N+1) blank lines
      (1  0)                                       ; JMP / JVB
      ((2 4 6 8) 8)
      (3  10)
      ((5 7) 16)
      ((9 10) 4)
      ((11 13) 2)
      ((12 14 15) 1)
      (t 1))))

(defun pm-dma-cycles (dmactl)
  "Per-scanline cycles stolen by P/M DMA given DMACTL.
Bit 2 enables 1-cycle missile DMA; bit 3 enables 4-cycle player DMA."
  (declare (type (unsigned-byte 8) dmactl))
  (+ (if (logtest dmactl +dmactl-missile-mask+) 1 0)
     (if (logtest dmactl +dmactl-player-mask+)  4 0)))

(declaim (inline %scanline-steal))

(defun %scanline-steal (antic)
  "Cycles ANTIC steals on the current scanline (DRAM refresh + P/M DMA)."
  (declare (type antic antic))
  (+ +dram-refresh-cycles+
     (pm-dma-cycles (antic-dmactl antic))))

(defun bytes-per-screen-row (mode)
  "Return the number of screen-RAM bytes one mode line of the given ANTIC
mode nibble consumes at NORMAL playfield width.  For character modes
this is the NAME bytes per character row; for map modes it is the
screen bytes per mode line (fetched on the mode line's first scanline
and replayed from ANTIC's line buffer on the rest).

These are the real-hardware values — each mode's playfield width in
logical pixels times its bits per pixel, divided by 8 (Altirra Hardware
Reference Manual; also the SCANLINE_ACCURACY_PLAN.md Phase 3 table):
  modes 2-5:  40 chars                    → 40 bytes
  modes 6-7:  20 chars                    → 20 bytes
  mode  8:    40 px  2bpp, mode 9: 80 px 1bpp → 10 bytes
  mode  A:    80 px  2bpp, modes B/C: 160 px 1bpp → 20 bytes
  modes D/E: 160 px  2bpp, mode F: 320 px 1bpp → 40 bytes

The renderer (%RENDER-BITMAP-MODE) and the DMA-steal accounting
(PLAYFIELD-DMA-CYCLES) both derive from this table, and
%END-SCANLINE-EVENTS advances SCREEN-DATA-PTR by exactly this many
bytes at the end of each mode line — the three consumers cannot
disagree."
  (declare (type (unsigned-byte 8) mode))
  (case mode
    ((2 3 4 5)   40)
    ((6 7)       20)
    ((8 9)       10)
    ((10 11 12)  20)
    ((13 14 15)  40)
    (t           40)))

(defun playfield-dma-cycles (mode-byte dmactl first-line-p)
  "Return the CPU cycles ANTIC steals THIS scanline for playfield data —
character NAME/FONT bytes for modes 2-7, or a mode line's screen bytes
for map modes 8-F — given the DL MODE-BYTE currently in flight,
DMACTL (bits 0-1 select narrow/normal/wide), and whether this is the
first scanline of the current mode line (see ANTIC-SCAN-Y).

Byte counts come from BYTES-PER-SCREEN-ROW (the real-hardware table —
see its docstring for provenance); narrow width charges 4/5 of the
normal count and wide 6/5 (e.g. modes 2-5: 32/40/48, modes 8-9:
8/10/12), matching the SCANLINE_ACCURACY_PLAN.md Phase 3 table.

Fetch timing (Altirra Hardware Reference Manual):
  - Mode 0 (blank) and mode 1 (JMP/JVB) steal nothing (blank lines
    have no playfield; JMP/JVB doesn't display).
  - Character modes (2-7): on FIRST-LINE-P, ANTIC fetches NAME bytes
    (once per mode line, line-buffered for the remaining scanlines)
    *and* FONT bytes (every scanline) — double the byte count.  On
    later scanlines, only the FONT fetch happens — single byte count.
  - Map modes (8-F): screen bytes are fetched on FIRST-LINE-P only;
    ANTIC's line buffer replays them on the mode line's remaining
    scanlines, stealing nothing.

Steal cost is 1 CPU cycle per fetched byte, as on real hardware (each
ANTIC DMA slot transfers one byte)."
  (declare (type (unsigned-byte 8) mode-byte dmactl))
  (let ((mode (ldb (byte 4 0) mode-byte)))
    (declare (type (unsigned-byte 4) mode))
    (if (or (< mode 2)
            (and (>= mode 8) (not first-line-p)))   ; map modes: buffered replay
        0
        (let* ((normal (bytes-per-screen-row mode))
               (width  (ldb (byte 2 0) dmactl))
               (bytes  (case width
                          (0 0)                            ; DMA off
                          (1 (truncate (* normal 4) 5))     ; narrow (0.8x)
                          (2 normal)                        ; normal
                          (t (truncate (* normal 6) 5)))))  ; wide (1.2x)
          (declare (type fixnum normal bytes))
          (if (and (<= mode 7) first-line-p)
              (* bytes 2)   ; character modes, first line: NAME + FONT
              bytes)))))    ; char modes later lines (FONT), or map first line

(defun process-dl-instruction (antic)
  "Fetch one display-list instruction from the bus and update ANTIC.
Returns the number of DL bytes consumed by this instruction (1 for a
plain mode byte, 3 for JMP/JVB or any inst with the LMS bit set, etc.)
so the caller can charge it into the line's DMA steal."
  (declare (type antic antic))
  (let* ((bus  (antic-bus antic))
         (inst (atari800-cl.bus:bus-read bus (%dl-current-address antic)))
         (mode (ldb (byte 4 0) inst))
         (lms-p (and (logtest inst #x40) (>= mode 2)))
         (dli-p (logtest inst #x80))
         (bytes-consumed 1))
    (declare (type fixnum bytes-consumed))
    (incf (antic-dl-offset antic))
    (setf (antic-current-mode antic) inst
          (antic-dli-armed antic) dli-p)
    (cond
      ((= mode 1)
       ;; JMP / JVB.  Read two bytes for the new DL address, then either
       ;; jump immediately (JMP) or wait for VBLANK (JVB, bit 6).
       (let ((lo (atari800-cl.bus:bus-read bus (%dl-current-address antic))))
         (incf (antic-dl-offset antic))
         (let ((hi (atari800-cl.bus:bus-read bus (%dl-current-address antic))))
           (incf (antic-dl-offset antic))
           (incf bytes-consumed 2)
           (setf (antic-dlist-pointer antic) (dpb hi (byte 8 8) lo)
                 (antic-dl-offset antic) 0
                 (antic-mode-scanlines-remaining antic) 0)
           (when (logtest inst #x40)
             (setf (antic-jvb-wait antic) t)))))
      (t
       (when lms-p
         ;; Read the two-byte LMS address (lo then hi) and latch it into
         ;; SCREEN-DATA-PTR so the renderer knows where screen RAM starts.
         (let* ((lo (atari800-cl.bus:bus-read bus (%dl-current-address antic))))
           (incf (antic-dl-offset antic))
           (let ((hi (atari800-cl.bus:bus-read bus (%dl-current-address antic))))
             (incf (antic-dl-offset antic))
             (incf bytes-consumed 2)
             (setf (antic-screen-data-ptr antic)
                   (dpb hi (byte 8 8) lo)))))
       (setf (antic-mode-scanlines-remaining antic)
             (mode-line-scanlines inst)
             (antic-scan-y antic) 0)))
    bytes-consumed))

(declaim (inline %display-active-p))

(defun %display-active-p (antic)
  "Return T if ANTIC should be fetching DL bytes on the current scanline."
  (declare (type antic antic))
  (let ((s (antic-scanline antic)))
    (and (>= s +active-start-scanline+)
         (<  s +vbi-scanline+)
         (not (zerop (antic-dmactl antic))))))

;;; ---------------------------------------------------------------------------
;;; P/M graphics DMA (ROADMAP.md Phase 6a)

(defun %fetch-pm-graphics (antic)
  "Fetch this scanline's player/missile graphics bytes from P/M RAM and
deliver them through PM-WRITE-FN (players as objects 0-3, the combined
missile byte as object 4).  A no-op unless PM-WRITE-FN is wired and
DMACTL enables player (bit 3) and/or missile (bit 2) DMA.

Addressing (Altirra Hardware Reference Manual; the plan's from-memory
formula masked PMBASE with #xF8 for both resolutions, but double-line
mode only needs a 1K boundary, so bit 2 participates there):
  single-line (DMACTL bit 4 = 1): base = (PMBASE & #xF8) << 8 (2K boundary)
      missiles at base+$300+scanline, player p at base+$400+$100*p+scanline
  double-line (bit 4 = 0):        base = (PMBASE & #xFC) << 8 (1K boundary)
      missiles at base+$180+(scanline>>1), player p at base+$200+$80*p+(scanline>>1)
Addresses are masked to 16 bits.  Out of scope for now: VDELAY's
one-line delay of double-line objects, and the GRACTL receive gate —
that gate lives in the machine-wired closure, because GRACTL is a GTIA
register (DMACTL only decides whether the cycles are stolen and the
fetch happens; GRACTL decides whether GTIA latches the result)."
  (declare (type antic antic))
  (let ((fn (antic-pm-write-fn antic)))
    (when fn
      (let* ((dmactl     (antic-dmactl antic))
             (players-p  (logtest dmactl +dmactl-player-mask+))
             (missiles-p (logtest dmactl +dmactl-missile-mask+)))
        (when (or players-p missiles-p)
          (let* ((bus      (antic-bus antic))
                 (pmbase   (aref (antic-registers antic) +reg-pmbase+))
                 (single-p (logtest dmactl +dmactl-pm-hires-mask+))
                 (base     (if single-p
                               (ash (logand pmbase #xF8) 8)
                               (ash (logand pmbase #xFC) 8)))
                 (index    (if single-p
                               (logand (antic-scanline antic) #xFF)
                               (logand (ash (antic-scanline antic) -1) #x7F))))
            (declare (type fixnum base index))
            (when missiles-p
              (funcall fn 4
                       (atari800-cl.bus:bus-read
                        bus (ldb (byte 16 0)
                                 (+ base (if single-p #x300 #x180) index)))))
            (when players-p
              (dotimes (p 4)
                (funcall fn p
                         (atari800-cl.bus:bus-read
                          bus (ldb (byte 16 0)
                                   (+ base
                                      (if single-p
                                          (+ #x400 (* #x100 p))
                                          (+ #x200 (* #x80 p)))
                                      index))))))))))))

;;; ---------------------------------------------------------------------------
;;; NMI signalling

(declaim (inline %raise-nmi))

(defun %raise-nmi (antic)
  "Set CPU-PENDING-NMI on the attached CPU (if any)."
  (declare (type antic antic))
  (let ((cpu (antic-cpu antic)))
    (when cpu (setf (cpu-pending-nmi cpu) t))))

;;; ---------------------------------------------------------------------------
;;; Scanline events — the shared line-start / line-end logic
;;;
;;; Two drivers use these helpers: the per-cycle ANTIC-TICK (the original,
;;; heavily-tested reference path) and the scanline-granular
;;; ANTIC-BEGIN-SCANLINE / ANTIC-END-SCANLINE pair the machine scheduler
;;; calls.  Keeping the event logic in ONE place means the two paths
;;; cannot drift apart.

(defun %begin-scanline-events (antic)
  "Line-start work for the current scanline: VBI on entry to line 248
(NMIST latch + NMI when NMIEN bit 6 is set, JVB release, DL pointer
re-latch), display-list instruction fetch when a new mode line is due,
DLI on the last scanline of a mode line, and the lumped per-line cycle
steal (DRAM refresh + P/M DMA + DL-instruction fetch + playfield data;
see the file header and PLAYFIELD-DMA-CYCLES).  Returns the cycles
stolen this line."
  (declare (type antic antic))
  ;; VBI fires on entry to scanline 248.
  (when (= (antic-scanline antic) +vbi-scanline+)
    (setf (antic-nmist antic) (logior (antic-nmist antic) +nmi-vbi+))
    (when (logtest (antic-nmien antic) +nmi-vbi+)
      (%raise-nmi antic))
    ;; A JVB instruction parks ANTIC until VBLANK; we release it now.
    ;;
    ;; SIMPLIFICATION (ROADMAP.md Phase 20, MISC_IMPROVEMENTS_PLAN.md item
    ;; 10): real ANTIC's DLISTL/DLISTH are a plain latch -- the DL program
    ;; counter is loaded from them only when a JVB (JMP with bit 6 set)
    ;; instruction is executed and VBLANK arrives, not on every VBI. This
    ;; emulator instead re-latches the DL pointer from DLISTL/DLISTH
    ;; unconditionally on every VBI, whether or not a JVB was pending (see
    ;; the DLISTL/DLISTH write cases in ANTIC-WRITE below for the other
    ;; half of the same simplification). This is behaviourally
    ;; indistinguishable for OS-standard display lists, which always end
    ;; in JVB and so re-latch to the same address either way, but diverges
    ;; from hardware for a list that never reaches its own JVB before
    ;; VBLANK (e.g. one rewritten mid-frame without a terminating JVB) --
    ;; ACID800-ANTIC-DLISTWRAP exercises exactly this and is a documented,
    ;; not accidental, failure. Changing the behaviour to a true
    ;; JVB-gated latch belongs with SCANLINE_ACCURACY_PLAN.md Phase 4+.
    (setf (antic-jvb-wait antic) nil
          (antic-mode-scanlines-remaining antic) 0
          ;; Re-latch DL pointer from the shadow registers.
          (antic-dlist-pointer antic)
          (dpb (aref (antic-registers antic) +reg-dlisth+) (byte 8 8)
               (aref (antic-registers antic) +reg-dlistl+))
          (antic-dl-offset antic) 0))
  ;; P/M graphics DMA: deliver this line's object bytes to GTIA (via the
  ;; machine-wired PM-WRITE-FN) during the visible region.  The CYCLES
  ;; for P/M DMA are charged by %SCANLINE-STEAL below whenever the
  ;; DMACTL bits are set; this is only the data path.
  (let ((s (antic-scanline antic)))
    (when (and (>= s +active-start-scanline+) (< s +vbi-scanline+))
      (%fetch-pm-graphics antic)))
  ;; If a new mode line is needed, fetch the next DL instruction.  Track
  ;; the bytes it consumed so they can be charged into this line's steal.
  (let ((dl-fetch-bytes 0))
    (declare (type fixnum dl-fetch-bytes))
    (when (and (zerop (antic-mode-scanlines-remaining antic))
               (not (antic-jvb-wait antic))
               (%display-active-p antic))
      (setf dl-fetch-bytes (process-dl-instruction antic)))
    ;; DLI fires on the LAST scanline of the current mode line.  We
    ;; identify "last" by the remaining counter being 1 (it'll
    ;; decrement to 0 when the scanline finishes).
    (when (and (antic-dli-armed antic)
               (= (antic-mode-scanlines-remaining antic) 1))
      (setf (antic-nmist antic) (logior (antic-nmist antic) +nmi-dli+))
      (when (logtest (antic-nmien antic) +nmi-dli+)
        (%raise-nmi antic))
      (setf (antic-dli-armed antic) nil))
    ;; Snapshot the screen-data pointer for the renderer.  This must happen
    ;; AFTER the DL fetch (which may have set SCREEN-DATA-PTR via LMS) and
    ;; BEFORE any end-of-line advancement, so the renderer sees the address
    ;; that is correct for the scanline that is about to be rendered.
    (setf (antic-render-screen-data-ptr antic)
          (antic-screen-data-ptr antic))
    ;; Refresh + P/M DMA + DL-fetch + playfield steals for this line.
    ;; Playfield cycles are gated on %DISPLAY-ACTIVE-P: outside the
    ;; active region (or with DMA fully off) CURRENT-MODE may still hold
    ;; a leftover value from the last active scanline, and it must not
    ;; contribute a steal here.
    (let* ((playfield (if (%display-active-p antic)
                           (playfield-dma-cycles (antic-current-mode antic)
                                                  (antic-dmactl antic)
                                                  (zerop (antic-scan-y antic)))
                           0))
           (stolen (+ (%scanline-steal antic) dl-fetch-bytes playfield)))
      (declare (type fixnum playfield stolen))
      (incf (antic-stolen-cycles antic) stolen)
      stolen)))

(defun %end-scanline-events (antic)
  "End-of-scanline housekeeping: decrement the current mode line's
remaining-scanlines counter, advance the scanline counter, and wrap at
the frame boundary (bumping FRAME-COUNT).  Returns ANTIC."
  (declare (type antic antic))
  (when (plusp (antic-mode-scanlines-remaining antic))
    (decf (antic-mode-scanlines-remaining antic)))
  ;; Advance scan-y and screen-data-ptr for the next scanline.
  ;; Only relevant during the active display region with DMA enabled.
  (when (%display-active-p antic)
    (let* ((inst  (antic-current-mode antic))
           (mode  (ldb (byte 4 0) inst))
           (total (mode-line-scanlines inst))
           (y     (antic-scan-y antic)))
      (when (>= mode 2)
        ;; Advance the screen pointer after the LAST scanline of the mode
        ;; line — character and map modes alike.  A mode line consumes
        ;; BYTES-PER-SCREEN-ROW bytes total, no matter how many scanlines
        ;; it spans: character modes re-read the line-buffered NAMEs and
        ;; map modes replay the line-buffered screen bytes on every
        ;; scanline after the first (single-scanline modes C/E/F advance
        ;; every line, since every line is a last line).
        (when (and (plusp total) (= y (1- total)))
          (setf (antic-screen-data-ptr antic)
                (ldb (byte 16 0)
                     (+ (antic-screen-data-ptr antic)
                        (bytes-per-screen-row mode))))))
        ;; Always increment scan-y (wraps at mode-line boundary).
        (setf (antic-scan-y antic)
              (if (zerop total) 0
                  (mod (1+ y) total)))))
  (incf (antic-scanline antic))
  (when (>= (antic-scanline antic) +scanlines-per-frame+)
    (setf (antic-scanline antic) 0)
    (incf (antic-frame-count antic)))
  antic)

;;; ---------------------------------------------------------------------------
;;; Scanline-granular entry points (SCANLINE_ACCURACY_PLAN.md Phase 1)
;;;
;;; The machine scheduler drives ANTIC one whole scanline at a time:
;;; ANTIC-BEGIN-SCANLINE at the start of each line (returning the cycles
;;; stolen), ANTIC-END-SCANLINE once the line's 114 CPU cycles have been
;;; distributed.  Neither touches the LINE-CYCLE slot — that counter
;;; belongs to the per-cycle ANTIC-TICK path.  Do not interleave the two
;;; APIs on the same ANTIC unless LINE-CYCLE is at 0 (a line boundary).

(declaim (ftype (function (antic (or null cpu) (or null bus)) fixnum)
                antic-begin-scanline))

(defun antic-begin-scanline (antic cpu bus)
  "Perform the line-start events for the current scanline and return the
number of CPU cycles ANTIC steals from it: VBI on entry to line 248,
display-list instruction fetch when a new mode line is due, DLI on the
last scanline of a mode line, and the lumped per-line steal (DRAM
refresh + P/M DMA + DL-instruction fetch + playfield data; see the file
header and PLAYFIELD-DMA-CYCLES).  CPU and BUS (either may be NIL to leave the current
pointer untouched) are cached on the struct so NMI routing and DL
fetches can reach them.  Pair every call with ANTIC-END-SCANLINE once
the line has been executed."
  (declare (type antic antic))
  ;; Cache CPU and bus pointers on the struct so helpers can reach them.
  (when cpu (setf (antic-cpu antic) cpu))
  (when bus (setf (antic-bus antic) bus))
  (%begin-scanline-events antic))

(defun antic-end-scanline (antic)
  "Close the current scanline: decrement the mode line's remaining-lines
counter, advance SCANLINE, and wrap at the frame boundary (bumping
FRAME-COUNT).  Returns ANTIC.  See ANTIC-BEGIN-SCANLINE."
  (declare (type antic antic))
  (%end-scanline-events antic))

;;; ---------------------------------------------------------------------------
;;; Tick — advances one CPU cycle (the single-cycle reference path)

(declaim (ftype (function (antic (or null cpu) (or null bus)) fixnum) antic-tick))

(defun antic-tick (antic cpu bus)
  "Advance ANTIC by one CPU cycle.  Returns the cycles stolen this tick.

The per-scanline steal (DRAM refresh + P/M DMA) is lumped at cycle 0 of
each new scanline; all subsequent ticks within the same scanline return
0.  Display-list parsing, VBI, and DLI events are all serviced at cycle
0 as well.  Built on the same %BEGIN-SCANLINE-EVENTS /
%END-SCANLINE-EVENTS helpers as the scanline-granular API, so the two
paths cannot diverge."
  (declare (type antic antic))
  ;; Cache CPU and bus pointers on the struct so helpers can reach them.
  (when cpu (setf (antic-cpu antic) cpu))
  (when bus (setf (antic-bus antic) bus))
  (let ((stolen 0))
    (when (zerop (antic-line-cycle antic))
      (setf stolen (%begin-scanline-events antic)))
    ;; Advance the line-cycle counter.
    (incf (antic-line-cycle antic))
    (when (>= (antic-line-cycle antic) +cpu-cycles-per-scanline+)
      (setf (antic-line-cycle antic) 0)
      (%end-scanline-events antic))
    stolen))

;;; ---------------------------------------------------------------------------
;;; Register access

(defun antic-read (antic address)
  "Read an ANTIC register.  Special cases:
  $D40B (VCOUNT) — returns SCANLINE >> 1 (ANTIC's vertical-line counter)
  $D40F (NMIST)  — returns the NMI status latch
  $D406, $D408   — unbacked offsets; float to $FF (see the constants'
                   docstring)"
  (declare (type antic antic) (type (unsigned-byte 16) address))
  (let ((offset (ldb (byte 5 0) address)))
    (case offset
      ;; (byte 8 1) grabs bits 1-8 of the 9-bit counter: SCANLINE >> 1.
      (#.+reg-vcount+ (ldb (byte 8 1) (antic-scanline antic)))
      (#.+reg-nmires+ (antic-nmist antic))
      ((#.+reg-unused-6+ #.+reg-unused-8+) #xFF)
      (t (aref (antic-registers antic) offset)))))

(defun antic-write (antic address value)
  "Write an ANTIC register.  DMACTL/DLISTL/DLISTH/NMIEN/NMIRES update
their shadow slots; WSYNC ($D40A, offset $0A, mirrored across the $D4xx
page) arms WSYNC-PENDING; everything else is just latched into the
register file."
  (declare (type antic antic) (type (unsigned-byte 16) address)
           (type (unsigned-byte 8) value))
  (let ((offset (ldb (byte 5 0) address))
        (v (ldb (byte 8 0) value)))
    (setf (aref (antic-registers antic) offset) v)
    (case offset
      (#.+reg-dmactl+ (setf (antic-dmactl antic) v))
      ;; SIMPLIFICATION (ROADMAP.md Phase 20, MISC_IMPROVEMENTS_PLAN.md
      ;; item 10): on hardware, writing DLISTL/DLISTH only updates the
      ;; shadow latch -- ANTIC's live DL pointer is unaffected until the
      ;; next JVB-gated re-latch at VBLANK (see %BEGIN-SCANLINE-EVENTS
      ;; above). This emulator instead applies the write directly to the
      ;; live DL pointer (and resets the mid-list offset), so a DLISTL/H
      ;; write takes effect immediately rather than waiting for VBLANK.
      ;; Indistinguishable from hardware for the OS-standard pattern of
      ;; writing DLISTL/H only during VBLANK setup; diverges for a
      ;; mid-frame rewrite. See the VBI comment above for the
      ;; cross-reference to SCANLINE_ACCURACY_PLAN.md Phase 4+.
      (#.+reg-dlistl+ (setf (antic-dlist-pointer antic)
                            (dpb v (byte 8 0) (antic-dlist-pointer antic))
                            (antic-dl-offset antic) 0
                            (antic-mode-scanlines-remaining antic) 0))
      (#.+reg-dlisth+ (setf (antic-dlist-pointer antic)
                            (dpb v (byte 8 8) (antic-dlist-pointer antic))
                            (antic-dl-offset antic) 0
                            (antic-mode-scanlines-remaining antic) 0))
      (#.+reg-nmien+ (setf (antic-nmien antic) v))
      (#.+reg-nmires+ (setf (antic-nmist antic) 0))
      ;; WSYNC via a read-modify-write instruction (e.g. DEC WSYNC, whose
      ;; NMOS double-write hits the register twice in one instruction) is
      ;; out of scope until an NMOS bus-quirk phase models per-cycle
      ;; writes; both writes land here in the same instruction and simply
      ;; leave the one flag set.
      (#.+reg-wsync+ (setf (antic-wsync-pending antic) t))
      (t nil))))

(declaim (inline antic-consume-wsync))

(defun antic-consume-wsync (antic)
  "Read-and-clear ANTIC's WSYNC-PENDING flag.  Returns the old value (T if
a WSYNC write is pending, NIL otherwise).  Called once per instruction by
the machine scheduler's %RUN-CLOCKS; the per-cycle ANTIC-TICK reference
path does not call this, so WSYNC has no effect when driven through
ANTIC-TICK."
  (declare (type antic antic))
  (prog1 (antic-wsync-pending antic)
    (setf (antic-wsync-pending antic) nil)))

(defun reset-antic (antic)
  "Reset all ANTIC counters and shadow slots.  Returns ANTIC."
  (declare (type antic antic))
  (fill (antic-registers antic) 0)
  (setf (antic-dlist-pointer antic) 0
        (antic-dl-offset antic) 0
        (antic-scanline antic) 0
        (antic-line-cycle antic) 0
        (antic-dmactl antic) 0
        (antic-nmien antic) 0
        (antic-nmist antic) 0
        (antic-current-mode antic) 0
        (antic-mode-scanlines-remaining antic) 0
        (antic-dli-armed antic) nil
        (antic-jvb-wait antic) nil
        (antic-frame-count antic) 0
        (antic-stolen-cycles antic) 0
        (antic-wsync-pending antic) nil
        (antic-screen-data-ptr antic) 0
        (antic-render-screen-data-ptr antic) 0
        (antic-scan-y antic) 0)
  antic)

(defun attach-antic (bus antic &optional cpu)
  "Install ANTIC's read/write closures into BUS.  When CPU is supplied,
ANTIC stores the back-pointer so NMI events can route there."
  (declare (type antic antic))
  (when cpu (setf (antic-cpu antic) cpu))
  (setf (antic-bus antic) bus
        (bus-antic bus) antic
        (bus-antic-read-fn  bus) (lambda (addr) (antic-read antic addr))
        (bus-antic-write-fn bus) (lambda (addr val) (antic-write antic addr val)))
  bus)
