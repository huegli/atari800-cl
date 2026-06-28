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

(declaim (inline %write-rgb %fill-row))

(defun %write-rgb (fb base color)
  "Write Atari COLOR's RGB triple into FB at byte offset BASE."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type fixnum base) (type (unsigned-byte 8) color))
  (setf (aref fb base)       (atari-color->r color)
        (aref fb (+ base 1)) (atari-color->g color)
        (aref fb (+ base 2)) (atari-color->b color)))

(defun %fill-row (fb row-base color)
  "Fill all 384 pixels of the row at byte offset ROW-BASE with Atari COLOR."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type fixnum row-base) (type (unsigned-byte 8) color))
  (let ((r (atari-color->r color))
        (g (atari-color->g color))
        (b (atari-color->b color)))
    (dotimes (x +framebuffer-width+)
      (let ((p (+ row-base (* x 3))))
        (setf (aref fb p)       r
              (aref fb (+ p 1)) g
              (aref fb (+ p 2)) b)))))

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
  "Render bitmap modes 8-F into PF-BASE columns of FB.
All modes produce 320 output pixels: 1bpp and 2bpp modes stretch pixels
horizontally to fill the 320-pixel active area."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type fixnum pf-base)
           (type (unsigned-byte 16) screen-ptr)
           (type (unsigned-byte 8) mode)
           (type bus bus))
  (let ((colbk  (aref gtia-wr +w-colbk+))
        (colpf0 (aref gtia-wr +w-colpf0+))
        (colpf1 (aref gtia-wr (+ +w-colpf0+ 1)))
        (colpf2 (aref gtia-wr (+ +w-colpf0+ 2))))
    (case mode
      ;; Modes 8, A: 40 bytes, 1bpp → 160 logical pixels, each 2 output px.
      ((8 10)
       (dotimes (bx 40)
         (let ((byte (atari800-cl.bus:bus-read
                      bus (ldb (byte 16 0) (+ screen-ptr bx)))))
           (dotimes (bit 8)
             (let* ((v     (ldb (byte 1 (- 7 bit)) byte))
                    (color (if (zerop v) colbk colpf0))
                    (out-x (* (+ (* bx 8) bit) 2))
                    (p     (+ pf-base (* out-x 3))))
               (%write-rgb fb p color)
               (%write-rgb fb (+ p 3) color))))))
      ;; Modes 9, D: 20 bytes, 2bpp → 40 × 4px doubled to 320 output px.
      ((9 13)
       (dotimes (bx 20)
         (let ((byte (atari800-cl.bus:bus-read
                      bus (ldb (byte 16 0) (+ screen-ptr bx)))))
           (dotimes (pair 4)
             (let* ((shift (- 6 (* pair 2)))
                    (bits  (ldb (byte 2 shift) byte))
                    (color (case bits
                             (0 colbk) (1 colpf0) (2 colpf1) (t colpf2)))
                    (out-x (* (+ (* bx 4) pair) 4))
                    (p     (+ pf-base (* out-x 3))))
               (dotimes (dp 4)
                 (%write-rgb fb (+ p (* dp 3)) color)))))))
      ;; Mode B: 20 bytes, 1bpp → 160 logical px doubled.
      (11
       (dotimes (bx 20)
         (let ((byte (atari800-cl.bus:bus-read
                      bus (ldb (byte 16 0) (+ screen-ptr bx)))))
           (dotimes (bit 8)
             (let* ((v     (ldb (byte 1 (- 7 bit)) byte))
                    (color (if (zerop v) colbk colpf2))
                    (out-x (* (+ (* bx 8) bit) 2))
                    (p     (+ pf-base (* out-x 3))))
               (%write-rgb fb p color)
               (%write-rgb fb (+ p 3) color))))))
      ;; Mode C: 20 bytes, 1bpp → 160 px doubled.
      (12
       (dotimes (bx 20)
         (let ((byte (atari800-cl.bus:bus-read
                      bus (ldb (byte 16 0) (+ screen-ptr bx)))))
           (dotimes (bit 8)
             (let* ((v     (ldb (byte 1 (- 7 bit)) byte))
                    (color (if (zerop v) colbk colpf2))
                    (out-x (* (+ (* bx 8) bit) 2))
                    (p     (+ pf-base (* out-x 3))))
               (%write-rgb fb p color)
               (%write-rgb fb (+ p 3) color))))))
      ;; Mode E: 20 bytes, 2bpp → 40 × 4px doubled to 320 output px.
      (14
       (dotimes (bx 20)
         (let ((byte (atari800-cl.bus:bus-read
                      bus (ldb (byte 16 0) (+ screen-ptr bx)))))
           (dotimes (pair 4)
             (let* ((shift (- 6 (* pair 2)))
                    (bits  (ldb (byte 2 shift) byte))
                    (color (case bits
                             (0 colbk) (1 colpf0) (2 colpf1) (t colpf2)))
                    (out-x (* (+ (* bx 4) pair) 4))
                    (p     (+ pf-base (* out-x 3))))
               (dotimes (dp 4)
                 (%write-rgb fb (+ p (* dp 3)) color)))))))
      ;; Mode F: 40 bytes, 1bpp high-res → 320 output px (1:1).
      (15
       (dotimes (bx 40)
         (let ((byte (atari800-cl.bus:bus-read
                      bus (ldb (byte 16 0) (+ screen-ptr bx)))))
           (dotimes (bit 8)
             (let* ((v     (ldb (byte 1 (- 7 bit)) byte))
                    (color (if (zerop v) colbk colpf2))
                    (out-x (+ (* bx 8) bit))
                    (p     (+ pf-base (* out-x 3))))
               (%write-rgb fb p color)))))))))

