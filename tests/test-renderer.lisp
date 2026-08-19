;;;; tests/test-renderer.lisp --- Renderer unit tests.

(in-package #:atari800-cl/tests)

(def-suite renderer-suite
  :description "Pixel-level NTSC renderer: palette, scanline output, P/M compositing."
  :in atari800-cl-suite)

(in-suite renderer-suite)

;;; ---------------------------------------------------------------------------
;;; Palette tests

(test palette-gray-hue-is-neutral
  "Hue-0 colors have R = G = B at every luminance level."
  (dotimes (lum 8)
    (let ((c (* lum 2)))
      (is (= (atari800-cl.renderer:atari-color->r c)
             (atari800-cl.renderer:atari-color->g c)
             (atari800-cl.renderer:atari-color->b c))
          "hue-0 lum ~D: expected R=G=B but got R=~D G=~D B=~D"
          lum
          (atari800-cl.renderer:atari-color->r c)
          (atari800-cl.renderer:atari-color->g c)
          (atari800-cl.renderer:atari-color->b c)))))

(test palette-luminance-increases
  "Grayscale brightness strictly increases with luminance (hue 0)."
  (let ((prev -1))
    (dotimes (lum 8)
      (let ((r (atari800-cl.renderer:atari-color->r (* lum 2))))
        (is (> r prev) "lum ~D: brightness ~D not > prev ~D" lum r prev)
        (setf prev r)))))

(test palette-bit0-ignored
  "Color #x40 and #x41 map to the same RGB (bit 0 is discarded)."
  (is (= (atari800-cl.renderer:atari-color->r #x40)
         (atari800-cl.renderer:atari-color->r #x41)))
  (is (= (atari800-cl.renderer:atari-color->g #x40)
         (atari800-cl.renderer:atari-color->g #x41)))
  (is (= (atari800-cl.renderer:atari-color->b #x40)
         (atari800-cl.renderer:atari-color->b #x41))))

(test palette-colored-hue-not-neutral
  "A non-zero hue produces R≠G or R≠B (is not neutral gray)."
  ;; Hue 1, luminance 3 → color byte #x16.
  (let ((r (atari800-cl.renderer:atari-color->r #x16))
        (g (atari800-cl.renderer:atari-color->g #x16))
        (b (atari800-cl.renderer:atari-color->b #x16)))
    (is (not (and (= r g) (= g b)))
        "Expected colored pixel but got R=~D G=~D B=~D" r g b)))

;;; ---------------------------------------------------------------------------
;;; Framebuffer tests

(test make-framebuffer-correct-size
  "make-framebuffer produces a zeroed 384×240×3 byte vector."
  (let ((fb (atari800-cl.renderer:make-framebuffer)))
    (is (= (* 384 240 3) (length fb)))
    (is (every #'zerop fb))))

;;; ---------------------------------------------------------------------------
;;; Scanline rendering — blank/background

(test render-scanline-blank-mode-fills-with-colbk
  "Mode 0 (blank) with DMACTL=0: entire row is COLBK."
  (let* ((bus   (atari800-cl.bus:make-bus))
         (antic (atari800-cl.antic:make-antic))
         (gtia  (atari800-cl.gtia:make-gtia))
         (fb    (atari800-cl.renderer:make-framebuffer)))
    ;; COLBK = #x28 (orange-ish)
    (atari800-cl.gtia:gtia-write gtia #xD01A #x28)
    ;; current-mode = 0 (blank), DMACTL = 0 → no playfield.
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (let ((r (atari800-cl.renderer:atari-color->r #x28))
          (g (atari800-cl.renderer:atari-color->g #x28))
          (b (atari800-cl.renderer:atari-color->b #x28)))
      ;; First pixel
      (is (= r (aref fb 0)))
      (is (= g (aref fb 1)))
      (is (= b (aref fb 2)))
      ;; Last pixel
      (is (= r (aref fb (* 383 3))))
      (is (= g (aref fb (+ (* 383 3) 1))))
      (is (= b (aref fb (+ (* 383 3) 2)))))))

;;; ---------------------------------------------------------------------------
;;; Scanline rendering — bitmap mode F (1bpp high-res, 320px)

(test render-scanline-mode-f-all-ones
  "Mode F with 40 bytes of #xFF in screen RAM: active area all COLPF2."
  (let* ((bus   (atari800-cl.bus:make-bus))
         (antic (atari800-cl.antic:make-antic))
         (gtia  (atari800-cl.gtia:make-gtia))
         (fb    (atari800-cl.renderer:make-framebuffer)))
    ;; Load 40 bytes of #xFF at $4000.
    (dotimes (i 40)
      (atari800-cl.bus:bus-poke-ram bus (+ #x4000 i) #xFF))
    ;; COLPF2 = #xC4, COLBK = #x00.
    (atari800-cl.gtia:gtia-write gtia #xD018 #xC4)   ; COLPF2
    (atari800-cl.gtia:gtia-write gtia #xD01A #x00)   ; COLBK = black
    ;; Force ANTIC into mode F with screen-data-ptr at $4000, DMACTL on.
    (setf (atari800-cl.antic:antic-current-mode           antic) #x0F
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (let ((pf2-r (atari800-cl.renderer:atari-color->r #xC4))
          (bk-r  (atari800-cl.renderer:atari-color->r #x00)))
      ;; Left border (columns 0-31) should be COLBK.
      (is (= bk-r (aref fb 0))
          "Left border should be COLBK, got ~D" (aref fb 0))
      ;; First active pixel (column 32) should be COLPF2.
      (is (= pf2-r (aref fb (* 32 3)))
          "First active pixel should be COLPF2 ~D, got ~D" pf2-r (aref fb (* 32 3)))
      ;; Last active pixel (column 351).
      (is (= pf2-r (aref fb (* 351 3)))
          "Last active pixel should be COLPF2 ~D, got ~D" pf2-r (aref fb (* 351 3)))
      ;; Right border (columns 352-383) should be COLBK.
      (is (= bk-r (aref fb (* 352 3)))
          "Right border should be COLBK, got ~D" (aref fb (* 352 3))))))

;;; ---------------------------------------------------------------------------
;;; Map-mode hardware geometry (ROADMAP Phases 1-5 review fixes)
;;;
;;; These pin %RENDER-BITMAP-MODE to the real-hardware byte counts and
;;; color depths (BYTES-PER-SCREEN-ROW): mode 8 = 10 bytes 2bpp, mode 9
;;; = 10 bytes 1bpp, modes D/E = 40 bytes 2bpp, with 1bpp map pixels in
;;; COLPF0.  The pre-fix renderer used made-up geometry (mode 8 as 40
;;; bytes 1bpp, mode E as 20 bytes, ...), which had also leaked into the
;;; DMA-steal tables.

(defun %make-render-fixture ()
  "Return (VALUES BUS ANTIC GTIA FB) with standard playfield colors:
COLPF0 = #x24, COLPF1 = #x46, COLPF2 = #x68, COLBK = #x00."
  (let ((bus   (atari800-cl.bus:make-bus))
        (antic (atari800-cl.antic:make-antic))
        (gtia  (atari800-cl.gtia:make-gtia))
        (fb    (atari800-cl.renderer:make-framebuffer)))
    (atari800-cl.gtia:gtia-write gtia #xD016 #x24)   ; COLPF0
    (atari800-cl.gtia:gtia-write gtia #xD017 #x46)   ; COLPF1
    (atari800-cl.gtia:gtia-write gtia #xD018 #x68)   ; COLPF2
    (atari800-cl.gtia:gtia-write gtia #xD01A #x00)   ; COLBK
    (values bus antic gtia fb)))

(defun %fb-r (fb column)
  "Red component of framebuffer column COLUMN in row 0."
  (aref fb (* column 3)))

(test render-mode-8-is-10-bytes-2bpp-8x-wide
  "Mode 8 (GR.3): one screen byte holds four 2bpp pixels, each 8 output
columns wide; values 0-3 map to COLBK/COLPF0/COLPF1/COLPF2."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    ;; #x6C = 01 10 11 00 -> PF0, PF1, PF2, BAK.
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x6C)
    (setf (atari800-cl.antic:antic-current-mode           antic) #x08
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 32))
        "pixel value 01 must render COLPF0 at the first active column")
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 39))
        "each mode-8 pixel must span 8 output columns (col 39 still PF0)")
    (is (= (atari800-cl.renderer:atari-color->r #x46) (%fb-r fb 40))
        "pixel value 10 must render COLPF1 starting at column 40")
    (is (= (atari800-cl.renderer:atari-color->r #x68) (%fb-r fb 48))
        "pixel value 11 must render COLPF2 starting at column 48")
    (is (= (atari800-cl.renderer:atari-color->r #x00) (%fb-r fb 56))
        "pixel value 00 must render COLBK starting at column 56")))

(test render-mode-9-is-10-bytes-1bpp-pf0
  "Mode 9 (GR.4): 10 bytes of 1bpp pixels, 4 output columns each; set
pixels use COLPF0 (not COLPF2), and the LAST of the 10 bytes lands at
the right edge of the active area."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x80)         ; first px set
    (atari800-cl.bus:bus-poke-ram bus (+ #x4000 9) #x01)   ; last px set
    (setf (atari800-cl.antic:antic-current-mode           antic) #x09
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 32))
        "set 1bpp map pixel must render COLPF0")
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 35))
        "each mode-9 pixel must span 4 output columns")
    (is (= (atari800-cl.renderer:atari-color->r #x00) (%fb-r fb 36))
        "clear pixel must render COLBK")
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 351))
        "byte 9 bit 0 must render at the last active column (349-351)")
    (is (= (atari800-cl.renderer:atari-color->r #x00) (%fb-r fb 347))
        "the pixel before byte 9's last bit must still be COLBK")))

(test render-mode-e-reads-40-bytes
  "Mode E (GR.15): 40 bytes of 2bpp pixels, 2 output columns each; byte
39 colors the last 8 active columns (the pre-fix renderer stopped at
20 bytes and never read it)."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.bus:bus-poke-ram bus (+ #x4000 39) #xFF)  ; 4x pixel value 11
    (setf (atari800-cl.antic:antic-current-mode           antic) #x0E
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x00) (%fb-r fb 343))
        "columns from bytes 0-38 (all zero) must be COLBK")
    (is (= (atari800-cl.renderer:atari-color->r #x68) (%fb-r fb 344))
        "byte 39 must color columns 344-351 COLPF2 (pixel value 11)")
    (is (= (atari800-cl.renderer:atari-color->r #x68) (%fb-r fb 351))
        "...through the last active column")))

;;; ---------------------------------------------------------------------------
;;; Mode 2 with DMA stealing active, end to end (ROADMAP.md Phase 5's
;;; deferred render test): a real display list fetched by ANTIC under
;;; the scanline scheduler -- with DL-fetch + playfield steals charged --
;;; must still render the expected glyph pixels.

(test render-mode-2-frame-with-dma-steal-active
  "One full frame of a 24-line mode-2 display list (LMS $5000, glyphs at
CHBASE $60) renders solid COLPF2 glyph rows while playfield DMA stealing
is active."
  (let* ((m    (make-test-machine))
         (bus  (atari800-cl.machine:atari-machine-bus  m))
         (gtia (atari800-cl.machine:atari-machine-gtia m))
         (fb   (atari800-cl.renderer:make-framebuffer)))
    ;; DL at $4000: mode 2 + LMS -> $5000, 23 plain mode-2 lines, JVB.
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x42)
    (atari800-cl.bus:bus-poke-ram bus #x4001 #x00)
    (atari800-cl.bus:bus-poke-ram bus #x4002 #x50)
    (dotimes (i 23)
      (atari800-cl.bus:bus-poke-ram bus (+ #x4003 i) #x02))
    (atari800-cl.bus:bus-poke-ram bus #x401A #x41)   ; JVB
    (atari800-cl.bus:bus-poke-ram bus #x401B #x00)
    (atari800-cl.bus:bus-poke-ram bus #x401C #x40)
    ;; Screen RAM: 24 rows x 40 chars of char code 1.
    (dotimes (i (* 24 40))
      (atari800-cl.bus:bus-poke-ram bus (+ #x5000 i) #x01))
    ;; Char set at $6000: char 1's 8 glyph rows all #xFF (solid block).
    (dotimes (r 8)
      (atari800-cl.bus:bus-poke-ram bus (+ #x6008 r) #xFF))
    (atari800-cl.bus:bus-write bus #xD409 #x60)      ; CHBASE
    (atari800-cl.bus:bus-write bus #xD018 #x68)      ; COLPF2
    (atari800-cl.bus:bus-write bus #xD01A #x00)      ; COLBK
    (atari800-cl.bus:bus-write bus #xD402 #x00)      ; DLISTL
    (atari800-cl.bus:bus-write bus #xD403 #x40)      ; DLISTH
    (atari800-cl.bus:bus-write bus #xD400 #x22)      ; DMACTL
    ;; Render each completed active line, wired as the AESP server does.
    (setf (atari800-cl.machine:atari-machine-scanline-fn m)
          (lambda (mach)
            (let* ((a   (atari800-cl.machine:atari-machine-antic mach))
                   (sl  (mod (1- (atari800-cl.antic:antic-scanline a))
                             atari800-cl.antic:+scanlines-per-frame+))
                   (row (- sl atari800-cl.antic:+active-start-scanline+)))
              (when (and (>= row 0) (< row 240))
                (atari800-cl.renderer:render-scanline fb row a gtia bus)))))
    (atari800-cl.machine:machine-run-frame m)
    (let ((pf2-r (atari800-cl.renderer:atari-color->r #x68))
          (bk-r  (atari800-cl.renderer:atari-color->r #x00)))
      ;; Row 0 (scanline 8) is the first glyph row of the first mode line.
      (flet ((px-r (row col) (aref fb (+ (* row 384 3) (* col 3)))))
        (is (= bk-r  (px-r 0 0))   "left border must be COLBK")
        (is (= pf2-r (px-r 0 32))  "first active column must be COLPF2")
        (is (= pf2-r (px-r 0 351)) "last active column must be COLPF2")
        (is (= bk-r  (px-r 0 352)) "right border must be COLBK")
        (is (= pf2-r (px-r 100 100))
            "a mid-frame glyph row must also be COLPF2")
        (is (= bk-r (px-r 200 100))
            "rows after the 24 mode lines (192 scanlines) must be COLBK")))))

;;; ---------------------------------------------------------------------------
;;; P/M graphics compositing

(test pm-player0-overwrites-background
  "Player 0 with GRAFP0=#xFF, HPOSP0=80 overwrites background pixels."
  (let* ((bus   (atari800-cl.bus:make-bus))
         (antic (atari800-cl.antic:make-antic))
         (gtia  (atari800-cl.gtia:make-gtia))
         (fb    (atari800-cl.renderer:make-framebuffer)))
    ;; HPOSP0 = 80 → framebuffer column 80*2-64 = 96.
    (atari800-cl.gtia:gtia-write gtia #xD000 80)    ; HPOSP0
    (atari800-cl.gtia:gtia-write gtia #xD00D #xFF)  ; GRAFP0 = all bits set
    (atari800-cl.gtia:gtia-write gtia #xD012 #x28)  ; COLPM0
    (atari800-cl.gtia:gtia-write gtia #xD01A #x00)  ; COLBK = black
    ;; PRIOR bit 1 clear → P/M on top (default).
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    ;; Column 96 should be COLPM0.
    (is (= (atari800-cl.renderer:atari-color->r #x28)
           (aref fb (* 96 3)))
        "Expected COLPM0 at column 96, got ~D" (aref fb (* 96 3)))))

;;; ---------------------------------------------------------------------------
;;; Character-mode color selection (pins the per-character color-pair
;;; hoisting in %RENDER-CHAR-MODE)

(test render-mode-2-inverse-and-alternate-chars
  "Mode 2 attribute bits: bit 7 (inverse) swaps glyph-on/off colors,
bit 6 (alternate) draws set glyph bits in COLPF1."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    ;; Char set at $6000; char 1's glyph row 0 = #xF0 (left half set).
    (atari800-cl.bus:bus-poke-ram bus #x6008 #xF0)
    ;; Screen row at $4000: normal char 1, inverse char 1 (#x81),
    ;; alternate char 1 (#x41).
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x01)
    (atari800-cl.bus:bus-poke-ram bus #x4001 #x81)
    (atari800-cl.bus:bus-poke-ram bus #x4002 #x41)
    (setf (atari800-cl.antic:antic-current-mode           antic) #x02
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22
          (aref (atari800-cl.antic:antic-registers antic)
                atari800-cl.antic:+reg-chbase+)                  #x60)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (let ((bk-r  (atari800-cl.renderer:atari-color->r #x00))
          (pf1-r (atari800-cl.renderer:atari-color->r #x46))
          (pf2-r (atari800-cl.renderer:atari-color->r #x68)))
      ;; Char 0 (cols 32-39): set bits -> PF2, clear bits -> BAK.
      (is (= pf2-r (%fb-r fb 32)) "normal: glyph-on must be COLPF2")
      (is (= bk-r  (%fb-r fb 36)) "normal: glyph-off must be COLBK")
      ;; Char 1 (cols 40-47), inverse: colors swapped.
      (is (= bk-r  (%fb-r fb 40)) "inverse: glyph-on must be COLBK")
      (is (= pf2-r (%fb-r fb 44)) "inverse: glyph-off must be COLPF2")
      ;; Char 2 (cols 48-55), alternate: glyph-on is COLPF1.
      (is (= pf1-r (%fb-r fb 48)) "alternate: glyph-on must be COLPF1")
      (is (= bk-r  (%fb-r fb 52)) "alternate: glyph-off must be COLBK"))))

(test render-mode-6-wide-chars-select-color-from-char-bits
  "Mode 6: 20 chars of 16 px; the char's top two bits select the on
color (00 -> COLPF0, 01 -> COLPF1) and each glyph bit spans 2 columns."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.bus:bus-poke-ram bus #x6008 #x80)   ; char 1 row 0: bit 7 only
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x01)   ; char 1, top bits 00
    (atari800-cl.bus:bus-poke-ram bus #x4001 #x41)   ; char 1, top bits 01
    (setf (atari800-cl.antic:antic-current-mode           antic) #x06
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22
          (aref (atari800-cl.antic:antic-registers antic)
                atari800-cl.antic:+reg-chbase+)                  #x60)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (let ((bk-r  (atari800-cl.renderer:atari-color->r #x00))
          (pf0-r (atari800-cl.renderer:atari-color->r #x24))
          (pf1-r (atari800-cl.renderer:atari-color->r #x46)))
      ;; Char 0 (cols 32-47): bit 7 covers columns 32-33 in COLPF0.
      (is (= pf0-r (%fb-r fb 32)) "top bits 00 -> COLPF0")
      (is (= pf0-r (%fb-r fb 33)) "wide char: glyph bit spans 2 columns")
      (is (= bk-r  (%fb-r fb 34)) "cleared glyph bits -> COLBK")
      ;; Char 1 (cols 48-63): bit 7 covers columns 48-49 in COLPF1.
      (is (= pf1-r (%fb-r fb 48)) "top bits 01 -> COLPF1")
      (is (= bk-r  (%fb-r fb 50))))))

(test render-mode-5-multicolor-pixel-pairs
  "Mode 5 (and 4): each glyph byte is 4 pixel-pairs (MSB first), not 8
on/off bits -- 00/01/10/11 -> BAK/PF0/PF1/PF2, and 11 -> PF3 instead of
PF2 when the character code's bit 7 is set (Compute!'s First Book of
Atari Graphics ch.3, \"The Four-Color Character Modes\").  This pins the
FRAME_RAW/Attic interop bug where mode 4/5 text rendered as flat
single-color glyphs instead of genuine per-pixel-pair multicolor."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.gtia:gtia-write gtia #xD019 #x8A)   ; COLPF3
    ;; Char 1 row 0 = 0b00_01_10_11: BAK, PF0, PF1, PF2 (or PF3).
    (atari800-cl.bus:bus-poke-ram bus #x6008 #x1B)
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x01)   ; char 1, bit 7 clear
    (atari800-cl.bus:bus-poke-ram bus #x4001 #x81)   ; char 1, bit 7 set
    (setf (atari800-cl.antic:antic-current-mode           antic) #x05
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22
          (aref (atari800-cl.antic:antic-registers antic)
                atari800-cl.antic:+reg-chbase+)                  #x60)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (let ((bk-r  (atari800-cl.renderer:atari-color->r #x00))
          (pf0-r (atari800-cl.renderer:atari-color->r #x24))
          (pf1-r (atari800-cl.renderer:atari-color->r #x46))
          (pf2-r (atari800-cl.renderer:atari-color->r #x68))
          (pf3-r (atari800-cl.renderer:atari-color->r #x8A)))
      ;; Char 0 (cols 32-39), bit 7 clear: pairs 00/01/10/11 -> BAK/PF0/PF1/PF2,
      ;; each pair 2 columns wide.
      (is (= bk-r  (%fb-r fb 32)) "pair 00 -> COLBK")
      (is (= bk-r  (%fb-r fb 33)) "pixel-pair spans 2 columns")
      (is (= pf0-r (%fb-r fb 34)) "pair 01 -> COLPF0")
      (is (= pf1-r (%fb-r fb 36)) "pair 10 -> COLPF1")
      (is (= pf2-r (%fb-r fb 38)) "pair 11, bit7 clear -> COLPF2")
      ;; Char 1 (cols 40-47), bit 7 set: only the 11 pair changes, to PF3.
      (is (= bk-r  (%fb-r fb 40)) "bit7 set: pair 00 is still COLBK")
      (is (= pf0-r (%fb-r fb 42)) "bit7 set: pair 01 is still COLPF0")
      (is (= pf1-r (%fb-r fb 44)) "bit7 set: pair 10 is still COLPF1")
      (is (= pf3-r (%fb-r fb 46)) "bit7 set: pair 11 -> COLPF3, not COLPF2"))))

(test render-mode-5-double-height-stretches-glyph-rows
  "Mode 5 is 16 real scanlines per mode line but the character ROM only
has 8 rows per glyph: row = SCAN-Y/2 (each ROM row shown for 2 scanlines
running down the character), not SCAN-Y mod 8 (which would show ROM
rows 0-7 again for scanlines 8-15, drawing the line's text a second
time -- exactly what a real Atari does not do, and what edvent02.asm's
\"HELLO ATARI!\" banner visibly doubled before this fix)."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    ;; Char 1: ROM row 0 = all PF2 (0xFF -> four 11 pairs); ROM row 4 =
    ;; all BAK (0x00).  Real scanlines 0-1 show ROM row 0; scanlines 8-9
    ;; (SCAN-Y/2 = 4) show ROM row 4 -- the buggy SCAN-Y mod 8 would
    ;; instead show ROM row 0 again at scanline 8.
    (atari800-cl.bus:bus-poke-ram bus #x6008 #xFF)   ; chbase*256 + 1*8 + 0
    (atari800-cl.bus:bus-poke-ram bus #x600C #x00)   ; chbase*256 + 1*8 + 4
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x01)   ; char 1, bit 7 clear
    (setf (atari800-cl.antic:antic-current-mode           antic) #x05
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22
          (aref (atari800-cl.antic:antic-registers antic)
                atari800-cl.antic:+reg-chbase+)                  #x60)
    (let ((bk-r  (atari800-cl.renderer:atari-color->r #x00))
          (pf2-r (atari800-cl.renderer:atari-color->r #x68)))
      (setf (atari800-cl.antic:antic-scan-y antic) 0)
      (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
      (is (= pf2-r (%fb-r fb 32)) "scan-y=0 -> ROM row 0 (all PF2)")
      (setf (atari800-cl.antic:antic-scan-y antic) 8)
      (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
      (is (= bk-r (%fb-r fb 32))
          "scan-y=8 must show ROM row 4 (all BAK), not ROM row 0 again"))))

;;; ---------------------------------------------------------------------------
;;; Span-based P/M compositing semantics
;;;
;;; %RENDER-PM-LAYER paints per-object spans lowest-priority-first
;;; instead of scanning all 8 objects at every column; these pin the
;;; arbitration, sizing, missile geometry, and clipping the old
;;; per-pixel implementation defined.

(test pm-player0-wins-overlap-with-player1
  "P0 and P1 overlapping at the same HPOS: P0's color wins (lower index
= higher priority), and P1 shows through where P0's bits are clear."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.gtia:gtia-write gtia #xD000 80)    ; HPOSP0
    (atari800-cl.gtia:gtia-write gtia #xD001 80)    ; HPOSP1
    (atari800-cl.gtia:gtia-write gtia #xD00D #xF0)  ; GRAFP0: left half
    (atari800-cl.gtia:gtia-write gtia #xD00E #xFF)  ; GRAFP1: all bits
    (atari800-cl.gtia:gtia-write gtia #xD012 #x28)  ; COLPM0
    (atari800-cl.gtia:gtia-write gtia #xD013 #x46)  ; COLPM1
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    ;; HPOS 80 -> column 96.  Columns 96-99: both cover, P0 bit set -> P0.
    (is (= (atari800-cl.renderer:atari-color->r #x28) (%fb-r fb 96))
        "overlap with P0 bit set must show COLPM0")
    ;; Columns 100-103: P0's bits clear, P1's set -> P1 shows through.
    (is (= (atari800-cl.renderer:atari-color->r #x46) (%fb-r fb 100))
        "P0's clear bits must let P1 show through")))

(test pm-player-size-2-doubles-span
  "SIZEP0 = 2 doubles the player to 16 columns (2 per GRAFP bit)."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.gtia:gtia-write gtia #xD000 80)    ; HPOSP0 -> column 96
    (atari800-cl.gtia:gtia-write gtia #xD008 2)     ; SIZEP0 = 2
    (atari800-cl.gtia:gtia-write gtia #xD00D #xFF)  ; GRAFP0
    (atari800-cl.gtia:gtia-write gtia #xD012 #x28)  ; COLPM0
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x28) (%fb-r fb 96)))
    (is (= (atari800-cl.renderer:atari-color->r #x28) (%fb-r fb 111))
        "column 111 is the 16th and last column of the doubled player")
    (is (= (atari800-cl.renderer:atari-color->r #x00) (%fb-r fb 112))
        "column 112 is past the doubled player")))

(test pm-missile-uses-own-color-and-2px-width
  "Missile 1 (GRAFM bits 5-4) paints 2 columns at HPOSM1 in COLPM1 at
default SIZEM."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.gtia:gtia-write gtia #xD005 90)    ; HPOSM1 -> column 116
    (atari800-cl.gtia:gtia-write gtia #xD011 #x30)  ; GRAFM: missile 1 bits 11
    (atari800-cl.gtia:gtia-write gtia #xD013 #x46)  ; COLPM1
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x46) (%fb-r fb 116)))
    (is (= (atari800-cl.renderer:atari-color->r #x46) (%fb-r fb 117))
        "each GRAFM bit covers 1 column at SIZEM 0 (2 columns total)")
    (is (= (atari800-cl.renderer:atari-color->r #x00) (%fb-r fb 118))
        "column 118 is past the missile")))

(test pm-offscreen-spans-clip
  "Spans hanging off either framebuffer edge clip instead of erroring:
HPOSP0 = 10 (fully off-screen left) paints nothing; HPOSP1 = 220 with a
32-column quad player paints only up to column 383."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.gtia:gtia-write gtia #xD000 10)    ; HPOSP0 -> column -44
    (atari800-cl.gtia:gtia-write gtia #xD00D #xFF)  ; GRAFP0
    (atari800-cl.gtia:gtia-write gtia #xD012 #x28)  ; COLPM0
    (atari800-cl.gtia:gtia-write gtia #xD001 220)   ; HPOSP1 -> column 376
    (atari800-cl.gtia:gtia-write gtia #xD009 4)     ; SIZEP1 = 4 (32 cols)
    (atari800-cl.gtia:gtia-write gtia #xD00E #xFF)  ; GRAFP1
    (atari800-cl.gtia:gtia-write gtia #xD013 #x46)  ; COLPM1
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x00) (%fb-r fb 0))
        "a fully off-screen-left player must paint nothing at column 0")
    (is (= (atari800-cl.renderer:atari-color->r #x46) (%fb-r fb 383))
        "the right-edge player paints through the last column")))

;;; ---------------------------------------------------------------------------
;;; AESP frame-config bytes-per-pixel

(test aesp-frame-config-is-4-bytes-per-pixel
  "FRAME_CONFIG payload byte 4 must report 4 bytes per pixel, matching
FRAME_RAW's BGRA8888 wire format (see docs/PROTOCOL.md in the Attic
project) -- not the 24 bits this used to (wrongly) report."
  ;; Call the internal helper via the package-qualified name.
  (let ((payload (atari800-cl.aesp::%frame-config-payload)))
    (is (= 4 (aref payload 4))
        "Expected bytes-per-pixel=4 but got ~D" (aref payload 4))))

;;; ---------------------------------------------------------------------------
;;; Full PRIOR priority arbitration (ROADMAP.md Phase 6b)
;;;
;;; Playfield fixture for these tests: mode E with screen byte #x1B
;;; (2bpp pixels 00,01,10,11), giving columns 32-33 BAK, 34-35 PF0,
;;; 36-37 PF1, 38-39 PF2.  A normal-size player at HPOS 48 covers
;;; columns 32-39 -- one column pair per playfield source.

(defun %prior-fixture (prior &key (player 0) (grafp #xFF))
  "Return (VALUES BUS ANTIC GTIA FB) with the mode-E tag playfield, one
player at HPOS 48, and PRIOR set."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x1B)
    (setf (atari800-cl.antic:antic-current-mode           antic) #x0E
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22)
    (atari800-cl.gtia:gtia-write gtia (+ #xD000 player) 48)      ; HPOSPn
    (atari800-cl.gtia:gtia-write gtia (+ #xD00D player) grafp)   ; GRAFPn
    (atari800-cl.gtia:gtia-write gtia (+ #xD012 player)          ; COLPMn
                                 (+ #x28 (* player 2)))
    (atari800-cl.gtia:gtia-write gtia #xD01B prior)              ; PRIOR
    (values bus antic gtia fb)))

(test prior-bit0-players-beat-all-playfields
  "PRIOR bit 0: P0 P1 P2 P3 PF0 PF1 PF2 PF3 BAK -- the player draws
over BAK, PF0, PF1, and PF2 alike."
  (multiple-value-bind (bus antic gtia fb) (%prior-fixture #x01)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (let ((pm0-r (atari800-cl.renderer:atari-color->r #x28)))
      (dolist (col '(32 34 36 38))
        (is (= pm0-r (%fb-r fb col))
            "column ~D: player 0 must beat every playfield source" col)))))

(test prior-bit1-front-players-beat-playfield-back-players-lose
  "PRIOR bit 1: P0 P1 PF0 PF1 PF2 PF3 P2 P3 BAK -- P0 still beats all
playfields, but P2 hides behind them and shows only over BAK."
  ;; P0 case.
  (multiple-value-bind (bus antic gtia fb) (%prior-fixture #x02 :player 0)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x28) (%fb-r fb 36))
        "P0 must draw over PF1 under the bit-1 ordering"))
  ;; P2 case.
  (multiple-value-bind (bus antic gtia fb) (%prior-fixture #x02 :player 2)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x2C) (%fb-r fb 32))
        "P2 must draw over BAK")
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 34))
        "PF0 must draw over P2")
    (is (= (atari800-cl.renderer:atari-color->r #x68) (%fb-r fb 38))
        "PF2 must draw over P2")))

(test prior-bit2-playfields-beat-players
  "PRIOR bit 2: PF0 PF1 PF2 PF3 P0 P1 P2 P3 BAK -- every playfield
source hides the player; only BAK shows it."
  (multiple-value-bind (bus antic gtia fb) (%prior-fixture #x04)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x28) (%fb-r fb 32))
        "player must still draw over BAK")
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 34))
        "PF0 must hide the player")
    (is (= (atari800-cl.renderer:atari-color->r #x46) (%fb-r fb 36))
        "PF1 must hide the player")
    (is (= (atari800-cl.renderer:atari-color->r #x68) (%fb-r fb 38))
        "PF2 must hide the player")))

(test prior-bit3-players-between-playfield-pairs
  "PRIOR bit 3: PF0 PF1 P0 P1 P2 P3 PF2 PF3 BAK -- the player hides
behind PF0/PF1 but draws over PF2 and BAK."
  (multiple-value-bind (bus antic gtia fb) (%prior-fixture #x08)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x28) (%fb-r fb 32))
        "player over BAK")
    (is (= (atari800-cl.renderer:atari-color->r #x24) (%fb-r fb 34))
        "PF0 over player")
    (is (= (atari800-cl.renderer:atari-color->r #x46) (%fb-r fb 36))
        "PF1 over player")
    (is (= (atari800-cl.renderer:atari-color->r #x28) (%fb-r fb 38))
        "player over PF2")))

(test prior-fifth-player-missiles-render-as-playfield-3
  "PRIOR bit 4: the missiles render as one fifth player -- COLPF3 color,
playfield-3 priority.  A player beats it under the bit-0 ordering
(players beat PF3) but hides behind it under the bit-2 ordering
(playfields beat players)."
  ;; Fifth player alone over background: COLPF3 color shows.
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.gtia:gtia-write gtia #xD019 #x8A)   ; COLPF3
    (atari800-cl.gtia:gtia-write gtia #xD004 48)     ; HPOSM0
    (atari800-cl.gtia:gtia-write gtia #xD011 #xC0)   ; GRAFM: missile 0
    (atari800-cl.gtia:gtia-write gtia #xD01B #x11)   ; fifth + bit 0
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x8A) (%fb-r fb 32))
        "fifth-player missile must render in COLPF3"))
  ;; Player vs fifth player, both orderings.
  (flet ((run (prior)
           (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
             (atari800-cl.gtia:gtia-write gtia #xD019 #x8A)  ; COLPF3
             (atari800-cl.gtia:gtia-write gtia #xD004 48)    ; HPOSM0
             (atari800-cl.gtia:gtia-write gtia #xD011 #xC0)  ; GRAFM
             (atari800-cl.gtia:gtia-write gtia #xD000 48)    ; HPOSP0
             (atari800-cl.gtia:gtia-write gtia #xD00D #xFF)  ; GRAFP0
             (atari800-cl.gtia:gtia-write gtia #xD012 #x28)  ; COLPM0
             (atari800-cl.gtia:gtia-write gtia #xD01B prior)
             (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
             (%fb-r fb 32))))
    (is (= (atari800-cl.renderer:atari-color->r #x28) (run #x11))
        "bit-0 ordering: the player beats the fifth player (PF3)")
    (is (= (atari800-cl.renderer:atari-color->r #x8A) (run #x14))
        "bit-2 ordering: the fifth player (PF3) beats the player")))

(test prior-multicolor-players-or-their-colors
  "PRIOR bit 5: where P0 and P1 overlap, the drawn color is
COLPM0 | COLPM1."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.gtia:gtia-write gtia #xD000 80)     ; HPOSP0 -> cols 96-103
    (atari800-cl.gtia:gtia-write gtia #xD001 82)     ; HPOSP1 -> cols 100-107
    (atari800-cl.gtia:gtia-write gtia #xD00D #xFF)   ; GRAFP0
    (atari800-cl.gtia:gtia-write gtia #xD00E #xFF)   ; GRAFP1
    (atari800-cl.gtia:gtia-write gtia #xD012 #x32)   ; COLPM0
    (atari800-cl.gtia:gtia-write gtia #xD013 #x44)   ; COLPM1
    (atari800-cl.gtia:gtia-write gtia #xD01B #x21)   ; multicolor + bit 0
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (= (atari800-cl.renderer:atari-color->r #x32) (%fb-r fb 96))
        "P0 alone keeps COLPM0")
    (is (= (atari800-cl.renderer:atari-color->r (logior #x32 #x44))
           (%fb-r fb 100))
        "the P0/P1 overlap must OR the two color registers")
    (is (= (atari800-cl.renderer:atari-color->r #x44) (%fb-r fb 104))
        "P1 alone keeps COLPM1")))

;;; ---------------------------------------------------------------------------
;;; GTIA color modes 9/10/11 (ROADMAP.md Phase 7)
;;;
;;; PRIOR bits 6-7 reinterpret an ANTIC mode-F fetch: the 40 bytes
;;; become 80 four-bit nibbles, each one wide pixel = 4 output columns.

(defun %fb-rgb (fb column)
  "The (R G B) triple of framebuffer column COLUMN in row 0."
  (let ((base (* column 3)))
    (list (aref fb base) (aref fb (+ base 1)) (aref fb (+ base 2)))))

(defun %color-rgb (c)
  "The (R G B) triple the palette produces for Atari color byte C."
  (list (atari800-cl.renderer:atari-color->r c)
        (atari800-cl.renderer:atari-color->g c)
        (atari800-cl.renderer:atari-color->b c)))

(defun %gtia-mode-fixture (prior colbk &rest bytes)
  "Return (VALUES BUS ANTIC GTIA FB) set up for an ANTIC mode-F line
reading screen RAM at $4000, with PRIOR and COLBK programmed and BYTES
poked into that screen RAM."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (loop for b in bytes for i from 0
          do (atari800-cl.bus:bus-poke-ram bus (+ #x4000 i) b))
    (atari800-cl.gtia:gtia-write gtia #xD01A colbk)   ; COLBK
    (atari800-cl.gtia:gtia-write gtia #xD01B prior)   ; PRIOR
    (setf (atari800-cl.antic:antic-current-mode           antic) #x0F
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22)
    (values bus antic gtia fb)))

(test gtia-mode-9-nibble-is-luminance-of-colbk-hue
  "PRIOR bits 6-7 = 01 (mode 9): each nibble replaces COLBK's luminance
bits, keeping COLBK's hue, and paints 4 output columns."
  ;; COLBK = $30 (hue 3, luminance 0).  Bytes $2F, $40 -> nibbles 2, F, 4, 0.
  (multiple-value-bind (bus antic gtia fb)
      (%gtia-mode-fixture #x40 #x30 #x2F #x40)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (equal (%color-rgb #x32) (%fb-rgb fb 32))
        "nibble 2 must render color $32 at the first active column")
    (is (equal (%color-rgb #x32) (%fb-rgb fb 35))
        "each nibble spans 4 output columns (32-35)")
    (is (equal (%color-rgb #x3F) (%fb-rgb fb 36))
        "nibble F must render color $3F starting at column 36")
    (is (equal (%color-rgb #x34) (%fb-rgb fb 40))
        "byte 1's high nibble 4 must render color $34")
    (is (equal (%color-rgb #x30) (%fb-rgb fb 44))
        "byte 1's low nibble 0 must render COLBK's own luminance 0")))

(test gtia-mode-9-luminance-pairs-collapse
  "Known limitation: this project's palette is 128 entries indexed by
(color >> 1), so mode 9's 16 nibble values collapse to 8 luminances in
pairs.  The color BYTES are hardware-correct -- widening the palette to
256 entries is all that is needed to recover 16 distinct shades, and
this test is the reminder to revisit if that ever happens."
  (multiple-value-bind (bus antic gtia fb)
      (%gtia-mode-fixture #x40 #x30 #xEF)   ; nibbles E and F
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (equal (%fb-rgb fb 32) (%fb-rgb fb 36))
        "nibbles E and F differ only in color bit 0, which the palette drops")
    (is (not (equal (%fb-rgb fb 32) (%color-rgb #x30)))
        "...but they must still differ from luminance 0")))

(test gtia-mode-10-nibble-selects-color-register
  "PRIOR bits 6-7 = 10 (mode 10): nibble 0-3 selects COLPM0-3, 4-7
COLPF0-3, 8 COLBK.  Out-of-range nibbles 9-15 clamp to COLBK (CONFIRM
pending -- see %RENDER-GTIA-MODE)."
  (multiple-value-bind (bus antic gtia fb)
      ;; Bytes: $05 -> nibbles 0,5 ; $83 -> 8,3 ; $9F -> 9,F.
      (%gtia-mode-fixture #x80 #x1C #x05 #x83 #x9F)
    (atari800-cl.gtia:gtia-write gtia #xD012 #x3A)   ; COLPM0
    (atari800-cl.gtia:gtia-write gtia #xD015 #x7E)   ; COLPM3
    (atari800-cl.gtia:gtia-write gtia #xD017 #x56)   ; COLPF1
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (equal (%color-rgb #x3A) (%fb-rgb fb 32)) "nibble 0 -> COLPM0")
    (is (equal (%color-rgb #x56) (%fb-rgb fb 36)) "nibble 5 -> COLPF1")
    (is (equal (%color-rgb #x1C) (%fb-rgb fb 40)) "nibble 8 -> COLBK")
    (is (equal (%color-rgb #x7E) (%fb-rgb fb 44)) "nibble 3 -> COLPM3")
    (is (equal (%color-rgb #x1C) (%fb-rgb fb 48)) "nibble 9 clamps to COLBK")
    (is (equal (%color-rgb #x1C) (%fb-rgb fb 52)) "nibble F clamps to COLBK")))

(test gtia-mode-11-nibble-is-hue-at-colbk-luminance
  "PRIOR bits 6-7 = 11 (mode 11): the nibble supplies the hue and COLBK
the luminance.  Nibble 0 is hue 0 at COLBK's luminance -- a gray, which
is why mode 11 cannot display black unless COLBK's luminance is 0."
  ;; COLBK = $08 (hue 0, luminance 8).  Byte $50 -> nibbles 5, 0.
  (multiple-value-bind (bus antic gtia fb)
      (%gtia-mode-fixture #xC0 #x08 #x50)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (equal (%color-rgb #x58) (%fb-rgb fb 32))
        "nibble 5 must render hue 5 at COLBK's luminance")
    (is (equal (%color-rgb #x08) (%fb-rgb fb 36))
        "nibble 0 must render hue 0 at COLBK's luminance")
    (is (plusp (first (%fb-rgb fb 36)))
        "nibble 0 must be a gray, not black -- mode 11's no-black quirk")))

(test gtia-modes-ignored-on-non-f-antic-modes
  "GTIA bits set on an ANTIC mode other than F render that mode
normally (hardware produces garbage there; we do not model it)."
  (multiple-value-bind (bus antic gtia fb) (%make-render-fixture)
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x1B)   ; 2bpp: 00 01 10 11
    (atari800-cl.gtia:gtia-write gtia #xD01B #x40)   ; PRIOR: GTIA mode 9
    (setf (atari800-cl.antic:antic-current-mode           antic) #x0E
          (atari800-cl.antic:antic-render-screen-data-ptr antic) #x4000
          (atari800-cl.antic:antic-dmactl                 antic) #x22)
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (equal (%color-rgb #x00) (%fb-rgb fb 32)) "mode E pixel 00 -> COLBK")
    (is (equal (%color-rgb #x24) (%fb-rgb fb 34)) "mode E pixel 01 -> COLPF0")
    (is (equal (%color-rgb #x46) (%fb-rgb fb 36)) "mode E pixel 10 -> COLPF1")
    (is (equal (%color-rgb #x68) (%fb-rgb fb 38)) "mode E pixel 11 -> COLPF2")))

(test gtia-mode-selected-per-scanline
  "The GTIA mode is read from PRIOR per scanline, so a DLI that rewrites
PRIOR mid-frame switches modes from that line on."
  (multiple-value-bind (bus antic gtia fb)
      (%gtia-mode-fixture #x40 #x30 #x50)          ; mode 9, nibble 5
    (atari800-cl.renderer:render-scanline fb 0 antic gtia bus)
    (is (equal (%color-rgb #x35) (%fb-rgb fb 32))
        "row 0 under mode 9: nibble 5 is a luminance")
    ;; Now switch to mode 11 and render the next row.
    (atari800-cl.gtia:gtia-write gtia #xD01B #xC0)
    (atari800-cl.renderer:render-scanline fb 1 antic gtia bus)
    (let ((row1 (let ((base (* 1 384 3)))
                  (list (aref fb (+ base (* 32 3)))
                        (aref fb (+ base (* 32 3) 1))
                        (aref fb (+ base (* 32 3) 2))))))
      (is (equal (%color-rgb #x50) row1)
          "row 1 under mode 11: the same nibble 5 is now a hue"))))
