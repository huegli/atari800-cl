;;;; src/gtia.lisp --- GTIA (player/missile / collision latches / console).
;;;;
;;;; GTIA presents 32 8-bit registers across $D000-$D01F (mirrored
;;;; across the entire $D000-$D0FF page).  The chip uses SEPARATE
;;;; register windows for reads and writes — software that writes
;;;; HPOSP0 ($D000) and reads $D000 right after gets the M0PF collision
;;;; register, not the HPOSP0 it just wrote.
;;;;
;;;; Write window (by offset):
;;;;   0-3   HPOSP0-HPOSP3   horizontal positions of players
;;;;   4-7   HPOSM0-HPOSM3   horizontal positions of missiles
;;;;   8-11  SIZEP0-SIZEP3   player sizes
;;;;   12    SIZEM           missile sizes (one byte for all four)
;;;;   13-16 GRAFP0-GRAFP3   player graphics shift-register data
;;;;   17    GRAFM           missile graphics data
;;;;   18-21 COLPM0-COLPM3   player/missile colors
;;;;   22-25 COLPF0-COLPF3   playfield colors
;;;;   26    COLBK           background color
;;;;   27    PRIOR           priority control
;;;;   28    VDELAY          vertical delay for P/M graphics
;;;;   29    GRACTL          graphics control (enables P/M DMA → graphics regs)
;;;;   30    HITCLR          write-only — clears collision latches on ANY write
;;;;   31    CONSOL          write side = speaker output
;;;;
;;;; Read window (by offset):
;;;;   0-3   M0PF-M3PF       missile-to-playfield collisions
;;;;   4-7   P0PF-P3PF       player-to-playfield collisions
;;;;   8-11  M0P-M3P         missile-to-player collisions
;;;;   12-15 P0P-P3P         player-to-player collisions
;;;;   16-19 TRIG0-TRIG3     triggers (1 = released, 0 = pressed)
;;;;   20    PAL             PAL/NTSC indicator (1 = NTSC on the 800XL we model)
;;;;   31    CONSOL          read side = console-key state (low 3 bits)

