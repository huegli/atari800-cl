;;;; scripts/bench.lisp --- Frame-rate benchmark harness.
;;;;
;;;; Portable Common Lisp.  Loaded by scripts/bench-sbcl.sh and
;;;; scripts/bench-lispworks.lisp after ASDF has loaded :atari800-cl.
;;;;
;;;; This harness works WITHOUT real ROM images (roms/ is gitignored):
;;;; it builds the machine with a synthetic 16 KiB OS ROM, the same
;;;; approach as tests/test-helpers.lisp::%make-synthetic-os-rom, but
;;;; inlined here so the bench does not depend on the test system.
;;;;
;;;; Two workloads:
;;;;   NOP   — a NOP sled that loops back via a JMP at $FFF9, so the PC
;;;;           marches NOPs from $C000 to $FFF9 forever without running
;;;;           into the vector bytes.  Baseline CPU/memory path.
;;;;   IRQ   — a busy loop that sets up POKEY timer 1 (AUDF1=50, 64 kHz
;;;;           clock, IRQEN=timer1, STIMER reload), enables CPU IRQs
;;;;           with CLI, then JMP-self.  The IRQ handler at $FE00 is a
;;;;           bare RTI.  Exercises the interrupt path.
;;;;   KLAUS — Klaus Dormann 6502 functional test binary loaded into
;;;;           RAM at $0000, run until the success trap at $3469.
;;;;           Skips gracefully if roms/6502_functional_test.bin is absent.
;;;;
;;;; Procedure per workload: build machine, cold reset, run 60 warm-up
;;;; frames, then time 600 frames with get-internal-real-time and print
;;;; one machine-readable line:
;;;;
;;;;   BENCH <workload> frames=<n> seconds=<s> fps=<fps> realtime-x=<fps/59.92>

