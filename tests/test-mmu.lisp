;;;; tests/test-mmu.lisp --- MMU + bus memory-map dispatch tests.
;;;;
;;;; Covers the Atari 800 XL bank-switching predicates, every range in
;;;; the memory map, and the I/O dispatch.  The chip-attach paths are
;;;; exercised more directly in tests/test-pia.lisp and friends; this
;;;; suite focuses on the bus-side routing and on PORTB semantics.
;;;;
;;;; SBCL/arm64 note: direct AREF on a typed slot-accessed array with a
;;;; known-constant index can hit an assembler bug ("Invalid STR/LDR
;;;; arguments... :OFFSET ...") when the byte offset overflows the
;;;; 12-bit immediate field.  We use BUS-PEEK-RAM / BUS-POKE-RAM
;;;; (NOTINLINE functions in src/bus.lisp) to dodge that bug.

(in-package #:atari800-cl/tests)

(def-suite mmu-suite
  :description "Atari 800 XL MMU bank-switching and bus memory-map dispatch."
  :in atari800-cl-suite)

(in-suite mmu-suite)

;;; ---------------------------------------------------------------------------
;;; MMU predicates

(test mmu-defaults-portb-to-FF
  "Freshly-made MMU has PORTB = $FF (cold-reset default)."
  (let ((mmu (atari800-cl.mmu:make-mmu)))
    (is (= #xFF (atari800-cl.mmu:mmu-portb mmu))
        "Default PORTB must be $FF; got #x~2,'0X"
        (atari800-cl.mmu:mmu-portb mmu))))

(test mmu-os-rom-bit-toggle
  "PORTB bit 0 toggles OS ROM visibility."
  (let ((mmu (atari800-cl.mmu:make-mmu)))
    (atari800-cl.mmu:mmu-write-portb mmu #x01)
    (is-true (atari800-cl.mmu:os-rom-mapped-p mmu)
             "bit 0 = 1 must enable OS ROM")
    (atari800-cl.mmu:mmu-write-portb mmu #x00)
    (is-false (atari800-cl.mmu:os-rom-mapped-p mmu)
              "bit 0 = 0 must disable OS ROM")))

(test mmu-basic-rom-bit-toggle
  "PORTB bit 1 (inverted) toggles BASIC visibility."
  (let ((mmu (atari800-cl.mmu:make-mmu)))
    (atari800-cl.mmu:mmu-write-portb mmu #x01)
    (is-true (atari800-cl.mmu:basic-rom-mapped-p mmu)
             "bit 1 = 0 must enable BASIC ROM")
    (atari800-cl.mmu:mmu-write-portb mmu #x03)
    (is-false (atari800-cl.mmu:basic-rom-mapped-p mmu)
              "bit 1 = 1 must disable BASIC ROM")))

(test mmu-selftest-needs-bit7-clear-and-os-on
  "Self-test is enabled only when bit 7 = 0 AND OS ROM is mapped."
  (let ((mmu (atari800-cl.mmu:make-mmu)))
    (atari800-cl.mmu:mmu-write-portb mmu #x01)
    (is-true (atari800-cl.mmu:selftest-mapped-p mmu)
             "OS on + bit 7 clear must enable self-test")
    (atari800-cl.mmu:mmu-write-portb mmu #x81)
    (is-false (atari800-cl.mmu:selftest-mapped-p mmu)
              "bit 7 set must disable self-test")
    (atari800-cl.mmu:mmu-write-portb mmu #x00)
    (is-false (atari800-cl.mmu:selftest-mapped-p mmu)
              "OS off must imply self-test off")))

(test mmu-reset-restores-defaults
  "RESET-MMU forces PORTB back to $FF regardless of prior state."
  (let ((mmu (atari800-cl.mmu:make-mmu)))
    (atari800-cl.mmu:mmu-write-portb mmu #x00)
    (atari800-cl.mmu:reset-mmu mmu)
    (is (= #xFF (atari800-cl.mmu:mmu-portb mmu)))))

(test mmu-portb-decode-shape
  "PORTB-DECODE returns a plist with the four expected keys."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (decoded (atari800-cl.mmu:portb-decode mmu)))
    (is (= #xFF (getf decoded :portb)))
    (is-true (member :os-rom-mapped decoded))
    (is-true (member :basic-rom-mapped decoded))
    (is-true (member :selftest-mapped decoded))))

;;; ---------------------------------------------------------------------------
;;; Helper: install a synthetic ROM whose byte at every offset equals
;;; ((offset >> 8) XOR (offset AND $FF)) — so any individual byte is a
;;; quick predictable function of its address.

(defun %make-marked-rom (size)
  (let ((rom (make-array size :element-type '(unsigned-byte 8)
                              :initial-element 0)))
    (dotimes (i size)
      (setf (aref rom i) (logand (logxor (ash i -8) i) #xFF)))
    rom))

(defun %os-rom-byte-at (cpu-address)
  "Compute what a fresh marked OS ROM (16K) should return when read at
the given CPU address (with OS ROM mapped)."
  (let ((offset (cond ((<= #xC000 cpu-address #xCFFF) (- cpu-address #xC000))
                      ((<= #xD800 cpu-address #xFFFF) (- cpu-address #xC000))
                      (t (error "address $~4,'0X not in OS region" cpu-address)))))
    (logand (logxor (ash offset -8) offset) #xFF)))

;;; ---------------------------------------------------------------------------
;;; Bus: plain RAM behavior

(test bus-ram-roundtrips
  "Writes to RAM regions read back at any address $0000-$7FFF and $8000-$9FFF."
  (let ((bus (atari800-cl.bus:make-bus)))
    (dolist (addr '(#x0000 #x00FF #x0100 #x1234 #x7FFF #x8000 #x9FFF))
      (let ((v (logand addr #xFF)))
        (atari800-cl.bus:bus-write bus addr v)
        (is (= v (atari800-cl.bus:bus-read bus addr))
            "RAM write/read mismatch at $~4,'0X" addr)))))

(test bus-read16-little-endian
  "BUS-READ16 returns (high << 8) | low; ADDRESS+1 wraps within 64K."
  (let ((bus (atari800-cl.bus:make-bus)))
    (atari800-cl.bus:bus-write bus #x2000 #x34)
    (atari800-cl.bus:bus-write bus #x2001 #x12)
    (is (= #x1234 (atari800-cl.bus:bus-read16 bus #x2000)))
    ;; Wrap at $FFFF/$0000.
    (atari800-cl.bus:bus-write bus #xFFFF #xAA)
    (atari800-cl.bus:bus-write bus #x0000 #xBB)
    (is (= #xBBAA (atari800-cl.bus:bus-read16 bus #xFFFF)))))

;;; ---------------------------------------------------------------------------
;;; Bus: ROM overlay toggling

(test bus-basic-rom-toggle-shows-ram-or-rom
  "Toggling PORTB bit 1 makes BASIC ROM appear/disappear at $A000-$BFFF."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (rom (make-array #x2000 :element-type '(unsigned-byte 8)
                                 :initial-element #xCC)))
    (atari800-cl.bus:install-basic-rom bus rom)
    ;; Plant a RAM sentinel via the bypass helper.
    (atari800-cl.bus:bus-poke-ram bus #xA100 #x77)
    (atari800-cl.mmu:mmu-write-portb mmu #x01)               ; BASIC on
    (is (= #xCC (atari800-cl.bus:bus-read bus #xA100))
        "BASIC enabled: read must return ROM byte")
    (atari800-cl.mmu:mmu-write-portb mmu #x03)               ; BASIC off
    (is (= #x77 (atari800-cl.bus:bus-read bus #xA100))
        "BASIC disabled: RAM byte must show through")))

(test bus-os-rom-toggle-low-and-high-windows
  "PORTB bit 0 toggles both $C000-$CFFF and $D800-$FFFF together."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (rom (%make-marked-rom #x4000)))
    (atari800-cl.bus:install-os-rom bus rom)
    (atari800-cl.bus:bus-poke-ram bus #xC000 #x11)
    (atari800-cl.bus:bus-poke-ram bus #xD800 #x22)
    (atari800-cl.bus:bus-poke-ram bus #xFFFF #x33)
    ;; OS on
    (atari800-cl.mmu:mmu-write-portb mmu #x01)
    (is (= (%os-rom-byte-at #xC000) (atari800-cl.bus:bus-read bus #xC000))
        "OS low-window byte")
    (is (= (%os-rom-byte-at #xD800) (atari800-cl.bus:bus-read bus #xD800))
        "OS high-window byte")
    (is (= (%os-rom-byte-at #xFFFF) (atari800-cl.bus:bus-read bus #xFFFF))
        "OS top byte")
    ;; OS off: underlying RAM reappears
    (atari800-cl.mmu:mmu-write-portb mmu #x00)
    (is (= #x11 (atari800-cl.bus:bus-read bus #xC000)))
    (is (= #x22 (atari800-cl.bus:bus-read bus #xD800)))
    (is (= #x33 (atari800-cl.bus:bus-read bus #xFFFF)))))

(test bus-selftest-window-toggle
  "Self-test ROM at $5000-$57FF maps from OS-ROM[$1000-$17FF]."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (rom (%make-marked-rom #x4000)))
    (atari800-cl.bus:install-os-rom bus rom)
    (atari800-cl.bus:bus-poke-ram bus #x5000 #x88)
    (atari800-cl.bus:bus-poke-ram bus #x57FF #x99)
    ;; Self-test on
    (atari800-cl.mmu:mmu-write-portb mmu #x01)
    ;; OS-ROM[$1000] mapped to $5000.
    (let ((expected-lo (aref rom #x1000))
          (expected-hi (aref rom #x17FF)))
      (is (= expected-lo (atari800-cl.bus:bus-read bus #x5000)))
      (is (= expected-hi (atari800-cl.bus:bus-read bus #x57FF))))
    ;; Self-test off
    (atari800-cl.mmu:mmu-write-portb mmu #x81)
    (is (= #x88 (atari800-cl.bus:bus-read bus #x5000)))
    (is (= #x99 (atari800-cl.bus:bus-read bus #x57FF)))))

(test bus-rom-writes-go-to-underlying-ram
  "Writes under a ROM-mapped region land in RAM, not the ROM image."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (rom (make-array #x4000 :element-type '(unsigned-byte 8)
                                 :initial-element #xFF)))
    (atari800-cl.bus:install-os-rom bus rom)
    (atari800-cl.mmu:mmu-write-portb mmu #x01)             ; OS on
    (atari800-cl.bus:bus-write bus #xC123 #x42)
    (is (= #xFF (atari800-cl.bus:bus-read bus #xC123))
        "ROM still reads #xFF (write was masked)")
    (is (= #x42 (atari800-cl.bus:bus-peek-ram bus #xC123))
        "RAM underneath holds the written value")
    (atari800-cl.mmu:mmu-write-portb mmu #x00)
    (is (= #x42 (atari800-cl.bus:bus-read bus #xC123))
        "OS off: written byte now visible")))

;;; ---------------------------------------------------------------------------
;;; Bus: I/O range dispatch

(test bus-io-write-does-not-poke-ram
  "A write to $D300 (PIA range) with no chip attached must NOT land in RAM."
  (let ((bus (atari800-cl.bus:make-bus)))
    ;; Sanity: an out-of-range write does land in RAM.
    (atari800-cl.bus:bus-write bus #x0300 #x55)
    (is (= #x55 (atari800-cl.bus:bus-peek-ram bus #x0300)))
    ;; In-range write must be intercepted, leaving RAM at $D300 untouched.
    (atari800-cl.bus:bus-write bus #xD300 #x99)
    (is (zerop (atari800-cl.bus:bus-peek-ram bus #xD300))
        "$D300 write should not have leaked into RAM")))

(test bus-io-read-returns-open-bus-without-chips
  "Reads from unmapped I/O sub-pages return $FF (open bus)."
  (let ((bus (atari800-cl.bus:make-bus)))
    (dolist (addr '(#xD000 #xD200 #xD300 #xD400))
      (is (= #xFF (atari800-cl.bus:bus-read bus addr))
          "Open-bus default failed at $~4,'0X" addr))))

(test bus-io-dispatch-actually-routes-to-installed-closures
  "Installing a fake PIA closure proves dispatch reaches it (not RAM)."
  (let ((bus (atari800-cl.bus:make-bus))
        (captured nil))
    (setf (atari800-cl.bus:bus-pia-write-fn bus)
          (lambda (addr value) (push (cons addr value) captured)))
    (setf (atari800-cl.bus:bus-pia-read-fn bus)
          (lambda (addr) (declare (ignore addr)) #x5A))
    (atari800-cl.bus:bus-write bus #xD302 #xC0)
    (is (equal '((#xD302 . #xC0)) captured)
        "PIA write closure must have been called with the address and value")
    (is (= #x5A (atari800-cl.bus:bus-read bus #xD301))
        "PIA read closure must intercept the read")))

(test bus-pia-write-triggers-mmu-update-via-closure
  "Integration: an installed PIA closure that delegates to MMU-WRITE-PORTB
swaps OS ROM mapping immediately."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (rom (make-array #x4000 :element-type '(unsigned-byte 8)
                                 :initial-element #xA5)))
    (atari800-cl.bus:install-os-rom bus rom)
    (setf (atari800-cl.bus:bus-pia-write-fn bus)
          (lambda (addr value)
            ;; PORTB is offset 1 ($D301) on a 6520; offset 2 is PACTL.
            (when (= (logand addr #x03) #x01)
              (atari800-cl.mmu:mmu-write-portb mmu value))))
    (is (= #xA5 (atari800-cl.bus:bus-read bus #xC500))
        "OS on (default PORTB=$FF): ROM byte")
    (atari800-cl.bus:bus-write bus #xD301 #x00)
    (is (zerop (atari800-cl.bus:bus-peek-ram bus #xC500)))
    (is (= 0 (atari800-cl.bus:bus-read bus #xC500))
        "OS now off: read returns RAM (zero)")))

;;; ---------------------------------------------------------------------------
;;; Bus: render-dirty tracking (ROADMAP.md Phase 29b)
;;;
;;; This stage is bus-side infrastructure only -- nothing yet consults
;;; BUS-PAGE-DIRTY / BUS-IO-REGS-DIRTY-P to skip a render; these tests
;;; exercise the tracking itself directly.

(test bus-fresh-is-all-dirty
  "A freshly made bus starts with every page dirty and IO-REGS-DIRTY-P set,
so a machine's first frame always renders."
  (let ((bus (atari800-cl.bus:make-bus)))
    (is-true (atari800-cl.bus:bus-io-regs-dirty-p bus)
              "IO-REGS-DIRTY-P must start T")
    (loop for page from 0 below 256
          do (is (= 1 (aref (atari800-cl.bus:bus-page-dirty bus) page))
                 "page $~2,'0X must start dirty" page))))

(test bus-clear-render-dirty-cleans-everything
  "BUS-CLEAR-RENDER-DIRTY zeroes every PAGE-DIRTY slot and clears
IO-REGS-DIRTY-P."
  (let ((bus (atari800-cl.bus:make-bus)))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (is-false (atari800-cl.bus:bus-io-regs-dirty-p bus))
    (loop for page from 0 below 256
          do (is (zerop (aref (atari800-cl.bus:bus-page-dirty bus) page))
                 "page $~2,'0X must be clean" page))))

(test bus-ram-write-dirties-exactly-its-page
  "A single RAM write through BUS-WRITE dirties only the page its address
falls in, leaving every other page clean."
  (let ((bus (atari800-cl.bus:make-bus)))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-write bus #x9C40 #x41)
    (is (= 1 (aref (atari800-cl.bus:bus-page-dirty bus) #x9C))
        "page $9C (the write's page) must be dirty")
    (loop for page from 0 below 256
          unless (= page #x9C)
          do (is (zerop (aref (atari800-cl.bus:bus-page-dirty bus) page))
                 "page $~2,'0X must stay clean" page))))

(test bus-rom-overlay-write-dirties-underlying-ram-page
  "A write to an address currently showing ROM (e.g. under the OS ROM
window) still lands in RAM underneath and dirties that RAM page."
  (let* ((mmu (atari800-cl.mmu:make-mmu))
         (bus (atari800-cl.bus:make-bus :mmu mmu))
         (rom (make-array #x4000 :element-type '(unsigned-byte 8)
                                 :initial-element #xFF)))
    (atari800-cl.bus:install-os-rom bus rom)
    (atari800-cl.mmu:mmu-write-portb mmu #x01)              ; OS on
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-write bus #xC123 #x42)
    (is (= 1 (aref (atari800-cl.bus:bus-page-dirty bus) #xC1))
        "page $C1 (underlying RAM, even though ROM is currently mapped
over it) must be dirty")))

(test bus-poke-ram-also-dirties-its-page
  "BUS-POKE-RAM (the debugger/CLI bypass path) is still a RAM write for
dirty-tracking purposes."
  (let ((bus (atari800-cl.bus:make-bus)))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-poke-ram bus #x1234 #x99)
    (is (= 1 (aref (atari800-cl.bus:bus-page-dirty bus) #x12)))))

(test bus-gtia-color-write-sets-io-regs-dirty
  "A write to a GTIA color register (COLBK, offset $1A) sets
IO-REGS-DIRTY-P."
  (let ((bus (atari800-cl.bus:make-bus)))
    (setf (atari800-cl.bus:bus-gtia-write-fn bus) (lambda (addr val)
                                                      (declare (ignore addr val))))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-write bus #xD01A #x46)             ; COLBK
    (is-true (atari800-cl.bus:bus-io-regs-dirty-p bus))))

(test bus-antic-wsync-write-does-not-set-io-regs-dirty
  "A write to ANTIC's WSYNC ($D40A) -- a per-scanline timing strobe with no
rendering effect -- must NOT set IO-REGS-DIRTY-P."
  (let ((bus (atari800-cl.bus:make-bus)))
    (setf (atari800-cl.bus:bus-antic-write-fn bus) (lambda (addr val)
                                                       (declare (ignore addr val))))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-write bus #xD40A #x00)             ; WSYNC
    (is-false (atari800-cl.bus:bus-io-regs-dirty-p bus))))

(test bus-antic-dmactl-write-sets-io-regs-dirty
  "A write to ANTIC's DMACTL ($D400), which controls DMA/playfield mode,
sets IO-REGS-DIRTY-P."
  (let ((bus (atari800-cl.bus:make-bus)))
    (setf (atari800-cl.bus:bus-antic-write-fn bus) (lambda (addr val)
                                                       (declare (ignore addr val))))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-write bus #xD400 #x22)             ; DMACTL
    (is-true (atari800-cl.bus:bus-io-regs-dirty-p bus))))

(test bus-pokey-write-never-sets-io-regs-dirty
  "POKEY writes are never a render input; IO-REGS-DIRTY-P stays clear."
  (let ((bus (atari800-cl.bus:make-bus)))
    (setf (atari800-cl.bus:bus-pokey-write-fn bus) (lambda (addr val)
                                                       (declare (ignore addr val))))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-write bus #xD200 #xA0)             ; AUDF1
    (is-false (atari800-cl.bus:bus-io-regs-dirty-p bus))))

(test bus-pia-write-never-sets-io-regs-dirty
  "PIA writes are never a render input; IO-REGS-DIRTY-P stays clear."
  (let ((bus (atari800-cl.bus:make-bus)))
    (setf (atari800-cl.bus:bus-pia-write-fn bus) (lambda (addr val)
                                                     (declare (ignore addr val))))
    (atari800-cl.bus:bus-clear-render-dirty bus)
    (atari800-cl.bus:bus-write bus #xD300 #xFF)             ; PORTA
    (is-false (atari800-cl.bus:bus-io-regs-dirty-p bus))))