(in-package #:atari800-cl.gtia)

;;; ---------------------------------------------------------------------------
;;; Register-offset constants

;; Write side
(defconstant +w-hposp0+  #x00)
(defconstant +w-hposm0+  #x04)
(defconstant +w-sizep0+  #x08)
(defconstant +w-sizem+   #x0C)
(defconstant +w-grafp0+  #x0D)
(defconstant +w-grafm+   #x11)
(defconstant +w-colpm0+  #x12)
(defconstant +w-colpf0+  #x16)
(defconstant +w-colbk+   #x1A)
(defconstant +w-prior+   #x1B)
(defconstant +w-vdelay+  #x1C)
(defconstant +w-gractl+  #x1D)
(defconstant +w-hitclr+  #x1E)
(defconstant +w-consol+  #x1F)

;; Read side
(defconstant +r-m0pf+    #x00)   ; M{0..3}PF at offsets 0..3
(defconstant +r-p0pf+    #x04)   ; P{0..3}PF at offsets 4..7
(defconstant +r-m0p+     #x08)   ; M{0..3}P  at offsets 8..11
(defconstant +r-p0p+     #x0C)   ; P{0..3}P  at offsets 12..15
(defconstant +r-trig0+   #x10)   ; TRIG{0..3} at offsets 16..19
(defconstant +r-pal+     #x14)   ; PAL at offset 20
(defconstant +r-consol+  #x1F)   ; CONSOL at offset 31

;;; ---------------------------------------------------------------------------
;;; Defaults helper

(defun %make-gtia-read-regs ()
  "Build the read-side register array with cold-reset defaults:
TRIG0..3 = 1 (not pressed), PAL = 1 (NTSC), CONSOL = 7 (no keys)."
  (let ((r (make-array 32 :element-type '(unsigned-byte 8)
                          :initial-element 0)))
    (setf (aref r +r-trig0+)       1
          (aref r (+ +r-trig0+ 1)) 1
          (aref r (+ +r-trig0+ 2)) 1
          (aref r (+ +r-trig0+ 3)) 1
          (aref r +r-pal+)         1
          (aref r +r-consol+)      7)
    r))

;;; ---------------------------------------------------------------------------
;;; GTIA struct

(defstruct gtia
  "GTIA shadow state.

Slots:
  WRITE-REGS — 32-byte array of last-written values for each register.
               Reading the GTIA does NOT consult this array; it's only
               here so debuggers / tests can inspect software's writes.
  READ-REGS  — 32-byte array returned by GTIA-READ.  Collision latches
               live in offsets 0-15; triggers, PAL, and CONSOL provide
               the inputs."
  (write-regs (make-array 32 :element-type '(unsigned-byte 8)
                             :initial-element 0)
              :type (simple-array (unsigned-byte 8) (32)))
  (read-regs  (%make-gtia-read-regs)
              :type (simple-array (unsigned-byte 8) (32))))

;;; ---------------------------------------------------------------------------
;;; Public dispatch

(defun gtia-read (gtia address)
  "Return one byte from the read window (collision latches + triggers + CONSOL)."
  (declare (type gtia gtia) (type (unsigned-byte 16) address))
  (aref (gtia-read-regs gtia) (logand address #x1F)))

(defun gtia-clear-collisions (gtia)
  "Reset the 16 collision-latch bytes (offsets 0-15) to zero.  Triggers,
PAL, and CONSOL are NOT touched."
  (declare (type gtia gtia))
  (let ((r (gtia-read-regs gtia)))
    (dotimes (i 16)
      (setf (aref r i) 0)))
  gtia)

(defun gtia-write (gtia address value)
  "Write one byte to the GTIA's write window.  Side effects:
  HITCLR (offset $1E) — clears all collision latches on any write."
  (declare (type gtia gtia) (type (unsigned-byte 16) address)
           (type (unsigned-byte 8) value))
  (let ((offset (logand address #x1F))
        (v (logand value #xFF)))
    (setf (aref (gtia-write-regs gtia) offset) v)
    (when (= offset +w-hitclr+)
      (gtia-clear-collisions gtia))))

(defun reset-gtia (gtia)
  "Reset the write window to zero and restore the read-side defaults."
  (declare (type gtia gtia))
  (fill (gtia-write-regs gtia) 0)
  (fill (gtia-read-regs  gtia) 0)
  (let ((r (gtia-read-regs gtia)))
    (setf (aref r +r-trig0+)       1
          (aref r (+ +r-trig0+ 1)) 1
          (aref r (+ +r-trig0+ 2)) 1
          (aref r (+ +r-trig0+ 3)) 1
          (aref r +r-pal+)         1
          (aref r +r-consol+)      7))
  gtia)

;;; ---------------------------------------------------------------------------
;;; Collision recording
;;;
;;; Callers pass keyword identifiers; we decode them into (type, index)
;;; pairs and OR the appropriate bit into the right collision register.
;;; Player-player collisions are symmetric — both directions get latched.

(defun %obj-spec (key)
  "Decode KEY into (VALUES type index), where type ∈ {:missile :player :playfield}.
Returns (VALUES NIL NIL) for unknown keywords."
  (case key
    (:m0 (values :missile 0))  (:m1 (values :missile 1))
    (:m2 (values :missile 2))  (:m3 (values :missile 3))
    (:p0 (values :player 0))   (:p1 (values :player 1))
    (:p2 (values :player 2))   (:p3 (values :player 3))
    (:pf0 (values :playfield 0)) (:pf1 (values :playfield 1))
    (:pf2 (values :playfield 2)) (:pf3 (values :playfield 3))
    (t (values nil nil))))

(defun %or-bit (gtia offset bit)
  (declare (type gtia gtia) (type fixnum offset bit))
  (let ((r (gtia-read-regs gtia)))
    (setf (aref r offset)
          (logand #xFF (logior (aref r offset) (ash 1 bit))))))

(defun gtia-record-collision (gtia obj-a obj-b)
  "Record a collision between two objects.  Each is one of the keywords
:M0-:M3, :P0-:P3, :PF0-:PF3.  The appropriate bit in the appropriate
read-side collision register is OR'ed in.

Layout:
  Missile vs Playfield  → M{a}PF (offset 0..3),   bit = PF index
  Player  vs Playfield  → P{a}PF (offset 4..7),   bit = PF index
  Missile vs Player     → M{a}P  (offset 8..11),  bit = player index
  Player  vs Player     → P{a}P  AND P{b}P (both directions)

Missile-vs-missile is not modeled (GTIA has no missile-missile register).
Argument order does not matter for missile/player vs playfield or for
missile vs player — the function normalizes."
  (multiple-value-bind (atype aidx) (%obj-spec obj-a)
    (multiple-value-bind (btype bidx) (%obj-spec obj-b)
      (when (and atype btype)
        (cond
          ;; Always orient so the playfield is the SECOND argument.
          ((eq atype :playfield)
           (gtia-record-collision gtia obj-b obj-a))
          ;; Missile vs Playfield
          ((and (eq atype :missile) (eq btype :playfield))
           (%or-bit gtia (+ +r-m0pf+ aidx) bidx))
          ;; Player vs Playfield
          ((and (eq atype :player) (eq btype :playfield))
           (%or-bit gtia (+ +r-p0pf+ aidx) bidx))
          ;; Missile vs Player
          ((and (eq atype :missile) (eq btype :player))
           (%or-bit gtia (+ +r-m0p+ aidx) bidx))
          ;; Player vs Missile (mirror of the above)
          ((and (eq atype :player) (eq btype :missile))
           (%or-bit gtia (+ +r-m0p+ bidx) aidx))
          ;; Player vs Player — symmetric, set both
          ((and (eq atype :player) (eq btype :player))
           (unless (= aidx bidx)
             (%or-bit gtia (+ +r-p0p+ aidx) bidx)
             (%or-bit gtia (+ +r-p0p+ bidx) aidx)))
          ;; Missile-missile: not modeled
          (t nil))))))

;;; ---------------------------------------------------------------------------
;;; Bus wiring

(defun attach-gtia (bus gtia)
  "Install GTIA's read/write closures into BUS so addresses in $D000-$D0FF
route to it.  Returns BUS."
  (declare (type gtia gtia))
  (setf (bus-gtia bus) gtia
        (bus-gtia-read-fn  bus) (lambda (addr) (gtia-read gtia addr))
        (bus-gtia-write-fn bus) (lambda (addr val) (gtia-write gtia addr val)))
  bus)
