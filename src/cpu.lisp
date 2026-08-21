;;;; src/cpu.lisp --- NMOS 6502 CPU core.
;;;;
;;;; Bus-agnostic 6502 implementation.  The CPU communicates with the
;;;; outside world through two callbacks installed on the CPU state:
;;;;
;;;;   (cpu-bus-read  cpu)  -> (function (u16) u8)
;;;;   (cpu-bus-write cpu)  -> (function (u16 u8) *)
;;;;
;;;; A small helper, ATTACH-MEMORY-BUS, wires a MEMORY object's
;;;; MEM-READ/MEM-WRITE into those slots so existing callers keep working.
;;;;
;;;; The 256-entry dispatch table is built in src/cpu-opcodes.lisp.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; Bitwise operations used heavily in this file:
;;;;   LOGAND  — bitwise AND          (like & in C)
;;;;   LOGIOR  — bitwise inclusive OR  (like | in C)
;;;;   LOGXOR  — bitwise exclusive OR  (like ^ in C)
;;;;   LOGANDC2 — AND first arg with complement of second: (A & ~B)
;;;;              Less common than LOGAND, but avoids a separate LOGNOT call.
;;;;   LOGTEST — true when two integers share any set bits; the idiomatic
;;;;             spelling of (not (zerop (logand x mask)))
;;;;   ASH     — arithmetic shift; positive count shifts left, negative right
;;;;   ZEROP   — returns T if the number is zero
;;;;   1+, 1-  — increment / decrement by one (purely arithmetic, no mutation)
;;;;
;;;; Byte-field operators (the CL-native way to slice integers):
;;;;   BYTE — builds a field descriptor: (BYTE size position)
;;;;   LDB  — extracts a field: (ldb (byte 8 8) w) is the high byte of W;
;;;;          (ldb (byte 8 0) x) doubles as "wrap to 8 bits"
;;;;   DPB  — deposits a field: (dpb hi (byte 8 8) lo) assembles a 16-bit
;;;;          little-endian word from two bytes
;;;;
;;;; FUNCALL calls a function stored in a variable.  In CL, functions and
;;;; values live in separate namespaces (Lisp-2), so to call a function
;;;; held in a slot like CPU-BUS-READ, you must write
;;;;   (funcall (cpu-bus-read cpu) address)
;;;; rather than just ((cpu-bus-read cpu) address).
;;;;
;;;; VALUES returns multiple values from a function.  The caller can
;;;; receive them with MULTIPLE-VALUE-BIND.  This is CL's way of
;;;; returning a tuple without allocating a cons cell or struct.
;;;;
;;;; LAMBDA creates an anonymous function (a closure).  For example,
;;;;   (lambda (addr) (mem-read memory addr))
;;;; captures the MEMORY variable from the enclosing scope and returns a
;;;; function that takes one argument ADDR.
;;;;
;;;; DEFINE-CONDITION defines a new error/condition type.  Conditions are
;;;; CL's equivalent of exceptions.  :INITARG names a keyword for the
;;;; constructor; :READER creates a slot-accessor function; :REPORT
;;;; defines how the condition prints itself.
;;;;
;;;; DEFVAR defines a special (global) variable that is only set once.
;;;; Unlike DEFPARAMETER, re-loading the file does NOT reinitialise it.
;;;; This matters for *OPCODE-TABLE* because cpu-opcodes.lisp populates it,
;;;; and we don't want loading cpu.lisp again to wipe out the table.
;;;;
;;;; COND is a multi-branch conditional — like if/else-if/else.  Each
;;;; clause is (TEST BODY...).  The first clause whose TEST is true has
;;;; its BODY executed; T in the last clause acts as "else".
;;;;
;;;; SVREF accesses an element of a SIMPLE-VECTOR (a fixed-size,
;;;; non-adjustable, one-dimensional array of general Lisp objects).

