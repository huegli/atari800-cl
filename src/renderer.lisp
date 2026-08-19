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
;;; Playfield source tags + P/M priority (ROADMAP.md Phase 6b)
;;;
;;; PRIOR bits 0-3 select one of four fixed priority orderings between
;;; the four player channels and the playfield sources.  To arbitrate,
;;; the P/M compositor must know WHICH playfield register produced each
;;; pixel, not just its color: the playfield renderers record a source
;;; tag per output column into the GTIA's PF-TAG-ROW scratch (but only
;;; on rows where P/M objects are actually active — see RENDER-SCANLINE).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +tag-bak+ 0)
  (defconstant +tag-pf0+ 1)
  (defconstant +tag-pf1+ 2)
  (defconstant +tag-pf2+ 3)
  (defconstant +tag-pf3+ 4))

(defparameter +pm-beats-pf-masks+
  (make-array '(4 4)
              :element-type '(unsigned-byte 8)
              :initial-contents '((#b11111 #b11111 #b11111 #b11111)
                                  (#b11111 #b11111 #b00001 #b00001)
                                  (#b00001 #b00001 #b00001 #b00001)
                                  (#b11001 #b11001 #b11001 #b11001)))
  "Priority lookup: does player channel P draw over playfield tag T?

Row = the normalized PRIOR priority select (index of the lowest set bit
of PRIOR bits 0-3); column = player channel 0-3; value = a 5-bit mask
over tags (bit T set means the player draws over tag T, tags being
BAK=0, PF0-PF3=1-4).  Derived from the four orderings (top priority
first; standard table, cross-check pending against Altirra/atari800 per
the ROADMAP CONFIRM note):
  PRIOR bit 0: P0 P1 P2 P3 PF0 PF1 PF2 PF3 BAK — players beat every tag
  PRIOR bit 1: P0 P1 PF0-PF3 P2 P3 BAK         — P0/P1 beat all; P2/P3 only BAK
  PRIOR bit 2: PF0-PF3 P0 P1 P2 P3 BAK         — players beat only BAK
  PRIOR bit 3: PF0 PF1 P0-P3 PF2 PF3 BAK       — players beat BAK, PF2, PF3")

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
SCAN-Y is the 0-based row within the current mode line (0..7 for modes
2/4/6; 0..9 for mode 3; 0..15 for modes 5/7 -- see MODE-LINE-SCANLINES).
MODE is the ANTIC mode nibble (2-7).

Modes 2/3/6/7: 64-character set; bits 6-7 of char-code are attribute
flags (inverse/blink for 2/3; on-color select for 6/7), not part of the
character index.  Glyph address: chbase*256 + (char-code & 0x3F)*8 + row.

Modes 4/5: 128-character set -- only bit 7 is special (it swaps which
color register a glyph's \"11\" pixel-pairs use; see
%RENDER-MULTICOLOR-CHAR-MODE), so the glyph index keeps bit 6.  Glyph
address: chbase*256 + (char-code & 0x7F)*8 + row.  Source: Compute!'s
First Book of Atari Graphics ch.3, \"The Four-Color Character Modes\".

Modes 5/7 are double-height (16 real scanlines per mode line, per
MODE-LINE-SCANLINES) but the character ROM only has 8 rows per glyph:
each glyph row is stretched across 2 scanlines (row = SCAN-Y/2), not
repeated over 8-then-8 (which would draw the same 8 rows twice and,
for text, produce two visible copies of every line)."
  (declare (type (unsigned-byte 8) chbase char-code scan-y mode)
           (type bus bus))
  (let* ((wide-glyph-p     (or (= mode 4) (= mode 5)))
         (double-height-p  (or (= mode 5) (= mode 7)))
         (char-idx (if wide-glyph-p
                       (ldb (byte 7 0) char-code)
                       (ldb (byte 6 0) char-code)))
         (row-y    (if double-height-p
                       (ldb (byte 3 0) (ash scan-y -1))
                       (ldb (byte 3 0) scan-y)))
         (addr     (ldb (byte 16 0)
                        (+ (* (the fixnum chbase) 256)
                           (* char-idx 8)
                           row-y))))
    (atari800-cl.bus:bus-read bus addr)))

;;; ---------------------------------------------------------------------------
;;; Playfield renderers

(defun %render-char-mode (fb pf-base screen-ptr scan-y mode gtia-wr bus chbase
                          &optional tags)
  "Render single-color-per-character modes 2/3/6/7 into PF-BASE columns
of FB.  (Modes 4/5 are true 2-bits-per-pixel and go through
%RENDER-MULTICOLOR-CHAR-MODE instead -- see that function.)  Produces
320 output pixels (modes 2/3: 40 chars x 8px; modes 6/7: 20 chars x 16px).
When TAGS (the GTIA's PF-TAG-ROW) is non-NIL, also record each output
column's playfield source tag for P/M priority arbitration.

A character row has at most two colors — the glyph-on color and the
glyph-off color — both fixed per character: modes 2/3 pick them from
the character's attribute bits (bit 7 inverse video swaps them, bit 6
selects COLPF1), modes 6/7 pick the on-color from the character's top
two bits (COLPF0-3) with COLBK off.  Both RGB triples are therefore
resolved ONCE per character, and the 8-bit glyph loop only stores raw
bytes.  (The previous version dispatched on the mode and did three
palette lookups per output pixel, which decomposition measured at
~60-70% of the whole display-workload frame once P/M compositing was
fixed — hoisting it doubled the workload again on both
implementations.)"
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type fixnum pf-base scan-y)
           (type (unsigned-byte 16) screen-ptr)
           (type (unsigned-byte 8) mode chbase)
           (type bus bus)
           (type (or null (simple-array (unsigned-byte 8) (384))) tags))
  (let* ((wide-p    (or (= mode 6) (= mode 7)))
         (attr-p    (or (= mode 2) (= mode 3)))
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
             (inv-p (and attr-p (logtest ch #x80)))
             (alt-p (and attr-p (logtest ch #x40)))
             ;; Per-character color pair (see docstring).
             (on-color  (if attr-p
                            (cond (inv-p colbk)
                                  (alt-p colpf1)
                                  (t     colpf2))
                            (case (ldb (byte 2 6) ch)
                              (0 colpf0) (1 colpf1) (2 colpf2) (t colpf3))))
             (off-color (if inv-p colpf2 colbk))
             ;; Source tags mirror the color choice (inverse video's
             ;; glyph-on pixels really are background-sourced, etc.).
             (on-tag    (if attr-p
                            (cond (inv-p +tag-bak+)
                                  (alt-p +tag-pf1+)
                                  (t     +tag-pf2+))
                            (+ +tag-pf0+ (ldb (byte 2 6) ch))))
             (off-tag   (if inv-p +tag-pf2+ +tag-bak+))
             (on-r  (atari-color->r on-color))
             (on-g  (atari-color->g on-color))
             (on-b  (atari-color->b on-color))
             (off-r (atari-color->r off-color))
             (off-g (atari-color->g off-color))
             (off-b (atari-color->b off-color))
             (p     (+ pf-base (* cx px-per-ch 3)))
             (tx    (+ +playfield-left-border+ (* cx px-per-ch))))
        (declare (type fixnum p tx))
        (dotimes (bx 8)
          (multiple-value-bind (r g b tag)
              (if (logbitp (- 7 bx) bits)
                  (values on-r on-g on-b on-tag)
                  (values off-r off-g off-b off-tag))
            (setf (aref fb p)       r
                  (aref fb (+ p 1)) g
                  (aref fb (+ p 2)) b)
            (when tags (setf (aref tags tx) tag))
            (incf p 3)
            (incf tx)
            ;; Wide-char modes: each glyph bit covers 2 output pixels.
            (when wide-p
              (setf (aref fb p)       r
                    (aref fb (+ p 1)) g
                    (aref fb (+ p 2)) b)
              (when tags (setf (aref tags tx) tag))
              (incf p 3)
              (incf tx))))))))

(defun %render-multicolor-char-mode (fb pf-base screen-ptr scan-y mode gtia-wr
                                     bus chbase &optional tags)
  "Render ANTIC's four-color character modes 4/5 into PF-BASE columns of FB.

Unlike modes 2/3/6/7 (one on/off color pair per whole character; see
%RENDER-CHAR-MODE), modes 4/5 read each glyph byte as four 2-bit pixel
pairs, MSB first: 00 -> COLBK, 01 -> COLPF0, 10 -> COLPF1, 11 -> COLPF2,
or COLPF3 instead of COLPF2 when the character code's bit 7 is set.
(Source: Compute!'s First Book of Atari Graphics ch.3, \"The Four-Color
Character Modes\".)  Each 2-bit pixel is 2 output columns wide, so 4
pixels x 2 = 8 columns per character; these modes are always the
40-character-wide layout (never the mode 6/7 \"wide\" 16px/char one).
When TAGS (the GTIA's PF-TAG-ROW) is non-NIL, also record each output
column's playfield source tag for P/M priority arbitration."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type fixnum pf-base scan-y)
           (type (unsigned-byte 16) screen-ptr)
           (type (unsigned-byte 8) mode chbase)
           (type bus bus)
           (type (or null (simple-array (unsigned-byte 8) (384))) tags))
  (let ((colbk  (aref gtia-wr +w-colbk+))
        (colpf0 (aref gtia-wr +w-colpf0+))
        (colpf1 (aref gtia-wr (+ +w-colpf0+ 1)))
        (colpf2 (aref gtia-wr (+ +w-colpf0+ 2)))
        (colpf3 (aref gtia-wr (+ +w-colpf0+ 3))))
    (dotimes (cx 40)
      (let* ((ch       (atari800-cl.bus:bus-read
                        bus (ldb (byte 16 0) (+ screen-ptr cx))))
             (bits     (%char-row-bits bus chbase ch (ldb (byte 8 0) scan-y) mode))
             ;; Bit 7 of the character code swaps which register the
             ;; "11" pixel-pairs use -- this is NOT the mode 2/3 style
             ;; whole-character inverse video.
             (hi3-color (if (logbitp 7 ch) colpf3 colpf2))
             (hi3-tag   (if (logbitp 7 ch) +tag-pf3+ +tag-pf2+))
             (p        (+ pf-base (* cx 8 3)))
             (tx       (+ +playfield-left-border+ (* cx 8))))
        (declare (type fixnum p tx))
        (dotimes (px 4)
          (multiple-value-bind (color tag)
              (case (ldb (byte 2 (- 6 (* px 2))) bits)
                (0 (values colbk  +tag-bak+))
                (1 (values colpf0 +tag-pf0+))
                (2 (values colpf1 +tag-pf1+))
                (t (values hi3-color hi3-tag)))
            (let ((r (atari-color->r color))
                  (g (atari-color->g color))
                  (b (atari-color->b color)))
              ;; Each 2-bit pixel covers 2 output columns.
              (dotimes (rep 2)
                (setf (aref fb p)       r
                      (aref fb (+ p 1)) g
                      (aref fb (+ p 2)) b)
                (when tags (setf (aref tags tx) tag))
                (incf p 3)
                (incf tx)))))))))

(defun %render-bitmap-mode (fb pf-base screen-ptr mode gtia-wr bus
                            &optional tags)
  "Render map (bitmap) modes 8-F into PF-BASE columns of FB.
When TAGS (the GTIA's PF-TAG-ROW) is non-NIL, also record each output
column's playfield source tag for P/M priority arbitration (2bpp pixel
values 0-3 map directly to tags BAK/PF0/PF1/PF2; 1bpp set pixels are
PF0, except mode F's which are PF2).

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
           (type bus bus)
           (type (or null (simple-array (unsigned-byte 8) (384))) tags))
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
                (%write-rgb fb p color)
                (when tags
                  (setf (aref tags (+ +playfield-left-border+ out-x))
                        (if (zerop v) +tag-bak+ +tag-pf2+)))))))
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
                (multiple-value-bind (color tag)
                    (if two-bpp-p
                        ;; 2bpp: pixel value = tag value (BAK/PF0/PF1/PF2).
                        (let ((bits (ldb (byte 2 (- 6 (* px 2))) byte)))
                          (values (case bits
                                    (0 colbk) (1 colpf0) (2 colpf1) (t colpf2))
                                  bits))
                        (if (zerop (ldb (byte 1 (- 7 px)) byte))
                            (values colbk  +tag-bak+)
                            (values colpf0 +tag-pf0+)))
                  (let* ((out-x (* (+ (* bx px-per-byte) px) scale))
                         (p     (+ pf-base (* out-x 3))))
                    (dotimes (dp scale)
                      (%write-rgb fb (+ p (* dp 3)) color)
                      (when tags
                        (setf (aref tags (+ +playfield-left-border+ out-x dp))
                              tag))))))))))))

