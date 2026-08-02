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
;;; AESP frame-config bpp

(test aesp-frame-config-is-24bpp
  "FRAME_CONFIG payload byte 4 must report 24 bits per pixel."
  ;; Call the internal helper via the package-qualified name.
  (let ((payload (atari800-cl.aesp::%frame-config-payload)))
    (is (= 24 (aref payload 4))
        "Expected bpp=24 but got ~D" (aref payload 4))))
