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
