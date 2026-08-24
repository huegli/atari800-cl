;;;; src/machine.lisp --- Atari 800 XL top-level machine + frame scheduler.
;;;;
;;;; ATARI-MACHINE owns one of each chip and the bus that connects them
;;;; all to the 6502 CPU.  The cold-reset path loads ROM images and
;;;; lets the CPU fetch its first PC from the reset vector at $FFFC.
;;;;
;;;; MACHINE-RUN-FRAME runs one NTSC frame (29,868 clocks = 262 scanlines
;;;; of 114 CPU cycles) one SCANLINE at a time: ANTIC-BEGIN-SCANLINE
;;;; performs the line's events (VBI/DLI, display-list fetch) and reports
;;;; the cycles ANTIC steals; the rest of the line becomes CPU budget;
;;;; the CPU executes whole instructions against that budget with POKEY
;;;; advanced instruction-by-instruction alongside; ANTIC-END-SCANLINE
;;;; closes the line.  Pending NMI/IRQ lines are serviced inside STEP-CPU
;;;; before each instruction fetch, so the 7-cycle interrupt-entry
;;;; sequence is charged against the CPU budget exactly like an
;;;; instruction.

(in-package #:atari800-cl.machine)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  See the
;;; matching declaim in src/bus.lisp for the note on DECLAIM's proclaiming
;;; behaviour under :serial t; repeated here so this file's policy survives
;;; interactive recompilation on its own.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

(defconstant +clocks-per-frame+ 29868
  "262 scanlines × 114 CPU cycles/scanline (NTSC).  A real NTSC line is
228 color clocks at twice the CPU rate; this project's timing unit is
CPU cycles throughout, matching hardware-reference cycle numbers.")

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
  HOSTDEV     — host disk bridge (ROADMAP.md Phase 16, revised) at $D1xx;
                always present, so MOUNT-DISK et al. work on any machine,
                but inert (open-bus $D1xx) until a disk is mounted into it.
  FRAME-COUNT — frames elapsed since the machine was constructed.
  RUNNING-P   — when true, MACHINE-RUN-LOOP free-runs frames; when false it
                parks on the mailbox condvar (paused).
  MAILBOX     — COMMAND-MAILBOX other threads post work to.
  INPUT       — optional host INPUT-STATE wired into PIA/GTIA/POKEY.
  PRIORITY-PENDING-FLAG — hint set when a high-priority command is queued.
  SCANLINE-FN  — if non-nil, called as (funcall scanline-fn machine) after
                 each completed active scanline (NTSC scanlines 8-247).
                 Typically set by the AESP server to render into its framebuffer.
  POST-FRAME-FN — if non-nil, called as (funcall post-frame-fn machine) at
                  the end of MACHINE-RUN-FRAME (after frame-count increment).
                  Typically set by the AESP server to push the completed frame.
  POKEY-LAG    — ROADMAP.md Phase 30 (deferred POKEY advance): CPU cycles
                 POKEY is behind the CPU within the current scanline,
                 accumulated by %RUN-CLOCKS' deferring instruction loop
                 instead of being delivered immediately.  Zeroed by
                 %MACHINE-SYNC-POKEY, which the wrapped $D2xx bus closures
                 (installed in MAKE-ATARI-MACHINE) call before every
                 access so a register read or write always sees exact,
                 caught-up state.
  POKEY-DEFER-DISABLED-P — when true, %RUN-CLOCKS never defers, regardless
                 of what POKEY-DEFERRABLE-P would say; the debug/test
                 escape hatch for the machine-level equivalence tests.
  POKEY-DEFER-ENGAGEMENTS — count of scanlines on which the deferring
                 instruction loop ran (ROADMAP.md Phase 30c); test-only
                 instrumentation, not consulted by the scheduler itself.
  POKEY-DEFER-BREAK-P — set by the wrapped $D2xx WRITE closure to signal
                 that a mid-line write may have invalidated the deferral
                 gate (enabled a timer IRQ, attached audio, started a
                 serial transmission); %RUN-CLOCKS falls back to the
                 non-deferring per-instruction path for the rest of the
                 line when it sees this set, and clears it at the start
                 of each new line.
  WATCHED-PAGES — ROADMAP.md Phase 29 (dirty-frame render skip): a
                 preallocated 256-entry (SIMPLE-ARRAY (UNSIGNED-BYTE 8)
                 (256)) scratch buffer MACHINE-DISPLAY-CHANGED-SINCE-
                 RENDER-P passes to ANTIC-COLLECT-WATCHED-PAGES so that
                 function never has to allocate one itself. Single-
                 renderer-consumer semantics: this scratch buffer, and
                 the decision built on top of it, assume at most ONE
                 render client calls MACHINE-DISPLAY-CHANGED-SINCE-
                 RENDER-P / MACHINE-NOTE-FULL-RENDER on a given machine.
                 Two independent render clients sharing one machine
                 would race this buffer and would each clear the OTHER's
                 view of the bus dirty map via MACHINE-NOTE-FULL-RENDER
                 -- not supported, and nothing in this codebase attaches
                 more than one.
  RENDER-SKIP-COUNT — fixnum count of frames MACHINE-DISPLAY-CHANGED-
                 SINCE-RENDER-P found clean, incremented by the render
                 client's own scanline-fn (not by this file) whenever it
                 chooses to skip a frame. Pure observability: nothing in
                 src/machine.lisp reads it back. Exists so tests and
                 benchmarks have a cheap, exact way to confirm the skip
                 actually engaged instead of inferring it from timing."
  (cpu nil)
  (bus nil)
  (mmu nil)
  (pia nil)
  (antic nil)
  (gtia nil)
  (pokey nil)
  (hostdev nil)
  (frame-count 0 :type fixnum)
  (running-p nil)
  (mailbox (make-command-mailbox))
  (input nil)
  (priority-pending-flag nil)
  (scanline-fn   nil)
  (post-frame-fn nil)
  (pokey-lag 0 :type fixnum)
  (pokey-defer-disabled-p nil)
  (pokey-defer-engagements 0 :type fixnum)
  (pokey-defer-break-p nil)
  (watched-pages (make-array 256 :element-type '(unsigned-byte 8)
                                  :initial-element 0)
                 :type (simple-array (unsigned-byte 8) (256)))
  (render-skip-count 0 :type fixnum))

;;; ---------------------------------------------------------------------------
;;; Deferred POKEY advance (ROADMAP.md Phase 30)

(defun %machine-sync-pokey (machine)
  "If MACHINE's POKEY-LAG is positive, advance its POKEY by exactly that
many cycles and zero the lag; otherwise a no-op.

This is the sync half of Phase 30's deferral: %RUN-CLOCKS' deferring
instruction loop accumulates cycles into POKEY-LAG instead of calling
POKEY-ADVANCE after every instruction, and this function is the ONLY
place that lag is ever paid off.  It is called from three places: the
wrapped $D2xx bus read/write closures (MAKE-ATARI-MACHINE, below) before
every register access, so a read or write always observes state exactly
as caught-up as it would be without deferral; the deferring loop itself
when a mid-line write breaks the gate, so cycles are delivered to POKEY
in strict chronological order before falling back to the non-deferring
path; and %RUN-CLOCKS' end-of-line fold, which flushes whatever is left
before the line's usual top-up.  Any caller that reads or mutates POKEY
state outside those paths must call this first if it cannot prove it
only runs between frames (see the Phase 30a commit message for the full
audit)."
  (declare (type atari-machine machine))
  (let ((lag (atari-machine-pokey-lag machine)))
    (declare (type fixnum lag))
    (when (plusp lag)
      (pokey-advance (atari-machine-pokey machine) (atari-machine-cpu machine)
                      lag)
      (setf (atari-machine-pokey-lag machine) 0))))

;;; ---------------------------------------------------------------------------
;;; Construction

(defun make-atari-machine ()
  "Construct and wire a complete Atari 800 XL machine.

Each chip is built, the bus gets its MMU and all four chip-attach
closures installed, and the CPU's bus-read/bus-write hooks are pointed
at the bus.  The result is a machine that is ready for MACHINE-COLD-RESET."
  (let* ((cpu     (make-cpu))
         (mmu     (make-mmu))
         (bus     (make-bus :mmu mmu))
         (pia     (make-pia))
         (antic   (make-antic))
         (gtia    (make-gtia))
         (pokey   (make-pokey))
         (hostdev (make-host-bridge))
         (machine (%make-atari-machine :cpu cpu :bus bus :mmu mmu
                                        :pia pia :antic antic
                                        :gtia gtia :pokey pokey
                                        :hostdev hostdev)))
    ;; Wire chip dispatch into the bus.
    (attach-pia     bus pia mmu)
    (attach-antic   bus antic cpu)
    (attach-gtia    bus gtia)
    (attach-pokey   bus pokey cpu)
    (attach-hostdev bus hostdev)
    ;; ROADMAP.md Phase 30 (30a): wrap POKEY's bus dispatch closures (just
    ;; installed by ATTACH-POKEY, above) so every $D2xx access syncs the
    ;; deferred lag first.
    ;;
    ;; Timing-exactness note: without deferral, a $D2xx access today lands
    ;; with POKEY already advanced through every PREVIOUS instruction this
    ;; line ONLY -- the CURRENT instruction's own cycles are folded into
    ;; POKEY's clock AFTER STEP-CPU returns (see the instruction loop in
    ;; %RUN-CLOCKS), never before, so a register access mid-instruction
    ;; never observes that instruction's own elapsed time.  POKEY-LAG, by
    ;; construction, only ever holds cycles from instructions that have
    ;; ALREADY fully completed (the deferring loop adds the current
    ;; instruction's chunk to the lag only after STEP-CPU returns, exactly
    ;; where the non-deferring loop would have called POKEY-ADVANCE) --
    ;; so syncing here brings POKEY to the identical point in time an
    ;; access would see without deferral, never ahead of it and never
    ;; behind.
    (let ((orig-pokey-read  (bus-pokey-read-fn  bus))
          (orig-pokey-write (bus-pokey-write-fn bus)))
      (setf (bus-pokey-read-fn bus)
            (lambda (addr)
              (%machine-sync-pokey machine)
              (funcall (the function orig-pokey-read) addr)))
      (setf (bus-pokey-write-fn bus)
            (lambda (addr val)
              (%machine-sync-pokey machine)
              (funcall (the function orig-pokey-write) addr val)
              ;; A write can enable a timer IRQ, attach/start whatever
              ;; PENDING tracks, or otherwise change conditions
              ;; POKEY-DEFERRABLE-P depends on -- any of which invalidates
              ;; the deferral gate for the REST of this line.  Breaking
              ;; unconditionally on every write, rather than recomputing
              ;; eligibility mid-line, is the simple, obviously-correct
              ;; rule (ROADMAP.md Phase 30b item 2).
              (setf (atari-machine-pokey-defer-break-p machine) t))))
    ;; Wire the CPU to the bus.
    (setf (cpu-bus-read  cpu) (lambda (addr) (bus-read  bus addr))
          (cpu-bus-write cpu) (lambda (addr val) (bus-write bus addr val)))
    ;; Wire ANTIC's P/M graphics DMA into GTIA's GRAF registers.  ANTIC
    ;; fetches the bytes (and DMACTL decides whether it fetches at all);
    ;; GRACTL bit 1 gates whether GTIA latches player bytes, bit 0
    ;; missile bytes — software that leaves GRACTL clear keeps poked
    ;; GRAFPn values even while the DMA cycles are being stolen.
    (setf (antic-pm-write-fn antic)
          (lambda (object byte)
            (declare (type fixnum object) (type (unsigned-byte 8) byte))
            (let* ((wr     (gtia-write-regs gtia))
                   (gractl (aref wr +w-gractl+)))
              (if (= object 4)
                  (when (logtest gractl #x01)          ; missiles
                    (setf (aref wr +w-grafm+) byte))
                  (when (logtest gractl #x02)          ; players
                    (setf (aref wr (+ +w-grafp0+ object)) byte))))))
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
initialises CPU registers (P = $24, SP = $FF), and reads the reset
vector at $FFFC to set the initial PC.  Returns MACHINE."
  (let ((cpu (atari-machine-cpu machine))
        (bus (atari-machine-bus machine))
        (mmu (atari-machine-mmu machine)))
    (cond (os-rom    (install-os-rom bus os-rom))
          (os-path   (install-os-rom bus (load-rom-file os-path))))
    (cond (basic-rom (install-basic-rom bus basic-rom))
          (basic-path (install-basic-rom bus (load-rom-file basic-path))))
    (mmu-write-portb mmu #xFF)
    ;; P = $24 (U=1, I=1), matching RESET-CPU.  B is not a real status-
    ;; register bit on NMOS 6502 — it only exists in the copy of P a
    ;; BRK/IRQ pushes to the stack (STATUS-BYTE-FROM-PULL always forces
    ;; it off on a PLP/RTI read-back) — so #x34 (which also sets B) was
    ;; a phantom-bit divergence from RESET-CPU's #x24, not a real one.
    (setf (cpu-sp cpu)        #xFF
          (cpu-flags cpu)     #x24            ; U=1, I=1
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
;;; Audio (ROADMAP.md Phase 9)

(defun machine-attach-audio (machine &optional (audio (make-audio-unit)))
  "Attach an AUDIO-UNIT to MACHINE's POKEY so running frames accumulate
PCM samples, and return it.  With no argument a fresh unit is created;
pass NIL to detach (synthesis then costs nothing but a NIL test per
POKEY advance).  Drain the accumulated samples with MACHINE-AUDIO-DRAIN
— typically once per frame, which yields 746 or 747 samples at
+AUDIO-SAMPLE-RATE+.

ROADMAP.md Phase 30 audit: this function is reachable both from the
post-frame AESP path (provably lag-free — see %SYNC-AUDIO-ATTACHMENT's
docstring) and directly from the public facade / REPL / scripts, which
are not provably called only between frames.  Syncing first costs
nothing when the lag is already 0 and removes the ambiguity either way:
attaching or detaching audio changes what POKEY-DEFERRABLE-P will say
for scanlines from here on, and any cycles already claimed under the
OLD attachment state must be delivered under it, not the new one."
  (declare (type atari-machine machine))
  (%machine-sync-pokey machine)
  (attach-audio (atari-machine-pokey machine) audio))

(defun machine-audio-drain (machine)
  "Return a fresh (SIMPLE-ARRAY (UNSIGNED-BYTE 8)) of the PCM samples
MACHINE has accumulated since the last drain, emptying the buffer.
Returns an empty vector when no audio unit is attached."
  (declare (type atari-machine machine))
  (let ((audio (pokey-audio (atari-machine-pokey machine))))
    (if audio
        (audio-drain audio)
        (make-array 0 :element-type '(unsigned-byte 8)))))

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
          :i-flag-masked (flag-set-p cpu +flag-i+))))

;;; ---------------------------------------------------------------------------
;;; Frame scheduler

(defun %run-clocks (machine n &key abort-pred)
  "Run N NTSC clock cycles on MACHINE at scanline granularity.  Returns
the number of clocks actually run (N unless ABORT-PRED stopped early).

Structure (SCANLINE_ACCURACY_PLAN.md Phase 1): the loop advances one
scanline — 114 CPU cycles — at a time.  For each line:

  1. ANTIC-BEGIN-SCANLINE performs the line-start events (VBI/DLI NMIs,
     display-list fetch) and returns the cycles ANTIC steals; the
     remainder (114 - stolen) is added to CPU-BUDGET.
  2. The CPU executes whole instructions while at least 2 cycles (the
     minimum 6502 instruction) of budget remain.  POKEY is advanced
     instruction-by-instruction alongside the CPU — NOT in one
     line-sized batch — so its timer IRQs assert at the correct
     instruction boundary within the line.
  3. POKEY is topped up to exactly the line's cycle count (whatever the
     CPU did not account for), then ANTIC-END-SCANLINE closes the line.

POKEY accounting: POKEY receives exactly 114 cycles per line.  Because
CPU-BUDGET carries across lines, the CPU can occasionally consume a few
more cycles within one line than the line grants; POKEY advancement is
capped at the line length so the surplus is not double-counted.

Pending NMI/IRQ lines are serviced by STEP-CPU itself (NMI first, then
IRQ when the I flag is clear) before each instruction fetch; the 7 cycles
an interrupt-entry sequence consumes come out of CPU-BUDGET exactly like
an instruction's cycles, so the CPU cannot run ahead of the clock by
servicing interrupts for free.

Note on steal accounting: the old per-clock scheduler suppressed only
ONE budget cycle per line when ANTIC reported a steal; this scheduler
charges the full steal (114 - stolen granted per line), so the CPU now
correctly loses all 9+ stolen cycles each line.

Deferred POKEY advance (ROADMAP.md Phase 30): once per line, DEFER-P is
computed from POKEY-DEFERRABLE-P (no audio attached, no serial-tx/input
work pending, no timer IRQ source enabled) and MACHINE's debug
POKEY-DEFER-DISABLED-P escape hatch.  When true, nothing observable can
happen from POKEY's per-instruction state alone, so the instruction loop
accumulates each instruction's cycles into MACHINE's POKEY-LAG instead
of calling POKEY-ADVANCE immediately; POKEY-LAG is paid off by
%MACHINE-SYNC-POKEY, called by the wrapped $D2xx bus closures before any
access and by this function's own end-of-line fold (below).  A mid-line
$D2xx WRITE, via that same wrapper, sets POKEY-DEFER-BREAK-P — the
deferring loop's one extra per-instruction test — which flushes the lag
and falls back to the ordinary (non-deferring) per-instruction path for
the rest of the line; the non-deferring loop itself carries no new test
at all and is byte-identical to the pre-Phase-30 code.  POKEY-REMAINING
is decremented at the SAME point in both loops (when an instruction's
chunk is accounted for, whether delivered immediately or lagged), so by
line end it always holds exactly the cycles no instruction claimed at
all (typically the WSYNC-skipped tail); the end-of-line step folds any
leftover lag into POKEY first, then tops up by POKEY-REMAINING, so
POKEY receives precisely this line's 114 cycles in total regardless of
how many of them were deferred.

WSYNC ($D40A): after each instruction, ANTIC-CONSUME-WSYNC is checked;
if a WSYNC write is pending, CPU-BUDGET is clamped to (MIN CPU-BUDGET 0)
and the instruction loop stops for this line -- the CPU stalls to the
end of the scanline (a first cut; the hardware-accurate release at
cycle 105 is SCANLINE_ACCURACY_PLAN.md's stretch Phase 4).  The clamp
runs in both directions: a positive surplus carried from earlier lines
must not leak past the stall (real WSYNC freezes the CPU no matter how
far ahead it was), and a DEFICIT must survive it (the WSYNC-writing
instruction may have overshot the line's remaining budget; those
borrowed cycles still come out of the next line).  Back-to-back WSYNC
writes therefore stall to the END of the NEXT line: the first stalls
out the current line, and the second (executed as the first instruction
of the following line, before any further budget has been consumed)
immediately zeroes that line's budget too.  A WSYNC flag left armed by
an out-of-band write -- a debugger poke of $D40A or MACHINE-TRACE-STEP
executing a store, neither of which runs under this scheduler -- is
discarded on entry: there is no scanline context to stall against.

When N is not a multiple of 114, floor(N/114) full lines run, then one
partial line of the remaining cycles: it begins with the usual
line-start events and steal, but ANTIC-END-SCANLINE is NOT run for it
(the line is incomplete, so ANTIC's scanline counter must not advance).
The existing callers all pass whole-line multiples.

If ABORT-PRED is supplied it is funcalled once per scanline boundary
(before each line after the first); a true result stops early and
returns the clocks run so far.  The default run loop does NOT pass
ABORT-PRED — pause/resume/reset are handled at frame boundaries
(Decision 1: frame-granularity).  CPU-BUDGET is intentionally local: an
aborted partial run is discarded, not resumed, so no budget needs to
carry across calls."
  (declare (type atari-machine machine) (type fixnum n))
  (let* ((cpu   (atari-machine-cpu   machine))
         (bus   (atari-machine-bus   machine))
         (antic (atari-machine-antic machine))
         (pokey (atari-machine-pokey machine))
         (cpu-budget 0)
         (clocks-run 0))
    (declare (type fixnum cpu-budget clocks-run))
    ;; Discard a stale WSYNC flag armed outside this scheduler (debugger
    ;; poke of $D40A, MACHINE-TRACE-STEP executing a store).  Within a
    ;; run the flag is always consumed by the per-instruction check
    ;; below, so anything pending on entry has no scanline context and
    ;; must not stall the first line's first instruction.
    (antic-consume-wsync antic)
    (loop while (< clocks-run n)
          do ;; Scanline-boundary abort check (only when a predicate was
             ;; supplied, and never before the first line).
             (when (and abort-pred
                        (plusp clocks-run)
                        (funcall abort-pred))
               (return-from %run-clocks clocks-run))
             (let* ((line-cycles (min +cpu-cycles-per-scanline+
                                      (- n clocks-run)))
                    (stolen (antic-begin-scanline antic cpu bus))
                    (pokey-remaining line-cycles)
                    ;; Once PER LINE: is POKEY's per-instruction state
                    ;; unobservable for the rest of this line?  See
                    ;; POKEY-DEFERRABLE-P.  Cleared stale flag first — a
                    ;; break left armed by a PREVIOUS line's mid-line
                    ;; write must not suppress deferral on a line where
                    ;; nothing has written $D2xx yet.
                    ;;
                    ;; INVARIANT (ROADMAP.md Phase 30c item 1): DEFER-P
                    ;; requires POKEY-DEFERRABLE-P, which requires every
                    ;; timer IRQ enable bit (IRQEN & (TIMER1|TIMER2|TIMER4))
                    ;; to be clear.  A cleared enable bit means no timer
                    ;; expiry the deferring loop's lagged instructions could
                    ;; process -- immediately or later, once flushed -- can
                    ;; ever call %RAISE-IRQ (see %EXPIRE-CHANNEL), because
                    ;; that path is itself gated on the same IRQEN bit.  So
                    ;; no IRQ is ever raised, delayed, or reordered by
                    ;; deferral for as long as DEFER-P holds: the ONLY way
                    ;; IRQEN's timer bits can change mid-line is the wrapped
                    ;; $D2xx write closure, which breaks deferral (POKEY-
                    ;; DEFER-BREAK-P) for the remainder of the line before
                    ;; any instruction runs under the NEW IRQEN value.
                    (defer-p (progn
                               (setf (atari-machine-pokey-defer-break-p
                                      machine)
                                     nil)
                               (and (not (atari-machine-pokey-defer-disabled-p
                                          machine))
                                    (pokey-deferrable-p pokey)))))
               (declare (type fixnum line-cycles stolen pokey-remaining))
               (incf cpu-budget (- line-cycles stolen))
               ;; Run whole instructions while the budget allows.  STEP-CPU
               ;; services a pending NMI/IRQ instead of fetching when one is
               ;; due, returning the 7-cycle entry cost so it is charged to
               ;; the budget.  MACROLET, not a local function: NON-DEFER-LOOP
               ;; is spliced inline at both its call sites below so the
               ;; non-deferring path costs no extra funcall, the same shape
               ;; POKEY-ADVANCE's ADVANCE-LOOP macrolet uses to split its
               ;; audio/no-audio bodies (ROADMAP.md Phase 30b item 3 /
               ;; Phase 22's inner-loop-test lesson, quoted on POKEY-ADVANCE).
               (macrolet
                   ((non-defer-loop ()
                      `(loop while (and (>= cpu-budget 2) (not (cpu-halted cpu)))
                             do (handler-case
                                    (let ((used (step-cpu cpu)))
                                      (declare (type fixnum used))
                                      (decf cpu-budget used)
                                      ;; Advance POKEY alongside the
                                      ;; instruction, capped at this line's
                                      ;; remaining cycles.
                                      (let ((chunk (min used pokey-remaining)))
                                        (when (plusp chunk)
                                          (pokey-advance pokey cpu chunk)
                                          (decf pokey-remaining chunk))))
                                  ;; A KIL instruction signals ILLEGAL-OPCODE;
                                  ;; leave the CPU halted and stop stepping.
                                  (illegal-opcode ()
                                    (setf (cpu-halted cpu) t)))
                                ;; WSYNC ($D40A): a write halts the CPU until
                                ;; the end of the current scanline.  Clamp
                                ;; CPU-BUDGET to (MIN CPU-BUDGET 0): a
                                ;; positive surplus carried in from a
                                ;; previous line must not leak past the
                                ;; stall (real WSYNC freezes the CPU
                                ;; regardless of how far ahead it was), but
                                ;; a NEGATIVE budget -- the WSYNC-writing
                                ;; instruction overshot the line's
                                ;; remainder -- is a debt of already-
                                ;; executed cycles and must carry into the
                                ;; next line, not be forgiven.
                                ;; POKEY-REMAINING is left untouched here;
                                ;; the end-of-line fold/top-up below
                                ;; advances POKEY through the skipped
                                ;; remainder, so POKEY still sees every
                                ;; cycle of the line.  ANTIC-TICK (the
                                ;; per-cycle reference path) never calls
                                ;; ANTIC-CONSUME-WSYNC, so WSYNC has no
                                ;; effect outside this scheduler.
                                (when (antic-consume-wsync antic)
                                  (setf cpu-budget (min cpu-budget 0))
                                  (return)))))
                 (if defer-p
                     (progn
                       ;; Deferring loop.  Exactly the shape above, except
                       ;; the instruction's chunk goes into POKEY-LAG
                       ;; instead of an immediate POKEY-ADVANCE call, and
                       ;; ONE extra per-instruction test (the Phase 30b
                       ;; budget) reads POKEY-DEFER-BREAK-P: when a mid-
                       ;; line $D2xx write has set it, %MACHINE-SYNC-POKEY
                       ;; flushes the lag (so cycles reach POKEY in strict
                       ;; chronological order) before falling back to
                       ;; NON-DEFER-LOOP for the remainder of the line.
                       (loop while (and (>= cpu-budget 2) (not (cpu-halted cpu)))
                             do (handler-case
                                    (let ((used (step-cpu cpu)))
                                      (declare (type fixnum used))
                                      (decf cpu-budget used)
                                      (let ((chunk (min used pokey-remaining)))
                                        (when (plusp chunk)
                                          (incf (atari-machine-pokey-lag machine)
                                                chunk)
                                          (decf pokey-remaining chunk))))
                                  (illegal-opcode ()
                                    (setf (cpu-halted cpu) t)))
                                (when (antic-consume-wsync antic)
                                  (setf cpu-budget (min cpu-budget 0))
                                  (return))
                                (when (atari-machine-pokey-defer-break-p machine)
                                  (%machine-sync-pokey machine)
                                  (return)))
                       (incf (atari-machine-pokey-defer-engagements machine))
                       ;; A mid-line write broke the gate: finish the line
                       ;; the ordinary way.  A no-op when WSYNC or plain
                       ;; budget exhaustion already ended the line instead
                       ;; (NON-DEFER-LOOP's WHILE test is then false).
                       (when (atari-machine-pokey-defer-break-p machine)
                         (non-defer-loop)))
                     (non-defer-loop)))
               ;; End-of-line: fold any still-lagged cycles into POKEY
               ;; first -- they were already subtracted from
               ;; POKEY-REMAINING when the deferring loop accounted for
               ;; them, so flushing the lag and THEN topping up by
               ;; whatever POKEY-REMAINING still holds (the WSYNC-skipped
               ;; or never-executed tail) delivers each of this line's
               ;; cycles exactly once -- never double-counted, never
               ;; dropped, regardless of how many mid-line $D2xx accesses
               ;; already paid off part of the lag early.
               (let ((lag (atari-machine-pokey-lag machine)))
                 (declare (type fixnum lag))
                 (when (plusp lag)
                   (pokey-advance pokey cpu lag)
                   (setf (atari-machine-pokey-lag machine) 0)))
               (when (plusp pokey-remaining)
                 (pokey-advance pokey cpu pokey-remaining))
               ;; Close the line — but not a trailing partial line.
               (when (= line-cycles +cpu-cycles-per-scanline+)
                 (antic-end-scanline antic)
                 ;; The line just closed (SCANLINE has advanced past it);
                 ;; invoke the scanline callback if the completed line is in
                 ;; the active display region.
                 (let ((sfn (atari-machine-scanline-fn machine)))
                   (when sfn
                     (let ((done-sl (mod (1- (antic-scanline antic))
                                         +scanlines-per-frame+)))
                       (when (and (>= done-sl +active-start-scanline+)
                                  (<  done-sl +vbi-scanline+))
                         (funcall sfn machine))))))
               (incf clocks-run line-cycles)))
    n))

(defun machine-run-frame (machine)
  "Run one NTSC frame: 29,868 clocks = 262 scanlines of 114 CPU cycles.
Drives ANTIC and POKEY scanline-by-scanline in lockstep with the CPU
(servicing pending NMI/IRQ between instructions) and increments
FRAME-COUNT before returning MACHINE."
  (%run-clocks machine +clocks-per-frame+)
  (incf (atari-machine-frame-count machine))
  (let ((pfn (atari-machine-post-frame-fn machine)))
    (when pfn (funcall pfn machine)))
  machine)

;;; ---------------------------------------------------------------------------
;;; Dirty-frame render skip (ROADMAP.md Phase 29c)
;;;
;;; MACHINE-DISPLAY-CHANGED-SINCE-RENDER-P / MACHINE-NOTE-FULL-RENDER are
;;; the machine-level API a render client (src/aesp.lisp's START-AESP-
;;; SERVER, scripts/bench.lisp's :idle workload) uses to decide, once per
;;; frame, whether it needs to render at all.  Single-renderer-consumer
;;; semantics throughout (see the ATARI-MACHINE docstring's WATCHED-PAGES
;;; entry): both functions assume at most one client calls them on a
;;; given machine, since WATCHED-PAGES is one shared scratch buffer and
;;; the bus's dirty map is one shared piece of global state that
;;; MACHINE-NOTE-FULL-RENDER clears for whoever calls it.

(defun machine-display-changed-since-render-p (machine)
  "T if the render client attached to MACHINE must render the current
frame; NIL if nothing that feeds the renderer has changed since the last
MACHINE-NOTE-FULL-RENDER, so the frame can be skipped outright.

Calls ANTIC-COLLECT-WATCHED-PAGES into MACHINE's WATCHED-PAGES scratch
buffer.  If that returns NIL (the analysis could not be sure -- a
runaway display list, an operand landing in the $D000-$D7FF I/O range,
etc.), this function returns T unconditionally: per ROADMAP.md Phase
29's own rule, any doubt about the analysis must render, because only
the SKIP depends on the map's precision -- the displayed frame's
correctness never does.

Otherwise returns T iff ATARI-MACHINE-BUS's IO-REGS-DIRTY-P is set (a
render-relevant GTIA/ANTIC register was written since the last
MACHINE-NOTE-FULL-RENDER) OR the 256-entry intersection of WATCHED-PAGES
against the bus's PAGE-DIRTY map is non-empty (a page the current frame
actually reads from was written since the last MACHINE-NOTE-FULL-
RENDER).  BUS-PAGE-DIRTY and BUS-IO-REGS-DIRTY-P both start all-dirty at
machine construction (see BUS's docstring), so the very first call on a
freshly built or just-reset machine always returns T without any special
casing here -- the first frame is unconditionally rendered because
everything reads as dirty."
  (declare (type atari-machine machine))
  (let* ((antic   (atari-machine-antic machine))
         (bus     (atari-machine-bus machine))
         (watched (atari-machine-watched-pages machine)))
    (if (not (antic-collect-watched-pages antic bus watched))
        t
        (or (bus-io-regs-dirty-p bus)
            (let ((dirty (bus-page-dirty bus)))
              (declare (type (simple-array (unsigned-byte 8) (256))
                             dirty watched))
              (dotimes (page 256 nil)
                ;; PAGE's declared range must include 256, not just the
                ;; valid AREF indices 0-255: DOTIMES's loop variable is
                ;; transiently assigned the count value itself (256) at
                ;; the termination check even though the body never runs
                ;; with that value, and SBCL's (safety 1) policy applies
                ;; the type check to every assignment, not just uses --
                ;; declaring (integer 0 255) here signals a TYPE-ERROR on
                ;; every call that runs the loop to completion (exactly
                ;; the all-clean case this function exists to detect).
                (declare (type (integer 0 256) page))
                (when (and (/= 0 (aref watched page)) (/= 0 (aref dirty page)))
                  (return t))))))))

(defun machine-note-full-render (machine)
  "Tell MACHINE's bus that the render client is about to fully render the
current frame: clears BUS's per-page dirty map and IO-REGS-DIRTY-P flag
(via BUS-CLEAR-RENDER-DIRTY) so writes from THIS point forward accumulate
toward the NEXT frame's MACHINE-DISPLAY-CHANGED-SINCE-RENDER-P decision.

Callers MUST call this at the START of a frame they have decided to
fully render -- BEFORE actually rendering any of it.  Any write that
lands during the frame being rendered (the CPU racing the beam) is then
correctly counted as dirt for the NEXT decision, forcing that next frame
to render too rather than being wrongly judged clean.  A client that
decides to SKIP a frame must NOT call this -- dirt keeps accumulating,
unconsulted, until the next frame that actually renders."
  (declare (type atari-machine machine))
  (bus-clear-render-dirty (atari-machine-bus machine))
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
registers reflect live input.  Pass NIL to detach.  Returns MACHINE.

ROADMAP.md Phase 30 audit: like MACHINE-ATTACH-AUDIO, this is public API
callable outside the mailbox-drained between-frames window, and
ATTACH-POKEY-INPUT flips POKEY's PENDING key bit (one of
POKEY-DEFERRABLE-P's conditions) — sync first so any already-lagged
cycles are delivered under the attachment state that was actually in
effect while they elapsed, not the one this call is about to install."
  (declare (type atari-machine machine))
  (%machine-sync-pokey machine)
  (setf (atari-machine-input machine) input)
  (attach-pia-input   (atari-machine-pia   machine) input)
  (attach-gtia-input  (atari-machine-gtia  machine) input)
  (attach-pokey-input (atari-machine-pokey machine) input)
  machine)

;;; ---------------------------------------------------------------------------
;;; Background run-loop driver

(defstruct (machine-runner (:constructor %make-machine-runner))
  "Handle for a background MACHINE-RUN-LOOP thread (see START-MACHINE).
STOP-CELL is a 1-element list whose car the stop-flag closure reads."
  machine
  thread
  (stop-cell (list nil)))

(defun start-machine (machine)
  "Spawn a background thread running MACHINE-RUN-LOOP on MACHINE and return a
MACHINE-RUNNER handle.  The machine starts paused (RUNNING-P NIL); drive it
by posting commands to its mailbox (e.g. RESUME from a protocol server).  A
running loop is required for the AESP/CLI servers' state-mutating commands to
complete.  Stop it with STOP-MACHINE."
  (declare (type atari-machine machine))
  (let* ((stop   (list nil))
         (runner (%make-machine-runner :machine machine :stop-cell stop)))
    (setf (machine-runner-thread runner)
          (make-thread (lambda () (machine-run-loop machine
                                                    :stop-flag (lambda () (car stop))))
                       :name "atari800-cl-machine"))
    runner))

(defun stop-machine (runner &key (timeout 2.0))
  "Signal RUNNER's run-loop to stop and join its thread (forcibly destroying
it if it outlives TIMEOUT seconds).  Returns RUNNER."
  (setf (car (machine-runner-stop-cell runner)) t)
  (let ((th (machine-runner-thread runner)))
    (when th
      (let ((deadline (+ (get-internal-real-time)
                         (truncate (* timeout internal-time-units-per-second)))))
        (loop while (and (thread-alive-p th) (< (get-internal-real-time) deadline))
              do (sleep 0.005))
        (when (thread-alive-p th) (destroy-thread th)))))
  runner)
