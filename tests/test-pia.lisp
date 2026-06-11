;;;; tests/test-pia.lisp --- PIA (6520) tests.
;;;;
;;;; Covers the four PIA registers individually, the (addr & $03)
;;;; mirroring, MMU forwarding from PORTB writes, and an end-to-end
;;;; integration that goes through BUS-WRITE → attached PIA closure →
;;;; MMU-WRITE-PORTB → bank-switching → visible read change.

(in-package #:atari800-cl/tests)

(def-suite pia-suite
  :description "Atari 800 XL PIA tests (PORTA/DDRA/PORTB/DDRB + MMU routing)."
  :in atari800-cl-suite)

(in-suite pia-suite)

;;; ---------------------------------------------------------------------------
;;; Register-level reads / writes

(test pia-defaults-cold-reset
  "Freshly-made PIA has the cold-reset latches: PORTA/PORTB = $FF, DDRs = 0."
  (let ((p (atari800-cl.pia:make-pia)))
    (is (= #xFF (atari800-cl.pia:pia-porta p)))
    (is (= #xFF (atari800-cl.pia:pia-portb p)))
    (is (= 0 (atari800-cl.pia:pia-ddra p)))
    (is (= 0 (atari800-cl.pia:pia-ddrb p)))))

(test pia-read-routes-by-low-two-bits
  "PIA-READ uses (addr AND $03) so all four addresses mirror correctly."
  (let ((p (atari800-cl.pia:make-pia)))
    (setf (atari800-cl.pia:pia-porta p) #x11
          (atari800-cl.pia:pia-ddra  p) #x22
          (atari800-cl.pia:pia-portb p) #x33
          (atari800-cl.pia:pia-ddrb  p) #x44)
    (is (= #x11 (atari800-cl.pia:pia-read p #xD300)))
    (is (= #x22 (atari800-cl.pia:pia-read p #xD301)))
    (is (= #x33 (atari800-cl.pia:pia-read p #xD302)))
    (is (= #x44 (atari800-cl.pia:pia-read p #xD303)))
    ;; Mirroring across the page: $D3F8 ≡ $D300, etc.
    (is (= #x11 (atari800-cl.pia:pia-read p #xD3F8)))
    (is (= #x22 (atari800-cl.pia:pia-read p #xD3F9)))
    (is (= #x33 (atari800-cl.pia:pia-read p #xD3FA)))
    (is (= #x44 (atari800-cl.pia:pia-read p #xD3FB)))))

(test pia-write-ddra-updates-slot
  "Writing $D301 updates the DDRA slot without touching others."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD301 #xF0)
    (is (= #xF0 (atari800-cl.pia:pia-ddra p)))
    (is (= 0    (atari800-cl.pia:pia-ddrb p))
        "DDRB must not change when DDRA is written")))

(test pia-write-ddrb-updates-slot
  "Writing $D303 updates the DDRB slot."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD303 #x55)
    (is (= #x55 (atari800-cl.pia:pia-ddrb p)))))

(test pia-write-porta-updates-latch
  "PORTA is an input but our model still latches writes for inspection."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD300 #x42)
    (is (= #x42 (atari800-cl.pia:pia-porta p)))))

(test pia-write-portb-updates-latch-without-mmu
  "PORTB write updates the latch even when no MMU is attached."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD302 #x7E)
    (is (= #x7E (atari800-cl.pia:pia-portb p)))))

(test pia-write-portb-forwards-to-mmu
  "When an MMU is attached, PORTB writes propagate via MMU-WRITE-PORTB."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (p   (atari800-cl.pia:make-pia :mmu mmu)))
    (atari800-cl.pia:pia-write p #xD302 #x03)        ; OS on, BASIC off
    (is (= #x03 (atari800-cl.mmu:mmu-portb mmu)))
    (is-true (atari800-cl.mmu:os-rom-mapped-p mmu))
    (is-false (atari800-cl.mmu:basic-rom-mapped-p mmu))))

(test pia-reset-restores-defaults
  "RESET-PIA brings all four latches back to their cold-reset values."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD300 #x01)
    (atari800-cl.pia:pia-write p #xD301 #x02)
    (atari800-cl.pia:pia-write p #xD302 #x03)
    (atari800-cl.pia:pia-write p #xD303 #x04)
    (atari800-cl.pia:reset-pia p)
    (is (= #xFF (atari800-cl.pia:pia-porta p)))
    (is (= #xFF (atari800-cl.pia:pia-portb p)))
    (is (= 0 (atari800-cl.pia:pia-ddra p)))
    (is (= 0 (atari800-cl.pia:pia-ddrb p)))))

;;; ---------------------------------------------------------------------------
;;; Bus integration (end-to-end)

(test pia-attach-installs-bus-dispatch
  "ATTACH-PIA installs the PIA's read/write closures into the bus."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (p   (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:attach-pia bus p mmu)
    (is (eq p (atari800-cl.bus:bus-pia bus)))
    (is (functionp (atari800-cl.bus:bus-pia-read-fn bus)))
    (is (functionp (atari800-cl.bus:bus-pia-write-fn bus)))))

(test pia-bus-write-to-d302-changes-mmu-mapping
  "BUS-WRITE $D302 → PIA closure → MMU PORTB update → ROM mapping toggled."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (p   (atari800-cl.pia:make-pia))
         (rom (make-array #x4000 :element-type '(unsigned-byte 8)
                                 :initial-element #xA5)))
    (atari800-cl.bus:install-os-rom bus rom)
    (atari800-cl.pia:attach-pia bus p mmu)
    ;; PORTB defaults to $FF → OS on.
    (is (= #xA5 (atari800-cl.bus:bus-read bus #xC100))
        "OS on by default: ROM byte visible")
    ;; Write PORTB = 0 → OS off.
    (atari800-cl.bus:bus-write bus #xD302 #x00)
    (is (= 0 (atari800-cl.mmu:mmu-portb mmu)))
    (is (= 0 (atari800-cl.bus:bus-read bus #xC100))
        "OS off after write: RAM byte (zero) visible")))

(test pia-bus-write-to-d301-updates-ddra-not-ram
  "Writing $D301 updates DDRA via the bus and does NOT poke RAM."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (p   (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:attach-pia bus p mmu)
    (atari800-cl.bus:bus-write bus #xD301 #xAB)
    (is (= #xAB (atari800-cl.pia:pia-ddra p))
        "DDRA must reflect the bus write")
    (is (zerop (atari800-cl.bus:bus-peek-ram bus #xD301))
        "RAM at $D301 must remain untouched")))

(test pia-bus-read-from-d300-returns-porta
  "BUS-READ at $D300 routes through the PIA closure and returns PORTA."
  (let* ((bus (atari800-cl.bus:make-bus))
         (p   (atari800-cl.pia:make-pia)))
    (setf (atari800-cl.pia:pia-porta p) #x69)
    (atari800-cl.pia:attach-pia bus p)
    (is (= #x69 (atari800-cl.bus:bus-read bus #xD300)))))

;;; ---------------------------------------------------------------------------
;;; Host input delegation (Stage 2)

(test pia-porta-reflects-attached-input
  "With an INPUT-STATE attached, a PORTA read returns the live joystick
packing instead of the static latch; detaching restores the latch."
  (let ((p  (atari800-cl.pia:make-pia))
        (in (make-input-state)))
    ;; Static latch path first: PORTA defaults to $FF.
    (is (= #xFF (atari800-cl.pia:pia-read p #xD300)) "latch idle = $FF")
    (atari800-cl.pia:attach-pia-input p in)
    (input-set-joystick in 0 :up t)      ; stick-0 up -> low nibble bit0 = 0
    (is (= #xFE (atari800-cl.pia:pia-read p #xD300))
        "PORTA reflects live input ($FE)")
    ;; Detach -> back to the static latch.
    (atari800-cl.pia:attach-pia-input p nil)
    (is (= #xFF (atari800-cl.pia:pia-read p #xD300)) "detached -> latch again")))
