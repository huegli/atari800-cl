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

(in-package #:atari800-cl.cpu)

;;; ---------------------------------------------------------------------------
;;; Common arithmetic / load / store helpers

(declaim (inline read-via write-via))

(defun read-via (cpu mode)
  "Apply MODE to CPU; return (VALUES VALUE PAGE-CROSSED? EFFECTIVE-ADDR)."
  (multiple-value-bind (addr xpage?) (funcall mode cpu)
    (values (cpu-read-byte cpu addr) xpage? addr)))

(defun do-adc (cpu value)
  (let* ((a (cpu-a cpu))
         (c (if (flag-set? cpu +flag-c+) 1 0)))
    (cond
      ((flag-set? cpu +flag-d+)
       ;; NMOS BCD ADC.  The Z flag is set from the binary sum; N and V
       ;; reflect the decimal-corrected high nibble.
       (let* ((bin (logand (+ a value c) #xFF))
              (lo  (+ (logand a #x0F) (logand value #x0F) c))
              (lo-carry (if (> lo 9) 1 0))
              (lo-final (logand (if (> lo 9) (+ lo 6) lo) #x0F))
              (hi  (+ (ash a -4) (ash value -4) lo-carry))
              (hi-carry (if (> hi 9) 1 0))
              (hi-final (logand (if (> hi 9) (+ hi 6) hi) #x0F))
              (result (logior (ash hi-final 4) lo-final))
              ;; N and V come from the high nibble's pre-correction sign.
              (signed-hi (logand (ash (+ (logand a #xF0)
                                         (logand value #xF0)
                                         (ash lo-carry 4))
                                      0)
                                 #xFF)))
         (set-flag-to cpu +flag-z+ (zerop bin))
         (set-flag-to cpu +flag-n+ (not (zerop (logand signed-hi #x80))))
         (set-flag-to cpu +flag-v+
                      (and (zerop (logand (logxor a value) #x80))
                           (not (zerop (logand (logxor a signed-hi) #x80)))))
         (set-flag-to cpu +flag-c+ (= 1 hi-carry))
         (setf (cpu-a cpu) result)))
      (t
       (let* ((sum (+ a value c))
              (result (logand sum #xFF)))
         (set-flag-to cpu +flag-c+ (> sum #xFF))
         (set-flag-to cpu +flag-v+
                      (and (zerop (logand (logxor a value) #x80))
                           (not (zerop (logand (logxor a result) #x80)))))
         (update-zn cpu result)
         (setf (cpu-a cpu) result))))))

(defun do-sbc (cpu value)
  (let* ((a (cpu-a cpu))
         (c (if (flag-set? cpu +flag-c+) 1 0)))
    (cond
      ((flag-set? cpu +flag-d+)
       ;; NMOS BCD subtraction: flags Z/N/V/C are set from the binary
       ;; calculation; only the result digits are decimal-corrected.
       (let* ((bin (logand (- a value (- 1 c)) #xFFFF))
              (binary-result (logand bin #xFF)))
         (set-flag-to cpu +flag-c+ (zerop (logand bin #x100)))
         (set-flag-to cpu +flag-v+
                      (and (not (zerop (logand (logxor a value) #x80)))
                           (not (zerop (logand (logxor a binary-result) #x80)))))
         (update-zn cpu binary-result)
         (let* ((lo (- (logand a #x0F) (logand value #x0F) (- 1 c)))
                (hi (- (logand a #xF0) (logand value #xF0)))
                (lo2 (if (minusp lo) (- lo 6) lo))
                (hi2 (if (minusp lo) (- hi #x10) hi))
                (hi3 (if (minusp hi2) (- hi2 #x60) hi2))
                (result (logand (logior (logand lo2 #x0F)
                                        (logand hi3 #xF0))
                                #xFF)))
           (setf (cpu-a cpu) result))))
      (t
       (let* ((diff (- a value (- 1 c)))
              (result (logand diff #xFF)))
         (set-flag-to cpu +flag-c+ (>= diff 0))
         (set-flag-to cpu +flag-v+
                      (and (not (zerop (logand (logxor a value) #x80)))
                           (not (zerop (logand (logxor a result) #x80)))))
         (update-zn cpu result)
         (setf (cpu-a cpu) result))))))

(defun do-cmp (cpu reg-value mem-value)
  (let ((diff (- reg-value mem-value)))
    (set-flag-to cpu +flag-c+ (>= reg-value mem-value))
    (update-zn cpu (logand diff #xFF))))

(defun do-asl (value cpu)
  (let* ((c (not (zerop (logand value #x80))))
         (r (logand (ash value 1) #xFF)))
    (set-flag-to cpu +flag-c+ c)
    (update-zn cpu r)
    r))

(defun do-lsr (value cpu)
  (let* ((c (not (zerop (logand value #x01))))
         (r (logand (ash value -1) #xFF)))
    (set-flag-to cpu +flag-c+ c)
    (update-zn cpu r)
    r))

(defun do-rol (value cpu)
  (let* ((cin (if (flag-set? cpu +flag-c+) 1 0))
         (cout (not (zerop (logand value #x80))))
         (r (logand (logior (ash value 1) cin) #xFF)))
    (set-flag-to cpu +flag-c+ cout)
    (update-zn cpu r)
    r))

(defun do-ror (value cpu)
  (let* ((cin (if (flag-set? cpu +flag-c+) #x80 0))
         (cout (not (zerop (logand value #x01))))
         (r (logand (logior (ash value -1) cin) #xFF)))
    (set-flag-to cpu +flag-c+ cout)
    (update-zn cpu r)
    r))

;;; ---------------------------------------------------------------------------
;;; Branch helper
;;;
;;; +1 cycle if branch is taken, +1 more if the branch crosses a page.

(defun do-branch (cpu condition)
  (multiple-value-bind (target) (addr-relative cpu)
    (cond
      ((not condition) 2)
      (t
       (let* ((before (cpu-pc cpu))
              (cycles (+ 2 1 (if (page-crossed? before target) 1 0))))
         (setf (cpu-pc cpu) target)
         cycles)))))

;;; ---------------------------------------------------------------------------
;;; Opcode table construction

(defparameter *opcode-table-builder* (make-array 256 :initial-element nil))

(defmacro defop (opcode lambda-list &body body)
  "Install an opcode handler at OPCODE in the dispatch table."
  `(setf (svref *opcode-table-builder* ,opcode)
         (lambda ,lambda-list ,@body)))

;;; ===========================================================================
;;; LDA / LDX / LDY
;;; ===========================================================================

(macrolet ((lda (op mode base &key page-cross)
             `(defop ,op (cpu)
                (multiple-value-bind (val xp?) (read-via cpu #',mode)
                  (declare (ignorable xp?))
                  (setf (cpu-a cpu) (update-zn cpu val))
                  (+ ,base ,(if page-cross '(if xp? 1 0) 0))))))
  (lda #xA9 addr-immediate         2)
  (lda #xA5 addr-zero-page         3)
  (lda #xB5 addr-zero-page-x       4)
  (lda #xAD addr-absolute          4)
  (lda #xBD addr-absolute-x        4 :page-cross t)
  (lda #xB9 addr-absolute-y        4 :page-cross t)
  (lda #xA1 addr-indexed-indirect  6)
  (lda #xB1 addr-indirect-indexed  5 :page-cross t))

(macrolet ((ldx (op mode base &key page-cross)
             `(defop ,op (cpu)
                (multiple-value-bind (val xp?) (read-via cpu #',mode)
                  (declare (ignorable xp?))
                  (setf (cpu-x cpu) (update-zn cpu val))
                  (+ ,base ,(if page-cross '(if xp? 1 0) 0))))))
  (ldx #xA2 addr-immediate    2)
  (ldx #xA6 addr-zero-page    3)
  (ldx #xB6 addr-zero-page-y  4)
  (ldx #xAE addr-absolute     4)
  (ldx #xBE addr-absolute-y   4 :page-cross t))

(macrolet ((ldy (op mode base &key page-cross)
             `(defop ,op (cpu)
                (multiple-value-bind (val xp?) (read-via cpu #',mode)
                  (declare (ignorable xp?))
                  (setf (cpu-y cpu) (update-zn cpu val))
                  (+ ,base ,(if page-cross '(if xp? 1 0) 0))))))
  (ldy #xA0 addr-immediate    2)
  (ldy #xA4 addr-zero-page    3)
  (ldy #xB4 addr-zero-page-x  4)
  (ldy #xAC addr-absolute     4)
  (ldy #xBC addr-absolute-x   4 :page-cross t))

;;; ===========================================================================
;;; STA / STX / STY (no page-cross penalty for stores)
;;; ===========================================================================

(macrolet ((sta (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (addr) (,mode cpu)
                  (cpu-write-byte cpu addr (cpu-a cpu))
                  ,base))))
  (sta #x85 addr-zero-page         3)
  (sta #x95 addr-zero-page-x       4)
  (sta #x8D addr-absolute          4)
  (sta #x9D addr-absolute-x        5)
  (sta #x99 addr-absolute-y        5)
  (sta #x81 addr-indexed-indirect  6)
  (sta #x91 addr-indirect-indexed  6))

(macrolet ((stx (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (addr) (,mode cpu)
                  (cpu-write-byte cpu addr (cpu-x cpu))
                  ,base))))
  (stx #x86 addr-zero-page    3)
  (stx #x96 addr-zero-page-y  4)
  (stx #x8E addr-absolute     4))

(macrolet ((sty (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (addr) (,mode cpu)
                  (cpu-write-byte cpu addr (cpu-y cpu))
                  ,base))))
  (sty #x84 addr-zero-page    3)
  (sty #x94 addr-zero-page-x  4)
  (sty #x8C addr-absolute     4))

;;; ===========================================================================
;;; Register transfers (TAX/TAY/TXA/TYA/TSX/TXS)
;;; ===========================================================================

(defop #xAA (cpu) (setf (cpu-x cpu) (update-zn cpu (cpu-a cpu))) 2)  ; TAX
(defop #xA8 (cpu) (setf (cpu-y cpu) (update-zn cpu (cpu-a cpu))) 2)  ; TAY
(defop #x8A (cpu) (setf (cpu-a cpu) (update-zn cpu (cpu-x cpu))) 2)  ; TXA
(defop #x98 (cpu) (setf (cpu-a cpu) (update-zn cpu (cpu-y cpu))) 2)  ; TYA
(defop #xBA (cpu) (setf (cpu-x cpu) (update-zn cpu (cpu-sp cpu))) 2) ; TSX
(defop #x9A (cpu) (setf (cpu-sp cpu) (cpu-x cpu)) 2)                 ; TXS

;;; ===========================================================================
;;; Stack ops
;;; ===========================================================================

(defop #x48 (cpu) (push-byte cpu (cpu-a cpu)) 3)   ; PHA
(defop #x08 (cpu) (push-byte cpu (status-byte-for-push cpu :b-flag t)) 3) ; PHP
(defop #x68 (cpu) (setf (cpu-a cpu) (update-zn cpu (pull-byte cpu))) 4)   ; PLA
(defop #x28 (cpu)                                                          ; PLP
  (setf (cpu-flags cpu) (status-byte-from-pull (pull-byte cpu)))
  4)

;;; ===========================================================================
;;; Logical ops: AND, ORA, EOR, BIT
;;; ===========================================================================

(macrolet ((logical (op mode base reduce &key page-cross)
             `(defop ,op (cpu)
                (multiple-value-bind (val xp?) (read-via cpu #',mode)
                  (declare (ignorable xp?))
                  (setf (cpu-a cpu)
                        (update-zn cpu (,reduce (cpu-a cpu) val)))
                  (+ ,base ,(if page-cross '(if xp? 1 0) 0))))))
  ;; AND
  (logical #x29 addr-immediate         2 logand)
  (logical #x25 addr-zero-page         3 logand)
  (logical #x35 addr-zero-page-x       4 logand)
  (logical #x2D addr-absolute          4 logand)
  (logical #x3D addr-absolute-x        4 logand :page-cross t)
  (logical #x39 addr-absolute-y        4 logand :page-cross t)
  (logical #x21 addr-indexed-indirect  6 logand)
  (logical #x31 addr-indirect-indexed  5 logand :page-cross t)
  ;; ORA
  (logical #x09 addr-immediate         2 logior)
  (logical #x05 addr-zero-page         3 logior)
  (logical #x15 addr-zero-page-x       4 logior)
  (logical #x0D addr-absolute          4 logior)
  (logical #x1D addr-absolute-x        4 logior :page-cross t)
  (logical #x19 addr-absolute-y        4 logior :page-cross t)
  (logical #x01 addr-indexed-indirect  6 logior)
  (logical #x11 addr-indirect-indexed  5 logior :page-cross t)
  ;; EOR
  (logical #x49 addr-immediate         2 logxor)
  (logical #x45 addr-zero-page         3 logxor)
  (logical #x55 addr-zero-page-x       4 logxor)
  (logical #x4D addr-absolute          4 logxor)
  (logical #x5D addr-absolute-x        4 logxor :page-cross t)
  (logical #x59 addr-absolute-y        4 logxor :page-cross t)
  (logical #x41 addr-indexed-indirect  6 logxor)
  (logical #x51 addr-indirect-indexed  5 logxor :page-cross t))

(macrolet ((bit-op (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (val) (read-via cpu #',mode)
                  (set-flag-to cpu +flag-z+ (zerop (logand (cpu-a cpu) val)))
                  (set-flag-to cpu +flag-n+ (not (zerop (logand val #x80))))
                  (set-flag-to cpu +flag-v+ (not (zerop (logand val #x40))))
                  ,base))))
  (bit-op #x24 addr-zero-page  3)
  (bit-op #x2C addr-absolute   4))

;;; ===========================================================================
;;; ADC / SBC
;;; ===========================================================================

(macrolet ((adc (op mode base &key page-cross)
             `(defop ,op (cpu)
                (multiple-value-bind (val xp?) (read-via cpu #',mode)
                  (declare (ignorable xp?))
                  (do-adc cpu val)
                  (+ ,base ,(if page-cross '(if xp? 1 0) 0))))))
  (adc #x69 addr-immediate         2)
  (adc #x65 addr-zero-page         3)
  (adc #x75 addr-zero-page-x       4)
  (adc #x6D addr-absolute          4)
  (adc #x7D addr-absolute-x        4 :page-cross t)
  (adc #x79 addr-absolute-y        4 :page-cross t)
  (adc #x61 addr-indexed-indirect  6)
  (adc #x71 addr-indirect-indexed  5 :page-cross t))

(macrolet ((sbc (op mode base &key page-cross)
             `(defop ,op (cpu)
                (multiple-value-bind (val xp?) (read-via cpu #',mode)
                  (declare (ignorable xp?))
                  (do-sbc cpu val)
                  (+ ,base ,(if page-cross '(if xp? 1 0) 0))))))
  (sbc #xE9 addr-immediate         2)
  (sbc #xE5 addr-zero-page         3)
  (sbc #xF5 addr-zero-page-x       4)
  (sbc #xED addr-absolute          4)
  (sbc #xFD addr-absolute-x        4 :page-cross t)
  (sbc #xF9 addr-absolute-y        4 :page-cross t)
  (sbc #xE1 addr-indexed-indirect  6)
  (sbc #xF1 addr-indirect-indexed  5 :page-cross t))

;;; ===========================================================================
;;; Compares: CMP / CPX / CPY
;;; ===========================================================================

(macrolet ((cmp (op mode base &key page-cross)
             `(defop ,op (cpu)
                (multiple-value-bind (val xp?) (read-via cpu #',mode)
                  (declare (ignorable xp?))
                  (do-cmp cpu (cpu-a cpu) val)
                  (+ ,base ,(if page-cross '(if xp? 1 0) 0))))))
  (cmp #xC9 addr-immediate         2)
  (cmp #xC5 addr-zero-page         3)
  (cmp #xD5 addr-zero-page-x       4)
  (cmp #xCD addr-absolute          4)
  (cmp #xDD addr-absolute-x        4 :page-cross t)
  (cmp #xD9 addr-absolute-y        4 :page-cross t)
  (cmp #xC1 addr-indexed-indirect  6)
  (cmp #xD1 addr-indirect-indexed  5 :page-cross t))

(macrolet ((cpx (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (val) (read-via cpu #',mode)
                  (do-cmp cpu (cpu-x cpu) val)
                  ,base))))
  (cpx #xE0 addr-immediate  2)
  (cpx #xE4 addr-zero-page  3)
  (cpx #xEC addr-absolute   4))

(macrolet ((cpy (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (val) (read-via cpu #',mode)
                  (do-cmp cpu (cpu-y cpu) val)
                  ,base))))
  (cpy #xC0 addr-immediate  2)
  (cpy #xC4 addr-zero-page  3)
  (cpy #xCC addr-absolute   4))

;;; ===========================================================================
;;; Inc / Dec memory and registers
;;; ===========================================================================

(macrolet ((incmem (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (addr) (,mode cpu)
                  (let ((v (logand (1+ (cpu-read-byte cpu addr)) #xFF)))
                    (cpu-write-byte cpu addr v)
                    (update-zn cpu v))
                  ,base))))
  (incmem #xE6 addr-zero-page    5)
  (incmem #xF6 addr-zero-page-x  6)
  (incmem #xEE addr-absolute     6)
  (incmem #xFE addr-absolute-x   7))

(macrolet ((decmem (op mode base)
             `(defop ,op (cpu)
                (multiple-value-bind (addr) (,mode cpu)
                  (let ((v (logand (1- (cpu-read-byte cpu addr)) #xFF)))
                    (cpu-write-byte cpu addr v)
                    (update-zn cpu v))
                  ,base))))
  (decmem #xC6 addr-zero-page    5)
  (decmem #xD6 addr-zero-page-x  6)
  (decmem #xCE addr-absolute     6)
  (decmem #xDE addr-absolute-x   7))

(defop #xE8 (cpu) (setf (cpu-x cpu) (update-zn cpu (1+ (cpu-x cpu)))) 2) ; INX
(defop #xC8 (cpu) (setf (cpu-y cpu) (update-zn cpu (1+ (cpu-y cpu)))) 2) ; INY
(defop #xCA (cpu) (setf (cpu-x cpu) (update-zn cpu (1- (cpu-x cpu)))) 2) ; DEX
(defop #x88 (cpu) (setf (cpu-y cpu) (update-zn cpu (1- (cpu-y cpu)))) 2) ; DEY

;;; ===========================================================================
;;; Shifts and rotates
;;; ===========================================================================

(defop #x0A (cpu) (setf (cpu-a cpu) (do-asl (cpu-a cpu) cpu)) 2) ; ASL A
(defop #x4A (cpu) (setf (cpu-a cpu) (do-lsr (cpu-a cpu) cpu)) 2) ; LSR A
(defop #x2A (cpu) (setf (cpu-a cpu) (do-rol (cpu-a cpu) cpu)) 2) ; ROL A
(defop #x6A (cpu) (setf (cpu-a cpu) (do-ror (cpu-a cpu) cpu)) 2) ; ROR A

(macrolet ((rmw (op mode base op-fn)
             `(defop ,op (cpu)
                (multiple-value-bind (addr) (,mode cpu)
                  (let* ((v (cpu-read-byte cpu addr))
                         (r (,op-fn v cpu)))
                    (cpu-write-byte cpu addr r))
                  ,base))))
  (rmw #x06 addr-zero-page    5 do-asl)
  (rmw #x16 addr-zero-page-x  6 do-asl)
  (rmw #x0E addr-absolute     6 do-asl)
  (rmw #x1E addr-absolute-x   7 do-asl)
  (rmw #x46 addr-zero-page    5 do-lsr)
  (rmw #x56 addr-zero-page-x  6 do-lsr)
  (rmw #x4E addr-absolute     6 do-lsr)
  (rmw #x5E addr-absolute-x   7 do-lsr)
  (rmw #x26 addr-zero-page    5 do-rol)
  (rmw #x36 addr-zero-page-x  6 do-rol)
  (rmw #x2E addr-absolute     6 do-rol)
  (rmw #x3E addr-absolute-x   7 do-rol)
  (rmw #x66 addr-zero-page    5 do-ror)
  (rmw #x76 addr-zero-page-x  6 do-ror)
  (rmw #x6E addr-absolute     6 do-ror)
  (rmw #x7E addr-absolute-x   7 do-ror))

;;; ===========================================================================
;;; Branches
;;; ===========================================================================

(defop #x10 (cpu) (do-branch cpu (not (flag-set? cpu +flag-n+))))   ; BPL
(defop #x30 (cpu) (do-branch cpu (flag-set? cpu +flag-n+)))         ; BMI
(defop #x50 (cpu) (do-branch cpu (not (flag-set? cpu +flag-v+))))   ; BVC
(defop #x70 (cpu) (do-branch cpu (flag-set? cpu +flag-v+)))         ; BVS
(defop #x90 (cpu) (do-branch cpu (not (flag-set? cpu +flag-c+))))   ; BCC
(defop #xB0 (cpu) (do-branch cpu (flag-set? cpu +flag-c+)))         ; BCS
(defop #xD0 (cpu) (do-branch cpu (not (flag-set? cpu +flag-z+))))   ; BNE
(defop #xF0 (cpu) (do-branch cpu (flag-set? cpu +flag-z+)))         ; BEQ

;;; ===========================================================================
;;; Jumps and subroutines
;;; ===========================================================================

(defop #x4C (cpu)                                ; JMP absolute
  (multiple-value-bind (addr) (addr-absolute cpu)
    (setf (cpu-pc cpu) addr))
  3)

(defop #x6C (cpu)                                ; JMP (indirect)
  (multiple-value-bind (addr) (addr-indirect cpu)
    (setf (cpu-pc cpu) addr))
  5)

(defop #x20 (cpu)                                ; JSR absolute
  ;; Push (PC of the third byte of the JSR instruction).  At this point
  ;; we've consumed only the opcode.  Read the target word, then push
  ;; (PC - 1) which is the address of the high byte of the operand.
  (let* ((target (read-pc-word cpu))
         (return-addr (logand (1- (cpu-pc cpu)) #xFFFF)))
    (push-word cpu return-addr)
    (setf (cpu-pc cpu) target))
  6)

(defop #x60 (cpu)                                ; RTS
  (let ((addr (pull-word cpu)))
    (setf (cpu-pc cpu) (logand (1+ addr) #xFFFF)))
  6)

(defop #x40 (cpu)                                ; RTI
  (setf (cpu-flags cpu) (status-byte-from-pull (pull-byte cpu)))
  (setf (cpu-pc cpu) (pull-word cpu))
  6)

(defop #x00 (cpu)                                ; BRK
  ;; BRK pushes PC+1 (one byte past the BRK opcode's operand byte),
  ;; pushes status with B=1, sets I, and vectors through $FFFE.
  (let ((return-pc (logand (1+ (cpu-pc cpu)) #xFFFF)))
    (push-word cpu return-pc)
    (push-byte cpu (status-byte-for-push cpu :b-flag t))
    (set-flag cpu +flag-i+)
    (setf (cpu-pc cpu) (cpu-read-word cpu +irq-vector+)))
  7)

;;; ===========================================================================
;;; Flag set/clear
;;; ===========================================================================

(defop #x18 (cpu) (clear-flag cpu +flag-c+) 2)   ; CLC
(defop #x38 (cpu) (set-flag   cpu +flag-c+) 2)   ; SEC
(defop #x58 (cpu) (clear-flag cpu +flag-i+) 2)   ; CLI
(defop #x78 (cpu) (set-flag   cpu +flag-i+) 2)   ; SEI
(defop #xB8 (cpu) (clear-flag cpu +flag-v+) 2)   ; CLV
(defop #xD8 (cpu) (clear-flag cpu +flag-d+) 2)   ; CLD
(defop #xF8 (cpu) (set-flag   cpu +flag-d+) 2)   ; SED

;;; ===========================================================================
;;; NOP
;;; ===========================================================================

(defop #xEA (cpu) (declare (ignore cpu)) 2)

;;; ---------------------------------------------------------------------------
;;; Finalize: install the builder array as the live dispatch table.

(setf *opcode-table* *opcode-table-builder*)

(defun documented-opcodes ()
  "Return a list of opcodes (integers) that have a handler installed."
  (loop for i below 256
        when (svref *opcode-table* i)
          collect i))
