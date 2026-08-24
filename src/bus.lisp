;;;; src/bus.lisp --- Atari 800 XL system bus and memory map dispatch.
;;;;
;;;; The CPU talks to the outside world through BUS-READ and BUS-WRITE.
;;;; This file owns the memory map and routes every address either to
;;;; RAM, to one of the ROM images, or to one of the four memory-mapped
;;;; chip ranges.
;;;;
;;;; Memory map (Atari 800 XL):
;;;;
;;;;   $0000-$7FFF  RAM (always)
;;;;   $5000-$57FF  Self-test ROM overlay when PORTB bit 7 = 0 AND OS on
;;;;   $8000-$9FFF  Cartridge right slot or RAM (no cart -> RAM)
;;;;   $A000-$BFFF  BASIC ROM (PORTB bit 1 = 0) or RAM
;;;;   $C000-$CFFF  OS ROM low (PORTB bit 0 = 1) or RAM
;;;;   $D000-$D0FF  GTIA
;;;;   $D100-$D1FF  Host disk bridge (ROADMAP.md Phase 16) when attached,
;;;;                else open bus (reads = $FF)
;;;;   $D200-$D2FF  POKEY
;;;;   $D300-$D3FF  PIA
;;;;   $D400-$D4FF  ANTIC
;;;;   $D500-$D7FF  Open bus
;;;;   $D800-$FFFF  OS ROM high (PORTB bit 0 = 1) or RAM
;;;;
;;;; The OS ROM is a 16 KiB image laid out so the I/O hole between
;;;; $D000-$D7FF still lives at offsets $1000-$17FF of the image — that
;;;; same range is what gets mapped into $5000-$57FF when the self-test
;;;; is enabled.
;;;;
;;;; ---- Chip dispatch (avoiding package circular dependencies) ----
;;;;
;;;; Each chip (GTIA, POKEY, PIA, ANTIC) registers two closures into the
;;;; bus when it is attached: one for reads, one for writes.  The bus
;;;; only invokes those closures — it never references the chip-package
;;;; symbols directly.  That keeps src/bus.lisp compile-time-independent
;;;; of the chip implementations.  The host disk bridge (ROADMAP.md Phase
;;;; 16, revised; src/hostdev.lisp) at $D100-$D1FF follows the identical
;;;; pattern even though it isn't one of the four real chips.

