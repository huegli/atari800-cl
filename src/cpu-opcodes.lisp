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
;;;
;;; Each documented opcode is given a named function (OPCODE-#xNN-MNEMONIC)
;;; via DEFOPCODE so it shows up in backtraces and can be inspected from a
;;; disassembler.  The handler is then installed into *OPCODE-TABLE-BUILDER*
;;; at the corresponding opcode index.  DEFOP is a thin wrapper used by the
;;; family-defining MACROLETs that don't have a stable mnemonic to embed in
;;; the function name.

(defparameter *opcode-table-builder* (make-array 256 :initial-element nil))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %opcode-handler-name (opcode mnemonic)
    (intern (format nil "OPCODE-~A-~2,'0X"
                    (string-upcase (string mnemonic))
                    opcode)
            :atari800-cl.cpu)))

(defmacro defopcode (opcode mnemonic lambda-list &body body)
  "Define a named handler for OPCODE and install it in the dispatch table.

MNEMONIC is a symbol (e.g. LDA-IMM, BRK, JMP-IND) used to build a stable
function name like OPCODE-A9-LDA-IMM, so each opcode shows up in
backtraces and can be looked up from a disassembler/debugger."
  (let ((fn-name (%opcode-handler-name opcode mnemonic)))
    `(progn
       (defun ,fn-name ,lambda-list ,@body)
       (setf (svref *opcode-table-builder* ,opcode) (function ,fn-name))
       ',fn-name)))

(defmacro defop (opcode lambda-list &body body)
  "Install an anonymous opcode handler at OPCODE in the dispatch table.
Kept for legacy callers; prefer DEFOPCODE so each opcode gets a named
function.  Family macrolets below auto-generate names from MNEMONIC and
the addressing mode, so they go through DEFOPCODE."
  `(setf (svref *opcode-table-builder* ,opcode)
         (lambda ,lambda-list ,@body)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %mode->suffix (mode)
    "Turn an addr-mode symbol like ADDR-ABSOLUTE-X into a short tag (ABSX)."
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

(macrolet ((load-op (mnemonic reg op mode base &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val xp?) (read-via cpu #',mode)
                    (declare (ignorable xp?))
                    (setf (,reg cpu) (update-zn cpu val))
                    (+ ,base ,(if page-cross '(if xp? 1 0) 0)))))))
  ;; LDA
  (load-op "LDA" cpu-a #xA9 addr-immediate         2)
  (load-op "LDA" cpu-a #xA5 addr-zero-page         3)
  (load-op "LDA" cpu-a #xB5 addr-zero-page-x       4)
  (load-op "LDA" cpu-a #xAD addr-absolute          4)
  (load-op "LDA" cpu-a #xBD addr-absolute-x        4 :page-cross t)
  (load-op "LDA" cpu-a #xB9 addr-absolute-y        4 :page-cross t)
  (load-op "LDA" cpu-a #xA1 addr-indexed-indirect  6)
  (load-op "LDA" cpu-a #xB1 addr-indirect-indexed  5 :page-cross t)
  ;; LDX
  (load-op "LDX" cpu-x #xA2 addr-immediate    2)
  (load-op "LDX" cpu-x #xA6 addr-zero-page    3)
  (load-op "LDX" cpu-x #xB6 addr-zero-page-y  4)
  (load-op "LDX" cpu-x #xAE addr-absolute     4)
  (load-op "LDX" cpu-x #xBE addr-absolute-y   4 :page-cross t)
  ;; LDY
  (load-op "LDY" cpu-y #xA0 addr-immediate    2)
  (load-op "LDY" cpu-y #xA4 addr-zero-page    3)
  (load-op "LDY" cpu-y #xB4 addr-zero-page-x  4)
  (load-op "LDY" cpu-y #xAC addr-absolute     4)
  (load-op "LDY" cpu-y #xBC addr-absolute-x   4 :page-cross t))

;;; ===========================================================================
;;; STA / STX / STY (no page-cross penalty for stores)
;;; ===========================================================================

(macrolet ((store-op (mnemonic reg op mode base)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (addr) (,mode cpu)
                    (cpu-write-byte cpu addr (,reg cpu))
                    ,base)))))
  ;; STA
  (store-op "STA" cpu-a #x85 addr-zero-page         3)
  (store-op "STA" cpu-a #x95 addr-zero-page-x       4)
  (store-op "STA" cpu-a #x8D addr-absolute          4)
  (store-op "STA" cpu-a #x9D addr-absolute-x        5)
  (store-op "STA" cpu-a #x99 addr-absolute-y        5)
  (store-op "STA" cpu-a #x81 addr-indexed-indirect  6)
  (store-op "STA" cpu-a #x91 addr-indirect-indexed  6)
  ;; STX
  (store-op "STX" cpu-x #x86 addr-zero-page    3)
  (store-op "STX" cpu-x #x96 addr-zero-page-y  4)
  (store-op "STX" cpu-x #x8E addr-absolute     4)
  ;; STY
  (store-op "STY" cpu-y #x84 addr-zero-page    3)
  (store-op "STY" cpu-y #x94 addr-zero-page-x  4)
  (store-op "STY" cpu-y #x8C addr-absolute     4))

;;; ===========================================================================
;;; Register transfers (TAX/TAY/TXA/TYA/TSX/TXS)
;;; ===========================================================================

(defopcode #xAA tax (cpu) (setf (cpu-x cpu) (update-zn cpu (cpu-a cpu))) 2)
(defopcode #xA8 tay (cpu) (setf (cpu-y cpu) (update-zn cpu (cpu-a cpu))) 2)
(defopcode #x8A txa (cpu) (setf (cpu-a cpu) (update-zn cpu (cpu-x cpu))) 2)
(defopcode #x98 tya (cpu) (setf (cpu-a cpu) (update-zn cpu (cpu-y cpu))) 2)
(defopcode #xBA tsx (cpu) (setf (cpu-x cpu) (update-zn cpu (cpu-sp cpu))) 2)
(defopcode #x9A txs (cpu) (setf (cpu-sp cpu) (cpu-x cpu)) 2)

;;; ===========================================================================
;;; Stack ops
;;; ===========================================================================

(defopcode #x48 pha (cpu) (push-byte cpu (cpu-a cpu)) 3)
(defopcode #x08 php (cpu) (push-byte cpu (status-byte-for-push cpu :b-flag t)) 3)
(defopcode #x68 pla (cpu) (setf (cpu-a cpu) (update-zn cpu (pull-byte cpu))) 4)
(defopcode #x28 plp (cpu)
  (setf (cpu-flags cpu) (status-byte-from-pull (pull-byte cpu)))
  4)

;;; ===========================================================================
;;; Logical ops: AND, ORA, EOR, BIT
;;; ===========================================================================

(macrolet ((logical (mnemonic op mode base reduce &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val xp?) (read-via cpu #',mode)
                    (declare (ignorable xp?))
                    (setf (cpu-a cpu)
                          (update-zn cpu (,reduce (cpu-a cpu) val)))
                    (+ ,base ,(if page-cross '(if xp? 1 0) 0)))))))
  ;; AND
  (logical "AND" #x29 addr-immediate         2 logand)
  (logical "AND" #x25 addr-zero-page         3 logand)
  (logical "AND" #x35 addr-zero-page-x       4 logand)
  (logical "AND" #x2D addr-absolute          4 logand)
  (logical "AND" #x3D addr-absolute-x        4 logand :page-cross t)
  (logical "AND" #x39 addr-absolute-y        4 logand :page-cross t)
  (logical "AND" #x21 addr-indexed-indirect  6 logand)
  (logical "AND" #x31 addr-indirect-indexed  5 logand :page-cross t)
  ;; ORA
  (logical "ORA" #x09 addr-immediate         2 logior)
  (logical "ORA" #x05 addr-zero-page         3 logior)
  (logical "ORA" #x15 addr-zero-page-x       4 logior)
  (logical "ORA" #x0D addr-absolute          4 logior)
  (logical "ORA" #x1D addr-absolute-x        4 logior :page-cross t)
  (logical "ORA" #x19 addr-absolute-y        4 logior :page-cross t)
  (logical "ORA" #x01 addr-indexed-indirect  6 logior)
  (logical "ORA" #x11 addr-indirect-indexed  5 logior :page-cross t)
  ;; EOR
  (logical "EOR" #x49 addr-immediate         2 logxor)
  (logical "EOR" #x45 addr-zero-page         3 logxor)
  (logical "EOR" #x55 addr-zero-page-x       4 logxor)
  (logical "EOR" #x4D addr-absolute          4 logxor)
  (logical "EOR" #x5D addr-absolute-x        4 logxor :page-cross t)
  (logical "EOR" #x59 addr-absolute-y        4 logxor :page-cross t)
  (logical "EOR" #x41 addr-indexed-indirect  6 logxor)
  (logical "EOR" #x51 addr-indirect-indexed  5 logxor :page-cross t))

(macrolet ((bit-op (op mode base)
             (let ((tag (intern (format nil "BIT-~A" (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val) (read-via cpu #',mode)
                    (set-flag-to cpu +flag-z+ (zerop (logand (cpu-a cpu) val)))
                    (set-flag-to cpu +flag-n+ (not (zerop (logand val #x80))))
                    (set-flag-to cpu +flag-v+ (not (zerop (logand val #x40))))
                    ,base)))))
  (bit-op #x24 addr-zero-page  3)
  (bit-op #x2C addr-absolute   4))

;;; ===========================================================================
;;; ADC / SBC
;;; ===========================================================================

(macrolet ((arith (mnemonic doer op mode base &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val xp?) (read-via cpu #',mode)
                    (declare (ignorable xp?))
                    (,doer cpu val)
                    (+ ,base ,(if page-cross '(if xp? 1 0) 0)))))))
  ;; ADC
  (arith "ADC" do-adc #x69 addr-immediate         2)
  (arith "ADC" do-adc #x65 addr-zero-page         3)
  (arith "ADC" do-adc #x75 addr-zero-page-x       4)
  (arith "ADC" do-adc #x6D addr-absolute          4)
  (arith "ADC" do-adc #x7D addr-absolute-x        4 :page-cross t)
  (arith "ADC" do-adc #x79 addr-absolute-y        4 :page-cross t)
  (arith "ADC" do-adc #x61 addr-indexed-indirect  6)
  (arith "ADC" do-adc #x71 addr-indirect-indexed  5 :page-cross t)
  ;; SBC
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

(macrolet ((cmp-op (mnemonic reg op mode base &key page-cross)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val xp?) (read-via cpu #',mode)
                    (declare (ignorable xp?))
                    (do-cmp cpu (,reg cpu) val)
                    (+ ,base ,(if page-cross '(if xp? 1 0) 0)))))))
  ;; CMP
  (cmp-op "CMP" cpu-a #xC9 addr-immediate         2)
  (cmp-op "CMP" cpu-a #xC5 addr-zero-page         3)
  (cmp-op "CMP" cpu-a #xD5 addr-zero-page-x       4)
  (cmp-op "CMP" cpu-a #xCD addr-absolute          4)
  (cmp-op "CMP" cpu-a #xDD addr-absolute-x        4 :page-cross t)
  (cmp-op "CMP" cpu-a #xD9 addr-absolute-y        4 :page-cross t)
  (cmp-op "CMP" cpu-a #xC1 addr-indexed-indirect  6)
  (cmp-op "CMP" cpu-a #xD1 addr-indirect-indexed  5 :page-cross t)
  ;; CPX
  (cmp-op "CPX" cpu-x #xE0 addr-immediate  2)
  (cmp-op "CPX" cpu-x #xE4 addr-zero-page  3)
  (cmp-op "CPX" cpu-x #xEC addr-absolute   4)
  ;; CPY
  (cmp-op "CPY" cpu-y #xC0 addr-immediate  2)
  (cmp-op "CPY" cpu-y #xC4 addr-zero-page  3)
  (cmp-op "CPY" cpu-y #xCC addr-absolute   4))

;;; ===========================================================================
;;; Inc / Dec memory and registers
;;; ===========================================================================

(macrolet ((memop (mnemonic delta op mode base)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (addr) (,mode cpu)
                    (let ((v (logand (+ (cpu-read-byte cpu addr) ,delta)
                                     #xFF)))
                      (cpu-write-byte cpu addr v)
                      (update-zn cpu v))
                    ,base)))))
  ;; INC
  (memop "INC"  1 #xE6 addr-zero-page    5)
  (memop "INC"  1 #xF6 addr-zero-page-x  6)
  (memop "INC"  1 #xEE addr-absolute     6)
  (memop "INC"  1 #xFE addr-absolute-x   7)
  ;; DEC
  (memop "DEC" -1 #xC6 addr-zero-page    5)
  (memop "DEC" -1 #xD6 addr-zero-page-x  6)
  (memop "DEC" -1 #xCE addr-absolute     6)
  (memop "DEC" -1 #xDE addr-absolute-x   7))

(defopcode #xE8 inx (cpu) (setf (cpu-x cpu) (update-zn cpu (1+ (cpu-x cpu)))) 2)
(defopcode #xC8 iny (cpu) (setf (cpu-y cpu) (update-zn cpu (1+ (cpu-y cpu)))) 2)
(defopcode #xCA dex (cpu) (setf (cpu-x cpu) (update-zn cpu (1- (cpu-x cpu)))) 2)
(defopcode #x88 dey (cpu) (setf (cpu-y cpu) (update-zn cpu (1- (cpu-y cpu)))) 2)

;;; ===========================================================================
;;; Shifts and rotates
;;; ===========================================================================

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
                    (let* ((v (cpu-read-byte cpu addr))
                           (r (,op-fn v cpu)))
                      (cpu-write-byte cpu addr r))
                    ,base)))))
  (rmw "ASL" #x06 addr-zero-page    5 do-asl)
  (rmw "ASL" #x16 addr-zero-page-x  6 do-asl)
  (rmw "ASL" #x0E addr-absolute     6 do-asl)
  (rmw "ASL" #x1E addr-absolute-x   7 do-asl)
  (rmw "LSR" #x46 addr-zero-page    5 do-lsr)
  (rmw "LSR" #x56 addr-zero-page-x  6 do-lsr)
  (rmw "LSR" #x4E addr-absolute     6 do-lsr)
  (rmw "LSR" #x5E addr-absolute-x   7 do-lsr)
  (rmw "ROL" #x26 addr-zero-page    5 do-rol)
  (rmw "ROL" #x36 addr-zero-page-x  6 do-rol)
  (rmw "ROL" #x2E addr-absolute     6 do-rol)
  (rmw "ROL" #x3E addr-absolute-x   7 do-rol)
  (rmw "ROR" #x66 addr-zero-page    5 do-ror)
  (rmw "ROR" #x76 addr-zero-page-x  6 do-ror)
  (rmw "ROR" #x6E addr-absolute     6 do-ror)
  (rmw "ROR" #x7E addr-absolute-x   7 do-ror))

;;; ===========================================================================
;;; Branches
;;; ===========================================================================

(defopcode #x10 bpl (cpu) (do-branch cpu (not (flag-set? cpu +flag-n+))))
(defopcode #x30 bmi (cpu) (do-branch cpu (flag-set? cpu +flag-n+)))
(defopcode #x50 bvc (cpu) (do-branch cpu (not (flag-set? cpu +flag-v+))))
(defopcode #x70 bvs (cpu) (do-branch cpu (flag-set? cpu +flag-v+)))
(defopcode #x90 bcc (cpu) (do-branch cpu (not (flag-set? cpu +flag-c+))))
(defopcode #xB0 bcs (cpu) (do-branch cpu (flag-set? cpu +flag-c+)))
(defopcode #xD0 bne (cpu) (do-branch cpu (not (flag-set? cpu +flag-z+))))
(defopcode #xF0 beq (cpu) (do-branch cpu (flag-set? cpu +flag-z+)))

;;; ===========================================================================
;;; Jumps and subroutines
;;; ===========================================================================

(defopcode #x4C jmp-abs (cpu)
  (multiple-value-bind (addr) (addr-absolute cpu)
    (setf (cpu-pc cpu) addr))
  3)

(defopcode #x6C jmp-ind (cpu)
  (multiple-value-bind (addr) (addr-indirect cpu)
    (setf (cpu-pc cpu) addr))
  5)

(defopcode #x20 jsr (cpu)
  ;; Push (PC - 1) — i.e. the address of the high byte of the operand.
  (let* ((target (read-pc-word cpu))
         (return-addr (logand (1- (cpu-pc cpu)) #xFFFF)))
    (push-word cpu return-addr)
    (setf (cpu-pc cpu) target))
  6)

(defopcode #x60 rts (cpu)
  (let ((addr (pull-word cpu)))
    (setf (cpu-pc cpu) (logand (1+ addr) #xFFFF)))
  6)

(defopcode #x40 rti (cpu)
  (setf (cpu-flags cpu) (status-byte-from-pull (pull-byte cpu)))
  (setf (cpu-pc cpu) (pull-word cpu))
  6)

(defopcode #x00 brk (cpu)
  ;; BRK pushes PC+1, pushes status with B=1, sets I, vectors through $FFFE.
  (let ((return-pc (logand (1+ (cpu-pc cpu)) #xFFFF)))
    (push-word cpu return-pc)
    (push-byte cpu (status-byte-for-push cpu :b-flag t))
    (set-flag cpu +flag-i+)
    (setf (cpu-pc cpu) (cpu-read-word cpu +irq-vector+)))
  7)

;;; ===========================================================================
;;; Flag set/clear
;;; ===========================================================================

(defopcode #x18 clc (cpu) (clear-flag cpu +flag-c+) 2)
(defopcode #x38 sec (cpu) (set-flag   cpu +flag-c+) 2)
(defopcode #x58 cli (cpu) (clear-flag cpu +flag-i+) 2)
(defopcode #x78 sei (cpu) (set-flag   cpu +flag-i+) 2)
(defopcode #xB8 clv (cpu) (clear-flag cpu +flag-v+) 2)
(defopcode #xD8 cld (cpu) (clear-flag cpu +flag-d+) 2)
(defopcode #xF8 sed (cpu) (set-flag   cpu +flag-d+) 2)

;;; ===========================================================================
;;; NOP
;;; ===========================================================================

(defopcode #xEA nop (cpu) (declare (ignore cpu)) 2)

;;; ---------------------------------------------------------------------------
;;; Finalize: install the builder array as the live dispatch table.

(setf *opcode-table* *opcode-table-builder*)

(defun documented-opcodes ()
  "Return a list of opcodes (integers) that have a handler installed."
  (loop for i below 256
        when (svref *opcode-table* i)
          collect i))
