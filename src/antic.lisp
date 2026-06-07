;;;; src/antic.lisp --- ANTIC display-list + DMA engine (NTSC).
;;;;
;;;; The Atari 800 XL's ANTIC chip is a dedicated DMA controller for
;;;; the display.  It walks a "display list" — a small program in main
;;;; memory that tells ANTIC, line by line, what to fetch and display.
;;;; While ANTIC is fetching, it steals CPU cycles on the shared bus.
;;;;
;;;; Timing model (NTSC):
;;;;   262 scanlines / frame
;;;;   114 color clocks / scanline   (one color clock = one CPU half-cycle;
;;;;                                  for our integer model we treat them
;;;;                                  as 1:1 with CPU cycles)
;;;;   scanlines 8-247  — active display region
;;;;   scanline 248     — VBLANK begins; VBI fires here when NMIEN bit 6 set
;;;;
;;;; Cycle-stealing accounting is simplified: we lump all the per-line
;;;; steals (DRAM refresh + P/M DMA) at color-clock 0 of each scanline,
;;;; returning that lump from ANTIC-TICK so the machine scheduler can
;;;; deduct them from the CPU's budget for the line.
;;;;
;;;; Display-list parsing supports:
;;;;   mode 0 (blank lines)  — bits 4-6 specify (N+1) scanlines of blank
;;;;   mode 1 (JMP / JVB)    — bit 6 = JVB (wait for VBLANK after jump);
;;;;                            next two bytes are the new DL address
;;;;   modes 2-F             — character / graphics modes with a known
;;;;                            number of scanlines per mode line
;;;;   bit 7 (DLI)           — fire NMI on the LAST scanline of this mode
;;;;                            line (gated by NMIEN bit 7)
;;;;   bit 6 (LMS on modes 2-F) — next two bytes are a screen-data base
;;;;                              address.  We advance the DL offset past
;;;;                              them but don't otherwise emulate display
;;;;                              data fetching.