(in-package #:atari800-cl.cpu)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  See the
;;; matching declaim in src/bus.lisp for the note on DECLAIM's proclaiming
;;; behaviour under :serial t; repeated here so this file's policy survives
;;; interactive recompilation on its own.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Status-register flag bits (NV-BDIZC)
;;;
;;; The 6502 packs eight flags into a single byte.  Each constant below
;;; is a single-bit mask.  To test whether a flag is set, we LOGTEST the
;;; flags register against the mask.
;;;
;;; Bit layout (MSB to LSB):
;;;   7  6  5  4  3  2  1  0
;;;   N  V  U  B  D  I  Z  C
;;;
;;; N = Negative, V = oVerflow, U = Unused (always 1), B = Break,
;;; D = Decimal, I = Interrupt disable, Z = Zero, C = Carry.

(defconstant +flag-c+ #x01)   ; Carry
(defconstant +flag-z+ #x02)   ; Zero
(defconstant +flag-i+ #x04)   ; Interrupt disable
(defconstant +flag-d+ #x08)   ; Decimal mode (BCD arithmetic)
(defconstant +flag-b+ #x10)   ; Break — only visible on the stack, not in register
(defconstant +flag-u+ #x20)   ; Unused — always reads as 1
(defconstant +flag-v+ #x40)   ; Overflow
(defconstant +flag-n+ #x80)   ; Negative (sign bit)

;;; ---------------------------------------------------------------------------
;;; CPU state
;;;
;;; PENDING-NMI is edge-triggered: the bus controller sets it and the CPU
;;; clears it after servicing.  PENDING-IRQ is level-sensitive: the bus
;;; controller keeps it true while the line is asserted.
;;;
;;; The slot type (OR NULL FUNCTION) means the slot can hold either NIL
;;; (bus not yet wired) or a function object.  BOOLEAN is CL's type for
;;; T (true) and NIL (false).

(defstruct cpu
  "NMOS 6502 register state plus bus hooks and interrupt lines.

Slots:
  PC, A, X, Y, SP, FLAGS — register file (FLAGS packed NV-BDIZC).
  CYCLES                  — total cycles since last reset.
  BUS-READ                — function (u16)      -> u8.
  BUS-WRITE               — function (u16 u8)   -> *.
  PENDING-IRQ             — level-sensitive IRQ line.
  PENDING-NMI             — edge-triggered NMI request.
  HALTED                  — set when an illegal opcode aborts execution."
  (pc          0    :type u16)
  (a           0    :type u8)
  (x           0    :type u8)
  (y           0    :type u8)
  (sp          #xFD :type u8)            ; stack pointer starts at $FD after reset
  (flags       #x24 :type u8)            ; U=1, I=1 after reset
  ;; FIXNUM rather than (UNSIGNED-BYTE 64): raw (unsigned-byte 64) struct
  ;; slots are SBCL-specific goodness but may box on LispWorks, whereas
  ;; fixnum is fast (unboxed) on both.  62 bits of cycle count is
  ;; millennia of emulated time, so the narrower range is not a concern.
  (cycles      0    :type fixnum)
  (bus-read    nil :type (or null function))
  (bus-write   nil :type (or null function))
  (pending-irq nil :type boolean)
  (pending-nmi nil :type boolean)
  (halted      nil :type boolean))

;;; ---------------------------------------------------------------------------
;;; Bus access helpers
;;;
;;; These thin wrappers call the bus-read/bus-write closures stored in the
;;; CPU struct.  The LDB field extractions wrap addresses to 16 bits and
;;; values to 8 bits, even if arithmetic overflows.

(declaim (inline cpu-read-byte cpu-write-byte))

(defun cpu-read-byte (cpu address)
  (declare (type cpu cpu) (type u16 address))
  ;; FUNCALL is needed because CPU-BUS-READ returns a function object,
  ;; and CL requires FUNCALL to invoke a value in the "variable" namespace.
  ;; The slot's declared type is (OR NULL FUNCTION); checking for NIL up
  ;; front lets THE tell the compiler the FUNCALL target is a known
  ;; FUNCTION afterward, instead of an opaque callable it must look up via
  ;; FDEFINITION on every single memory access.
  (let ((fn (cpu-bus-read cpu)))
    (unless fn (error "CPU bus-read hook is not wired"))
    (funcall (the function fn) (ldb (byte 16 0) address))))

(defun cpu-write-byte (cpu address value)
  (declare (type cpu cpu) (type u16 address) (type u8 value))
  (let ((fn (cpu-bus-write cpu)))
    (unless fn (error "CPU bus-write hook is not wired"))
    (funcall (the function fn)
             (ldb (byte 16 0) address)
             (ldb (byte 8 0) value))))

(defun cpu-read-word (cpu address)
  "Read a little-endian 16-bit word: low byte at ADDRESS, high byte at ADDRESS+1."
  (declare (type cpu cpu) (type u16 address))
  (let ((lo (cpu-read-byte cpu address))
        (hi (cpu-read-byte cpu (ldb (byte 16 0) (1+ address)))))
    ;; DPB deposits HI into bits 8-15 of LO, forming the 16-bit word.
    (dpb hi (byte 8 8) lo)))

(defun attach-memory-bus (cpu memory)
  "Wire a MEMORY object's MEM-READ/MEM-WRITE into CPU's bus hooks.

Creates two closures (anonymous functions) that capture the MEMORY
object and installs them as the CPU's bus-read and bus-write callbacks.
This is how the CPU accesses the 64K address space without knowing
the details of the memory implementation."
  (declare (type cpu cpu) (type memory memory))
  ;; SETF can assign multiple places in one form: the first pair sets
  ;; BUS-READ, the second pair sets BUS-WRITE.
  (setf (cpu-bus-read cpu)
        (lambda (addr) (mem-read memory addr))
        (cpu-bus-write cpu)
        (lambda (addr value) (mem-write memory addr value)))
  cpu)

;;; ---------------------------------------------------------------------------
;;; Flag helpers
;;;
;;; These small functions manipulate individual flag bits in the CPU's
;;; FLAGS register using bitwise operations.

(declaim (inline flag-set-p set-flag clear-flag set-flag-to))

(defun flag-set-p (cpu mask)
  "Return T if the flag bit(s) in MASK are set in the CPU's flags register."
  (declare (type cpu cpu) (type u8 mask))
  ;; LOGTEST is true when the two integers share any set bits.
  (logtest (cpu-flags cpu) mask))

(defun set-flag (cpu mask)
  "Set the flag bit(s) indicated by MASK to 1."
  (declare (type cpu cpu) (type u8 mask))
  ;; LOGIOR of two bytes cannot exceed 8 bits, so no re-masking is needed.
  (setf (cpu-flags cpu) (logior (cpu-flags cpu) mask)))

(defun clear-flag (cpu mask)
  "Clear the flag bit(s) indicated by MASK to 0."
  (declare (type cpu cpu) (type u8 mask))
  ;; LOGANDC2 computes (flags AND (NOT mask)), i.e. clears just those bits.
  (setf (cpu-flags cpu) (logandc2 (cpu-flags cpu) mask)))

(defun set-flag-to (cpu mask bool)
  "Set flag bit(s) to 1 if BOOL is true, 0 otherwise."
  (if bool (set-flag cpu mask) (clear-flag cpu mask)))

(defun update-zn (cpu value)
  "Set Z and N flags from the low 8 bits of VALUE; return the masked byte.
This is called after most ALU operations to update the Zero and Negative
flags based on the result."
  (declare (type cpu cpu))
  (let ((v (ldb (byte 8 0) value)))     ; wrap to 8 bits
    (set-flag-to cpu +flag-z+ (zerop v))               ; Z=1 if result is 0
    (set-flag-to cpu +flag-n+ (logtest v #x80))        ; N=1 if bit 7 is set
    v))

(defun status-byte-for-push (cpu &key (b-flag t))
  "Build the status byte to push onto the stack.
U (unused) is always set to 1.  B (break) is set to 1 for PHP/BRK
instructions, but cleared to 0 for hardware interrupts (IRQ/NMI)."
  (let ((s (logior (cpu-flags cpu) +flag-u+)))  ; always set U
    (if b-flag
        (logior s +flag-b+)                     ; set B for PHP/BRK
        (logandc2 s +flag-b+))))                ; clear B for IRQ/NMI

(defun status-byte-from-pull (byte)
  "Reconstruct the flags register from a byte pulled off the stack.
Always forces U=1 and B=0, because the B flag only exists on the
stack — it is not a real register bit."
  (logandc2 (logior byte +flag-u+)             ; set U ...
            +flag-b+))                           ; ... and clear B

;;; ---------------------------------------------------------------------------
;;; Stack helpers (page $0100, post-decrement on push, pre-increment on pull)
;;;
;;; The 6502 stack lives in page 1 ($0100–$01FF).  The stack pointer (SP)
;;; is an 8-bit register; the full address is $0100 + SP.  On push, the
;;; value is written at the current SP and SP is decremented.  On pull, SP
;;; is incremented first, then the value is read.  Both wrap within the
;;; 8-bit range (no stack overflow detection on the real hardware).

(declaim (inline push-byte pull-byte))

(defun push-byte (cpu value)
  "Push a byte onto the 6502 stack: write at $0100+SP, then decrement SP."
  (declare (type cpu cpu) (type u8 value))
  ;; LOGIOR #x0100 puts the 8-bit SP into the $0100 page.
  (cpu-write-byte cpu (logior #x0100 (cpu-sp cpu)) value)
  ;; LDB of (byte 8 0) wraps the decrement within 0-255.
  (setf (cpu-sp cpu) (ldb (byte 8 0) (1- (cpu-sp cpu)))))

(defun pull-byte (cpu)
  "Pull a byte from the 6502 stack: increment SP, then read at $0100+SP."
  (declare (type cpu cpu))
  (setf (cpu-sp cpu) (ldb (byte 8 0) (1+ (cpu-sp cpu))))
  (cpu-read-byte cpu (logior #x0100 (cpu-sp cpu))))

(defun push-word (cpu word)
  "Push a 16-bit word onto the stack, high byte first (as the 6502 does)."
  (declare (type cpu cpu) (type u16 word))
  ;; LDB extracts each half: (byte 8 8) is the high byte, (byte 8 0) the low.
  (push-byte cpu (ldb (byte 8 8) word))
  (push-byte cpu (ldb (byte 8 0) word)))

(defun pull-word (cpu)
  "Pull a 16-bit word: low byte first (since the 6502 pushed high byte first)."
  (declare (type cpu cpu))
  (let ((lo (pull-byte cpu))
        (hi (pull-byte cpu)))
    (dpb hi (byte 8 8) lo)))

;;; ---------------------------------------------------------------------------
;;; Reset / IRQ / NMI
;;;
;;; These are the three hardware interrupt/reset vectors in the 6502.
;;; Each is a 16-bit address stored in the top of the address space.
;;; On reset, the CPU reads the PC from $FFFC/$FFFD (little-endian).

(defconstant +nmi-vector+   #xFFFA)
(defconstant +reset-vector+ #xFFFC)
(defconstant +irq-vector+   #xFFFE)

(defun reset-cpu (cpu &optional memory)
  "Apply 6502 reset semantics.

If MEMORY is supplied, also wire CPU's bus hooks to that memory.  The
two-argument call shape matches the original scaffold API."
  (declare (type cpu cpu))
  ;; WHEN is a one-branch IF: execute the body only if the test is true.
  ;; &OPTIONAL means MEMORY can be omitted (defaults to NIL).
  (when memory
    (attach-memory-bus cpu memory))
  ;; Read the reset vector to get the initial PC value.
  (let* ((lo (cpu-read-byte cpu +reset-vector+))
         (hi (cpu-read-byte cpu (1+ +reset-vector+))))
    ;; SETF can set multiple places at once.  Each pair is (PLACE VALUE).
    (setf (cpu-pc cpu)        (dpb hi (byte 8 8) lo)
          (cpu-a  cpu)        0
          (cpu-x  cpu)        0
          (cpu-y  cpu)        0
          (cpu-sp cpu)        #xFD        ; SP starts at $FD after reset sequence
          (cpu-flags cpu)     #x24        ; U=1, I=1
          (cpu-cycles cpu)    0
          (cpu-pending-irq cpu) nil
          (cpu-pending-nmi cpu) nil
          (cpu-halted cpu)    nil))
  cpu)

(defun service-nmi (cpu)
  "Handle a non-maskable interrupt: push PC and status, jump through NMI vector."
  (declare (type cpu cpu))
  (push-word cpu (cpu-pc cpu))
  (push-byte cpu (status-byte-for-push cpu :b-flag nil))  ; B=0 for hardware interrupts
  (set-flag cpu +flag-i+)                                 ; disable further IRQs
  (setf (cpu-pc cpu) (cpu-read-word cpu +nmi-vector+))
  ;; INCF adds to a place in-place: (incf x n) is equivalent to (setf x (+ x n)).
  (incf (cpu-cycles cpu) 7)
  (setf (cpu-pending-nmi cpu) nil))                       ; edge-triggered: clear after service

(defun service-irq (cpu)
  "Handle a maskable interrupt: push PC and status, jump through IRQ vector."
  (declare (type cpu cpu))
  (push-word cpu (cpu-pc cpu))
  (push-byte cpu (status-byte-for-push cpu :b-flag nil))
  (set-flag cpu +flag-i+)
  (setf (cpu-pc cpu) (cpu-read-word cpu +irq-vector+))
  (incf (cpu-cycles cpu) 7))

(defun trigger-nmi (cpu)
  "Assert the NMI line (edge-triggered — latched until serviced)."
  (setf (cpu-pending-nmi cpu) t) cpu)

(defun set-irq-line (cpu level)
  "Set or clear the IRQ line.  LEVEL is true to assert, NIL to de-assert.
(AND LEVEL T) normalises any truthy value to exactly T for the boolean slot."
  (setf (cpu-pending-irq cpu) (and level t)) cpu)

;;; ---------------------------------------------------------------------------
;;; PC fetch helpers and addressing modes
;;;
;;; Each addressing-mode helper reads operand bytes from the program
;;; counter (advancing PC as it goes) and returns two values:
;;;   1. The effective address to read from or write to
;;;   2. Whether a page boundary was crossed (relevant for cycle counting)
;;;
;;; The VALUES form returns multiple values.  Callers receive them with
;;; MULTIPLE-VALUE-BIND:
;;;   (multiple-value-bind (addr page-crossed-p) (addr-absolute-x cpu) ...)

(declaim (inline read-pc-byte read-pc-word page-crossed-p))

(defun read-pc-byte (cpu)
  "Fetch the byte at PC and advance PC by one."
  (declare (type cpu cpu))
  (let ((b (cpu-read-byte cpu (cpu-pc cpu))))
    (setf (cpu-pc cpu) (ldb (byte 16 0) (1+ (cpu-pc cpu))))
    b))

(defun read-pc-word (cpu)
  "Fetch a little-endian 16-bit word at PC and advance PC by two."
  (declare (type cpu cpu))
  (let ((lo (read-pc-byte cpu))
        (hi (read-pc-byte cpu)))
    (dpb hi (byte 8 8) lo)))

(defun page-crossed-p (base offset-addr)
  "Return T if BASE and OFFSET-ADDR are on different 256-byte pages.
A page boundary cross adds an extra cycle on certain 6502 instructions."
  (/= (ldb (byte 8 8) base) (ldb (byte 8 8) offset-addr)))

(declaim (inline %uncarried-indexed-address))

(defun %uncarried-indexed-address (base index)
  "NMOS indexed addressing (abs,X / abs,Y / (zp),Y) hardware quirk: before
reaching the corrected effective address, the CPU first forms an address
using BASE's high byte together with the 8-bit-wrapped sum of BASE's low
byte and INDEX -- i.e. the address as it would be if the index's carry
into the high byte hadn't happened yet.  A READ instruction dummy-reads
this address only when the real access crosses a page (the wasted cycle
IS the page-cross penalty); a STORE or RMW instruction always does,
whether or not the access crosses (their cycle count is already the
worst case).  See SCANLINE_ACCURACY_PLAN.md Phase 5 item 2 /
ROADMAP.md Phase 17."
  (declare (type u16 base) (type u8 index))
  (dpb (ldb (byte 8 8) base) (byte 8 8) (ldb (byte 8 0) (+ (ldb (byte 8 0) base) index))))

;;; --- Addressing modes ---
;;; Each returns (VALUES effective-address page-crossed-p uncarried-address).
;;; UNCARRIED-ADDRESS is only meaningful (non-NIL) for ADDR-ABSOLUTE-X,
;;; ADDR-ABSOLUTE-Y, and ADDR-INDIRECT-INDEXED -- the three modes whose
;;; dummy-read address differs from their real one; callers that don't
;;; need it simply don't bind a third value.  ADDR-ZERO-PAGE-X/Y and
;;; ADDR-INDEXED-INDIRECT perform their own dummy read unconditionally
;;; (real hardware always spends that cycle there, regardless of whether
;;; the caller is a load, store, or RMW), so they need no third value.

(defun addr-immediate (cpu)
  "Immediate: the operand IS the byte at PC."
  (let ((addr (cpu-pc cpu)))
    (setf (cpu-pc cpu) (ldb (byte 16 0) (1+ addr)))
    (values addr nil)))

(defun addr-zero-page (cpu)
  "Zero page: the operand byte is a single-byte address in page zero ($00xx)."
  (values (read-pc-byte cpu) nil))

(defun addr-zero-page-x (cpu)
  "Zero page,X: (operand + X) wrapped to 8 bits (stays in zero page).
NMOS hardware always dummy-reads the UNINDEXED operand address first --
the cycle that indexing zero page costs over plain zero page is spent
there, not on the final read/write."
  (let ((zp (read-pc-byte cpu)))
    (cpu-read-byte cpu zp)  ; dummy read at the unindexed zero-page address
    (values (ldb (byte 8 0) (+ zp (cpu-x cpu))) nil)))

(defun addr-zero-page-y (cpu)
  "Zero page,Y: (operand + Y) wrapped to 8 bits (stays in zero page).
See ADDR-ZERO-PAGE-X for the unconditional dummy-read note."
  (let ((zp (read-pc-byte cpu)))
    (cpu-read-byte cpu zp)  ; dummy read at the unindexed zero-page address
    (values (ldb (byte 8 0) (+ zp (cpu-y cpu))) nil)))

(defun addr-absolute (cpu)
  "Absolute: a full 16-bit address follows the opcode."
  (values (read-pc-word cpu) nil))

(defun addr-absolute-x (cpu)
  "Absolute,X: 16-bit base + X register.  Reports page cross and the
un-carried dummy-read address (see %UNCARRIED-INDEXED-ADDRESS)."
  (let* ((base (read-pc-word cpu))
         (addr (ldb (byte 16 0) (+ base (cpu-x cpu)))))
    (values addr (page-crossed-p base addr) (%uncarried-indexed-address base (cpu-x cpu)))))

(defun addr-absolute-y (cpu)
  "Absolute,Y: 16-bit base + Y register.  Reports page cross and the
un-carried dummy-read address (see %UNCARRIED-INDEXED-ADDRESS)."
  (let* ((base (read-pc-word cpu))
         (addr (ldb (byte 16 0) (+ base (cpu-y cpu)))))
    (values addr (page-crossed-p base addr) (%uncarried-indexed-address base (cpu-y cpu)))))

(defun addr-indirect (cpu)
  "JMP indirect: read a 16-bit pointer, then fetch the target from that address.
Faithfully reproduces the NMOS page-wrap bug: if the pointer's low byte is $FF,
the high byte of the target is read from $xx00 (same page) instead of $xx00+$100
(next page).  For example, JMP ($10FF) reads the low byte from $10FF and the high
byte from $1000, NOT $1100."
  (let* ((ptr (read-pc-word cpu))
         (lo  (cpu-read-byte cpu ptr))
         ;; Wrap within the same page: DPB replaces only the low byte of
         ;; PTR with the incremented value, leaving the page byte alone.
         (hi-addr (dpb (1+ ptr) (byte 8 0) ptr))
         (hi  (cpu-read-byte cpu hi-addr)))
    (values (dpb hi (byte 8 8) lo) nil)))

(defun addr-indexed-indirect (cpu)
  "(zp,X): add X to the zero-page operand (wrapping to 8 bits), then read a
16-bit pointer from that zero-page location.  The pointer fetch also wraps
within zero page.  NMOS hardware always dummy-reads the UNINDEXED pointer
address first, before adding X -- see ADDR-ZERO-PAGE-X."
  (let ((zp0 (read-pc-byte cpu)))
    (cpu-read-byte cpu zp0)  ; dummy read at the unindexed pointer address
    (let* ((zp  (ldb (byte 8 0) (+ zp0 (cpu-x cpu))))
           (lo  (cpu-read-byte cpu zp))
           (hi  (cpu-read-byte cpu (ldb (byte 8 0) (1+ zp)))))
      (values (dpb hi (byte 8 8) lo) nil))))

(defun addr-indirect-indexed (cpu)
  "(zp),Y: read a 16-bit pointer from the zero-page operand (with wrap),
then add Y to get the effective address.  Reports page cross and the
un-carried dummy-read address (see %UNCARRIED-INDEXED-ADDRESS)."
  (let* ((zp   (read-pc-byte cpu))
         (lo   (cpu-read-byte cpu zp))
         (hi   (cpu-read-byte cpu (ldb (byte 8 0) (1+ zp))))
         (base (dpb hi (byte 8 8) lo))
         (addr (ldb (byte 16 0) (+ base (cpu-y cpu)))))
    (values addr (page-crossed-p base addr) (%uncarried-indexed-address base (cpu-y cpu)))))

(defun addr-relative (cpu)
  "Relative: used by branch instructions.  The operand is a signed 8-bit
offset from the NEXT instruction's address (i.e. from PC after the offset
byte has been consumed)."
  (let* ((off (read-pc-byte cpu))
         ;; Convert unsigned byte to signed: values >= #x80 are negative.
         (s   (the (signed-byte 16)
                   (if (>= off #x80) (- off #x100) off))))
    (declare (type u8 off))
    (values (ldb (byte 16 0) (+ (cpu-pc cpu) s)) nil)))

;;; ---------------------------------------------------------------------------
;;; Fetch / decode / dispatch
;;;
;;; DEFINE-CONDITION defines a new condition (error) type.  In CL, the
;;; condition system is more flexible than simple exceptions: you can
;;; define restarts (recovery strategies) that callers can invoke.
;;; Here we define ILLEGAL-OPCODE as a subtype of ERROR.

(define-condition illegal-opcode (error)
  ;; Each slot has an :INITARG (keyword for the constructor) and a :READER
  ;; (accessor function to retrieve the value from a condition object).
  ((opcode :initarg :opcode :reader illegal-opcode-opcode)
   (pc     :initarg :pc     :reader illegal-opcode-pc))
  ;; :REPORT defines how this condition prints.  The lambda receives
  ;; the condition object (C) and a stream (S) to print to.
  ;; ~2,'0X formats a number as 2-digit hex with zero-padding.
  (:report (lambda (c s)
             (format s "Illegal/undocumented 6502 opcode #x~2,'0X at PC=#x~4,'0X"
                     (illegal-opcode-opcode c)
                     (illegal-opcode-pc     c)))))

;; DEFVAR only sets the initial value the first time it's loaded, so
;; reloading this file alone (e.g. interactively) does not wipe out
;; opcode handlers DEFOPCODE has already installed from cpu-opcodes.lisp
;; or illegal.lisp.  The array is allocated here, at cpu.lisp load time,
;; so it exists as soon as this file loads — DEFOPCODE (in the later
;; files) writes directly into it via SVREF, with no intermediate
;; "builder" array and no final bulk install.  This means reloading just
;; cpu-opcodes.lisp (without illegal.lisp) no longer silently drops the
;; 105 illegal-opcode handlers: each file's DEFOPCODE forms only ever
;; touch their own slots.
(defvar *opcode-table* (make-array 256 :initial-element nil)
  "256-entry SIMPLE-VECTOR populated by DEFOPCODE forms in
src/cpu-opcodes.lisp and src/illegal.lisp as those files load.  Each
element is either NIL (illegal opcode with no handler defined) or a
function of one argument (CPU) that returns the number of cycles
consumed.")

(defvar *opcode-mnemonic-table* (make-array 256 :initial-element nil)
  "Parallel to *OPCODE-TABLE*: stores the mnemonic string (e.g.
\"LDA-IMM\") for each installed opcode, populated by DEFOPCODE forms in
src/cpu-opcodes.lisp and src/illegal.lisp.  Used by the trace /
disassembly helpers.")

(declaim (ftype (function (cpu) fixnum) step-cpu))

(defun step-cpu (cpu)
  "Execute one instruction, returning the number of cycles consumed.
Services pending NMI/IRQ before fetching the next opcode.

The CPU's bus hooks must already be wired — either by the machine
constructor, or via ATTACH-MEMORY-BUS / RESET-CPU for a bare CPU.

Interrupt priority: NMI first (it's non-maskable), then IRQ (only if
the I flag is clear).  If neither is pending, fetch and execute the
next opcode from the dispatch table."
  (declare (type cpu cpu))
  ;; COND evaluates each test in order; the first true branch executes.
  (cond
    ;; NMI has highest priority (non-maskable).
    ((cpu-pending-nmi cpu)
     (service-nmi cpu)
     7)
    ;; IRQ fires only when the I (interrupt disable) flag is clear.
    ((and (cpu-pending-irq cpu) (not (flag-set-p cpu +flag-i+)))
     (service-irq cpu)
     7)
    ;; Normal instruction execution.
    (t
     (let* ((pc-at-fetch (cpu-pc cpu))
            (opcode (read-pc-byte cpu))     ; fetch opcode byte, advance PC
            ;; SVREF accesses an element of a simple-vector by index.
            ;; *OPCODE-TABLE* always exists (allocated at cpu.lisp load
            ;; time); a NIL slot means no DEFOPCODE has claimed this
            ;; opcode number yet.
            (handler (svref *opcode-table* opcode)))
       ;; UNLESS is (WHEN (NOT ...)).  If no handler, it's an illegal opcode.
       (unless handler
         (setf (cpu-halted cpu) t)
         ;; ERROR signals a condition.  The keyword arguments fill the
         ;; slots defined by DEFINE-CONDITION above.
         (error 'illegal-opcode :opcode opcode :pc pc-at-fetch))
       ;; Call the handler function; it returns the number of cycles consumed.
       (let ((cycles (funcall handler cpu)))
         (incf (cpu-cycles cpu) cycles)
         cycles)))))

(defun run-cpu (cpu &key (cycles 0))
  "Run the CPU.

If CYCLES is 0, execute exactly one instruction and return its cycle
count.  Otherwise run until at least CYCLES cycles have elapsed since
this call began, returning the total cycles executed during the call.

Like STEP-CPU, this expects the bus hooks to be wired already (see
ATTACH-MEMORY-BUS / RESET-CPU)."
  (declare (type cpu cpu))
  (if (zerop cycles)
      (step-cpu cpu)
      ;; LOOP WHILE ... DO ... is CL's structured while-loop.
      (let ((target (+ (cpu-cycles cpu) cycles))
            (start  (cpu-cycles cpu)))
        (loop while (< (cpu-cycles cpu) target)
              do (step-cpu cpu))
        (- (cpu-cycles cpu) start))))
