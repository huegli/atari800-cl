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
;;;; Seven workloads:
;;;;   NOP     — a NOP sled that loops back via a JMP at $FFF9, so the PC
;;;;             marches NOPs from $C000 to $FFF9 forever without running
;;;;             into the vector bytes.  Baseline CPU/memory path.
;;;;   IRQ     — a busy loop that sets up POKEY timer 1 (AUDF1=50, 64 kHz
;;;;             clock, IRQEN=timer1, STIMER reload), enables CPU IRQs
;;;;             with CLI, then JMP-self.  The IRQ handler at $FE00 is a
;;;;             bare RTI.  Exercises the interrupt path.
;;;;   DISPLAY — the NOP sled with a 24-line mode-2 display list fetched
;;;;             by ANTIC (DMACTL $22) and the pixel renderer attached
;;;;             via the machine's scanline callback, exactly as the
;;;;             AESP server wires it.  Exercises the DMA-active steal
;;;;             accounting plus per-line rendering — the path real
;;;;             display programs (and A/V capture) actually run.
;;;;   AUDIO   — the NOP sled with POKEY audio synthesis attached and all
;;;;             four channels voiced (two on the 1.79 MHz clock, so
;;;;             underflows — and therefore flip-flop clocking — are
;;;;             frequent), draining once per frame as an AESP audio
;;;;             client would.  The other workloads all run with audio
;;;;             DETACHED, so the pair of rows shows both that the
;;;;             no-audio path stays free and what synthesis costs.
;;;;   IDLE    — a single JMP-to-self at reset (no NOP sled -- the PC
;;;;             just re-fetches the same three bytes forever) with the
;;;;             DISPLAY workload's static 24-line mode-2 screen and
;;;;             renderer attached, PLUS ROADMAP.md Phase 29c's row-0
;;;;             dirty-frame render-skip decision consulted every frame
;;;;             (:CONSULT-RENDER-SKIP T) -- unlike DISPLAY, which always
;;;;             renders.  The canonical parked-machine load: spin loop +
;;;;             unchanging screen, e.g. a real OS sitting at the BASIC
;;;;             READY prompt, so this is the workload Phase 29's skip is
;;;;             meant to speed up.
;;;;   SERVE   — the IDLE machine plus a real AESP server with one
;;;;             connected video client draining FRAME_RAW on a
;;;;             background thread, exercising the actual push path
;;;;             (render -> BGRA convert -> TCP write) an idle served
;;;;             session still pays for every frame.  Skips gracefully
;;;;             (like KLAUS) if a loopback TCP listener cannot be bound
;;;;             in this sandbox.
;;;;   KLAUS   — Klaus Dormann 6502 functional test binary loaded into
;;;;             RAM at $0000, run until the success trap at $3469.
;;;;             Skips gracefully if roms/6502_functional_test.bin is absent.
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
            #:run-serve-workload
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

