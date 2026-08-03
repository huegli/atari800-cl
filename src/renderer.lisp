;;;; src/renderer.lisp --- Per-scanline NTSC pixel renderer.
;;;;
;;;; Converts ANTIC display-list state + GTIA register values into a
;;;; 384×240 24-bit RGB framebuffer.
;;;;
;;;; Rendering steps per active scanline (NTSC lines 8-247):
;;;;   1. Flood the entire 384-pixel row with the COLBK (background) color.
;;;;   2. If DMA is enabled and mode >= 2, render a 320-pixel playfield
;;;;      into columns 32-351 (32-pixel left/right borders remain COLBK).
;;;;   3. Composite player/missile graphics over the playfield using the
;;;;      PRIOR register for priority arbitration.
;;;;
;;;; Framebuffer layout: a flat (simple-array (unsigned-byte 8) (*)) of
;;;; length 384 * 240 * 3.  Pixel (x, row) occupies bytes
;;;; (+ (* row 384 3) (* x 3)) ... +2 in R, G, B order.

(in-package #:atari800-cl.renderer)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  See the
;;; matching declaim in src/bus.lisp for the note on DECLAIM's proclaiming
;;; behaviour under :serial t; repeated here so this file's policy survives
;;; interactive recompilation on its own.  (Until the Phases 1-5 review
;;; this file had no declaim of its own and relied on the policy leaking
;;; from earlier files during a serial build — measured worth ~8% on
;;; LispWorks when recompiled standalone.)
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Framebuffer geometry

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +framebuffer-width+       384)
  (defconstant +framebuffer-height+      240)
  (defconstant +playfield-left-border+    32)  ; columns before active playfield
  (defconstant +playfield-pixel-width+   320)) ; active playfield in output pixels

(defun make-framebuffer ()
  "Return a zeroed 384×240 24-bit RGB framebuffer (276,480 bytes)."
  (make-array (* +framebuffer-width+ +framebuffer-height+ 3)
              :element-type '(unsigned-byte 8)
              :initial-element 0))

;;; ---------------------------------------------------------------------------
;;; Atari NTSC color palette
;;;
;;; The Atari color register uses 7 significant bits:
;;;   bits 7-4 (4 bits): hue  (0 = grayscale; 1-15 = equally-spaced hues)
;;;   bits 3-1 (3 bits): luminance (0-7, low to high brightness)
;;;   bit  0   (1 bit):  ignored (always 0 in hardware writes)
;;;
;;; The palette is indexed by (ash color-register -1), giving 128 entries.
;;; Each entry occupies 3 consecutive bytes (R, G, B).