(defpackage #:atari800-cl.bench
  (:use #:cl)
  (:documentation "Frame-rate benchmark harness for atari800-cl.")
  (:export #:run-benchmarks
            #:run-workload
            #:run-klaus-workload
            #:*warmup-frames*
            #:*measured-frames*
            #:*ntsc-fps*))

(in-package #:atari800-cl.bench)

;;; NTSC reference frame rate (59.92 Hz for the 6502@1.79MHz / 29868 clocks).
(defparameter *ntsc-fps* 59.92
  "Reference NTSC frame rate used to compute realtime-x.")
(defparameter *warmup-frames* 60
  "Number of warm-up frames run before the timed measurement.")
(defparameter *measured-frames* 600
  "Number of frames timed for the benchmark.")

(defparameter *klaus-functional-test-success-pc* #x3469
  "Trap address Klaus Dormann's test reaches once every check passes.")

(defun %klaus-functional-test-search-paths ()
  "Return candidate pathnames for the Klaus functional test binary."
  (let ((env (uiop:getenv "ATARI800_CL_FUNCTIONAL_TEST"))
        (system-dir (ignore-errors
                      (asdf:system-source-directory "atari800-cl"))))
    (remove nil
            (list
             (and env
                  (merge-pathnames
                   (make-pathname
                    :name "6502_functional_test"
                    :type "bin")
                   (uiop:ensure-directory-pathname env)))
             (and system-dir
                  (merge-pathnames
                   (make-pathname
                    :directory '(:relative "roms")
                    :name "6502_functional_test"
                    :type "bin")
                   system-dir))
             (merge-pathnames
              (make-pathname
               :directory '(:relative "roms")
               :name "6502_functional_test"
               :type "bin")
              (uiop:physicalize-pathname (merge-pathnames #P"./")))))))

(defun %klaus-functional-test-binary-path ()
  "Return the pathname of the Klaus functional test binary, or NIL."
  (find-if #'probe-file (%klaus-functional-test-search-paths)))

;;; ---------------------------------------------------------------------------
;;; Synthetic ROM builder
;;;
;;; Builds a 16 KiB OS ROM image ($C000-$FFFF) filled with $EA (NOP) and
;;; then patches in a program + vectors.  Addresses supplied are absolute
;;; (e.g., $C000, not 0).

(defun %poke (rom address value)
  "Write VALUE to the ROM array slot for the absolute ADDRESS ($C000-$FFFF)."
  (setf (aref rom (- address #xC000)) value))

(defun %make-rom (overrides &key reset-pc nmi-pc irq-pc)
  "Build a 16 KiB OS ROM filled with NOPs, then apply OVERRIDES (an alist
of absolute-address . byte) and set the three vectors.  Returns a
(simple-array (unsigned-byte 8) (16384))."
  (let ((rom (make-array #x4000 :element-type '(unsigned-byte 8)
                         :initial-element #xEA)))
    (dolist (cell overrides)
      (%poke rom (car cell) (cdr cell)))
    ;; Vectors: $FFFC/D reset, $FFFA/B NMI, $FFFE/F IRQ.
    (%poke rom #xFFFC (logand reset-pc #xFF))
    (%poke rom #xFFFD (logand (ash reset-pc -8) #xFF))
    (%poke rom #xFFFA (logand nmi-pc   #xFF))
    (%poke rom #xFFFB (logand (ash nmi-pc   -8) #xFF))
    (%poke rom #xFFFE (logand irq-pc   #xFF))
    (%poke rom #xFFFF (logand (ash irq-pc   -8) #xFF))
    rom))

;;; ---------------------------------------------------------------------------
;;; Workload programs
;;;
;;; 6502 opcodes used:
;;;   A9 xx      LDA #immediate
;;;   8D ll hh   STA $hhll     (absolute)
;;;   58         CLI
;;;   4C ll hh   JMP $hhll      (absolute)
;;;   40         RTI
;;;   EA         NOP

(defun make-nop-rom ()
  "NOP-sled workload ROM.  Reset at $C000; the sled runs NOPs from $C000
up to $FFF7 where a JMP $C000 loops it back.  The jump is placed below
the 6-byte vector region ($FFFA-$FFFF) so its operand bytes do not
collide with the NMI/IRQ/reset vectors.  NMI/IRQ vectors point at $FE00
(a NOP)."
  (let ((loop-target #xC000)
        (jump-addr   #xFFF7))        ; JMP occupies $FFF7-$FFF9
    (%make-rom
     (list (cons jump-addr  #x4C)                 ; JMP opcode
           (cons (1+ jump-addr) (logand loop-target #xFF))
           (cons (+ 2 jump-addr) (logand (ash loop-target -8) #xFF)))
     :reset-pc #xC000
     :nmi-pc   #xFE00
     :irq-pc   #xFE00)))

(defun make-irq-rom ()
  "Busy-loop + POKEY timer IRQ workload ROM.

Program at $C000:
    $C000  A9 32       LDA #$32         ; AUDF1 = 50
    $C002  8D 00 D2    STA $D200
    $C005  A9 00       LDA #$00         ; AUDCTL = 0 (64 kHz)
    $C007  8D 08 D2    STA $D208
    $C00A  A9 01       LDA #$01         ; IRQEN = timer1
    $C00C  8D 0E D2    STA $D20E
    $C00F  A9 00       LDA #$00         ; STIMER (reload)
    $C011  8D 09 D2    STA $D209
    $C014  58          CLI
    $C015  4C 15 C0    JMP $C015        ; busy loop

IRQ/NMI handler at $FE00:
    $FE00  40          RTI

Timer 1 period ~ 50 * 28 = 1400 cycles, so IRQs fire roughly every
~78 instructions, exercising the interrupt entry/exit path."
  (let ((loop-addr #xC015))
    (%make-rom
     (list (cons #xC000 #xA9) (cons #xC001 #x32)
           (cons #xC002 #x8D) (cons #xC003 #x00) (cons #xC004 #xD2)
           (cons #xC005 #xA9) (cons #xC006 #x00)
           (cons #xC007 #x8D) (cons #xC008 #x08) (cons #xC009 #xD2)
           (cons #xC00A #xA9) (cons #xC00B #x01)
           (cons #xC00C #x8D) (cons #xC00D #x0E) (cons #xC00E #xD2)
           (cons #xC00F #xA9) (cons #xC010 #x00)
           (cons #xC011 #x8D) (cons #xC012 #x09) (cons #xC013 #xD2)
           (cons #xC014 #x58)
           (cons #xC015 #x4C)
           (cons #xC016 (logand loop-addr #xFF))
           (cons #xC017 (logand (ash loop-addr -8) #xFF))
           (cons #xFE00 #x40))                 ; RTI
     :reset-pc #xC000
     :nmi-pc   #xFE00
     :irq-pc   #xFE00)))

;;; ---------------------------------------------------------------------------
;;; Klaus Dormann functional test workload

(defun %load-klaus-binary-into-bus (bus bytes)
  "Blit BYTES into the bus RAM starting at $0000."
  (let ((ram (atari800-cl.bus:bus-ram bus)))
    (loop for i from 0 below (min (length bytes) #x10000)
          do (setf (aref ram i) (aref bytes i)))))

(defun run-klaus-workload (&key (max-instructions 200000000))
  "Run Klaus Dormann's 6502 functional test as a benchmark workload.

Loads the binary into machine RAM at $0000, sets CPU state to the test's
entry point, then runs frames until the PC traps at the success address
($3469) or the instruction budget is exhausted.

Returns a list: (line frames).  LINE is the printed BENCH string;
FRAMES is the number of frames run.  Returns NIL if the binary is not
found (prints a SKIP line instead)."
  (let ((path (%klaus-functional-test-binary-path)))
    (cond
      ((null path)
       (format *standard-output*
               "SKIP klaus binary ~A not found (or via $ATARI800_CL_FUNCTIONAL_TEST)~%"
               "6502_functional_test.bin")
       (force-output *standard-output*)
       nil)
      (t
       (let* ((bytes (atari800-cl.compat:read-binary-file path))
              (machine (atari800-cl.machine:make-atari-machine))
              (cpu (atari800-cl.machine:atari-machine-cpu machine))
              (bus (atari800-cl.machine:atari-machine-bus machine)))
         (%load-klaus-binary-into-bus bus bytes)
         (setf (atari800-cl.cpu:cpu-pc cpu) #x0400
               (atari800-cl.cpu:cpu-sp cpu) #xFD
               (atari800-cl.cpu:cpu-flags cpu) #x24
               (atari800-cl.cpu:cpu-cycles cpu) 0)
         (let ((previous-pc -1)
               (instructions 0)
               (frames 0)
               (start (get-internal-real-time)))
           (loop
             (let ((pc (atari800-cl.cpu:cpu-pc cpu)))
               (when (= pc previous-pc)
                 (return))
               (setf previous-pc pc))
             (atari800-cl.machine:machine-run-frame machine)
             (incf frames)
             (incf instructions
                   (- (atari800-cl.cpu:cpu-cycles cpu) instructions))
             (when (>= instructions max-instructions)
               (return)))
           (let* ((end (get-internal-real-time))
                  (ticks (- end start))
                  (secs (/ (coerce ticks 'double-float)
                           (coerce internal-time-units-per-second 'double-float)))
                  (fps (/ (coerce frames 'double-float) secs))
                  (rx (/ fps *ntsc-fps*))
                  (final-pc (atari800-cl.cpu:cpu-pc cpu))
                  (status (if (= final-pc *klaus-functional-test-success-pc*)
                              "PASS"
                              (format nil "FAIL pc=$~4,'0X" final-pc)))
                  (workload-name (format nil "klaus+~A" status))
                  (line (format nil "BENCH ~A frames=~D seconds=~6,3F fps=~8,2F realtime-x=~6,3F status=~A"
                                workload-name frames secs fps rx status)))
             (write-line line)
             (force-output *standard-output*)
             (list line frames))))))))

;;; ---------------------------------------------------------------------------
;;; Workload runner

(defun run-workload (name rom)
  "Build a machine with ROM installed, cold-reset, run *warmup-frames*
warm-up frames, then time *measured-frames* frames and print a single
BENCH line to *standard-output*.  Returns the printed line as a string."
  (declare (type string name))
  (let ((machine (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset machine :os-rom rom)
    ;; Warm up: prime caches, JIT-ish inline caches, etc.
    (dotimes (i *warmup-frames*)
      (atari800-cl.machine:machine-run-frame machine))
    ;; Timed run.
    (let* ((start (get-internal-real-time))
           (frames *measured-frames*))
      (dotimes (i frames)
        (atari800-cl.machine:machine-run-frame machine))
      (let* ((end   (get-internal-real-time))
             (ticks (- end start))
             (secs  (/ (coerce ticks 'double-float)
                       (coerce internal-time-units-per-second 'double-float)))
             (fps   (/ (coerce frames 'double-float) secs))
             (rx    (/ fps *ntsc-fps*))
             (line  (format nil "BENCH ~A frames=~D seconds=~6,3F fps=~8,2F realtime-x=~6,3F"
                            name frames secs fps rx)))
        (write-line line)
        (force-output *standard-output*)
        line))))

(defun run-benchmarks (&key (workloads '(:nop :irq :klaus)))
  "Run every workload named in WORKLOADS (default :nop, :irq, :klaus)
and print one BENCH line per workload.  The :klaus workload skips
gracefully if the functional test binary is not found.
Returns a list of the printed lines (NIL entries for skipped workloads
are removed)."
  (let ((roms (list (cons :nop (make-nop-rom))
                    (cons :irq (make-irq-rom))))
        (lines '()))
    (dolist (w workloads)
      (cond
        ((eq w :klaus)
         (let ((result (run-klaus-workload)))
           (when result
             (push (first result) lines))))
        (t
         (let ((rom (cdr (assoc w roms))))
           (unless rom
             (error "unknown workload: ~A" w))
           (push (run-workload (string-downcase (string w)) rom) lines)))))
    (nreverse lines)))