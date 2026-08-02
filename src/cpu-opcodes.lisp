;;;; src/cpu-opcodes.lisp --- NMOS 6502 opcode dispatch table.
;;;;
;;;; All 151 documented NMOS 6502 instructions are installed here.  The
;;;; result is *OPCODE-TABLE*, a 256-entry SIMPLE-VECTOR whose elements
;;;; are either NIL (illegal/undocumented opcode) or a function
;;;; (LAMBDA (CPU) -> CYCLES).
;;;;
;;;; Cycle counts follow the standard NMOS reference (e.g. masswerk's
;;;; opcode table): the base is encoded directly, and the +1 page-cross
;;;; or +1/+2 branch-cross penalty is added at runtime.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; This file makes heavy use of CL's macro system to avoid writing 151
;;;; nearly-identical opcode handler functions by hand.  The key constructs:
;;;;
;;;; DEFMACRO defines a macro — a function that runs at compile time and
;;;; produces code.  When the compiler encounters a macro call, it calls
;;;; the macro function, which returns a new Lisp form that replaces the
;;;; original.  This is called "macro expansion".
;;;;
;;;; MACROLET defines macros that are local to a block of code (like
;;;; FLET/LABELS for functions, but for macros).  We use MACROLET so the
;;;; helper macros (LOAD-OP, STORE-OP, etc.) are only visible within the
;;;; block of opcode definitions that need them, keeping the namespace clean.
;;;;
;;;; Backquote templates (` , ,@):
;;;;   `(foo ,x ,@body) is a code template that:
;;;;   - keeps FOO literally
;;;;   - inserts the value of X with ,
;;;;   - splices the list BODY with ,@
;;;;   Example: if X=3 and BODY=(a b), result is (FOO 3 A B).
;;;;
;;;; #'SYMBOL (or (FUNCTION SYMBOL)) gets the function object bound to
;;;; SYMBOL.  Used here as #'ADDR-ABSOLUTE to pass an addressing-mode
;;;; function as a value.
;;;;
;;;; MULTIPLE-VALUE-BIND receives multiple return values from a function.
;;;; For example, the addressing-mode functions return two values
;;;; (address, page-crossed-p), and we bind both with:
;;;;   (multiple-value-bind (addr xpage-p) (addr-absolute-x cpu) ...)
;;;;
;;;; (DECLARE (IGNORABLE CROSSED-P)) tells the compiler not to warn if CROSSED-P
;;;; is unused.  This is needed because the macro generates the same
;;;; MULTIPLE-VALUE-BIND for all addressing modes, but not all modes
;;;; produce a meaningful page-cross value.
;;;;
;;;; EVAL-WHEN controls when code is evaluated:
;;;;   :COMPILE-TOPLEVEL — when compiling this file
;;;;   :LOAD-TOPLEVEL    — when loading the compiled file
;;;;   :EXECUTE          — when evaluating at the REPL
;;;; We need all three so that helper functions used by macros are
;;;; available in every scenario.
;;;;
;;;; INTERN creates or finds a symbol in a package.  We use it to build
;;;; function names like OPCODE-LDA-IMM-A9 from strings at macro-expansion
;;;; time, so each opcode gets a descriptive function name.

(in-package #:atari800-cl.cpu)

;;; Hot-path optimize policy (PERFORMANCE_PLAN.md Phase 1).  See the
;;; matching declaim in src/bus.lisp for the note on DECLAIM's proclaiming
;;; behaviour under :serial t; repeated here so this file's policy survives
;;; interactive recompilation on its own.
(declaim (optimize (speed 3) (safety 1) (debug 1)))

;;; ---------------------------------------------------------------------------
;;; Common arithmetic / load / store helpers
;;;
;;; These functions implement the core ALU (Arithmetic Logic Unit) operations
;;; shared across multiple opcodes.  Each opcode handler calls the appropriate
;;; helper rather than duplicating the logic.

(declaim (inline read-via write-via))

(defun read-via (cpu mode)
  "Apply addressing MODE to CPU; return (VALUES VALUE PAGE-CROSSED? EFFECTIVE-ADDR).
MODE is a function like #'ADDR-ABSOLUTE-X.  We call it to get the effective
address, then read the byte at that address."
  (declare (type cpu cpu) (type function mode))
  ;; FUNCALL is needed because MODE is a function passed as a value.
  (multiple-value-bind (addr xpage-p) (funcall mode cpu)
    (values (cpu-read-byte cpu addr) xpage-p addr)))

;;; --- ADC (Add with Carry) ---
;;;
;;; The 6502 ADC supports both binary and BCD (Binary-Coded Decimal) mode.
;;; The D flag selects which mode is active.  BCD mode treats each nibble
;;; (4 bits) as a decimal digit (0–9), so the byte #x42 represents "42".
;;; The NMOS 6502's BCD behaviour has well-documented quirks: the Z flag is
;;; set from the binary sum, while N and V reflect the decimal-corrected
;;; high nibble.

(defun do-adc (cpu value)
  "Perform ADC: A = A + VALUE + Carry.  Updates A, C, Z, N, V flags."
  (let* ((a (cpu-a cpu))
         (c (if (flag-set-p cpu +flag-c+) 1 0)))
    (cond
      ;; BCD (decimal) mode
      ((flag-set-p cpu +flag-d+)
       (let* ((bin (ldb (byte 8 0) (+ a value c)))  ; binary sum for Z flag
              ;; Low nibble: add the two low nibbles and carry
              (lo  (+ (ldb (byte 4 0) a) (ldb (byte 4 0) value) c))
              (lo-carry (if (> lo 9) 1 0))         ; decimal carry from low nibble
              (lo-final (ldb (byte 4 0) (if (> lo 9) (+ lo 6) lo)))  ; BCD correction
              ;; High nibble: add the two high nibbles and carry from low
              (hi  (+ (ldb (byte 4 4) a) (ldb (byte 4 4) value) lo-carry))
              (hi-carry (if (> hi 9) 1 0))
              (hi-final (ldb (byte 4 0) (if (> hi 9) (+ hi 6) hi)))
              (result (dpb hi-final (byte 4 4) lo-final))
              ;; N and V come from the high nibble's pre-correction sign.
              (signed-hi (ldb (byte 8 0) (+ (logand a #xF0)
                                            (logand value #xF0)
                                            (ash lo-carry 4)))))
         (set-flag-to cpu +flag-z+ (zerop bin))
         (set-flag-to cpu +flag-n+ (logtest signed-hi #x80))
         (set-flag-to cpu +flag-v+
                      ;; Overflow: operands have same sign, result has different sign
                      (and (not (logtest (logxor a value) #x80))
                           (logtest (logxor a signed-hi) #x80)))
         (set-flag-to cpu +flag-c+ (= 1 hi-carry))
         (setf (cpu-a cpu) result)))
      ;; Binary (normal) mode
      (t
       (let* ((sum (+ a value c))
              (result (ldb (byte 8 0) sum)))  ; wrap to 8 bits
         (set-flag-to cpu +flag-c+ (> sum #xFF))   ; carry if sum > 255
         (set-flag-to cpu +flag-v+
                      ;; Overflow: same-sign operands produce different-sign result
                      (and (not (logtest (logxor a value) #x80))
                           (logtest (logxor a result) #x80)))
         (update-zn cpu result)
         (setf (cpu-a cpu) result))))))

;;; --- SBC (Subtract with Carry) ---
;;;
;;; SBC performs A = A - VALUE - (1 - Carry).  The carry flag acts as
;;; an inverted borrow: C=1 means no borrow, C=0 means borrow.

(defun do-sbc (cpu value)
  "Perform SBC: A = A - VALUE - (1 - Carry).  Updates A, C, Z, N, V flags."
  (let* ((a (cpu-a cpu))
         (c (if (flag-set-p cpu +flag-c+) 1 0)))
    (cond
      ;; BCD (decimal) mode
      ((flag-set-p cpu +flag-d+)
       ;; NMOS BCD subtraction: flags Z/N/V/C are set from the binary
       ;; calculation; only the result digits are decimal-corrected.
       (let* ((bin (ldb (byte 16 0) (- a value (- 1 c))))
              (binary-result (ldb (byte 8 0) bin)))
         (set-flag-to cpu +flag-c+ (not (logtest bin #x100)))
         (set-flag-to cpu +flag-v+
                      (and (logtest (logxor a value) #x80)
                           (logtest (logxor a binary-result) #x80)))
         (update-zn cpu binary-result)
         ;; Decimal correction of the result digits
         (let* ((lo (- (ldb (byte 4 0) a) (ldb (byte 4 0) value) (- 1 c)))
                (hi (- (logand a #xF0) (logand value #xF0)))
                (lo2 (if (minusp lo) (- lo 6) lo))        ; MINUSP tests < 0
                (hi2 (if (minusp lo) (- hi #x10) hi))     ; borrow from low nibble
                (hi3 (if (minusp hi2) (- hi2 #x60) hi2))  ; borrow from high nibble
                (result (ldb (byte 8 0) (logior (ldb (byte 4 0) lo2)
                                                (logand hi3 #xF0)))))
           (setf (cpu-a cpu) result))))
      ;; Binary (normal) mode
      (t
       (let* ((diff (- a value (- 1 c)))
              (result (ldb (byte 8 0) diff)))
         (set-flag-to cpu +flag-c+ (>= diff 0))     ; C=1 if no borrow
         (set-flag-to cpu +flag-v+
                      (and (logtest (logxor a value) #x80)
                           (logtest (logxor a result) #x80)))
         (update-zn cpu result)
         (setf (cpu-a cpu) result))))))

;;; --- Compare ---

(defun do-cmp (cpu reg-value mem-value)
  "Compare REG-VALUE with MEM-VALUE: set C if reg >= mem, update Z and N."
  (set-flag-to cpu +flag-c+ (>= reg-value mem-value))
  ;; UPDATE-ZN wraps its argument to 8 bits itself.
  (update-zn cpu (- reg-value mem-value)))

;;; --- Shifts and rotates ---
;;;
;;; Each returns the shifted/rotated 8-bit result and updates C, Z, N.
;;; ASH (Arithmetic SHift) with a positive count shifts left, negative shifts right.

(defun do-asl (value cpu)
  "Arithmetic Shift Left: shift VALUE left by 1, old bit 7 goes to Carry."
  (let* ((c (logtest value #x80))                  ; old bit 7 becomes carry
         (r (ldb (byte 8 0) (ash value 1))))        ; shift left, wrap to 8 bits
    (set-flag-to cpu +flag-c+ c)
    (update-zn cpu r)
    r))

(defun do-lsr (value cpu)
  "Logical Shift Right: shift VALUE right by 1, old bit 0 goes to Carry."
  (let* ((c (logtest value #x01))                  ; old bit 0 becomes carry
         (r (ldb (byte 8 0) (ash value -1))))       ; shift right, wrap to 8 bits
    (set-flag-to cpu +flag-c+ c)
    (update-zn cpu r)
    r))

(defun do-rol (value cpu)
  "Rotate Left: shift left, old Carry enters bit 0, old bit 7 exits to Carry."
  (let* ((cin (if (flag-set-p cpu +flag-c+) 1 0))  ; current carry becomes bit 0
         (cout (logtest value #x80))                ; old bit 7 becomes new carry
         (r (ldb (byte 8 0) (logior (ash value 1) cin))))
    (set-flag-to cpu +flag-c+ cout)
    (update-zn cpu r)
    r))

(defun do-ror (value cpu)
  "Rotate Right: shift right, old Carry enters bit 7, old bit 0 exits to Carry."
  (let* ((cin (if (flag-set-p cpu +flag-c+) #x80 0)) ; current carry becomes bit 7
         (cout (logtest value #x01))                  ; old bit 0 becomes new carry
         (r (ldb (byte 8 0) (logior (ash value -1) cin))))
    (set-flag-to cpu +flag-c+ cout)
    (update-zn cpu r)
    r))

;;; ---------------------------------------------------------------------------
;;; Branch helper
;;;
;;; All 6502 branch instructions share the same cycle-counting rules:
;;;   Base:     2 cycles (opcode + offset byte)
;;;   Taken:   +1 cycle
;;;   Page cross: +1 more cycle (if the branch target is on a different page)

(defun do-branch (cpu condition)
  "Execute a conditional branch.  CONDITION is a boolean: if true, branch
to the relative target; if false, skip (the offset byte was already consumed
by ADDR-RELATIVE).  Returns the number of cycles consumed."
  (multiple-value-bind (target) (addr-relative cpu)
    (cond
      ((not condition) 2)                ; not taken: 2 cycles
      (t
       (let* ((before (cpu-pc cpu))
              ;; 2 (base) + 1 (taken) + 1 if page crossed
              (cycles (+ 2 1 (if (page-crossed-p before target) 1 0))))
         (setf (cpu-pc cpu) target)
         cycles)))))

;;; ---------------------------------------------------------------------------
;;; Opcode table construction
;;;
;;; DEFOPCODE is the central macro: it defines a named function for each
;;; opcode and installs it directly into *OPCODE-TABLE* (defined in
;;; cpu.lisp, which loads before this file).  Named functions are
;;; preferable to anonymous lambdas because they show up in backtraces
;;; and can be inspected in a debugger.

;; EVAL-WHEN ensures this helper function exists at compile time, because
;; DEFOPCODE (a macro) calls it during macro expansion (which happens at
;; compile time).  Without EVAL-WHEN, the function wouldn't exist yet when
;; the compiler tries to expand the macro.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %opcode-handler-name (opcode mnemonic)
    "Build a symbol like OPCODE-LDA-IMM-A9 for an opcode handler function.
The % prefix is a CL convention for internal/private helper functions."
    ;; INTERN creates or finds a symbol in a package.
    ;; FORMAT builds the string; ~A inserts human-readable, ~2,'0X inserts
    ;; as 2-digit zero-padded hex.
    (intern (format nil "OPCODE-~A-~2,'0X"
                    (string-upcase (string mnemonic))
                    opcode)
            :atari800-cl.cpu)))

(defmacro defopcode (opcode mnemonic lambda-list &body body)
  "Define a named handler for OPCODE and install it in the dispatch table.

MNEMONIC is a symbol (e.g. LDA-IMM, BRK, JMP-IND) used to build a stable
function name like OPCODE-LDA-IMM-A9, so each opcode shows up in
backtraces and can be looked up from a disassembler/debugger.

The macro expands into:
  1. A DEFUN that defines the named handler function
  2. A SETF that installs the function into the dispatch table
  3. A quoted symbol name (the return value of the PROGN)"
  (let ((fn-name (%opcode-handler-name opcode mnemonic)))
    ;; The backquote builds code at compile time:
    ;;   ,FN-NAME inserts the computed function name
    ;;   ,LAMBDA-LIST inserts the parameter list
    ;;   ,@BODY splices the handler body forms
    ;;   ,OPCODE inserts the opcode number
    ;;   #'... gets the function object for the SETF
    `(progn
       (defun ,fn-name ,lambda-list ,@body)
       (setf (svref *opcode-table* ,opcode) (function ,fn-name)
             (svref *opcode-mnemonic-table* ,opcode)
             ,(string-upcase (string mnemonic)))
       ',fn-name)))

;; Another EVAL-WHEN helper: converts addressing-mode function names to
;; short suffixes for building human-readable opcode handler names.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %mode->suffix (mode)
    "Turn an addr-mode symbol like ADDR-ABSOLUTE-X into a short tag (ABSX).
Used by the family macrolets to auto-generate descriptive function names."
    ;; SYMBOL-NAME returns the string name of a symbol.
    ;; STRING= compares strings (case-sensitive).
    (let ((s (symbol-name mode)))
      (cond
        ((string= s "ADDR-IMMEDIATE")        "IMM")
        ((string= s "ADDR-ZERO-PAGE")        "ZP")
        ((string= s "ADDR-ZERO-PAGE-X")      "ZPX")
        ((string= s "ADDR-ZERO-PAGE-Y")      "ZPY")
        ((string= s "ADDR-ABSOLUTE")         "ABS")
        ((string= s "ADDR-ABSOLUTE-X")       "ABSX")
        ((string= s "ADDR-ABSOLUTE-Y")       "ABSY")
        ((string= s "ADDR-INDIRECT")         "IND")
        ((string= s "ADDR-INDEXED-INDIRECT") "INDX")
        ((string= s "ADDR-INDIRECT-INDEXED") "INDY")
        ((string= s "ADDR-RELATIVE")         "REL")
        (t (string-upcase s))))))

;;; ===========================================================================
;;; LDA / LDX / LDY
;;; ===========================================================================
;;;
;;; MACROLET defines a local macro LOAD-OP visible only within this block.
;;; Each invocation of LOAD-OP expands into a DEFOPCODE call for one
;;; addressing mode of the load instruction.
;;;
;;; Parameters:
;;;   MNEMONIC   — "LDA", "LDX", or "LDY" (for naming)
;;;   REG        — the accessor function (CPU-A, CPU-X, or CPU-Y)
;;;   OP         — the opcode byte (e.g. #xA9 for LDA immediate)
;;;   MODE       — the addressing-mode function (e.g. ADDR-IMMEDIATE)
;;;   BASE       — base cycle count
;;;   :PAGE-CROSS — if T, add +1 cycle when the effective address crosses
;;;                 a page boundary

(macrolet ((load-op (mnemonic reg op mode base &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val crossed-p) (read-via cpu #',mode)
                    (declare (ignorable crossed-p))
                    ;; Set the target register and update Z/N flags
                    (setf (,reg cpu) (update-zn cpu val))
                    ;; Return cycle count, adding 1 if page crossed
                    (+ ,base ,(if page-cross '(if crossed-p 1 0) 0)))))))
  ;; LDA — Load Accumulator (8 addressing modes)
  (load-op "LDA" cpu-a #xA9 addr-immediate         2)
  (load-op "LDA" cpu-a #xA5 addr-zero-page         3)
  (load-op "LDA" cpu-a #xB5 addr-zero-page-x       4)
  (load-op "LDA" cpu-a #xAD addr-absolute          4)
  (load-op "LDA" cpu-a #xBD addr-absolute-x        4 :page-cross t)
  (load-op "LDA" cpu-a #xB9 addr-absolute-y        4 :page-cross t)
  (load-op "LDA" cpu-a #xA1 addr-indexed-indirect  6)
  (load-op "LDA" cpu-a #xB1 addr-indirect-indexed  5 :page-cross t)
  ;; LDX — Load X Register (5 addressing modes)
  (load-op "LDX" cpu-x #xA2 addr-immediate    2)
  (load-op "LDX" cpu-x #xA6 addr-zero-page    3)
  (load-op "LDX" cpu-x #xB6 addr-zero-page-y  4)
  (load-op "LDX" cpu-x #xAE addr-absolute     4)
  (load-op "LDX" cpu-x #xBE addr-absolute-y   4 :page-cross t)
  ;; LDY — Load Y Register (5 addressing modes)
  (load-op "LDY" cpu-y #xA0 addr-immediate    2)
  (load-op "LDY" cpu-y #xA4 addr-zero-page    3)
  (load-op "LDY" cpu-y #xB4 addr-zero-page-x  4)
  (load-op "LDY" cpu-y #xAC addr-absolute     4)
  (load-op "LDY" cpu-y #xBC addr-absolute-x   4 :page-cross t))

;;; ===========================================================================
;;; STA / STX / STY (no page-cross penalty for stores)
;;; ===========================================================================
;;;
;;; Store instructions always take the same number of cycles regardless of
;;; page crossing, which is why STORE-OP has no :PAGE-CROSS parameter.

(macrolet ((store-op (mnemonic reg op mode base)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (addr) (,mode cpu)
                    (cpu-write-byte cpu addr (,reg cpu))
                    ,base)))))
  ;; STA — Store Accumulator
  (store-op "STA" cpu-a #x85 addr-zero-page         3)
  (store-op "STA" cpu-a #x95 addr-zero-page-x       4)
  (store-op "STA" cpu-a #x8D addr-absolute          4)
  (store-op "STA" cpu-a #x9D addr-absolute-x        5)
  (store-op "STA" cpu-a #x99 addr-absolute-y        5)
  (store-op "STA" cpu-a #x81 addr-indexed-indirect  6)
  (store-op "STA" cpu-a #x91 addr-indirect-indexed  6)
  ;; STX — Store X Register
  (store-op "STX" cpu-x #x86 addr-zero-page    3)
  (store-op "STX" cpu-x #x96 addr-zero-page-y  4)
  (store-op "STX" cpu-x #x8E addr-absolute     4)
  ;; STY — Store Y Register
  (store-op "STY" cpu-y #x84 addr-zero-page    3)
  (store-op "STY" cpu-y #x94 addr-zero-page-x  4)
  (store-op "STY" cpu-y #x8C addr-absolute     4))

;;; ===========================================================================
;;; Register transfers (TAX/TAY/TXA/TYA/TSX/TXS)
;;; ===========================================================================
;;;
;;; All transfer instructions copy one register to another and update Z/N,
;;; except TXS which copies X to SP without touching flags.

(defopcode #xAA tax (cpu) (setf (cpu-x cpu) (update-zn cpu (cpu-a cpu))) 2)
(defopcode #xA8 tay (cpu) (setf (cpu-y cpu) (update-zn cpu (cpu-a cpu))) 2)
(defopcode #x8A txa (cpu) (setf (cpu-a cpu) (update-zn cpu (cpu-x cpu))) 2)
(defopcode #x98 tya (cpu) (setf (cpu-a cpu) (update-zn cpu (cpu-y cpu))) 2)
(defopcode #xBA tsx (cpu) (setf (cpu-x cpu) (update-zn cpu (cpu-sp cpu))) 2)
(defopcode #x9A txs (cpu) (setf (cpu-sp cpu) (cpu-x cpu)) 2)  ; no flag update!

;;; ===========================================================================
;;; Stack ops
;;; ===========================================================================
;;;
;;; PHA/PHP push a value; PLA/PLP pull a value.  PLP restores the flags
;;; register, but always forces U=1 and B=0 (the B flag only exists on
;;; the stack, not as a real register bit).

(defopcode #x48 pha (cpu) (push-byte cpu (cpu-a cpu)) 3)
(defopcode #x08 php (cpu) (push-byte cpu (status-byte-for-push cpu :b-flag t)) 3)
(defopcode #x68 pla (cpu) (setf (cpu-a cpu) (update-zn cpu (pull-byte cpu))) 4)
(defopcode #x28 plp (cpu)
  (setf (cpu-flags cpu) (status-byte-from-pull (pull-byte cpu)))
  4)

;;; ===========================================================================
;;; Logical ops: AND, ORA, EOR, BIT
;;; ===========================================================================
;;;
;;; AND/ORA/EOR perform bitwise operations between A and a memory value,
;;; storing the result back in A.  The LOGICAL macrolet generates all
;;; addressing-mode variants; REDUCE is the CL bitwise function to use
;;; (LOGAND, LOGIOR, or LOGXOR).

(macrolet ((logical (mnemonic op mode base reduce &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val crossed-p) (read-via cpu #',mode)
                    (declare (ignorable crossed-p))
                    (setf (cpu-a cpu)
                          (update-zn cpu (,reduce (cpu-a cpu) val)))
                    (+ ,base ,(if page-cross '(if crossed-p 1 0) 0)))))))
  ;; AND — bitwise AND with accumulator
  (logical "AND" #x29 addr-immediate         2 logand)
  (logical "AND" #x25 addr-zero-page         3 logand)
  (logical "AND" #x35 addr-zero-page-x       4 logand)
  (logical "AND" #x2D addr-absolute          4 logand)
  (logical "AND" #x3D addr-absolute-x        4 logand :page-cross t)
  (logical "AND" #x39 addr-absolute-y        4 logand :page-cross t)
  (logical "AND" #x21 addr-indexed-indirect  6 logand)
  (logical "AND" #x31 addr-indirect-indexed  5 logand :page-cross t)
  ;; ORA — bitwise OR with accumulator
  (logical "ORA" #x09 addr-immediate         2 logior)
  (logical "ORA" #x05 addr-zero-page         3 logior)
  (logical "ORA" #x15 addr-zero-page-x       4 logior)
  (logical "ORA" #x0D addr-absolute          4 logior)
  (logical "ORA" #x1D addr-absolute-x        4 logior :page-cross t)
  (logical "ORA" #x19 addr-absolute-y        4 logior :page-cross t)
  (logical "ORA" #x01 addr-indexed-indirect  6 logior)
  (logical "ORA" #x11 addr-indirect-indexed  5 logior :page-cross t)
  ;; EOR — bitwise exclusive OR with accumulator
  (logical "EOR" #x49 addr-immediate         2 logxor)
  (logical "EOR" #x45 addr-zero-page         3 logxor)
  (logical "EOR" #x55 addr-zero-page-x       4 logxor)
  (logical "EOR" #x4D addr-absolute          4 logxor)
  (logical "EOR" #x5D addr-absolute-x        4 logxor :page-cross t)
  (logical "EOR" #x59 addr-absolute-y        4 logxor :page-cross t)
  (logical "EOR" #x41 addr-indexed-indirect  6 logxor)
  (logical "EOR" #x51 addr-indirect-indexed  5 logxor :page-cross t))

;;; --- BIT (test bits) ---
;;; BIT is unusual: it sets Z from (A AND memory), but N and V come directly
;;; from bits 7 and 6 of the memory value (not the AND result).

(macrolet ((bit-op (op mode base)
             (let ((tag (intern (format nil "BIT-~A" (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val) (read-via cpu #',mode)
                    (set-flag-to cpu +flag-z+ (not (logtest (cpu-a cpu) val)))
                    (set-flag-to cpu +flag-n+ (logtest val #x80))
                    (set-flag-to cpu +flag-v+ (logtest val #x40))
                    ,base)))))
  (bit-op #x24 addr-zero-page  3)
  (bit-op #x2C addr-absolute   4))

;;; ===========================================================================
;;; ADC / SBC
;;; ===========================================================================
;;;
;;; The ARITH macrolet generates all addressing-mode variants of ADC and SBC.
;;; DOER is the helper function to call (DO-ADC or DO-SBC).

(macrolet ((arith (mnemonic doer op mode base &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val crossed-p) (read-via cpu #',mode)
                    (declare (ignorable crossed-p))
                    (,doer cpu val)
                    (+ ,base ,(if page-cross '(if crossed-p 1 0) 0)))))))
  ;; ADC — Add with Carry
  (arith "ADC" do-adc #x69 addr-immediate         2)
  (arith "ADC" do-adc #x65 addr-zero-page         3)
  (arith "ADC" do-adc #x75 addr-zero-page-x       4)
  (arith "ADC" do-adc #x6D addr-absolute          4)
  (arith "ADC" do-adc #x7D addr-absolute-x        4 :page-cross t)
  (arith "ADC" do-adc #x79 addr-absolute-y        4 :page-cross t)
  (arith "ADC" do-adc #x61 addr-indexed-indirect  6)
  (arith "ADC" do-adc #x71 addr-indirect-indexed  5 :page-cross t)
  ;; SBC — Subtract with Carry (borrow)
  (arith "SBC" do-sbc #xE9 addr-immediate         2)
  (arith "SBC" do-sbc #xE5 addr-zero-page         3)
  (arith "SBC" do-sbc #xF5 addr-zero-page-x       4)
  (arith "SBC" do-sbc #xED addr-absolute          4)
  (arith "SBC" do-sbc #xFD addr-absolute-x        4 :page-cross t)
  (arith "SBC" do-sbc #xF9 addr-absolute-y        4 :page-cross t)
  (arith "SBC" do-sbc #xE1 addr-indexed-indirect  6)
  (arith "SBC" do-sbc #xF1 addr-indirect-indexed  5 :page-cross t))

;;; ===========================================================================
;;; Compares: CMP / CPX / CPY
;;; ===========================================================================
;;;
;;; Compare instructions subtract without storing the result; they only
;;; update C, Z, and N flags.

(macrolet ((cmp-op (mnemonic reg op mode base &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val crossed-p) (read-via cpu #',mode)
                    (declare (ignorable crossed-p))
                    (do-cmp cpu (,reg cpu) val)
                    (+ ,base ,(if page-cross '(if crossed-p 1 0) 0)))))))
  ;; CMP — Compare with Accumulator
  (cmp-op "CMP" cpu-a #xC9 addr-immediate         2)
  (cmp-op "CMP" cpu-a #xC5 addr-zero-page         3)
  (cmp-op "CMP" cpu-a #xD5 addr-zero-page-x       4)
  (cmp-op "CMP" cpu-a #xCD addr-absolute          4)
  (cmp-op "CMP" cpu-a #xDD addr-absolute-x        4 :page-cross t)
  (cmp-op "CMP" cpu-a #xD9 addr-absolute-y        4 :page-cross t)
  (cmp-op "CMP" cpu-a #xC1 addr-indexed-indirect  6)
  (cmp-op "CMP" cpu-a #xD1 addr-indirect-indexed  5 :page-cross t)
  ;; CPX — Compare with X Register
  (cmp-op "CPX" cpu-x #xE0 addr-immediate  2)
  (cmp-op "CPX" cpu-x #xE4 addr-zero-page  3)
  (cmp-op "CPX" cpu-x #xEC addr-absolute   4)
  ;; CPY — Compare with Y Register
  (cmp-op "CPY" cpu-y #xC0 addr-immediate  2)
  (cmp-op "CPY" cpu-y #xC4 addr-zero-page  3)
  (cmp-op "CPY" cpu-y #xCC addr-absolute   4))

;;; ===========================================================================
;;; Inc / Dec memory and registers
;;; ===========================================================================
;;;
;;; INC/DEC are read-modify-write (RMW) instructions: they read a memory
;;; byte, modify it, and write it back.  INX/INY/DEX/DEY operate on
;;; registers instead.

(macrolet ((memop (mnemonic delta op mode base)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (addr) (,mode cpu)
                    (let ((v (ldb (byte 8 0)
                                  (+ (cpu-read-byte cpu addr) ,delta))))
                      (cpu-write-byte cpu addr v)
                      (update-zn cpu v))
                    ,base)))))
  ;; INC — Increment Memory
  (memop "INC"  1 #xE6 addr-zero-page    5)
  (memop "INC"  1 #xF6 addr-zero-page-x  6)
  (memop "INC"  1 #xEE addr-absolute     6)
  (memop "INC"  1 #xFE addr-absolute-x   7)
  ;; DEC — Decrement Memory
  (memop "DEC" -1 #xC6 addr-zero-page    5)
  (memop "DEC" -1 #xD6 addr-zero-page-x  6)
  (memop "DEC" -1 #xCE addr-absolute     6)
  (memop "DEC" -1 #xDE addr-absolute-x   7))

;; Register increment/decrement: 1+ and 1- are arithmetic (return a new
;; value), not mutation; UPDATE-ZN masks to 8 bits and sets flags.
(defopcode #xE8 inx (cpu) (setf (cpu-x cpu) (update-zn cpu (1+ (cpu-x cpu)))) 2)
(defopcode #xC8 iny (cpu) (setf (cpu-y cpu) (update-zn cpu (1+ (cpu-y cpu)))) 2)
(defopcode #xCA dex (cpu) (setf (cpu-x cpu) (update-zn cpu (1- (cpu-x cpu)))) 2)
(defopcode #x88 dey (cpu) (setf (cpu-y cpu) (update-zn cpu (1- (cpu-y cpu)))) 2)

;;; ===========================================================================
;;; Shifts and rotates
;;; ===========================================================================
;;;
;;; Accumulator variants operate directly on A.  Memory variants use the
;;; RMW macrolet: read from memory, apply the shift/rotate, write back.

(defopcode #x0A asl-a (cpu) (setf (cpu-a cpu) (do-asl (cpu-a cpu) cpu)) 2)
(defopcode #x4A lsr-a (cpu) (setf (cpu-a cpu) (do-lsr (cpu-a cpu) cpu)) 2)
(defopcode #x2A rol-a (cpu) (setf (cpu-a cpu) (do-rol (cpu-a cpu) cpu)) 2)
(defopcode #x6A ror-a (cpu) (setf (cpu-a cpu) (do-ror (cpu-a cpu) cpu)) 2)

(macrolet ((rmw (mnemonic op mode base op-fn)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (addr) (,mode cpu)
                    (let* ((v (cpu-read-byte cpu addr))    ; read
                           (r (,op-fn v cpu)))             ; modify
                      (cpu-write-byte cpu addr r))         ; write
                    ,base)))))
  ;; ASL — Arithmetic Shift Left (memory)
  (rmw "ASL" #x06 addr-zero-page    5 do-asl)
  (rmw "ASL" #x16 addr-zero-page-x  6 do-asl)
  (rmw "ASL" #x0E addr-absolute     6 do-asl)
  (rmw "ASL" #x1E addr-absolute-x   7 do-asl)
  ;; LSR — Logical Shift Right (memory)
  (rmw "LSR" #x46 addr-zero-page    5 do-lsr)
  (rmw "LSR" #x56 addr-zero-page-x  6 do-lsr)
  (rmw "LSR" #x4E addr-absolute     6 do-lsr)
  (rmw "LSR" #x5E addr-absolute-x   7 do-lsr)
  ;; ROL — Rotate Left (memory)
  (rmw "ROL" #x26 addr-zero-page    5 do-rol)
  (rmw "ROL" #x36 addr-zero-page-x  6 do-rol)
  (rmw "ROL" #x2E addr-absolute     6 do-rol)
  (rmw "ROL" #x3E addr-absolute-x   7 do-rol)
  ;; ROR — Rotate Right (memory)
  (rmw "ROR" #x66 addr-zero-page    5 do-ror)
  (rmw "ROR" #x76 addr-zero-page-x  6 do-ror)
  (rmw "ROR" #x6E addr-absolute     6 do-ror)
  (rmw "ROR" #x7E addr-absolute-x   7 do-ror))

;;; ===========================================================================
;;; Branches
;;; ===========================================================================
;;;
;;; Each branch tests one flag.  If the condition is true, the CPU branches
;;; to a relative offset from PC.  All branch instructions are 2 bytes.

(defopcode #x10 bpl (cpu) (do-branch cpu (not (flag-set-p cpu +flag-n+))))  ; Branch if Positive (N=0)
(defopcode #x30 bmi (cpu) (do-branch cpu (flag-set-p cpu +flag-n+)))        ; Branch if Minus (N=1)
(defopcode #x50 bvc (cpu) (do-branch cpu (not (flag-set-p cpu +flag-v+))))  ; Branch if Overflow Clear
(defopcode #x70 bvs (cpu) (do-branch cpu (flag-set-p cpu +flag-v+)))        ; Branch if Overflow Set
(defopcode #x90 bcc (cpu) (do-branch cpu (not (flag-set-p cpu +flag-c+))))  ; Branch if Carry Clear
(defopcode #xB0 bcs (cpu) (do-branch cpu (flag-set-p cpu +flag-c+)))        ; Branch if Carry Set
(defopcode #xD0 bne (cpu) (do-branch cpu (not (flag-set-p cpu +flag-z+))))  ; Branch if Not Equal (Z=0)
(defopcode #xF0 beq (cpu) (do-branch cpu (flag-set-p cpu +flag-z+)))        ; Branch if Equal (Z=1)

;;; ===========================================================================
;;; Jumps and subroutines
;;; ===========================================================================

(defopcode #x4C jmp-abs (cpu)
  "JMP absolute: set PC to the 16-bit operand."
  (multiple-value-bind (addr) (addr-absolute cpu)
    (setf (cpu-pc cpu) addr))
  3)

(defopcode #x6C jmp-ind (cpu)
  "JMP indirect: read a pointer from the operand address, set PC to the
value found there.  Includes the NMOS page-wrap bug (see ADDR-INDIRECT)."
  (multiple-value-bind (addr) (addr-indirect cpu)
    (setf (cpu-pc cpu) addr))
  5)

(defopcode #x20 jsr (cpu)
  "JSR: push (PC - 1) onto the stack (pointing at the last byte of the
JSR instruction), then jump to the target address.  RTS will pull this
address and add 1 to resume after the JSR."
  (let* ((target (read-pc-word cpu))
         (return-addr (ldb (byte 16 0) (1- (cpu-pc cpu)))))
    (push-word cpu return-addr)
    (setf (cpu-pc cpu) target))
  6)

(defopcode #x60 rts (cpu)
  "RTS: pull the return address from the stack (pushed by JSR) and add 1
to get the actual resume address."
  (let ((addr (pull-word cpu)))
    (setf (cpu-pc cpu) (ldb (byte 16 0) (1+ addr))))
  6)

(defopcode #x40 rti (cpu)
  "RTI: return from interrupt.  Pull the status register and then PC
from the stack (in that order — opposite of how the interrupt pushed them)."
  (setf (cpu-flags cpu) (status-byte-from-pull (pull-byte cpu)))
  (setf (cpu-pc cpu) (pull-word cpu))
  6)

(defopcode #x00 brk (cpu)
  "BRK: software interrupt.  Pushes PC+1 (not PC+2 — the byte after BRK
is a 'signature' byte that the handler can inspect), pushes status with B=1,
sets I flag, and vectors through $FFFE (same as IRQ)."
  (let ((return-pc (ldb (byte 16 0) (1+ (cpu-pc cpu)))))
    (push-word cpu return-pc)
    (push-byte cpu (status-byte-for-push cpu :b-flag t))
    (set-flag cpu +flag-i+)
    (setf (cpu-pc cpu) (cpu-read-word cpu +irq-vector+)))
  7)

;;; ===========================================================================
;;; Flag set/clear
;;; ===========================================================================
;;;
;;; Single-byte instructions that set or clear individual flags.

(defopcode #x18 clc (cpu) (clear-flag cpu +flag-c+) 2)  ; Clear Carry
(defopcode #x38 sec (cpu) (set-flag   cpu +flag-c+) 2)  ; Set Carry
(defopcode #x58 cli (cpu) (clear-flag cpu +flag-i+) 2)  ; Clear Interrupt Disable
(defopcode #x78 sei (cpu) (set-flag   cpu +flag-i+) 2)  ; Set Interrupt Disable
(defopcode #xB8 clv (cpu) (clear-flag cpu +flag-v+) 2)  ; Clear Overflow
(defopcode #xD8 cld (cpu) (clear-flag cpu +flag-d+) 2)  ; Clear Decimal Mode
(defopcode #xF8 sed (cpu) (set-flag   cpu +flag-d+) 2)  ; Set Decimal Mode

;;; ===========================================================================
;;; NOP
;;; ===========================================================================

(defopcode #xEA nop (cpu)
  "NOP: No Operation.  Does nothing for 2 cycles."
  ;; DECLARE IGNORE tells the compiler we intentionally don't use CPU.
  (declare (ignore cpu)) 2)

;;; DOCUMENTED-OPCODES is defined in src/illegal.lisp, after the full
;;; opcode map (documented + 105 NMOS undocumented) has been installed.
;;; It filters *OPCODE-TABLE* against *ILLEGAL-OPCODE-LIST* to return
;;; just the 151 officially documented entries.