(eval-when (:compile-toplevel :load-toplevel :execute)

  (defun %clamp-u8 (x)
    (declare (type real x))
    (let ((i (round x)))
      (cond ((< i 0) 0) ((> i 255) 255) (t i))))

  (defun %build-atari-palette ()
    "Compute the 128-entry 384-byte Atari NTSC palette using YIQ conversion.
Luminance 0-7 maps Y linearly from 8 to 190.  Saturation constant = 0.28.
Hue angles start near orange-red (offset 0.4 radians) and step by 2π/15."
    (let ((tbl (make-array 384 :element-type '(unsigned-byte 8) :initial-element 0)))
      (dotimes (i 128)
        (let* ((lum  (ldb (byte 3 0) i))
               (hue  (ldb (byte 4 3) i))
               (y    (float (+ (* lum 26) 8)))
               (base (* i 3)))
          (cond
            ((zerop hue)
             ;; Grayscale: R = G = B = Y.
             (let ((v (%clamp-u8 y)))
               (setf (aref tbl base)       v
                     (aref tbl (+ base 1)) v
                     (aref tbl (+ base 2)) v)))
            (t
             ;; Colored: use YIQ → RGB.
             (let* ((ang   (+ (* (float (1- hue)) (/ (* 2.0 pi) 15.0)) 0.4))
                    (sat   255.0)
                    (ii    (* (cos ang) 0.28 sat))
                    (q     (* (sin ang) 0.28 sat)))
               (setf (aref tbl base)
                     (%clamp-u8 (+ y (* 0.956 ii) (* 0.621 q)))
                     (aref tbl (+ base 1))
                     (%clamp-u8 (- y (* 0.272 ii) (* 0.647 q)))
                     (aref tbl (+ base 2))
                     (%clamp-u8 (+ y (* -1.106 ii) (* 1.703 q)))))))))
      tbl))

  (defparameter +atari-rgb-palette+ (%build-atari-palette)
    "384-byte vector: 128 Atari NTSC color entries in R, G, B order.
Index with (* (ash color-register -1) 3)."))

(declaim (inline atari-color->r atari-color->g atari-color->b))

(defun atari-color->r (c)
  "Return the red component (0-255) for Atari color byte C."
  (declare (type (unsigned-byte 8) c))
  (aref +atari-rgb-palette+ (* (ash c -1) 3)))

(defun atari-color->g (c)
  "Return the green component (0-255) for Atari color byte C."
  (declare (type (unsigned-byte 8) c))
  (aref +atari-rgb-palette+ (+ (* (ash c -1) 3) 1)))

(defun atari-color->b (c)
  "Return the blue component (0-255) for Atari color byte C."
  (declare (type (unsigned-byte 8) c))
  (aref +atari-rgb-palette+ (+ (* (ash c -1) 3) 2)))

;;; ---------------------------------------------------------------------------
;;; Framebuffer pixel helpers

(declaim (inline %write-rgb %fill-span %fill-row))

(defun %write-rgb (fb base color)
  "Write Atari COLOR's RGB triple into FB at byte offset BASE."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type fixnum base) (type (unsigned-byte 8) color))
  (setf (aref fb base)       (atari-color->r color)
        (aref fb (+ base 1)) (atari-color->g color)
        (aref fb (+ base 2)) (atari-color->b color)))

(defun %fill-span (fb row-base start-x n color)
  "Fill N consecutive pixels of the row at byte offset ROW-BASE with
Atari COLOR, starting at output column START-X.  The palette lookup is
hoisted out of the loop."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type fixnum row-base start-x n)
           (type (unsigned-byte 8) color))
  (let ((r (atari-color->r color))
        (g (atari-color->g color))
        (b (atari-color->b color))
        (p (+ row-base (* start-x 3))))
    (declare (type fixnum p))
    (dotimes (i n)
      (setf (aref fb p)       r
            (aref fb (+ p 1)) g
            (aref fb (+ p 2)) b)
      (incf p 3))))

(defun %fill-row (fb row-base color)
  "Fill all 384 pixels of the row at byte offset ROW-BASE with Atari COLOR."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type fixnum row-base) (type (unsigned-byte 8) color))
  (%fill-span fb row-base 0 +framebuffer-width+ color))

;;; ---------------------------------------------------------------------------
;;; Character ROM lookup

(defun %char-row-bits (bus chbase char-code scan-y mode)
  "Return the 8-bit glyph pattern for one row of a character.
CHBASE is the ANTIC register value (character set base address >> 8).
CHAR-CODE is the raw byte from screen memory.
SCAN-Y is the 0-based row within the current mode line.
MODE is the ANTIC mode nibble (2-7).

Modes 2/3: 64-character set; bits 6-7 of char-code are attribute flags,
not part of the character index.  Glyph address:
  chbase*256 + (char-code & 0x3F)*8 + (scan-y mod 8).

Modes 4/5: same 64-char layout but the upper 2 bits select color.

Modes 6/7: 64 wide characters, glyph row at mod 8 of scan-y."
  (declare (type (unsigned-byte 8) chbase char-code scan-y mode)
           (type bus bus))
  (let* ((char-idx (ldb (byte 6 0) char-code))
         (row-y    (ldb (byte 3 0) scan-y))
         (addr     (ldb (byte 16 0)
                        (+ (* (the fixnum chbase) 256)
                           (* char-idx 8)
                           row-y))))
    (declare (ignore mode))
    (atari800-cl.bus:bus-read bus addr)))

;;; ---------------------------------------------------------------------------
;;; Playfield renderers