;;; ---------------------------------------------------------------------------
;;; Player/missile compositing

(defun %pm-pixel-color (gtia-wr fb-x)
  "Return the GTIA color for whichever P/M object covers framebuffer column
FB-X, or NIL if no object covers it.  Players are checked before missiles;
within each class the lower-numbered object wins on ties (P0 > P1 > P2 > P3).

Horizontal position mapping: HPOS value H → framebuffer column H*2 - 64.
This places HPOS=0 at column -64 (off-screen left), HPOS=128 at center.

Player size: SIZE=1 → 8px, SIZE=2 → 16px, SIZE=4 → 32px.
Missile size: SIZEM 2-bit field per missile: 0→2px, 1→4px, 2→8px, 3→16px."
  (declare (type (simple-array (unsigned-byte 8) (*)) gtia-wr)
           (type fixnum fb-x))
  ;; Players 0-3
  (dotimes (p 4)
    (let* ((hpos  (aref gtia-wr (+ +w-hposp0+ p)))
           (size  (aref gtia-wr (+ +w-sizep0+ p)))
           (grafp (aref gtia-wr (+ +w-grafp0+ p)))
           (px-w  (case size (2 16) (4 32) (t 8)))
           (left  (- (* hpos 2) 64))
           (right (+ left px-w)))
      (declare (type fixnum left right px-w))
      (when (and (>= fb-x left) (< fb-x right))
        (let* ((bit-pos (truncate (* (- fb-x left) 8) px-w))
               (bit-val (ldb (byte 1 (- 7 bit-pos)) grafp)))
          (when (= bit-val 1)
            (return-from %pm-pixel-color
              (aref gtia-wr (+ +w-colpm0+ p))))))))
  ;; Missiles 0-3
  (let ((grafm (aref gtia-wr +w-grafm+))
        (sizem (aref gtia-wr +w-sizem+)))
    (dotimes (m 4)
      (let* ((hpos  (aref gtia-wr (+ +w-hposm0+ m)))
             (m-sz  (ldb (byte 2 (* m 2)) sizem))
             (px-w  (case m-sz (0 2) (1 4) (2 8) (t 16)))
             (left  (- (* hpos 2) 64))
             (right (+ left px-w))
             ;; Missile m uses 2 bits of GRAFM: bits (7-2m) and (6-2m).
             (graf-bits (ldb (byte 2 (- 6 (* m 2))) grafm)))
        (declare (type fixnum left right px-w))
        (when (and (plusp graf-bits) (>= fb-x left) (< fb-x right))
          (let* ((bit-pos (truncate (* (- fb-x left) 2) px-w))
                 (bit-val (ldb (byte 1 (- 1 bit-pos)) graf-bits)))
            (when (= bit-val 1)
              (return-from %pm-pixel-color
                (aref gtia-wr (+ +w-colpm0+ m)))))))))
  nil)

(defun %render-pm-layer (fb row-base prior gtia-wr)
  "Composite player/missile graphics over the already-rendered playfield row.
When PRIOR bit 1 is clear (the common case), P/M objects draw on top of the
playfield.  When bit 1 is set, playfield colors 0/1 take priority; we leave
existing playfield pixels untouched (full multi-layer priority is not
modelled in this initial implementation)."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type (unsigned-byte 8) prior)
           (type fixnum row-base))
  (let ((pf-over-pm (logtest prior #x02)))
    (unless pf-over-pm
      (dotimes (x +framebuffer-width+)
        (let ((pm-color (%pm-pixel-color gtia-wr x)))
          (when pm-color
            (%write-rgb fb (+ row-base (* x 3)) pm-color)))))))

;;; ---------------------------------------------------------------------------
;;; Top-level scanline renderer

(defun render-scanline (fb row antic gtia bus)
  "Render active display row ROW (0-based within the 240-line active window,
where row 0 = NTSC scanline 8) into framebuffer FB.

Steps:
  1. Flood the 384-pixel row with COLBK (background color).
  2. If DMACTL != 0 and the current DL mode >= 2, render a 320-pixel active
     playfield at columns 32-351.  Character modes 2-7 look up glyphs in the
     character ROM at CHBASE; bitmap modes 8-F read pixels from screen RAM.
  3. Composite player/missile graphics using PRIOR for priority.

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
    ;; Step 1: background.
    (%fill-row fb row-base colbk)
    ;; Step 2: playfield (only when DMA is enabled and mode is non-blank).
    (when (and (not (zerop dmactl)) (>= mode 2))
      (if (<= mode 7)
          (%render-char-mode fb pf-base sptr scan-y mode wr bus chbase)
          (%render-bitmap-mode fb pf-base sptr mode wr bus)))
    ;; Step 3: player/missile compositing.
    (%render-pm-layer fb row-base prior wr)))
