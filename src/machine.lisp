;;;; src/machine.lisp --- Atari 800 XL top-level machine + frame scheduler.
;;;;
;;;; ATARI-MACHINE owns one of each chip and the bus that connects them
;;;; all to the 6502 CPU.  The cold-reset path loads ROM images and
;;;; lets the CPU fetch its first PC from the reset vector at $FFFC.
;;;;
;;;; MACHINE-RUN-FRAME pumps 29,868 NTSC color clocks (262 × 114),
;;;; ticking ANTIC and POKEY at each clock.  When ANTIC reports cycles
;;;; stolen for that clock, the CPU does NOT advance; otherwise we add
;;;; one cycle to the CPU's budget and, once the budget is large enough,
;;;; fetch and execute the next instruction.  Pending NMI/IRQ lines are
;;;; serviced at every clock before the CPU decides whether to step.

(in-package #:atari800-cl.machine)

(defconstant +clocks-per-frame+ 29868
  "262 scanlines × 114 color clocks/scanline (NTSC).")

;;; ---------------------------------------------------------------------------
;;; Command mailbox
;;;
;;; The machine is owned by a single emulator thread (see MACHINE-RUN-LOOP).
;;; Other threads — socket reader threads in the AESP/CLI servers — never
;;; touch the machine directly; they post a MACHINE-COMMAND to the mailbox
;;; and block until the emulator thread runs it and fills in the reply.  This
;;; keeps all machine mutation single-threaded without a giant lock.

(define-condition mailbox-full (error)
  ((mailbox :initarg :mailbox :reader mailbox-full-mailbox))
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "Command mailbox is full (server busy).")))
  (:documentation "Signalled by MACHINE-SUBMIT when the mailbox is over its
soft cap; callers map this to a 'server busy' protocol reply."))

(defstruct (machine-command (:constructor %make-machine-command))
  "One unit of work posted to a machine's mailbox.

THUNK is called on the emulator thread with the machine as its only
argument.  Its value lands in RESULT (or a signalled error in ERROR); DONE
is then set and CV notified so the submitting thread can collect the reply.
PRIORITY marks pause/resume/reset/quit so they can be expedited."
  (thunk    nil :type (or null function))
  (priority nil)
  (result   nil)
  (error    nil)
  (done     nil)
  (lock     (make-lock "machine-command"))
  (cv       (make-condition-variable "machine-command")))

(defstruct (command-mailbox (:constructor make-command-mailbox))
  "FIFO of pending MACHINE-COMMANDs guarded by LOCK; CV wakes a parked
emulator thread when work arrives.  QUEUE is kept newest-first and reversed
on drain.  SOFT-CAP bounds the backlog so a flood of commands replies
'busy' instead of growing without limit."
  (lock     (make-lock "command-mailbox"))
  (cv       (make-condition-variable "command-mailbox"))
  (queue    '())
  (count    0    :type fixnum)
  (soft-cap 1024 :type fixnum))

(defstruct (atari-machine
            (:constructor %make-atari-machine))
  "Atari 800 XL machine.

Slots:
  CPU         — the 6502 core.
  BUS         — system bus owning RAM, ROM images, and chip dispatch.
  MMU         — bank-switching unit (PORTB shadow).
  PIA         — 6520 PIA (input + PORTB output).
  ANTIC       — display-list / DMA engine.
  GTIA        — player/missile / collision latches.
  POKEY       — timers, IRQ, RNG, audio scaffolding.
  FRAME-COUNT — frames elapsed since the machine was constructed.
  RUNNING-P   — when true, MACHINE-RUN-LOOP free-runs frames; when false it
                parks on the mailbox condvar (paused).
  MAILBOX     — COMMAND-MAILBOX other threads post work to.
  INPUT       — optional host INPUT-STATE wired into PIA/GTIA/POKEY.
  PRIORITY-PENDING-FLAG — hint set when a high-priority command is queued."
  (cpu nil)
  (bus nil)
  (mmu nil)
  (pia nil)
  (antic nil)
  (gtia nil)
  (pokey nil)
  (frame-count 0 :type fixnum)
  (running-p nil)
  (mailbox (make-command-mailbox))
  (input nil)
  (priority-pending-flag nil))

;;; ---------------------------------------------------------------------------
;;; Construction

(defun make-atari-machine ()
  "Construct and wire a complete Atari 800 XL machine.

Each chip is built, the bus gets its MMU and all four chip-attach
closures installed, and the CPU's bus-read/bus-write hooks are pointed
at the bus.  The result is a machine that is ready for MACHINE-COLD-RESET."
  (let* ((cpu   (make-cpu))
         (mmu   (make-mmu))
         (bus   (make-bus :mmu mmu))
         (pia   (make-pia))
         (antic (make-antic))
         (gtia  (make-gtia))
         (pokey (make-pokey))
         (machine (%make-atari-machine :cpu cpu :bus bus :mmu mmu
                                        :pia pia :antic antic
                                        :gtia gtia :pokey pokey)))
    ;; Wire chip dispatch into the bus.
    (attach-pia   bus pia mmu)
    (attach-antic bus antic cpu)
    (attach-gtia  bus gtia)
    (attach-pokey bus pokey cpu)
    ;; Wire the CPU to the bus.
    (setf (cpu-bus-read  cpu) (lambda (addr) (bus-read  bus addr))
          (cpu-bus-write cpu) (lambda (addr val) (bus-write bus addr val)))
    machine))

;;; ---------------------------------------------------------------------------
;;; ROM loading + cold reset

(defun load-rom-file (path)
  "Read PATH from disk and return its bytes as a (simple-array u8 (*))."
  (read-binary-file path))

(defun machine-install-roms (machine &key os-rom basic-rom)
  "Install ROM byte sequences (OS-ROM / BASIC-ROM) into the machine's bus
without performing a reset.  Either argument may be NIL to leave the
corresponding slot unchanged.  Returns MACHINE."
  (let ((bus (atari-machine-bus machine)))
    (when os-rom    (install-os-rom    bus os-rom))
    (when basic-rom (install-basic-rom bus basic-rom)))
  machine)

(defun machine-cold-reset (machine &key os-rom basic-rom os-path basic-path)
  "Perform a cold reset.  Loads supplied ROM images (either as raw byte
sequences via OS-ROM / BASIC-ROM, or by reading the files at OS-PATH /
BASIC-PATH), sets PORTB to $FF (OS ROM mapped, BASIC + self-test off),
initialises CPU registers (P = $34, SP = $FF), and reads the reset
vector at $FFFC to set the initial PC.  Returns MACHINE."
  (let ((cpu (atari-machine-cpu machine))
        (bus (atari-machine-bus machine))
        (mmu (atari-machine-mmu machine)))
    (cond (os-rom    (install-os-rom bus os-rom))
          (os-path   (install-os-rom bus (load-rom-file os-path))))
    (cond (basic-rom (install-basic-rom bus basic-rom))
          (basic-path (install-basic-rom bus (load-rom-file basic-path))))
    (mmu-write-portb mmu #xFF)
    (setf (cpu-sp cpu)        #xFF
          (cpu-flags cpu)     #x34            ; U=1, I=1, B=1
          (cpu-a cpu)         0
          (cpu-x cpu)         0
          (cpu-y cpu)         0
          (cpu-cycles cpu)    0
          (cpu-pending-irq cpu) nil
          (cpu-pending-nmi cpu) nil
          (cpu-halted cpu)    nil
          (cpu-pc cpu) (bus-read16 bus #xFFFC)))
  machine)

;;; ---------------------------------------------------------------------------
;;; Frame scheduler

;;; ---------------------------------------------------------------------------
;;; Debug / instrumentation helpers (Prompt 11)
;;;
;;; These are the entry points the README's "Running toward BASIC" section
;;; recommends for poking at a running machine from the REPL.

(defun machine-trace-step (machine n)
  "Step the CPU N times, returning a list of N snapshots in execution order.
Each snapshot is a plist:
  (:pc <u16> :opcode <u8> :mnemonic <string-or-nil>
   :a <u8> :x <u8> :y <u8> :p <u8> :sp <u8> :cycles <fixnum>)

If the CPU halts (illegal opcode → CPU-HALTED set to T), tracing stops
early and the partial list is returned.  No ANTIC/POKEY pumping happens
here — use MACHINE-RUN-FRAME for full-system stepping."
  (declare (type atari-machine machine) (type fixnum n))
  (let* ((cpu (atari-machine-cpu machine))
         (bus (atari-machine-bus machine))
         (snapshots '()))
    (dotimes (i n)
      (declare (ignore i))
      (when (cpu-halted cpu) (return))
      (let* ((pc      (cpu-pc cpu))
             (opcode  (bus-read bus pc))
             (mnem    (svref *opcode-mnemonic-table* opcode)))
        (push (list :pc pc :opcode opcode :mnemonic mnem
                    :a (cpu-a cpu) :x (cpu-x cpu) :y (cpu-y cpu)
                    :p (cpu-flags cpu) :sp (cpu-sp cpu)
                    :cycles (cpu-cycles cpu))
              snapshots))
      (handler-case (step-cpu cpu)
        (illegal-opcode ()
          (setf (cpu-halted cpu) t)
          (return))))
    (nreverse snapshots)))

(defun machine-portb-state (machine)
  "Return a plist describing the current PORTB / bank-switching state.
Keys: :PORTB :OS-ROM-MAPPED :BASIC-ROM-MAPPED :SELFTEST-MAPPED."
  (declare (type atari-machine machine))
  (portb-decode (atari-machine-mmu machine)))

(defun machine-scanline (machine)
  "Return the current ANTIC scanline counter (0..261)."
  (declare (type atari-machine machine))
  (antic-scanline (atari-machine-antic machine)))

(defun machine-pending-interrupts (machine)
  "Return a plist with the current interrupt-line state:
  :IRQ-PENDING <boolean>
  :NMI-PENDING <boolean>
  :I-FLAG-MASKED <boolean> (T when IRQs are masked by the CPU's I flag)"
  (declare (type atari-machine machine))
  (let ((cpu (atari-machine-cpu machine)))
    (list :irq-pending  (cpu-pending-irq cpu)
          :nmi-pending  (cpu-pending-nmi cpu)
          :i-flag-masked (flag-set? cpu +flag-i+))))

;;; ---------------------------------------------------------------------------
;;; Frame scheduler

(defun %run-clocks (machine n &key abort-pred)
  "Run N NTSC color clocks on MACHINE, pumping ANTIC + POKEY in lockstep with
the CPU and servicing NMI/IRQ each clock.  Returns the number of clocks
actually run.

If ABORT-PRED is supplied it is funcalled once per scanline (every 114
clocks); a true result stops early and returns the clocks run so far.  The
default run loop does NOT pass ABORT-PRED — pause/resume/reset are handled
at frame boundaries (Decision 1: frame-granularity) — but the hook is here
for a future scanline-granular abort.  CPU-BUDGET is intentionally local: an
aborted partial run is discarded, not resumed, so no budget needs to carry
across calls."
  (declare (type atari-machine machine) (type fixnum n))
  (let* ((cpu   (atari-machine-cpu   machine))
         (bus   (atari-machine-bus   machine))
         (antic (atari-machine-antic machine))
         (pokey (atari-machine-pokey machine))
         (cpu-budget 0))
    (declare (type fixnum cpu-budget))
    (dotimes (clock n)
      (declare (type fixnum clock))
      ;; Frame-granular abort check (only when a predicate was supplied).
      (when (and abort-pred
                 (zerop (mod clock 114))
                 (plusp clock)
                 (funcall abort-pred))
        (return-from %run-clocks clock))
      (let ((stolen (antic-tick antic cpu bus)))
        (declare (type fixnum stolen))
        (pokey-tick pokey cpu)
        ;; A clock that ANTIC did NOT steal contributes one cycle of
        ;; CPU budget; stolen clocks consume the cycle silently.
        (when (zerop stolen)
          (incf cpu-budget))
        ;; Service interrupts before each candidate instruction.
        (check-and-dispatch-nmi cpu)
        (check-and-dispatch-irq cpu)
        ;; If we have budget for at least the minimum instruction (2 cycles
        ;; on the 6502) and the CPU isn't halted, step it once.
        (when (and (>= cpu-budget 2) (not (cpu-halted cpu)))
          (handler-case
              (let ((used (step-cpu cpu)))
                (declare (type fixnum used))
                (decf cpu-budget used))
            ;; A KIL instruction signals ILLEGAL-OPCODE; leave the CPU
            ;; halted and stop trying to step.
            (illegal-opcode ()
              (setf (cpu-halted cpu) t))))))
    n))

(defun machine-run-frame (machine)
  "Run one NTSC frame: 29,868 color clocks.  Pumps ANTIC + POKEY in
lockstep with the CPU, services NMI/IRQ each clock, and increments
FRAME-COUNT before returning MACHINE."
  (%run-clocks machine +clocks-per-frame+)
  (incf (atari-machine-frame-count machine))
  machine)

;;; ---------------------------------------------------------------------------
;;; Command mailbox plumbing + run loop

(defun %run-command (machine cmd)
  "Run CMD's thunk on the current (emulator) thread, capture its value or
error, then mark it done and wake the submitter."
  (handler-case
      (setf (machine-command-result cmd)
            (funcall (machine-command-thunk cmd) machine))
    (error (e)
      (setf (machine-command-error cmd) e)))
  (with-lock ((machine-command-lock cmd))
    (setf (machine-command-done cmd) t)
    (condition-notify (machine-command-cv cmd))))

(defun mailbox-enqueue (mailbox cmd)
  "Append CMD to MAILBOX.  Returns :OK, or :BUSY when the backlog is at the
soft cap (the caller should reply 'server busy' rather than block)."
  (with-lock ((command-mailbox-lock mailbox))
    (cond
      ((>= (command-mailbox-count mailbox) (command-mailbox-soft-cap mailbox))
       :busy)
      (t (push cmd (command-mailbox-queue mailbox))
         (incf (command-mailbox-count mailbox))
         (condition-notify (command-mailbox-cv mailbox))
         :ok))))

(defun mailbox-drain (mailbox machine)
  "Run every currently-queued command on the current (emulator) thread, in
FIFO order.  Returns the number of commands run."
  (let ((cmds (with-lock ((command-mailbox-lock mailbox))
                (prog1 (nreverse (command-mailbox-queue mailbox))
                  (setf (command-mailbox-queue mailbox) '()
                        (command-mailbox-count mailbox) 0)))))
    (dolist (cmd cmds)
      (%run-command machine cmd))
    (length cmds)))

(defun mailbox-wait (mailbox &key (timeout 0.05))
  "Block until a command is queued in MAILBOX or TIMEOUT seconds elapse."
  (with-lock ((command-mailbox-lock mailbox))
    (when (null (command-mailbox-queue mailbox))
      (condition-wait (command-mailbox-cv mailbox)
                      (command-mailbox-lock mailbox)
                      :timeout timeout))))

(defun machine-submit (machine thunk &key priority)
  "Post THUNK to MACHINE's mailbox and block until the emulator thread runs
it; return THUNK's value, or re-signal the error it raised.  THUNK is called
with MACHINE as its only argument.  Signals MAILBOX-FULL if the mailbox is
over its soft cap.  This is the only safe way for a non-emulator thread to
touch the machine."
  (declare (type atari-machine machine) (type function thunk))
  (let ((mailbox (atari-machine-mailbox machine))
        (cmd     (%make-machine-command :thunk thunk :priority priority)))
    (ecase (mailbox-enqueue mailbox cmd)
      (:busy (error 'mailbox-full :mailbox mailbox))
      (:ok
       (when priority
         (setf (atari-machine-priority-pending-flag machine) t))
       ;; Block until the emulator thread has run our command.
       (with-lock ((machine-command-lock cmd))
         (loop until (machine-command-done cmd)
               do (condition-wait (machine-command-cv cmd)
                                  (machine-command-lock cmd))))
       (when (machine-command-error cmd)
         (error (machine-command-error cmd)))
       (machine-command-result cmd)))))

(defun machine-run-loop (machine &key stop-flag)
  "Own MACHINE on the current thread until STOP-FLAG (a thunk returning a
generalized boolean) is true.  Each iteration drains the command mailbox,
then: if RUNNING-P, runs one full frame; otherwise parks on the mailbox
condvar (paused) until a command arrives or a short timeout elapses so
STOP-FLAG is re-checked.  Returns MACHINE."
  (declare (type atari-machine machine))
  (let ((mailbox (atari-machine-mailbox machine)))
    (loop
      (when (and stop-flag (funcall stop-flag)) (return))
      (mailbox-drain mailbox machine)
      (setf (atari-machine-priority-pending-flag machine) nil)
      (if (atari-machine-running-p machine)
          (machine-run-frame machine)
          (mailbox-wait mailbox)))
    machine))

;;; ---------------------------------------------------------------------------
;;; Host input

(defun attach-input (machine input)
  "Wire host INPUT-STATE into MACHINE's PIA, GTIA, and POKEY so their input
registers reflect live input.  Pass NIL to detach.  Returns MACHINE."
  (declare (type atari-machine machine))
  (setf (atari-machine-input machine) input)
  (attach-pia-input   (atari-machine-pia   machine) input)
  (attach-gtia-input  (atari-machine-gtia  machine) input)
  (attach-pokey-input (atari-machine-pokey machine) input)
  machine)