;;; ---------------------------------------------------------------------------
;;; GTIA color modes 9/10/11 (ROADMAP.md Phase 7)

(defun %render-gtia-mode (fb pf-base screen-ptr gtia-mode gtia-wr bus
                          &optional tags)
  "Render one ANTIC mode-F scanline reinterpreted by a GTIA color mode.

GTIA-MODE is the PRIOR bits 6-7 selector: 1 = GTIA mode 9 (16
luminances of one hue), 2 = mode 10 (9 colors), 3 = mode 11 (16 hues at
one luminance).  ANTIC still fetches mode F's 40 bytes, but GTIA
consumes them as 80 four-bit nibbles instead of 320 one-bit pixels, so
each nibble is one wide pixel — 4 output columns at this renderer's
320-column playfield scale.

Nibble → color byte:
  Mode 9:  (COLBK & $F0) | nibble — the nibble replaces COLBK's
           luminance bits, keeping its hue.  NOTE: this project's
           palette is 128 entries indexed by (color >> 1), i.e. color
           bit 0 is ignored (see ATARI-COLOR->R and the deliberate
           PALETTE-BIT0-IGNORED test), so the 16 nibble values collapse
           to 8 distinct luminances in pairs.  The color BYTE produced
           here is hardware-correct; widening the palette to 256
           entries would recover all 16 shades and is the only change
           needed (GTIA-MODE-9-LUMINANCE-PAIRS-COLLAPSE pins the
           current behaviour).
  Mode 10: the nibble selects a color REGISTER — 0-3 → COLPM0-3,
           4-7 → COLPF0-3, 8 → COLBK.  Those nine registers are
           contiguous in the write window ($12-$1A), so the nibble
           indexes them directly.  Values 9-15 are outside the
           documented range; we clamp them to 8 (COLBK), matching a
           minimal 'bit 3 set selects background' decode.  **CONFIRM**
           against Altirra/atari800 gtia.c — unverified here.
  Mode 11: (nibble << 4) | (COLBK & $0F) — the nibble supplies the hue
           and COLBK the luminance.  Nibble 0 is therefore hue 0 at
           COLBK's luminance (a gray, not black): GTIA mode 11 cannot
           display black unless COLBK's luminance is itself 0.

When TAGS is non-NIL every column is tagged PF2, the same source tag a
normal mode-F pixel carries, so Phase 6b's P/M priority arbitration
behaves sensibly.  Per-pixel priority nuances within the GTIA modes —
notably mode 10's COLPM0-3 selections, which on hardware carry player
priority rather than playfield priority — are NOT modelled."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb gtia-wr)
           (type fixnum pf-base gtia-mode)
           (type (unsigned-byte 16) screen-ptr)
           (type bus bus)
           (type (or null (simple-array (unsigned-byte 8) (384))) tags))
  (let ((colbk (aref gtia-wr +w-colbk+)))
    (dotimes (bx 40)
      (let ((byte (atari800-cl.bus:bus-read
                   bus (ldb (byte 16 0) (+ screen-ptr bx)))))
        (dotimes (half 2)
          (let* ((nibble (if (zerop half)
                             (ldb (byte 4 4) byte)
                             (ldb (byte 4 0) byte)))
                 (color  (case gtia-mode
                           (1 (logior (logand colbk #xF0) nibble))
                           (2 (aref gtia-wr (+ +w-colpm0+ (min nibble 8))))
                           (t (logior (ash nibble 4) (logand colbk #x0F)))))
                 (out-x  (* (+ (* bx 2) half) 4))
                 (p      (+ pf-base (* out-x 3))))
            (declare (type fixnum out-x p))
            (dotimes (d 4)
              (%write-rgb fb (+ p (* d 3)) color)
              (when tags
                (setf (aref tags (+ +playfield-left-border+ out-x d))
                      +tag-pf2+)))))))))

;;; ---------------------------------------------------------------------------
;;; Player/missile compositing

(defun %mark-pm-span (pm-row hpos px-w graf nbits chan-bit min-x max-x)
  "Mark one P/M object's coverage into PM-ROW (the GTIA's PM-MASK-ROW).
GRAF's NBITS bits are read MSB-first; each SET bit ORs CHAN-BIT into
PX-W/NBITS consecutive columns, starting at framebuffer column
HPOS*2 - 64 (HPOS 0 is off-screen left, HPOS 128 is center).  Columns
outside 0-383 are clipped.  Returns (VALUES MIN-X MAX-X) updated with
the extent actually marked, so the arbitration pass can skip untouched
columns."
  (declare (type (simple-array (unsigned-byte 8) (384)) pm-row)
           (type fixnum px-w nbits chan-bit min-x max-x)
           (type (unsigned-byte 8) hpos graf))
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
                (setf (aref pm-row x) (logior (aref pm-row x) chan-bit))
                (when (< x min-x) (setf min-x x))
                (when (> x max-x) (setf max-x x))))))))
    (values min-x max-x)))