(defun %render-char-mode (fb pf-base screen-ptr scan-y mode gtia-wr bus chbase)
  "Render character modes 2-7 into PF-BASE columns of FB.
Produces 320 output pixels (modes 2-5: 40 chars × 8px; modes 6-7: 20 chars × 16px)."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type fixnum pf-base scan-y)
           (type (unsigned-byte 16) screen-ptr)
           (type (unsigned-byte 8) mode chbase)
           (type bus bus))
  (let* ((wide-p    (or (= mode 6) (= mode 7)))
         (n-chars   (if wide-p 20 40))
         (px-per-ch (if wide-p 16 8))
         (colbk     (aref gtia-wr +w-colbk+))
         (colpf0    (aref gtia-wr +w-colpf0+))
         (colpf1    (aref gtia-wr (+ +w-colpf0+ 1)))
         (colpf2    (aref gtia-wr (+ +w-colpf0+ 2)))
         (colpf3    (aref gtia-wr (+ +w-colpf0+ 3))))
    (dotimes (cx n-chars)
      (let* ((ch    (atari800-cl.bus:bus-read
                     bus (ldb (byte 16 0) (+ screen-ptr cx))))
             (bits  (%char-row-bits bus chbase ch (ldb (byte 8 0) scan-y) mode))
             (inv-p (and (logtest ch #x80) (or (= mode 2) (= mode 3))))
             (alt-p (and (logtest ch #x40) (or (= mode 2) (= mode 3)))))
        (dotimes (bx 8)
          (let* ((bit-val (ldb (byte 1 (- 7 bx)) bits))
                 (color
                  (case mode
                    ((2 3)
                     (cond
                       (inv-p (if (zerop bit-val) colpf2 colbk))
                       (alt-p (if (zerop bit-val) colbk  colpf1))
                       (t     (if (zerop bit-val) colbk  colpf2))))
                    ((4 5)
                     (if (zerop bit-val) colbk
                         (case (ldb (byte 2 6) ch)
                           (0 colpf0) (1 colpf1) (2 colpf2) (t colpf3))))
                    ((6 7)
                     (if (zerop bit-val) colbk
                         (case (ldb (byte 2 6) ch)
                           (0 colpf0) (1 colpf1) (2 colpf2) (t colpf3))))
                    (t colbk)))
                 ;; For wide-char modes each glyph bit covers 2 output pixels.
                 (out-x (+ (* cx px-per-ch) (* bx (if wide-p 2 1))))
                 (p     (+ pf-base (* out-x 3))))
            (%write-rgb fb p color)
            (when wide-p
              (%write-rgb fb (+ p 3) color))))))))

(defun %render-bitmap-mode (fb pf-base screen-ptr mode gtia-wr bus)
  "Render map (bitmap) modes 8-F into PF-BASE columns of FB.

Geometry follows real hardware: each mode line consumes
BYTES-PER-SCREEN-ROW bytes (the shared ANTIC table — 10 for modes 8-9,
20 for A-C, 40 for D-F at normal width), decoded at that mode's color
depth and stretched to fill the 320-pixel active area:

  mode 8 (GR.3):   10 bytes  2bpp →  40 logical px × 8 output columns
  mode 9 (GR.4):   10 bytes  1bpp →  80 logical px × 4
  mode A (GR.5):   20 bytes  2bpp →  80 logical px × 4
  mode B (GR.6):   20 bytes  1bpp → 160 logical px × 2
  mode C:          20 bytes  1bpp → 160 logical px × 2
  mode D (GR.7):   40 bytes  2bpp → 160 logical px × 2
  mode E (GR.15):  40 bytes  2bpp → 160 logical px × 2
  mode F (GR.8):   40 bytes  1bpp → 320 px, 1:1

Color registers (Altirra Hardware Reference Manual): 2bpp map modes map
pixel values 0/1/2/3 to COLBK/COLPF0/COLPF1/COLPF2; 1bpp map modes 9/B/C
map 0/1 to COLBK/COLPF0.  Mode F keeps this renderer's simplified
0→COLBK, 1→COLPF2 output (real GR.8 shows COLPF2 as the playfield
background with COLPF1's luminance for set pixels — that artifact model
is out of scope until the GTIA-mode work, ROADMAP.md Phase 7)."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type fixnum pf-base)
           (type (unsigned-byte 16) screen-ptr)
           (type (unsigned-byte 8) mode)
           (type bus bus))
  (let ((colbk  (aref gtia-wr +w-colbk+))
        (colpf0 (aref gtia-wr +w-colpf0+))
        (colpf1 (aref gtia-wr (+ +w-colpf0+ 1)))
        (colpf2 (aref gtia-wr (+ +w-colpf0+ 2))))
    (if (= mode 15)
        ;; Mode F: 40 bytes, 1bpp high-res → 320 output px (1:1).
        (dotimes (bx 40)
          (let ((byte (atari800-cl.bus:bus-read
                       bus (ldb (byte 16 0) (+ screen-ptr bx)))))
            (dotimes (bit 8)
              (let* ((v     (ldb (byte 1 (- 7 bit)) byte))
                     (color (if (zerop v) colbk colpf2))
                     (out-x (+ (* bx 8) bit))
                     (p     (+ pf-base (* out-x 3))))
                (%write-rgb fb p color)))))
        ;; Modes 8-E: generic scaled decode from the shared byte table.
        (let* ((nbytes      (bytes-per-screen-row mode))
               (two-bpp-p   (case mode ((8 10 13 14) t) (t nil)))
               (px-per-byte (if two-bpp-p 4 8))
               (scale       (truncate +playfield-pixel-width+
                                      (* nbytes px-per-byte))))
          (declare (type fixnum nbytes px-per-byte scale))
          (dotimes (bx nbytes)
            (let ((byte (atari800-cl.bus:bus-read
                         bus (ldb (byte 16 0) (+ screen-ptr bx)))))
              (dotimes (px px-per-byte)
                (let* ((color (if two-bpp-p
                                  (case (ldb (byte 2 (- 6 (* px 2))) byte)
                                    (0 colbk) (1 colpf0) (2 colpf1) (t colpf2))
                                  (if (zerop (ldb (byte 1 (- 7 px)) byte))
                                      colbk
                                      colpf0)))
                       (out-x (* (+ (* bx px-per-byte) px) scale))
                       (p     (+ pf-base (* out-x 3))))
                  (dotimes (dp scale)
                    (%write-rgb fb (+ p (* dp 3)) color))))))))))

;;; ---------------------------------------------------------------------------
;;; Player/missile compositing

(defun %paint-pm-span (fb row-base hpos px-w graf nbits color)
  "Paint one P/M object's graphics bits into the row at byte offset
ROW-BASE.  GRAF's NBITS bits are read MSB-first; each SET bit paints
PX-W/NBITS consecutive output columns in COLOR, starting at framebuffer
column HPOS*2 - 64 (HPOS 0 is off-screen left, HPOS 128 is center —
the same mapping the per-pixel arbitration used).  Columns outside
0-383 are clipped.  Clear bits paint nothing, so lower-priority objects
already painted underneath show through, exactly like hardware."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type fixnum row-base px-w nbits)
           (type (unsigned-byte 8) hpos graf color))
  (let ((left         (- (* hpos 2) 64))
        (cols-per-bit (truncate px-w nbits)))
    (declare (type fixnum left cols-per-bit))
    (dotimes (bit nbits)
      (when (logbitp (- nbits 1 bit) graf)
        (let ((x0 (+ left (* bit cols-per-bit))))
          (declare (type fixnum x0))
          (dotimes (d cols-per-bit)
            (let ((x (+ x0 d)))
              (declare (type fixnum x))
              (when (and (>= x 0) (< x +framebuffer-width+))
                (%write-rgb fb (+ row-base (* x 3)) color)))))))))

(defun %render-pm-layer (fb row-base prior gtia-wr)
  "Composite player/missile graphics over the already-rendered playfield row.

When PRIOR bit 1 is clear (the common case), P/M objects draw on top of
the playfield.  When bit 1 is set, playfield colors take priority; we
leave existing playfield pixels untouched (full multi-layer priority is
ROADMAP.md Phase 6b).

Span-based: each enabled object paints its own <= 32-column span
directly, painted lowest-priority first (missiles M3 down to M0, then
players P3 down to P0) so the highest-priority object's color lands on
top — reproducing the old per-pixel arbitration exactly (players beat
missiles, lower index beats higher; an object's CLEAR bits paint
nothing, so whatever is underneath shows through).  The previous
implementation instead asked, for every one of the 384 output columns,
which of the 8 objects covers it: 92,160 non-inlined %PM-PIXEL-COLOR
calls per frame that re-read every object's loop-invariant HPOS/SIZE/
GRAF registers per pixel — measured at 52% (SBCL) to 67% (LispWorks)
of a display frame's entire cost with no P/M objects enabled.  A row
whose GRAFP0-3/GRAFM are all zero now exits after five register reads.

Object geometry (unchanged): player = 8 GRAFPn bits over 8/16/32
columns (SIZEPn 1/2/4); missile m = 2 GRAFM bits (bits 7-2m, 6-2m) over
2/4/8/16 columns (its 2-bit field in SIZEM); missile m is colored
COLPMm."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type (unsigned-byte 8) prior)
           (type fixnum row-base))
  (let ((pf-over-pm (logtest prior #x02)))
    (unless pf-over-pm
      (let ((grafp0 (aref gtia-wr +w-grafp0+))
            (grafp1 (aref gtia-wr (+ +w-grafp0+ 1)))
            (grafp2 (aref gtia-wr (+ +w-grafp0+ 2)))
            (grafp3 (aref gtia-wr (+ +w-grafp0+ 3)))
            (grafm  (aref gtia-wr +w-grafm+)))
        ;; Row-level early-out: nothing to composite (the overwhelmingly
        ;; common case for software that never touches P/M graphics).
        (when (plusp (logior grafp0 grafp1 grafp2 grafp3 grafm))
          ;; Missiles first — lowest priority — M3 down to M0.
          (when (plusp grafm)
            (let ((sizem (aref gtia-wr +w-sizem+)))
              (loop for m fixnum from 3 downto 0
                    do (let ((bits (ldb (byte 2 (- 6 (* m 2))) grafm)))
                         (when (plusp bits)
                           (%paint-pm-span fb row-base
                                           (aref gtia-wr (+ +w-hposm0+ m))
                                           (case (ldb (byte 2 (* m 2)) sizem)
                                             (0 2) (1 4) (2 8) (t 16))
                                           bits 2
                                           (aref gtia-wr (+ +w-colpm0+ m))))))))
          ;; Players P3 down to P0 — P0 painted last, so it wins overlaps.
          (flet ((paint-player (p grafp)
                   (declare (type fixnum p) (type (unsigned-byte 8) grafp))
                   (when (plusp grafp)
                     (%paint-pm-span fb row-base
                                     (aref gtia-wr (+ +w-hposp0+ p))
                                     (case (aref gtia-wr (+ +w-sizep0+ p))
                                       (2 16) (4 32) (t 8))
                                     grafp 8
                                     (aref gtia-wr (+ +w-colpm0+ p))))))
            (paint-player 3 grafp3)
            (paint-player 2 grafp2)
            (paint-player 1 grafp1)
            (paint-player 0 grafp0)))))))

;;; ---------------------------------------------------------------------------
;;; Top-level scanline renderer

(defun render-scanline (fb row antic gtia bus)
  "Render active display row ROW (0-based within the 240-line active window,
where row 0 = NTSC scanline 8) into framebuffer FB.

Steps:
  1. Background: flood the full 384-pixel row with COLBK when no
     playfield will be drawn; otherwise flood only the two 32-column
     borders (the playfield renderers cover all 320 active columns).
  2. If DMACTL != 0 and the current DL mode >= 2, render a 320-pixel active
     playfield at columns 32-351.  Character modes 2-7 look up glyphs in the
     character ROM at CHBASE; bitmap modes 8-F read pixels from screen RAM.
  3. Composite player/missile graphics using PRIOR for priority
     (span-based; see %RENDER-PM-LAYER).

The screen-data address is read from ANTIC-RENDER-SCREEN-DATA-PTR (a snapshot
taken at the start of the scanline before any end-of-line advancement)."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type fixnum row)
           (type antic antic) (type gtia gtia) (type bus bus))
  (let* ((wr      (gtia-write-regs gtia))
         (regs    (antic-registers antic))
         (colbk   (aref wr +w-colbk+))
         (prior   (aref wr +w-prior+))
         (dmactl  (antic-dmactl antic))
         (mode    (ldb (byte 4 0) (antic-current-mode antic)))
         (chbase  (aref regs +reg-chbase+))
         (scan-y  (antic-scan-y antic))
         (sptr    (antic-render-screen-data-ptr antic))
         (row-base (* row +framebuffer-width+ 3))
         (pf-base (+ row-base (* +playfield-left-border+ 3))))
    ;; Steps 1+2: background + playfield.  The playfield renderers write
    ;; ALL 320 active columns themselves, so when one will run, only the
    ;; two 32-column borders need the background flood — flooding the
    ;; full row first just to overwrite 320 of its 384 pixels was pure
    ;; waste on every playfield line.
    (cond
      ((and (not (zerop dmactl)) (>= mode 2))
       (%fill-span fb row-base 0 +playfield-left-border+ colbk)
       (%fill-span fb row-base
                   (+ +playfield-left-border+ +playfield-pixel-width+)
                   (- +framebuffer-width+
                      +playfield-left-border+ +playfield-pixel-width+)
                   colbk)
       (if (<= mode 7)
           (%render-char-mode fb pf-base sptr scan-y mode wr bus chbase)
           (%render-bitmap-mode fb pf-base sptr mode wr bus)))
      (t
       (%fill-row fb row-base colbk)))
    ;; Step 3: player/missile compositing.
    (%render-pm-layer fb row-base prior wr)))