(defun make-idle-rom ()
  "Idle/parked-machine workload ROM.  Reset at $C000 is a single
JMP $C000 (opcode $4C targeting its own address): the PC re-fetches the
same three bytes forever, touching no other memory -- the canonical
parked-machine CPU load, e.g. a real OS sitting at the BASIC READY
prompt.  NMI/IRQ vectors point at $FE00, a bare RTI stub; nothing in
this workload enables interrupts, so the stub is never actually
reached, but a vector pointing at real RTI code (rather than relying on
the ROM's NOP fill) is what a parked machine's reset/interrupt table
looks like."
  (%make-rom
   (list (cons #xC000 #x4C)
         (cons #xC001 (logand #xC000 #xFF))
         (cons #xC002 (logand (ash #xC000 -8) #xFF))
         (cons #xFE00 #x40))                 ; RTI
   :reset-pc #xC000
   :nmi-pc   #xFE00
   :irq-pc   #xFE00))

;;; ---------------------------------------------------------------------------
;;; Display workload setup
;;;
;;; Runs on the NOP-sled ROM; the interesting work is ANTIC fetching a
;;; real display list (with playfield + DL-fetch cycle steals charged)
;;; and the renderer producing pixels for all 192 playfield scanlines
;;; of every frame.

(defun %setup-display-workload (machine &key consult-render-skip)
  "Poke a 24-line mode-2 display list + screen data into MACHINE's RAM,
enable playfield DMA, and attach the pixel renderer through the
machine's scanline callback (the same wiring src/aesp.lisp uses).
Called by RUN-WORKLOAD after cold reset, before the warm-up frames.

CONSULT-RENDER-SKIP, when true, makes the scanline closure apply
ROADMAP.md Phase 29c's row-0 decision protocol -- the same one
src/aesp.lisp's START-AESP-SERVER wires in: at row 0 of every frame, ask
ATARI800-CL.MACHINE:MACHINE-DISPLAY-CHANGED-SINCE-RENDER-P and either
call ATARI800-CL.MACHINE:MACHINE-NOTE-FULL-RENDER and render every row
0-239, or skip every row this frame and bump ATARI-MACHINE-RENDER-SKIP-
COUNT once.  The :IDLE workload passes T: a deployed idle machine (spin
loop + unchanging screen) is exactly the render client Phase 29 targets,
so its benchmark row should show the skip's payoff.  The :DISPLAY
workload leaves this NIL (the default) and always renders every row:
:DISPLAY exists specifically to measure the renderer's own per-scanline
cost, and consulting the skip there would silently turn it into a
second, redundant copy of :IDLE instead of a renderer benchmark."
  (let ((bus  (atari800-cl.machine:atari-machine-bus  machine))
        (gtia (atari800-cl.machine:atari-machine-gtia machine))
        (fb   (atari800-cl.renderer:make-framebuffer))
        (render-this-frame t))
    ;; DL at $4000: mode 2 + LMS -> $5000, 23 plain mode-2 lines, JVB $4000.
    (atari800-cl.bus:bus-poke-ram bus #x4000 #x42)
    (atari800-cl.bus:bus-poke-ram bus #x4001 #x00)
    (atari800-cl.bus:bus-poke-ram bus #x4002 #x50)
    (loop for i from 0 below 23
          do (atari800-cl.bus:bus-poke-ram bus (+ #x4003 i) #x02))
    (atari800-cl.bus:bus-poke-ram bus #x401A #x41)
    (atari800-cl.bus:bus-poke-ram bus #x401B #x00)
    (atari800-cl.bus:bus-poke-ram bus #x401C #x40)
    ;; Screen RAM: 24 rows x 40 chars of char code 1; glyphs at $6000
    ;; with char 1 a solid block, so every playfield pixel is written.
    (dotimes (i (* 24 40))
      (atari800-cl.bus:bus-poke-ram bus (+ #x5000 i) #x01))
    (dotimes (r 8)
      (atari800-cl.bus:bus-poke-ram bus (+ #x6008 r) #xFF))
    (atari800-cl.bus:bus-write bus #xD409 #x60)      ; CHBASE
    (atari800-cl.bus:bus-write bus #xD018 #x68)      ; COLPF2
    (atari800-cl.bus:bus-write bus #xD402 #x00)      ; DLISTL
    (atari800-cl.bus:bus-write bus #xD403 #x40)      ; DLISTH
    (atari800-cl.bus:bus-write bus #xD400 #x22)      ; DMACTL
    (setf (atari800-cl.machine:atari-machine-scanline-fn machine)
          (lambda (m)
            (let* ((a   (atari800-cl.machine:atari-machine-antic m))
                   (sl  (mod (1- (atari800-cl.antic:antic-scanline a))
                             atari800-cl.antic:+scanlines-per-frame+))
                   (row (- sl atari800-cl.antic:+active-start-scanline+)))
              (when (and (>= row 0) (< row 240))
                (if consult-render-skip
                    (progn
                      (when (zerop row)
                        (setf render-this-frame
                              (atari800-cl.machine:machine-display-changed-since-render-p m))
                        (if render-this-frame
                            (atari800-cl.machine:machine-note-full-render m)
                            (incf (atari800-cl.machine:atari-machine-render-skip-count m))))
                      (when render-this-frame
                        (atari800-cl.renderer:render-scanline
                         fb row a gtia (atari800-cl.machine:atari-machine-bus m))))
                    (atari800-cl.renderer:render-scanline
                     fb row a gtia (atari800-cl.machine:atari-machine-bus m)))))))))

;;; ---------------------------------------------------------------------------
;;; Audio workload setup
;;;
;;; Measures the synthesis path: an attached audio unit, all four
;;; channels voiced with different distortions, two of them on the
;;; 1.79 MHz clock so their flip-flops are clocked every few cycles.
;;; Every other workload runs with audio detached, which is what makes
;;; the detached/attached row pair meaningful.

(defun %setup-audio-workload (machine)
  "Attach an audio unit to MACHINE, voice all four POKEY channels, and
drain once per frame (as an AESP audio client will in Phase 10)."
  (let ((bus (atari800-cl.machine:atari-machine-bus machine)))
    (atari800-cl.machine:machine-attach-audio machine)
    ;; AUDCTL: channels 1 and 3 on the 1.79 MHz clock.
    (atari800-cl.bus:bus-write bus #xD208 #x60)
    ;; Four channels, four distortions, all at full volume.
    (atari800-cl.bus:bus-write bus #xD200 60)   ; AUDF1
    (atari800-cl.bus:bus-write bus #xD201 #xAF) ; AUDC1: pure tone
    (atari800-cl.bus:bus-write bus #xD202 80)   ; AUDF2
    (atari800-cl.bus:bus-write bus #xD203 #x8F) ; AUDC2: poly17 noise
    (atari800-cl.bus:bus-write bus #xD204 100)  ; AUDF3
    (atari800-cl.bus:bus-write bus #xD205 #xCF) ; AUDC3: poly4
    (atari800-cl.bus:bus-write bus #xD206 120)  ; AUDF4
    (atari800-cl.bus:bus-write bus #xD207 #x2F) ; AUDC4: poly5-gated tone
    (atari800-cl.bus:bus-write bus #xD209 0)    ; STIMER
    ;; Drain per frame so the buffer never grows past one frame's worth.
    (setf (atari800-cl.machine:atari-machine-post-frame-fn machine)
          (lambda (m) (atari800-cl.machine:machine-audio-drain m)))))

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
               ;; A repeated PC at two consecutive frame boundaries is
               ;; only a HINT of a trap: the scanline scheduler grants a
               ;; deterministic cycle count per frame, and when that
               ;; count is a multiple of a long-running test loop's
               ;; period, the boundary PC aliases while the program is
               ;; still progressing.  Confirm at instruction
               ;; granularity: a real trap (the success JMP $3469 or a
               ;; failure JMP-*/branch-to-self) returns to the same PC
               ;; after ONE instruction.  The confirmation step advances
               ;; the CPU without ANTIC/POKEY, which is harmless for a
               ;; benchmark — and on a false alarm it also breaks the
               ;; resonance that caused it.
               (when (= pc previous-pc)
                 (atari800-cl.cpu:step-cpu cpu)
                 (when (= pc (atari800-cl.cpu:cpu-pc cpu))
                   (return)))
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
;;; Serve workload
;;;
;;; Same idle-machine setup as :idle, plus the real AESP push path: a
;;; running AESP server, one connected video client draining FRAME_RAW
;;; messages on a background thread, and MACHINE-RUN-FRAME timed with
;;; the post-frame render/convert/send active.  Measures the layer-3/4
;;; idle waste ROADMAP.md's Phase 27-31 tranche targets: unconditional
;;; per-scanline rendering and per-frame BGRA conversion/send even
;;; though the screen and client never change.

(defun %drain-video-client (stream stop-cell)
  "Loop reading and discarding AESP messages from STREAM until (CAR
STOP-CELL) is true or the read errors.  RUN-SERVE-WORKLOAD's teardown
closes the socket out from under this loop (from the caller's thread)
to unblock a pending read, so an error here is an expected exit, not a
failure -- it is swallowed silently."
  (handler-case
      (loop until (car stop-cell)
            do (atari800-cl.aesp:read-aesp-message stream))
    (error () nil)))

(defun run-serve-workload ()
  "Run the :serve workload: build a machine on MAKE-IDLE-ROM with
%SETUP-DISPLAY-WORKLOAD applied (the same static 24-line mode-2 screen
:idle uses), start a real AESP server on 127.0.0.1 with all three ports
OS-assigned, connect one video client through the project's own TCP
transport (atari800-cl.transport, the layer tests/test-aesp.lisp uses),
and drain it on a background thread while timing *measured-frames*
worth of MACHINE-RUN-FRAME with the post-frame FRAME_RAW/AUDIO_PCM push
active (START-AESP-SERVER wires its own scanline-fn/post-frame-fn over
%SETUP-DISPLAY-WORKLOAD's, exactly as it does for a real served
machine).  Prints and returns a BENCH line like RUN-WORKLOAD.

Sandboxed command environments can deny loopback TCP listener creation
(TCP-LISTEN signals an error, typically EPERM) -- the same caveat the
run-tests skill documents for the live AESP server tests.  When that
happens this workload prints a SKIP line and returns NIL, exactly as
RUN-KLAUS-WORKLOAD does when its binary is missing."
  (let ((machine (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset machine :os-rom (make-idle-rom))
    (%setup-display-workload machine)
    (let ((server
            (handler-case
                (atari800-cl.aesp:start-aesp-server
                 machine :host "127.0.0.1"
                         :control-port 0 :video-port 0 :audio-port 0)
              (error (e)
                (format *standard-output*
                        "SKIP serve AESP listener unavailable: ~A~%" e)
                (force-output *standard-output*)
                nil))))
      (when (null server)
        (return-from run-serve-workload nil))
      (let* ((conn (atari800-cl.transport:tcp-connect
                    "127.0.0.1"
                    (atari800-cl.aesp:aesp-server-video-port server)))
             (stream (atari800-cl.transport:tcp-stream conn))
             (stop-cell (list nil))
             (drain-thread (atari800-cl.compat:make-thread
                            (lambda () (%drain-video-client stream stop-cell))
                            :name "bench-serve-video-drain")))
        (unwind-protect
             (progn
               (dotimes (i *warmup-frames*)
                 (atari800-cl.machine:machine-run-frame machine))
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
                        (line  (format nil "BENCH serve frames=~D seconds=~6,3F fps=~8,2F realtime-x=~6,3F"
                                       frames secs fps rx)))
                   (write-line line)
                   (force-output *standard-output*)
                   line)))
          ;; Teardown, in order: stop the drain thread (flag + close its
          ;; socket to unblock the read, then wait it out with the same
          ;; timeout/DESTROY-THREAD fallback STOP-AESP-SERVER uses for its
          ;; own reader threads), close the client, STOP-AESP-SERVER.
          (setf (car stop-cell) t)
          (ignore-errors (atari800-cl.transport:tcp-close conn))
          (let ((deadline (+ (get-internal-real-time)
                             (truncate (* 2.0 internal-time-units-per-second)))))
            (loop while (and (atari800-cl.compat:thread-alive-p drain-thread)
                             (< (get-internal-real-time) deadline))
                  do (sleep 0.005))
            (when (atari800-cl.compat:thread-alive-p drain-thread)
              (atari800-cl.compat:destroy-thread drain-thread)))
          (atari800-cl.aesp:stop-aesp-server server))))))

;;; ---------------------------------------------------------------------------
;;; Workload runner

(defun run-workload (name rom &key setup-fn)
  "Build a machine with ROM installed, cold-reset, run *warmup-frames*
warm-up frames, then time *measured-frames* frames and print a single
BENCH line to *standard-output*.  When SETUP-FN is supplied it is called
with the machine after cold reset and before warm-up (the :display
workload uses it to poke its display list and attach the renderer).
Returns the printed line as a string."
  (declare (type string name))
  (let ((machine (atari800-cl.machine:make-atari-machine)))
    (atari800-cl.machine:machine-cold-reset machine :os-rom rom)
    (when setup-fn (funcall setup-fn machine))
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

(defun run-benchmarks (&key (workloads '(:nop :irq :display :audio :idle :serve :klaus)))
  "Run every workload named in WORKLOADS (default :nop, :irq, :display,
:audio, :idle, :serve, :klaus) and print one BENCH line per workload.
The :idle workload is a JMP-self spin loop with the :display workload's
static screen attached (the canonical parked-machine load); :serve adds
a real AESP server with one drained video client on top of :idle.  The
:serve and :klaus workloads skip gracefully -- :serve when a loopback
TCP listener cannot be bound in this sandbox, :klaus when the
functional test binary is not found.  Returns a list of the printed
lines (NIL entries for skipped workloads are removed)."
  (let ((roms (list (cons :nop (make-nop-rom))
                    (cons :irq (make-irq-rom))))
        (lines '()))
    (dolist (w workloads)
      (cond
        ((eq w :klaus)
         (let ((result (run-klaus-workload)))
           (when result
             (push (first result) lines))))
        ((eq w :display)
         (push (run-workload "display" (make-nop-rom)
                             :setup-fn #'%setup-display-workload)
               lines))
        ((eq w :audio)
         (push (run-workload "audio" (make-nop-rom)
                             :setup-fn #'%setup-audio-workload)
               lines))
        ((eq w :idle)
         (push (run-workload "idle" (make-idle-rom)
                             :setup-fn (lambda (m)
                                         (%setup-display-workload
                                          m :consult-render-skip t)))
               lines))
        ((eq w :serve)
         (let ((result (run-serve-workload)))
           (when result
             (push result lines))))
        (t
         (let ((rom (cdr (assoc w roms))))
           (unless rom
             (error "unknown workload: ~A" w))
           (push (run-workload (string-downcase (string w)) rom) lines)))))
    (nreverse lines)))