(defun %paint-fifth-player-missile (fb row-base tags hpos px-w graf colpf3)
  "Paint one missile's pixels as PLAYFIELD 3 (the PRIOR bit-4 fifth
player): each of GRAF's 2 bits paints PX-W/2 columns with COLPF3 and
records tag PF3, so subsequent player arbitration treats the pixels
exactly like playfield 3 — the atari800 model of 'the fifth player has
playfield 3's priority'."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type (simple-array (unsigned-byte 8) (384)) tags)
           (type fixnum row-base px-w)
           (type (unsigned-byte 8) hpos graf colpf3))
  (let ((left         (- (* hpos 2) 64))
        (cols-per-bit (truncate px-w 2)))
    (declare (type fixnum left cols-per-bit))
    (dotimes (bit 2)
      (when (logbitp (- 1 bit) graf)
        (let ((x0 (+ left (* bit cols-per-bit))))
          (declare (type fixnum x0))
          (dotimes (d cols-per-bit)
            (let ((x (+ x0 d)))
              (declare (type fixnum x))
              (when (and (>= x 0) (< x +framebuffer-width+))
                (setf (aref tags x) +tag-pf3+)
                (%write-rgb fb (+ row-base (* x 3)) colpf3)))))))))

(defun %render-pm-layer (fb row-base prior gtia)
  "Composite player/missile graphics over the already-rendered playfield
row with the full PRIOR priority model (ROADMAP.md Phase 6b).

PRIOR bits 0-3 select the priority ordering between player channels and
playfield sources — see +PM-BEATS-PF-MASKS+ for the four orderings.
Exactly one bit is normally set; when several are set the lowest wins
here, and when none are set the bit-0 ordering (P/M on top) is used.
Real GTIA produces color-merged/black conflict colors in those two
cases — a documented simplification.

Missile m normally has player m's priority and COLPMm's color, so its
coverage is simply merged into channel m.  PRIOR bit 4 (fifth player)
instead paints all four missiles as PLAYFIELD 3 — COLPF3 color, PF3
source tag — before player arbitration, giving them exactly playfield
3's priority (the atari800 model).  PRIOR bit 5 (multicolor players)
ORs the color registers where P0/P1 overlap (and P2/P3 likewise).
PRIOR bits 6-7 select the GTIA color modes:
;; Phase 7: GTIA modes 9/10/11 hook in at the RENDER-SCANLINE level.

Mechanics: enabled objects mark their coverage into the GTIA's
PM-MASK-ROW scratch (one channel bit per column, bounded extent), then
one arbitration pass over the marked extent resolves, per column, the
highest-priority present channel against the playfield source tag the
playfield renderers recorded in PF-TAG-ROW.  RENDER-SCANLINE only calls
this (and only maintains the tag row) when some GRAF register is
non-zero, so rows without P/M objects — the common case — cost nothing
beyond that check."
  (declare (type (simple-array (unsigned-byte 8) (*)) fb)
           (type (unsigned-byte 8) prior)
           (type fixnum row-base)
           (type gtia gtia))
  (let* ((wr     (gtia-write-regs gtia))
         (tags   (gtia-pf-tag-row gtia))
         (pm     (gtia-pm-mask-row gtia))
         (grafp0 (aref wr +w-grafp0+))
         (grafp1 (aref wr (+ +w-grafp0+ 1)))
         (grafp2 (aref wr (+ +w-grafp0+ 2)))
         (grafp3 (aref wr (+ +w-grafp0+ 3)))
         (grafm  (aref wr +w-grafm+)))
    (when (plusp (logior grafp0 grafp1 grafp2 grafp3 grafm))
      (let ((fifth-p (logtest prior #x10))
            (multi-p (logtest prior #x20))
            (srow    (cond ((logtest prior #x01) 0)
                           ((logtest prior #x02) 1)
                           ((logtest prior #x04) 2)
                           ((logtest prior #x08) 3)
                           (t 0)))
            (min-x   +framebuffer-width+)
            (max-x   -1))
        (declare (type fixnum srow min-x max-x))
        (fill pm 0)
        ;; Missiles: as the fifth player they become playfield 3 pixels
        ;; right now; otherwise their coverage joins player channel m.
        (when (plusp grafm)
          (let ((sizem (aref wr +w-sizem+)))
            (dotimes (m 4)
              (let ((bits (ldb (byte 2 (- 6 (* m 2))) grafm))
                    (px-w (case (ldb (byte 2 (* m 2)) sizem)
                            (0 2) (1 4) (2 8) (t 16))))
                (when (plusp bits)
                  (if fifth-p
                      (%paint-fifth-player-missile
                       fb row-base tags
                       (aref wr (+ +w-hposm0+ m)) px-w bits
                       (aref wr (+ +w-colpf0+ 3)))
                      (multiple-value-setq (min-x max-x)
                        (%mark-pm-span pm (aref wr (+ +w-hposm0+ m))
                                       px-w bits 2 (ash 1 m)
                                       min-x max-x))))))))
        ;; Players: mark coverage per channel.
        (flet ((mark-player (p grafp)
                 (declare (type fixnum p) (type (unsigned-byte 8) grafp))
                 (when (plusp grafp)
                   (multiple-value-setq (min-x max-x)
                     (%mark-pm-span pm (aref wr (+ +w-hposp0+ p))
                                    (case (aref wr (+ +w-sizep0+ p))
                                      (2 16) (4 32) (t 8))
                                    grafp 8 (ash 1 p)
                                    min-x max-x)))))
          (mark-player 0 grafp0)
          (mark-player 1 grafp1)
          (mark-player 2 grafp2)
          (mark-player 3 grafp3))
        ;; Arbitration pass over the marked extent.
        (loop for x fixnum from min-x to max-x
              do (let ((mask (aref pm x)))
                   (unless (zerop mask)
                     (let* ((chan  (cond ((logtest mask #x01) 0)
                                         ((logtest mask #x02) 1)
                                         ((logtest mask #x04) 2)
                                         (t 3)))
                            (beats (aref +pm-beats-pf-masks+ srow chan)))
                       (when (logbitp (aref tags x) beats)
                         (let ((color (aref wr (+ +w-colpm0+ chan))))
                           ;; Multicolor: overlapping P0/P1 (P2/P3) OR
                           ;; their color registers.
                           (when multi-p
                             (cond ((and (= chan 0) (logtest mask #x02))
                                    (setf color (logior color
                                                        (aref wr (+ +w-colpm0+ 1)))))
                                   ((and (= chan 2) (logtest mask #x08))
                                    (setf color (logior color
                                                        (aref wr (+ +w-colpm0+ 3)))))))
                           (%write-rgb fb (+ row-base (* x 3)) color)))))))))))

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
     When PRIOR bits 6-7 select a GTIA color mode AND the ANTIC mode is F,
     the line goes to %RENDER-GTIA-MODE instead (modes 9/10/11).
  3. Composite player/missile graphics using PRIOR for priority
     (span-based; see %RENDER-PM-LAYER).

GTIA color modes are evaluated per scanline, so a DLI that rewrites
PRIOR mid-frame switches modes exactly where the hardware would.  With
the GTIA bits set on an ANTIC mode OTHER than F, hardware reinterprets
whatever color-clock stream that mode emits and generally produces
garbage; we render the ANTIC mode normally and leave it at that.

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
         (pf-base (+ row-base (* +playfield-left-border+ 3)))
         ;; P/M compositing (and therefore the playfield source-tag row
         ;; it arbitrates against) is only needed when some GRAF register
         ;; is non-zero; rows without P/M objects skip all tag work.
         (pm-active-p (plusp (logior (aref wr +w-grafp0+)
                                     (aref wr (+ +w-grafp0+ 1))
                                     (aref wr (+ +w-grafp0+ 2))
                                     (aref wr (+ +w-grafp0+ 3))
                                     (aref wr +w-grafm+))))
         (tags    (and pm-active-p (gtia-pf-tag-row gtia))))
    (when tags (fill tags +tag-bak+))
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
       (let ((gtia-mode (ldb (byte 2 6) prior)))
         (cond
           ((or (= mode 4) (= mode 5))
            (%render-multicolor-char-mode fb pf-base sptr scan-y mode wr bus chbase tags))
           ((<= mode 7)
            (%render-char-mode fb pf-base sptr scan-y mode wr bus chbase tags))
           ;; GTIA color modes reinterpret an ANTIC mode-F fetch.
           ((and (plusp gtia-mode) (= mode 15))
            (%render-gtia-mode fb pf-base sptr gtia-mode wr bus tags))
           (t
            (%render-bitmap-mode fb pf-base sptr mode wr bus tags)))))
      (t
       (%fill-row fb row-base colbk)))
    ;; Step 3: player/missile compositing (full PRIOR arbitration).
    (when pm-active-p
      (%render-pm-layer fb row-base prior gtia))))