(in-package #:atari800-cl.bus)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  DECLAIM
;;; PROCLAIMS: under :serial t this also applies to every file compiled
;;; after this one in the same build, which is intentional here (the whole
;;; core wants this policy) — but the same declaim is repeated in each hot
;;; file below so the policy survives recompiling a single file
;;; interactively.  Safety floor stays at 1: no (safety 0) anywhere.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Memory-map constants

(defconstant +ram-size+              #x10000)
(defconstant +selftest-base+         #x5000)
(defconstant +selftest-end+          #x57FF)
(defconstant +selftest-os-offset+    #x1000)
(defconstant +basic-rom-base+        #xA000)
(defconstant +basic-rom-end+         #xBFFF)
(defconstant +os-rom-low-base+       #xC000)
(defconstant +os-rom-low-end+        #xCFFF)
(defconstant +io-base+               #xD000)
(defconstant +io-end+                #xD7FF)
(defconstant +os-rom-high-base+      #xD800)
(defconstant +os-rom-high-end+       #xFFFF)

(deftype bus-ram ()
  `(simple-array (unsigned-byte 8) (,+ram-size+)))

(deftype rom-array ()
  '(simple-array (unsigned-byte 8) (*)))

(defconstant +page-count+ 256)

(deftype page-dirty-map ()
  "A 256-entry byte vector, one slot per 256-byte page of the 64K address
space, used to record which pages a RAM write touched (ROADMAP.md Phase
29b). Slot N is nonzero iff page N has been written since the last
BUS-CLEAR-RENDER-DIRTY. A byte vector rather than a bit vector: it is
what FAST-AREF's contract wants (a SIMPLE-ARRAY of a small unsigned-byte
element type), and 256 bytes is noise next to the 64K RAM array it
shadows."
  `(simple-array (unsigned-byte 8) (,+page-count+)))

;;; ---------------------------------------------------------------------------
;;; Bus struct

(defstruct bus
  "Atari 800 XL system bus.

Slots:
  RAM         — flat 64K backing store (writes always land here, even
                under ROM-mapped regions; reads consult the map).
  OS-ROM      — 16K Atari OS image, or NIL when no ROM is loaded.
  BASIC-ROM   — 8K BASIC image, or NIL.
  MMU         — MMU object whose PORTB drives banking, or NIL.
  GTIA / POKEY / PIA / ANTIC — chip object back-pointers, set by
                each chip's attach-to-bus function.
  *-READ-FN / *-WRITE-FN     — per-chip dispatch closures.  Each is
                either NIL (chip not attached) or a function:
                  read closure:  (lambda (address) -> u8)
                  write closure: (lambda (address value) -> *)
  PAGE-DIRTY  — ROADMAP.md Phase 29b render-dirty tracking: a 256-entry
                PAGE-DIRTY-MAP, one slot per 256-byte page. Every RAM
                write sets its page's slot to 1. Starts ALL-DIRTY (every
                slot 1) so a freshly built or just-reset machine renders
                its first frame unconditionally rather than reading a
                stale all-clean map. A future render client consults
                this (via BUS-PAGE-DIRTY) to decide whether the pages it
                cares about changed, then calls BUS-CLEAR-RENDER-DIRTY.
                This bus never reads or clears the map itself.
  IO-REGS-DIRTY-P — companion boolean: T when a render-relevant GTIA or
                ANTIC register has been written since the last
                BUS-CLEAR-RENDER-DIRTY. Starts T for the same
                fresh/reset reason as PAGE-DIRTY."
  (ram (make-array +ram-size+ :element-type '(unsigned-byte 8)
                              :initial-element 0)
       :type bus-ram)
  (os-rom    nil :type (or null rom-array))
  (basic-rom nil :type (or null rom-array))
  (mmu       nil :type (or null mmu))
  (page-dirty (make-array +page-count+ :element-type '(unsigned-byte 8)
                                        :initial-element 1)
              :type page-dirty-map)
  (io-regs-dirty-p t :type boolean)
  ;; Per-chip dispatch closures.
  (gtia-read-fn   nil :type (or null function))
  (gtia-write-fn  nil :type (or null function))
  (pokey-read-fn  nil :type (or null function))
  (pokey-write-fn nil :type (or null function))
  (pia-read-fn    nil :type (or null function))
  (pia-write-fn   nil :type (or null function))
  (antic-read-fn  nil :type (or null function))
  (antic-write-fn nil :type (or null function))
  ;; Host disk bridge (ROADMAP.md Phase 16, revised) -- $D100-$D1FF.  Not a
  ;; real Atari chip; NIL on every machine that never calls ATTACH-HOSTDEV,
  ;; which leaves this page's behaviour exactly the open-bus default below.
  (hostdev-read-fn  nil :type (or null function))
  (hostdev-write-fn nil :type (or null function))
  ;; Chip object back-pointers.
  (gtia  nil)
  (pokey nil)
  (pia   nil)
  (antic nil))

;;; ---------------------------------------------------------------------------
;;; RAM peek/poke helpers (bypass the memory map).
;;;
;;; These exist primarily for tests and debugger inspection: they let
;;; callers reach into the underlying 64K backing store directly,
;;; without any ROM-overlay or I/O routing.  Declared NOTINLINE so
;;; SBCL's arm64 backend cannot fold a constant address into an
;;; out-of-range STR/LDR immediate.

(declaim (notinline bus-peek-ram bus-poke-ram))

(defun bus-peek-ram (bus address)
  "Read directly from the 64K RAM backing store, ignoring the memory map."
  (declare (type bus bus) (type u16 address))
  (aref (bus-ram bus) address))

(defun bus-poke-ram (bus address value)
  "Write directly to the 64K RAM backing store, ignoring the memory map.
Still a RAM write for render-dirty purposes (ROADMAP.md Phase 29b): a
debugger/CLI poke through this path can touch screen memory exactly as a
CPU store would, and the render skip's correctness must never depend on
which door a RAM write came through -- only BUS-WRITE's I/O-range branch
is exempt, because that write does NOT land in RAM at all."
  (declare (type bus bus) (type u16 address) (type u8 value))
  (setf (aref (bus-ram bus) address) (ldb (byte 8 0) value))
  ;; Index (ldb (byte 8 8) address) is in [0, 255] by construction: ADDRESS
  ;; is declared U16 (unsigned-byte 16), and (byte 8 8) extracts exactly its
  ;; high byte, which is provably a valid PAGE-DIRTY-MAP index.
  (setf (fast-aref (simple-array (unsigned-byte 8) (256))
                   (bus-page-dirty bus) (ldb (byte 8 8) address))
        1))

(defun bus-clear-render-dirty (bus)
  "Mark BUS's render-dirty state fully clean: every PAGE-DIRTY slot back
to 0 and IO-REGS-DIRTY-P back to NIL. Called by the future render client
(ROADMAP.md Phase 29c, not this commit) after it has rendered a complete
frame reflecting every write recorded since the last call. This bus
never calls it itself -- clearing is entirely the render client's call,
so a machine with no attached render client simply accumulates dirt
forever, which is harmless (it only ever gets read, never sized on)."
  (declare (type bus bus))
  (fill (bus-page-dirty bus) 0)
  (setf (bus-io-regs-dirty-p bus) nil)
  bus)

;;; ---------------------------------------------------------------------------
;;; ROM / MMU wiring helpers

(declaim (inline %byte-at))

(defun %byte-at (rom offset)
  "Read OFFSET from a (possibly shorter than expected) ROM array.
Returns #xFF when the offset is past the end of the image, mimicking
the open-bus / no-pull-up behaviour of unmapped ROM pages."
  (declare (type rom-array rom) (type fixnum offset))
  (if (and (>= offset 0) (< offset (length rom)))
      (aref rom offset)
      #xFF))

(defun attach-mmu (bus mmu)
  "Wire an MMU object into BUS.  Returns BUS for method-chaining."
  (declare (type bus bus) (type mmu mmu))
  (setf (bus-mmu bus) mmu)
  bus)

(defun install-os-rom (bus bytes)
  "Install BYTES (a sequence of u8 values) as the OS ROM image.
The image is coerced into a typed simple-array for fast reads."
  (declare (type bus bus))
  (setf (bus-os-rom bus)
        (coerce bytes '(simple-array (unsigned-byte 8) (*))))
  bus)

(defun install-basic-rom (bus bytes)
  "Install BYTES as the BASIC ROM image."
  (declare (type bus bus))
  (setf (bus-basic-rom bus)
        (coerce bytes '(simple-array (unsigned-byte 8) (*))))
  bus)

;;; ---------------------------------------------------------------------------
;;; Memory-map dispatch
;;;
;;; CL comparison operators take any number of arguments, so the
;;; inclusive range test "is ADDRESS within [LOW, HIGH]?" is spelled
;;; directly as (<= LOW ADDRESS HIGH) — no helper needed.

(declaim (ftype (function (bus u16) (values u8 &optional)) bus-read)
         (ftype (function (bus u16 u8) t) bus-write))

(defun bus-read (bus address)
  "Read one byte from ADDRESS, dispatching through the memory map.

Lookup order — first match wins:
  1. Self-test ROM at $5000-$57FF (when bit 7 = 0 AND OS ROM is on)
  2. BASIC ROM at $A000-$BFFF
  3. OS ROM low at $C000-$CFFF
  4. I/O space at $D000-$D7FF
  5. OS ROM high at $D800-$FFFF
  6. RAM (everywhere else, or anywhere a ROM is not currently mapped)"
  (declare (type bus bus) (type u16 address))
  (let ((mmu (bus-mmu bus)))
    (cond
      ((and mmu (bus-os-rom bus)
            (selftest-mapped-p mmu)
            (<= +selftest-base+ address +selftest-end+))
       (%byte-at (bus-os-rom bus)
                 (+ +selftest-os-offset+ (- address +selftest-base+))))
      ((and mmu (bus-basic-rom bus)
            (basic-rom-mapped-p mmu)
            (<= +basic-rom-base+ address +basic-rom-end+))
       (%byte-at (bus-basic-rom bus) (- address +basic-rom-base+)))
      ((and mmu (bus-os-rom bus)
            (os-rom-mapped-p mmu)
            (<= +os-rom-low-base+ address +os-rom-low-end+))
       (%byte-at (bus-os-rom bus) (- address +os-rom-low-base+)))
      ((<= +io-base+ address +io-end+)
       (io-read bus address))
      ((and mmu (bus-os-rom bus)
            (os-rom-mapped-p mmu)
            (<= +os-rom-high-base+ address +os-rom-high-end+))
       (%byte-at (bus-os-rom bus) (- address +os-rom-low-base+)))
      (t (aref (bus-ram bus) address)))))

(defun bus-write (bus address value)
  "Write VALUE to ADDRESS.  Writes to the I/O range ($D000-$D7FF) go
through the chip dispatch closures; everything else (including the
RAM under any currently-mapped ROM) lands in the 64K RAM array.

Every RAM store also marks its page dirty (ROADMAP.md Phase 29b) --
this is THE hot-path addition of the phase, so it is kept to one extra
store and zero extra branches on the common (non-I/O) path: the
COND's existing RAM clause gains a second SETF, nothing more.  I/O
writes never reach this store; their own render-dirty bookkeeping (for
the subset of GTIA/ANTIC registers that can affect pixels) lives in
IO-WRITE below, on the already-cold chip-dispatch branch."
  (declare (type bus bus) (type u16 address) (type u8 value))
  (cond
    ((<= +io-base+ address +io-end+)
     (io-write bus address (ldb (byte 8 0) value)))
    (t
     (setf (aref (bus-ram bus) address) (ldb (byte 8 0) value))
     ;; Index (ldb (byte 8 8) address) is in [0, 255] by construction:
     ;; ADDRESS is declared U16 (unsigned-byte 16), and (byte 8 8)
     ;; extracts exactly its high byte -- a provably valid PAGE-DIRTY-MAP
     ;; index, independent of any bounds check FAST-AREF may or may not
     ;; perform underneath it.
     (setf (fast-aref (simple-array (unsigned-byte 8) (256))
                      (bus-page-dirty bus) (ldb (byte 8 8) address))
           1))))

(defun bus-read16 (bus address)
  "Read a little-endian 16-bit word.  ADDRESS+1 wraps within 64K."
  (declare (type bus bus) (type u16 address))
  (let ((lo (bus-read bus address))
        (hi (bus-read bus (ldb (byte 16 0) (1+ address)))))
    (dpb hi (byte 8 8) lo)))

;;; ---------------------------------------------------------------------------
;;; I/O sub-dispatch (one switch over the high byte of the I/O page).
;;;
;;; If the chip's dispatch closure is NIL (chip not attached), the read
;;; returns #xFF (open bus) and the write is silently dropped.  Crucially,
;;; the write does NOT fall through to RAM — that's what distinguishes
;;; an I/O-range write from a normal memory write.

(defun io-read (bus address)
  (declare (type bus bus) (type u16 address))
  (let ((fn (case (logand address #xFF00)
              (#xD000 (bus-gtia-read-fn bus))
              (#xD100 (bus-hostdev-read-fn bus))
              (#xD200 (bus-pokey-read-fn bus))
              (#xD300 (bus-pia-read-fn bus))
              (#xD400 (bus-antic-read-fn bus)))))
    (if fn (funcall fn address) #xFF)))

;;; ---------------------------------------------------------------------------
;;; Render-dirty register classification (ROADMAP.md Phase 29b).
;;;
;;; Every GTIA/ANTIC write sets IO-REGS-DIRTY-P EXCEPT a short, explicitly
;;; enumerated set that provably cannot change a rendered pixel:
;;;
;;;   GTIA HITCLR ($D01E, offset $1E) -- write-only strobe that clears the
;;;   collision latches (a READ-side bookkeeping effect only; nothing it
;;;   touches is consulted by the renderer).
;;;
;;;   GTIA CONSOL ($D01F, offset $1F) -- the write side of this register
;;;   drives the speaker (audio), not video; the read side (console keys)
;;;   is unrelated to this write-side classification.
;;;
;;;   ANTIC WSYNC ($D40A, offset $0A) -- a per-scanline CPU-halt timing
;;;   strobe; ANTIC-WRITE's only effect for this offset is arming
;;;   WSYNC-PENDING, consumed by the scheduler, never by the renderer.
;;;   Synchronized display code writes this every line, so leaving it
;;;   OUT of the dirty set is what makes the map usable at all -- folding
;;;   it in would make nearly every real program's frames look dirty.
;;;
;;;   ANTIC NMIEN ($D40E, offset $0E) -- gates whether DLI/VBI interrupts
;;;   fire; it does not itself hold or move any pixel data. Any actual
;;;   visual effect a DLI/VBI handler produces happens through a SEPARATE
;;;   GTIA/ANTIC register write inside that handler, which this same
;;;   classification already tracks on its own merits.
;;;
;;;   ANTIC NMIRES ($D40F, offset $0F) -- write-only strobe that clears
;;;   the NMI status latch (ANTIC-NMIST), a read-side flag with no
;;;   rendering effect.
;;;
;;; Everything else in either write window -- including every register
;;; the phase's own enumeration names (DMACTL, CHACTL, DLISTL/H, HSCROL,
;;; VSCROL, PMBASE, CHBASE, all GTIA positions/sizes/graphics/colors,
;;; PRIOR, VDELAY, GRACTL) -- sets the flag. Per the phase's "when in
;;; doubt, include" rule, any register not named above (e.g. ANTIC's
;;; unbacked $06/$08 offsets, or VCOUNT/PENH/PENV, which are nominally
;;; read-only but still latched into the register file on a write) also
;;; sets the flag rather than being reasoned about here.

(defconstant +gtia-w-hitclr+  #x1E)
(defconstant +gtia-w-consol+  #x1F)
(defconstant +antic-w-wsync+  #x0A)
(defconstant +antic-w-nmien+  #x0E)
(defconstant +antic-w-nmires+ #x0F)

(declaim (inline %gtia-write-render-inert-p %antic-write-render-inert-p))

(defun %gtia-write-render-inert-p (address)
  "T when ADDRESS (anywhere in the mirrored $D000-$D0FF GTIA write
window) is HITCLR or CONSOL -- see the section comment above."
  (declare (type u16 address))
  (let ((offset (ldb (byte 5 0) address)))
    (or (= offset +gtia-w-hitclr+) (= offset +gtia-w-consol+))))

(defun %antic-write-render-inert-p (address)
  "T when ADDRESS (anywhere in the mirrored $D400-$D4FF ANTIC write
window) is WSYNC, NMIEN, or NMIRES -- see the section comment above."
  (declare (type u16 address))
  (let ((offset (ldb (byte 5 0) address)))
    (or (= offset +antic-w-wsync+)
        (= offset +antic-w-nmien+)
        (= offset +antic-w-nmires+))))

(defun io-write (bus address value)
  (declare (type bus bus) (type u16 address) (type u8 value))
  (let ((fn (case (logand address #xFF00)
              (#xD000 (bus-gtia-write-fn bus))
              (#xD100 (bus-hostdev-write-fn bus))
              (#xD200 (bus-pokey-write-fn bus))
              (#xD300 (bus-pia-write-fn bus))
              (#xD400 (bus-antic-write-fn bus)))))
    (when fn
      (funcall fn address value)
      ;; PIA ($D300) and POKEY ($D200) writes never reach the COND below
      ;; setting anything (neither range matches either CLAUSE's guard),
      ;; matching the phase's explicit "never render inputs" rule for
      ;; those two chips.
      (cond
        ((and (<= #xD000 address #xD0FF)
              (not (%gtia-write-render-inert-p address)))
         (setf (bus-io-regs-dirty-p bus) t))
        ((and (<= #xD400 address #xD4FF)
              (not (%antic-write-render-inert-p address)))
         (setf (bus-io-regs-dirty-p bus) t))))))