(in-package #:atari800-cl.antic)

;;; ---------------------------------------------------------------------------
;;; NTSC timing constants

(defconstant +scanlines-per-frame+        262)
(defconstant +color-clocks-per-scanline+  114)
(defconstant +active-start-scanline+      8)
(defconstant +vbi-scanline+               248)
(defconstant +dram-refresh-cycles+        9)

;;; ANTIC register offsets (within the 32-byte register file).
(defconstant +reg-dmactl+  #x00)
(defconstant +reg-chactl+  #x01)
(defconstant +reg-dlistl+  #x02)
(defconstant +reg-dlisth+  #x03)
(defconstant +reg-hscrol+  #x04)
(defconstant +reg-vscrol+  #x05)
(defconstant +reg-pmbase+  #x07)
(defconstant +reg-chbase+  #x09)
(defconstant +reg-wsync+   #x0A)
(defconstant +reg-vcount+  #x0B)
(defconstant +reg-penh+    #x0C)
(defconstant +reg-penv+    #x0D)
(defconstant +reg-nmien+   #x0E)
(defconstant +reg-nmires+  #x0F)

;;; NMI status bits — also the masks used in NMIEN.
(defconstant +nmi-dli+    #x80)
(defconstant +nmi-vbi+    #x40)
(defconstant +nmi-reset+  #x20)

;;; DMACTL bits.
(defconstant +dmactl-playfield-mask+ #x03)   ; 00=off, 01=narrow, 10=normal, 11=wide
(defconstant +dmactl-missile-mask+   #x04)
(defconstant +dmactl-player-mask+    #x08)
(defconstant +dmactl-instructions+   #x20)   ; bit 5: DL fetching enabled

;;; ---------------------------------------------------------------------------
;;; ANTIC struct

(defstruct antic
  "ANTIC state.

Slots:
  REGISTERS                 — 32-byte register file (raw shadow store).
  DLIST-POINTER             — current display-list address (latched from
                              DLISTL/DLISTH; updated by JMP/JVB).
  DL-OFFSET                 — bytes consumed within the current DL since
                              DLIST-POINTER was last latched.
  SCANLINE                  — vertical line counter, 0-261.
  COLOR-CLOCK               — horizontal counter, 0-113.
  DMACTL                    — shadow of register $D400 (DMA enables).
  NMIEN                     — shadow of register $D40E (NMI enables).
  NMIST                     — NMI status latch (bits 6/7 = VBI/DLI pending).
  CURRENT-MODE              — DL instruction byte currently in flight.
  MODE-SCANLINES-REMAINING  — scanlines left in the current mode line.
  DLI-ARMED                 — T if the current mode line had DLI bit set.
  JVB-WAIT                  — T after a JVB instruction; cleared at VBI.
  FRAME-COUNT               — frames elapsed since reset (debug counter).
  STOLEN-CYCLES             — running total of cycles ANTIC has stolen.
  CPU                       — CPU back-pointer for NMI routing.
  BUS                       — bus back-pointer (currently unused in tick)."
  (registers (make-array 32 :element-type '(unsigned-byte 8)
                            :initial-element 0)
             :type (simple-array (unsigned-byte 8) (32)))
  (dlist-pointer 0 :type (unsigned-byte 16))
  (dl-offset     0 :type (unsigned-byte 16))
  (scanline      0 :type (unsigned-byte 9))
  (color-clock   0 :type (unsigned-byte 8))
  (dmactl        0 :type (unsigned-byte 8))
  (nmien         0 :type (unsigned-byte 8))
  (nmist         0 :type (unsigned-byte 8))
  (current-mode  0 :type (unsigned-byte 8))
  (mode-scanlines-remaining 0 :type fixnum)
  (dli-armed     nil :type boolean)
  (jvb-wait      nil :type boolean)
  (frame-count   0 :type fixnum)
  (stolen-cycles 0 :type fixnum)
  (cpu nil)
  (bus nil))

;;; ---------------------------------------------------------------------------
;;; DL parsing helpers

(declaim (inline %dl-current-address))

(defun %dl-current-address (antic)
  "Compute the absolute bus address of the next DL byte to fetch."
  (declare (type antic antic))
  (logand (+ (antic-dlist-pointer antic) (antic-dl-offset antic)) #xFFFF))

(defun mode-line-scanlines (mode-byte)
  "Return the number of scanlines a display-list mode line occupies."
  (declare (type (unsigned-byte 8) mode-byte))
  (let ((mode (logand mode-byte #x0F)))
    (case mode
      (0  (1+ (ash (logand mode-byte #x70) -4)))  ; mode 0: (N+1) blank lines
      (1  0)                                       ; JMP / JVB
      ((2 4 6 8) 8)
      (3  10)
      ((5 7) 16)
      ((9 10) 4)
      ((11 13) 2)
      ((12 14 15) 1)
      (t 1))))

(defun pm-dma-cycles (dmactl)
  "Per-scanline cycles stolen by P/M DMA given DMACTL.
Bit 2 enables 1-cycle missile DMA; bit 3 enables 4-cycle player DMA."
  (declare (type (unsigned-byte 8) dmactl))
  (+ (if (zerop (logand dmactl +dmactl-missile-mask+)) 0 1)
     (if (zerop (logand dmactl +dmactl-player-mask+))  0 4)))

(declaim (inline %scanline-steal))

(defun %scanline-steal (antic)
  "Cycles ANTIC steals on the current scanline (DRAM refresh + P/M DMA)."
  (declare (type antic antic))
  (+ +dram-refresh-cycles+
     (pm-dma-cycles (antic-dmactl antic))))

(defun process-dl-instruction (antic)
  "Fetch one display-list instruction from the bus and update ANTIC.
Returns the number of DL bytes consumed by this instruction (1 for a
plain mode byte, 3 for JMP/JVB or any inst with the LMS bit set, etc.)."
  (declare (type antic antic))
  (let* ((bus  (antic-bus antic))
         (inst (atari800-cl.bus:bus-read bus (%dl-current-address antic)))
         (mode (logand inst #x0F))
         (lms? (and (not (zerop (logand inst #x40))) (>= mode 2)))
         (dli? (not (zerop (logand inst #x80)))))
    (incf (antic-dl-offset antic))
    (setf (antic-current-mode antic) inst
          (antic-dli-armed antic) dli?)
    (cond
      ((= mode 1)
       ;; JMP / JVB.  Read two bytes for the new DL address, then either
       ;; jump immediately (JMP) or wait for VBLANK (JVB, bit 6).
       (let ((lo (atari800-cl.bus:bus-read bus (%dl-current-address antic))))
         (incf (antic-dl-offset antic))
         (let ((hi (atari800-cl.bus:bus-read bus (%dl-current-address antic))))
           (incf (antic-dl-offset antic))
           (setf (antic-dlist-pointer antic) (logior lo (ash hi 8))
                 (antic-dl-offset antic) 0
                 (antic-mode-scanlines-remaining antic) 0)
           (when (not (zerop (logand inst #x40)))
             (setf (antic-jvb-wait antic) t)))))
      (t
       (when lms?
         ;; Skip the two-byte LMS load-memory-scan address (we don't
         ;; model screen-data fetches).
         (incf (antic-dl-offset antic) 2))
       (setf (antic-mode-scanlines-remaining antic)
             (mode-line-scanlines inst))))))

(declaim (inline %display-active-p))

(defun %display-active-p (antic)
  "Return T if ANTIC should be fetching DL bytes on the current scanline."
  (declare (type antic antic))
  (let ((s (antic-scanline antic)))
    (and (>= s +active-start-scanline+)
         (<  s +vbi-scanline+)
         (not (zerop (antic-dmactl antic))))))

;;; ---------------------------------------------------------------------------
;;; NMI signalling

(declaim (inline %raise-nmi))

(defun %raise-nmi (antic)
  "Set CPU-PENDING-NMI on the attached CPU (if any)."
  (declare (type antic antic))
  (let ((cpu (antic-cpu antic)))
    (when cpu (setf (cpu-pending-nmi cpu) t))))

;;; ---------------------------------------------------------------------------
;;; Tick — advances one color clock

(defun antic-tick (antic cpu bus)
  "Advance ANTIC by one color clock.  Returns the cycles stolen this tick.

The per-scanline steal (DRAM refresh + P/M DMA) is lumped at
color-clock 0 of each new scanline; all subsequent ticks within the
same scanline return 0.  Display-list parsing, VBI, and DLI events
are all serviced at color-clock 0 as well."
  (declare (type antic antic))
  ;; Cache CPU and bus pointers on the struct so helpers can reach them.
  (when cpu (setf (antic-cpu antic) cpu))
  (when bus (setf (antic-bus antic) bus))
  (let ((stolen 0))
    (when (zerop (antic-color-clock antic))
      ;; ----- New scanline ----------------------------------------
      ;; VBI fires on entry to scanline 248.
      (when (= (antic-scanline antic) +vbi-scanline+)
        (setf (antic-nmist antic) (logior (antic-nmist antic) +nmi-vbi+))
        (when (not (zerop (logand (antic-nmien antic) +nmi-vbi+)))
          (%raise-nmi antic))
        ;; A JVB instruction parks ANTIC until VBLANK; we release it now.
        (setf (antic-jvb-wait antic) nil
              (antic-mode-scanlines-remaining antic) 0
              ;; Re-latch DL pointer from the shadow registers.
              (antic-dlist-pointer antic)
              (logior (aref (antic-registers antic) +reg-dlistl+)
                      (ash (aref (antic-registers antic) +reg-dlisth+) 8))
              (antic-dl-offset antic) 0))
      ;; If a new mode line is needed, fetch the next DL instruction.
      (when (and (zerop (antic-mode-scanlines-remaining antic))
                 (not (antic-jvb-wait antic))
                 (%display-active-p antic))
        (process-dl-instruction antic))
      ;; DLI fires on the LAST scanline of the current mode line.  We
      ;; identify "last" by the remaining counter being 1 (it'll
      ;; decrement to 0 when the scanline finishes).
      (when (and (antic-dli-armed antic)
                 (= (antic-mode-scanlines-remaining antic) 1))
        (setf (antic-nmist antic) (logior (antic-nmist antic) +nmi-dli+))
        (when (not (zerop (logand (antic-nmien antic) +nmi-dli+)))
          (%raise-nmi antic))
        (setf (antic-dli-armed antic) nil))
      ;; Refresh + P/M DMA steals for this line.
      (setf stolen (%scanline-steal antic))
      (incf (antic-stolen-cycles antic) stolen))
    ;; Advance the color clock.
    (incf (antic-color-clock antic))
    (when (>= (antic-color-clock antic) +color-clocks-per-scanline+)
      (setf (antic-color-clock antic) 0)
      ;; End-of-scanline housekeeping.
      (when (plusp (antic-mode-scanlines-remaining antic))
        (decf (antic-mode-scanlines-remaining antic)))
      (incf (antic-scanline antic))
      (when (>= (antic-scanline antic) +scanlines-per-frame+)
        (setf (antic-scanline antic) 0)
        (incf (antic-frame-count antic))))
    stolen))

;;; ---------------------------------------------------------------------------
;;; Register access

(defun antic-read (antic address)
  "Read an ANTIC register.  Special cases:
  $D40B (VCOUNT) — returns SCANLINE >> 1 (ANTIC's vertical-line counter)
  $D40F (NMIST)  — returns the NMI status latch"
  (declare (type antic antic) (type (unsigned-byte 16) address))
  (let ((offset (logand address #x1F)))
    (case offset
      (#.+reg-vcount+ (logand (ash (antic-scanline antic) -1) #xFF))
      (#.+reg-nmires+ (antic-nmist antic))
      (t (aref (antic-registers antic) offset)))))

(defun antic-write (antic address value)
  "Write an ANTIC register.  DMACTL/DLISTL/DLISTH/NMIEN/NMIRES update
their shadow slots; everything else is just latched into the register file."
  (declare (type antic antic) (type (unsigned-byte 16) address)
           (type (unsigned-byte 8) value))
  (let ((offset (logand address #x1F))
        (v (logand value #xFF)))
    (setf (aref (antic-registers antic) offset) v)
    (case offset
      (#.+reg-dmactl+ (setf (antic-dmactl antic) v))
      (#.+reg-dlistl+ (setf (antic-dlist-pointer antic)
                            (logior v (logand (antic-dlist-pointer antic)
                                              #xFF00))
                            (antic-dl-offset antic) 0
                            (antic-mode-scanlines-remaining antic) 0))
      (#.+reg-dlisth+ (setf (antic-dlist-pointer antic)
                            (logior (logand (antic-dlist-pointer antic) #xFF)
                                    (ash v 8))
                            (antic-dl-offset antic) 0
                            (antic-mode-scanlines-remaining antic) 0))
      (#.+reg-nmien+ (setf (antic-nmien antic) v))
      (#.+reg-nmires+ (setf (antic-nmist antic) 0))
      (t nil))))

(defun reset-antic (antic)
  "Reset all ANTIC counters and shadow slots.  Returns ANTIC."
  (declare (type antic antic))
  (fill (antic-registers antic) 0)
  (setf (antic-dlist-pointer antic) 0
        (antic-dl-offset antic) 0
        (antic-scanline antic) 0
        (antic-color-clock antic) 0
        (antic-dmactl antic) 0
        (antic-nmien antic) 0
        (antic-nmist antic) 0
        (antic-current-mode antic) 0
        (antic-mode-scanlines-remaining antic) 0
        (antic-dli-armed antic) nil
        (antic-jvb-wait antic) nil
        (antic-frame-count antic) 0
        (antic-stolen-cycles antic) 0)
  antic)

(defun attach-antic (bus antic &optional cpu)
  "Install ANTIC's read/write closures into BUS.  When CPU is supplied,
ANTIC stores the back-pointer so NMI events can route there."
  (declare (type antic antic))
  (when cpu (setf (antic-cpu antic) cpu))
  (setf (antic-bus antic) bus
        (bus-antic bus) antic
        (bus-antic-read-fn  bus) (lambda (addr) (antic-read antic addr))
        (bus-antic-write-fn bus) (lambda (addr val) (antic-write antic addr val)))
  bus)
