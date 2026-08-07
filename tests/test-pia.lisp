;;;; tests/test-pia.lisp --- PIA (6520) tests.
;;;;
;;;; Covers the four PIA register addresses individually, the PACTL/PBCTL
;;;; bit-2 port-vs-DDR select, the (addr & $03) mirroring, MMU forwarding
;;;; from PORTB writes, and an end-to-end integration that goes through
;;;; BUS-WRITE → attached PIA closure → MMU-WRITE-PORTB → bank-switching →
;;;; visible read change.

(in-package #:atari800-cl/tests)

(def-suite pia-suite
  :description "Atari 800 XL PIA tests (PORTA/DDRA/PORTB/DDRB, PACTL/PBCTL
port select, MMU routing)."
  :in atari800-cl-suite)

(in-suite pia-suite)

;;; Control-register values as the XL OS uses them: bit 2 clear selects the
;;; direction register at $D300 / $D301, bit 2 set selects the port itself.
(defconstant +pia-select-ddr+  #x38)
(defconstant +pia-select-port+ #x3C)

;;; ---------------------------------------------------------------------------
;;; Register-level reads / writes

(test pia-defaults-cold-reset
  "Freshly-made PIA has the cold-reset latches: PORTA/PORTB = $FF, DDRs = 0,
and both control registers 0 (so $D300/$D301 address the DDRs)."
  (let ((p (atari800-cl.pia:make-pia)))
    (is (= #xFF (atari800-cl.pia:pia-porta p)))
    (is (= #xFF (atari800-cl.pia:pia-portb p)))
    (is (= 0 (atari800-cl.pia:pia-ddra p)))
    (is (= 0 (atari800-cl.pia:pia-ddrb p)))
    (is (= 0 (atari800-cl.pia:pia-pactl p)))
    (is (= 0 (atari800-cl.pia:pia-pbctl p)))))

(test pia-read-routes-by-low-two-bits
  "PIA-READ uses (addr AND $03): $D302/$D303 are PACTL/PBCTL, and $D300/$D301
follow each control register's bit 2.  All four mirror across the page."
  (let ((p (atari800-cl.pia:make-pia)))
    (setf (atari800-cl.pia:pia-porta p) #x11
          (atari800-cl.pia:pia-ddra  p) #x22
          (atari800-cl.pia:pia-portb p) #x33
          (atari800-cl.pia:pia-ddrb  p) #x44)
    ;; Control registers cleared → $D300/$D301 read the direction registers.
    (is (= #x22 (atari800-cl.pia:pia-read p #xD300)))
    (is (= #x44 (atari800-cl.pia:pia-read p #xD301)))
    (is (= #x00 (atari800-cl.pia:pia-read p #xD302)))
    (is (= #x00 (atari800-cl.pia:pia-read p #xD303)))
    ;; Select the ports and the same two addresses read PORTA/PORTB.
    (atari800-cl.pia:pia-write p #xD302 +pia-select-port+)
    (atari800-cl.pia:pia-write p #xD303 +pia-select-port+)
    (is (= #x11 (atari800-cl.pia:pia-read p #xD300)))
    (is (= #x33 (atari800-cl.pia:pia-read p #xD301)))
    (is (= +pia-select-port+ (atari800-cl.pia:pia-read p #xD302)))
    (is (= +pia-select-port+ (atari800-cl.pia:pia-read p #xD303)))
    ;; Mirroring across the page: $D3F8 ≡ $D300, etc.
    (is (= #x11 (atari800-cl.pia:pia-read p #xD3F8)))
    (is (= #x33 (atari800-cl.pia:pia-read p #xD3F9)))
    (is (= +pia-select-port+ (atari800-cl.pia:pia-read p #xD3FA)))
    (is (= +pia-select-port+ (atari800-cl.pia:pia-read p #xD3FB)))))

(test pia-write-ddra-updates-slot
  "With PACTL bit 2 clear, writing $D300 updates DDRA without touching others."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD300 #xF0)
    (is (= #xF0 (atari800-cl.pia:pia-ddra p)))
    (is (= #xFF (atari800-cl.pia:pia-porta p))
        "PORTA must not change when DDRA is written")
    (is (= 0    (atari800-cl.pia:pia-ddrb p))
        "DDRB must not change when DDRA is written")))

(test pia-write-ddrb-updates-slot
  "With PBCTL bit 2 clear, writing $D301 updates DDRB."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD301 #x55)
    (is (= #x55 (atari800-cl.pia:pia-ddrb p)))
    (is (= #xFF (atari800-cl.pia:pia-portb p))
        "PORTB must not change when DDRB is written")))

(test pia-write-porta-updates-latch
  "PORTA is an input but our model still latches writes for inspection."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD302 +pia-select-port+)
    (atari800-cl.pia:pia-write p #xD300 #x42)
    (is (= #x42 (atari800-cl.pia:pia-porta p)))))

(test pia-write-portb-updates-latch-without-mmu
  "PORTB write updates the latch even when no MMU is attached."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD303 +pia-select-port+)
    (atari800-cl.pia:pia-write p #xD301 #x7E)
    (is (= #x7E (atari800-cl.pia:pia-portb p)))))

(test pia-write-portb-forwards-to-mmu
  "When an MMU is attached, PORTB writes propagate via MMU-WRITE-PORTB."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (p   (atari800-cl.pia:make-pia :mmu mmu)))
    (atari800-cl.pia:pia-write p #xD303 +pia-select-port+)
    (atari800-cl.pia:pia-write p #xD301 #x03)        ; OS on, BASIC off
    (is (= #x03 (atari800-cl.mmu:mmu-portb mmu)))
    (is-true (atari800-cl.mmu:os-rom-mapped-p mmu))
    (is-false (atari800-cl.mmu:basic-rom-mapped-p mmu))))

(test pia-ddrb-write-does-not-reach-mmu
  "With PBCTL bit 2 clear, $D301 is DDRB: the MMU's PORTB must not change.
This is the bug that unmapped the OS ROM during the XL boot sequence."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (p   (atari800-cl.pia:make-pia :mmu mmu)))
    (atari800-cl.pia:pia-write p #xD303 +pia-select-ddr+)
    (atari800-cl.pia:pia-write p #xD301 #x00)
    (is (= #x00 (atari800-cl.pia:pia-ddrb p)))
    (is (= #xFF (atari800-cl.mmu:mmu-portb mmu))
        "MMU PORTB must be untouched by a DDRB write")
    (is-true (atari800-cl.mmu:os-rom-mapped-p mmu))))

(test pia-control-writes-mask-irq-flag-bits
  "Bits 6-7 of PACTL/PBCTL are read-only IRQ flags; writes to them are dropped."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD302 #xFF)
    (atari800-cl.pia:pia-write p #xD303 #xC5)
    (is (= #x3F (atari800-cl.pia:pia-pactl p)))
    (is (= #x05 (atari800-cl.pia:pia-pbctl p)))))

(test pia-os-init-sequence-keeps-os-rom-mapped
  "The XL OS boot sequence at $EF91 — PACTL/PBCTL $38 (DDR) then $3C (port),
programming DDRA/DDRB in between — must leave the OS ROM mapped.  Decoding
$D302 as PORTB used to push $38 into the MMU and unmap the ROM mid-boot."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (p   (atari800-cl.pia:make-pia :mmu mmu)))
    (atari800-cl.pia:pia-write p #xD302 +pia-select-ddr+)   ; STX $D302
    (atari800-cl.pia:pia-write p #xD300 #x00)               ; STY $D300 → DDRA
    (atari800-cl.pia:pia-write p #xD302 +pia-select-port+)  ; STA $D302
    (atari800-cl.pia:pia-write p #xD300 #x00)               ; STY $D300 → PORTA
    (atari800-cl.pia:pia-write p #xD303 +pia-select-port+)  ; STA $D303
    (atari800-cl.pia:pia-write p #xD301 #x00)               ; STY $D301 → PORTB
    (atari800-cl.pia:pia-write p #xD301 #xFF)               ; DEY; STY $D301
    (atari800-cl.pia:pia-write p #xD303 +pia-select-ddr+)   ; STX $D303
    (atari800-cl.pia:pia-write p #xD301 #xFF)               ; STY $D301 → DDRB
    (atari800-cl.pia:pia-write p #xD303 +pia-select-port+)  ; STA $D303
    (is (= #x00 (atari800-cl.pia:pia-ddra p)))
    (is (= #xFF (atari800-cl.pia:pia-ddrb p)))
    (is (= #xFF (atari800-cl.pia:pia-portb p)))
    (is (= #xFF (atari800-cl.mmu:mmu-portb mmu)))
    (is-true (atari800-cl.mmu:os-rom-mapped-p mmu))))

(test pia-reset-restores-defaults
  "RESET-PIA brings every latch and both control registers back to their
cold-reset values."
  (let ((p (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:pia-write p #xD302 +pia-select-port+)
    (atari800-cl.pia:pia-write p #xD303 +pia-select-port+)
    (atari800-cl.pia:pia-write p #xD300 #x01)
    (atari800-cl.pia:pia-write p #xD301 #x02)
    (atari800-cl.pia:reset-pia p)
    (is (= #xFF (atari800-cl.pia:pia-porta p)))
    (is (= #xFF (atari800-cl.pia:pia-portb p)))
    (is (= 0 (atari800-cl.pia:pia-ddra p)))
    (is (= 0 (atari800-cl.pia:pia-ddrb p)))
    (is (= 0 (atari800-cl.pia:pia-pactl p)))
    (is (= 0 (atari800-cl.pia:pia-pbctl p)))))

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

(test pia-bus-write-to-d301-changes-mmu-mapping
  "BUS-WRITE $D301 (with PORTB selected) → PIA closure → MMU PORTB update →
ROM mapping toggled."
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
    ;; Select PORTB, then write PORTB = 0 → OS off.
    (atari800-cl.bus:bus-write bus #xD303 +pia-select-port+)
    (atari800-cl.bus:bus-write bus #xD301 #x00)
    (is (= 0 (atari800-cl.mmu:mmu-portb mmu)))
    (is (= 0 (atari800-cl.bus:bus-read bus #xC100))
        "OS off after write: RAM byte (zero) visible")))

(test pia-bus-write-to-d300-updates-ddra-not-ram
  "Writing $D300 with PACTL bit 2 clear updates DDRA via the bus and does
NOT poke RAM."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (p   (atari800-cl.pia:make-pia)))
    (atari800-cl.pia:attach-pia bus p mmu)
    (atari800-cl.bus:bus-write bus #xD300 #xAB)
    (is (= #xAB (atari800-cl.pia:pia-ddra p))
        "DDRA must reflect the bus write")
    (is (zerop (atari800-cl.bus:bus-peek-ram bus #xD300))
        "RAM at $D300 must remain untouched")))

(test pia-bus-read-from-d300-returns-porta
  "BUS-READ at $D300 with PORTA selected routes through the PIA closure and
returns PORTA."
  (let* ((bus (atari800-cl.bus:make-bus))
         (p   (atari800-cl.pia:make-pia)))
    (setf (atari800-cl.pia:pia-porta p) #x69
          (atari800-cl.pia:pia-pactl p) +pia-select-port+)
    (atari800-cl.pia:attach-pia bus p)
    (is (= #x69 (atari800-cl.bus:bus-read bus #xD300)))))

;;; ---------------------------------------------------------------------------
;;; Host input delegation (Stage 2)

(test pia-porta-reflects-attached-input
  "With an INPUT-STATE attached, a PORTA read returns the live joystick
packing instead of the static latch; detaching restores the latch."
  (let ((p  (atari800-cl.pia:make-pia))
        (in (make-input-state)))
    ;; PORTA (not DDRA) must be the selected register for these reads.
    (setf (atari800-cl.pia:pia-pactl p) +pia-select-port+)
    ;; Static latch path first: PORTA defaults to $FF.
    (is (= #xFF (atari800-cl.pia:pia-read p #xD300)) "latch idle = $FF")
    (atari800-cl.pia:attach-pia-input p in)
    (input-set-joystick in 0 :up t)      ; stick-0 up -> low nibble bit0 = 0
    (is (= #xFE (atari800-cl.pia:pia-read p #xD300))
        "PORTA reflects live input ($FE)")
    ;; Detach -> back to the static latch.
    (atari800-cl.pia:attach-pia-input p nil)
    (is (= #xFF (atari800-cl.pia:pia-read p #xD300)) "detached -> latch again")))
