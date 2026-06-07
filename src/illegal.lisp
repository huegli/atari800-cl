;;;; src/illegal.lisp --- NMOS 6502 illegal / undocumented opcodes.
;;;;
;;;; All 105 NMOS-specific undocumented opcodes, taking the dispatch table
;;;; from 151 entries to a full 256.  Categories implemented:
;;;;
;;;;   - 12 KIL/JAM opcodes that halt the CPU
;;;;       $02 $12 $22 $32 $42 $52 $62 $72 $92 $B2 $D2 $F2
;;;;
;;;;   - Compound read-modify-write + accumulator ops (42 entries, six
;;;;     mnemonics × seven addressing modes):
;;;;       SLO = ASL then ORA   $03 $07 $0F $13 $17 $1B $1F
;;;;       RLA = ROL then AND   $23 $27 $2F $33 $37 $3B $3F
;;;;       SRE = LSR then EOR   $43 $47 $4F $53 $57 $5B $5F
;;;;       RRA = ROR then ADC   $63 $67 $6F $73 $77 $7B $7F
;;;;       DCP = DEC then CMP   $C3 $C7 $CF $D3 $D7 $DB $DF
;;;;       ISC = INC then SBC   $E3 $E7 $EF $F3 $F7 $FB $FF
;;;;
;;;;   - Combined load/store:
;;;;       LAX (LDA + LDX)      $A3 $A7 $AB $AF $B3 $B7 $BF
;;;;       SAX (A AND X → M)    $83 $87 $8F $97
;;;;
;;;;   - Bitwise / accumulator:
;;;;       ANC #imm    $0B $2B   A = A AND imm; C = N
;;;;       ALR #imm    $4B       A = (A AND imm); A = LSR A
;;;;       ARR #imm    $6B       A = A AND imm; A = ROR A; C/V from bits 6/5
;;;;       XAA #imm    $8B       A = X AND imm     (UNSTABLE)
;;;;       AXS #imm    $CB       X = (A AND X) - imm
;;;;       LAS abs,Y   $BB       A = X = SP = M AND SP
;;;;
;;;;   - Unstable high-byte store variants:
;;;;       AHX/SHA (zp),Y  $93   M = A AND X AND (high(base)+1)   (UNSTABLE)
;;;;       AHX/SHA abs,Y   $9F   M = A AND X AND (high(base)+1)   (UNSTABLE)
;;;;       SHY     abs,X   $9C   M = Y     AND (high(base)+1)     (UNSTABLE)
;;;;       SHX     abs,Y   $9E   M = X     AND (high(base)+1)     (UNSTABLE)
;;;;       TAS/SHS abs,Y   $9B   SP = A AND X; M = SP AND (high+1) (UNSTABLE)
;;;;
;;;;   - Duplicate SBC #imm:       $EB
;;;;
;;;;   - 27 multi-byte / extra NOPs:
;;;;       Implied (1B, 2c):       $1A $3A $5A $7A $DA $FA
;;;;       Immediate (2B, 2c):     $80 $82 $89 $C2 $E2
;;;;       Zero page (2B, 3c):     $04 $44 $64
;;;;       Zero page,X (2B, 4c):   $14 $34 $54 $74 $D4 $F4
;;;;       Absolute (3B, 4c):      $0C
;;;;       Absolute,X (3B, 4c+1):  $1C $3C $5C $7C $DC $FC
;;;;
;;;; UNSTABLE INSTRUCTIONS — hardware caveats:
;;;;
;;;; Several opcodes behave erratically on real NMOS 6502 hardware because
;;;; the chip lets two internal buses contend during the cycle.  We
;;;; implement the "canonical" behaviour documented by the visual6502
;;;; project and used by most cycle-accurate emulators, but the actual
;;;; on-chip results vary by chip, supply voltage, and temperature.  No
;;;; production code should rely on these opcodes.
;;;;
;;;;   AHX/SHA, SHX, SHY, TAS:
;;;;     The byte stored is logical-ANDed with (high-byte-of-base + 1).
;;;;     If the indexed addressing crosses a page boundary, real hardware
;;;;     also writes the same ANDed value into the target's high byte,
;;;;     corrupting the destination address.  We do NOT model that
;;;;     fault-injection mode — the value is written to the canonical
;;;;     effective address.
;;;;
;;;;   XAA/ANE ($8B):  A = (A | "magic") AND X AND imm.  The "magic"
;;;;     constant varies (#xEE, #xEF, #xFF, or #x00 have all been
;;;;     observed).  We implement A = X AND imm, the most consistent
;;;;     observed result.
;;;;
;;;;   LAX #imm ($AB):  same family as XAA.  We implement A = X = imm.

(in-package #:atari800-cl.cpu)

;;; ---------------------------------------------------------------------------
;;; Helper functions used by the compound RMW handlers.
;;;
;;; Each compound RMW opcode reads memory, applies a shift/rotate/inc/dec,
;;; writes the result back, then applies a second operation (logical or
;;; arithmetic) to the accumulator using the post-RMW value.

(defun do-dec-byte (value cpu)
  "Decrement VALUE, mask to 8 bits, update Z/N; return the new byte.
Used by DCP.  Same signature shape as DO-ASL/DO-LSR/etc."
  (let ((r (logand (1- value) #xFF)))
    (update-zn cpu r)
    r))

(defun do-inc-byte (value cpu)
  "Increment VALUE, mask to 8 bits, update Z/N; return the new byte.
Used by ISC.  Same signature shape as DO-ASL/DO-LSR/etc."
  (let ((r (logand (1+ value) #xFF)))
    (update-zn cpu r)
    r))

(declaim (inline %ora-acc %and-acc %eor-acc %cmp-acc))

(defun %ora-acc (cpu value)
  "Compound-RMW accumulator step for SLO: A = A | VALUE; update Z/N."
  (setf (cpu-a cpu) (update-zn cpu (logior (cpu-a cpu) value))))

(defun %and-acc (cpu value)
  "Compound-RMW accumulator step for RLA: A = A AND VALUE; update Z/N."
  (setf (cpu-a cpu) (update-zn cpu (logand (cpu-a cpu) value))))

(defun %eor-acc (cpu value)
  "Compound-RMW accumulator step for SRE: A = A XOR VALUE; update Z/N."
  (setf (cpu-a cpu) (update-zn cpu (logxor (cpu-a cpu) value))))

(defun %cmp-acc (cpu value)
  "Compound-RMW accumulator step for DCP: compare A with VALUE; update C/Z/N."
  (do-cmp cpu (cpu-a cpu) value))

;;; ---------------------------------------------------------------------------
;;; Compound RMW: SLO / RLA / SRE / RRA / DCP / ISC
;;;
;;; Cycle counts (no page-cross penalty for RMW on the NMOS 6502):
;;;   (zp,X)   — 8
;;;   zp       — 5
;;;   abs      — 6
;;;   (zp),Y   — 8
;;;   zp,X     — 6
;;;   abs,Y    — 7
;;;   abs,X    — 7

(macrolet ((crmw (mnemonic op mode base rmw-fn acc-fn)
             (let ((tag (intern (format nil "~A-~A" mnemonic
                                        (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (addr) (,mode cpu)
                    (let* ((v (cpu-read-byte cpu addr))
                           (r (,rmw-fn v cpu)))
                      (cpu-write-byte cpu addr r)
                      (,acc-fn cpu r)))
                  ,base))))
  ;; --- SLO  (ASL then ORA) ---
  (crmw "SLO" #x03 addr-indexed-indirect  8 do-asl %ora-acc)
  (crmw "SLO" #x07 addr-zero-page         5 do-asl %ora-acc)
  (crmw "SLO" #x0F addr-absolute          6 do-asl %ora-acc)
  (crmw "SLO" #x13 addr-indirect-indexed  8 do-asl %ora-acc)
  (crmw "SLO" #x17 addr-zero-page-x       6 do-asl %ora-acc)
  (crmw "SLO" #x1B addr-absolute-y        7 do-asl %ora-acc)
  (crmw "SLO" #x1F addr-absolute-x        7 do-asl %ora-acc)
  ;; --- RLA  (ROL then AND) ---
  (crmw "RLA" #x23 addr-indexed-indirect  8 do-rol %and-acc)
  (crmw "RLA" #x27 addr-zero-page         5 do-rol %and-acc)
  (crmw "RLA" #x2F addr-absolute          6 do-rol %and-acc)
  (crmw "RLA" #x33 addr-indirect-indexed  8 do-rol %and-acc)
  (crmw "RLA" #x37 addr-zero-page-x       6 do-rol %and-acc)
  (crmw "RLA" #x3B addr-absolute-y        7 do-rol %and-acc)
  (crmw "RLA" #x3F addr-absolute-x        7 do-rol %and-acc)
  ;; --- SRE  (LSR then EOR) ---
  (crmw "SRE" #x43 addr-indexed-indirect  8 do-lsr %eor-acc)
  (crmw "SRE" #x47 addr-zero-page         5 do-lsr %eor-acc)
  (crmw "SRE" #x4F addr-absolute          6 do-lsr %eor-acc)
  (crmw "SRE" #x53 addr-indirect-indexed  8 do-lsr %eor-acc)
  (crmw "SRE" #x57 addr-zero-page-x       6 do-lsr %eor-acc)
  (crmw "SRE" #x5B addr-absolute-y        7 do-lsr %eor-acc)
  (crmw "SRE" #x5F addr-absolute-x        7 do-lsr %eor-acc)
  ;; --- RRA  (ROR then ADC)  ---
  ;; ROR updates C from old bit 0; that new C is then used as the ADC carry-in.
  (crmw "RRA" #x63 addr-indexed-indirect  8 do-ror do-adc)
  (crmw "RRA" #x67 addr-zero-page         5 do-ror do-adc)
  (crmw "RRA" #x6F addr-absolute          6 do-ror do-adc)
  (crmw "RRA" #x73 addr-indirect-indexed  8 do-ror do-adc)
  (crmw "RRA" #x77 addr-zero-page-x       6 do-ror do-adc)
  (crmw "RRA" #x7B addr-absolute-y        7 do-ror do-adc)
  (crmw "RRA" #x7F addr-absolute-x        7 do-ror do-adc)
  ;; --- DCP  (DEC then CMP) ---
  (crmw "DCP" #xC3 addr-indexed-indirect  8 do-dec-byte %cmp-acc)
  (crmw "DCP" #xC7 addr-zero-page         5 do-dec-byte %cmp-acc)
  (crmw "DCP" #xCF addr-absolute          6 do-dec-byte %cmp-acc)
  (crmw "DCP" #xD3 addr-indirect-indexed  8 do-dec-byte %cmp-acc)
  (crmw "DCP" #xD7 addr-zero-page-x       6 do-dec-byte %cmp-acc)
  (crmw "DCP" #xDB addr-absolute-y        7 do-dec-byte %cmp-acc)
  (crmw "DCP" #xDF addr-absolute-x        7 do-dec-byte %cmp-acc)
  ;; --- ISC / ISB  (INC then SBC) ---
  (crmw "ISC" #xE3 addr-indexed-indirect  8 do-inc-byte do-sbc)
  (crmw "ISC" #xE7 addr-zero-page         5 do-inc-byte do-sbc)
  (crmw "ISC" #xEF addr-absolute          6 do-inc-byte do-sbc)
  (crmw "ISC" #xF3 addr-indirect-indexed  8 do-inc-byte do-sbc)
  (crmw "ISC" #xF7 addr-zero-page-x       6 do-inc-byte do-sbc)
  (crmw "ISC" #xFB addr-absolute-y        7 do-inc-byte do-sbc)
  (crmw "ISC" #xFF addr-absolute-x        7 do-inc-byte do-sbc))

;;; ---------------------------------------------------------------------------
;;; LAX — Load A and X from the same effective address.
;;;
;;; Cycle counts mirror LDA / LDX:
;;;   (zp,X)  — 6     zp      — 3     abs     — 4
;;;   (zp),Y  — 5+1   zp,Y    — 4     abs,Y   — 4+1
;;;   #imm    — 2  (UNSTABLE — see file header)

(macrolet ((lax (op mode base &key page-cross)
             (let ((tag (intern (format nil "LAX-~A" (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (val xp?) (read-via cpu #',mode)
                    (declare (ignorable xp?))
                    (setf (cpu-a cpu) val
                          (cpu-x cpu) val)
                    (update-zn cpu val)
                    (+ ,base ,(if page-cross '(if xp? 1 0) 0)))))))
  (lax #xA3 addr-indexed-indirect  6)
  (lax #xA7 addr-zero-page         3)
  (lax #xAF addr-absolute          4)
  (lax #xB3 addr-indirect-indexed  5 :page-cross t)
  (lax #xB7 addr-zero-page-y       4)
  (lax #xBF addr-absolute-y        4 :page-cross t))

(defopcode #xAB lax-imm (cpu)
  "LAX #imm — UNSTABLE.  Hardware computes A = X = (A | magic) AND imm.
We implement the consistent A = X = imm (see file header)."
  (multiple-value-bind (val) (read-via cpu #'addr-immediate)
    (setf (cpu-a cpu) val
          (cpu-x cpu) val)
    (update-zn cpu val))
  2)

;;; ---------------------------------------------------------------------------
;;; SAX — Store (A AND X) to memory.  No flags affected.

(macrolet ((sax (op mode base)
             (let ((tag (intern (format nil "SAX-~A" (%mode->suffix mode))
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (multiple-value-bind (addr) (,mode cpu)
                    (cpu-write-byte cpu addr
                                    (logand (cpu-a cpu) (cpu-x cpu))))
                  ,base))))
  (sax #x83 addr-indexed-indirect  6)
  (sax #x87 addr-zero-page         3)
  (sax #x8F addr-absolute          4)
  (sax #x97 addr-zero-page-y       4))

;;; ---------------------------------------------------------------------------
;;; Bitwise / accumulator immediate-mode opcodes
;;;
;;; All take 2 cycles and consume one immediate operand byte.

(defun %anc (cpu)
  "Body of ANC #imm: A = A AND imm; Z/N from A; C = N (i.e., bit 7 of result)."
  (multiple-value-bind (val) (read-via cpu #'addr-immediate)
    (let ((r (logand (cpu-a cpu) val)))
      (setf (cpu-a cpu) (update-zn cpu r))
      (set-flag-to cpu +flag-c+ (not (zerop (logand r #x80)))))))

(defopcode #x0B anc-0B (cpu) (%anc cpu) 2)
(defopcode #x2B anc-2B (cpu) (%anc cpu) 2)   ; same instruction, separate opcode

(defopcode #x4B alr (cpu)
  "ALR / ASR #imm:  A = A AND imm, then A = LSR A.
Flags: C = old bit 0 of (A AND imm), Z/N from final A."
  (multiple-value-bind (val) (read-via cpu #'addr-immediate)
    (let ((tmp (logand (cpu-a cpu) val)))
      (setf (cpu-a cpu) (do-lsr tmp cpu))))
  2)

(defopcode #x6B arr (cpu)
  "ARR #imm:  A = A AND imm, then A = ROR A (carry-in from current C).
Quirk flags (binary mode):
  N = bit 7 of result
  Z = (result == 0)
  C = bit 6 of result        (NOT the bit that fell off!)
  V = bit 6 XOR bit 5 of result
ARR's decimal-mode flag behaviour is NOT emulated (atari800-cl does not
exercise BCD via this opcode)."
  (multiple-value-bind (val) (read-via cpu #'addr-immediate)
    (let* ((tmp (logand (cpu-a cpu) val))
           (cin (if (flag-set? cpu +flag-c+) #x80 0))
           (r   (logand (logior (ash tmp -1) cin) #xFF)))
      (setf (cpu-a cpu) r)
      (set-flag-to cpu +flag-z+ (zerop r))
      (set-flag-to cpu +flag-n+ (not (zerop (logand r #x80))))
      (set-flag-to cpu +flag-c+ (not (zerop (logand r #x40))))
      ;; Bit6 at position 6, bit5 shifted up to position 6 → XOR is 0x40
      ;; precisely when they differ.
      (set-flag-to cpu +flag-v+
                   (not (zerop (logxor (logand r #x40)
                                       (ash (logand r #x20) 1)))))))
  2)

(defopcode #x8B xaa (cpu)
  "XAA / ANE #imm — UNSTABLE.  Hardware: A = (A | magic) AND X AND imm.
We implement A = X AND imm (see file header)."
  (multiple-value-bind (val) (read-via cpu #'addr-immediate)
    (setf (cpu-a cpu) (update-zn cpu (logand (cpu-x cpu) val))))
  2)

(defopcode #xCB axs (cpu)
  "AXS / SBX #imm:  X = (A AND X) - imm.
Flags: C set if (A AND X) >= imm (no borrow), Z/N from X.  V is unchanged.
Carry-in is NOT consulted (unlike SBC)."
  (multiple-value-bind (val) (read-via cpu #'addr-immediate)
    (let* ((ax   (logand (cpu-a cpu) (cpu-x cpu)))
           (diff (- ax val)))
      (set-flag-to cpu +flag-c+ (>= ax val))
      (setf (cpu-x cpu) (update-zn cpu (logand diff #xFF)))))
  2)

(defopcode #xBB las (cpu)
  "LAS abs,Y:  A = X = SP = (M AND SP); update Z/N.  +1 cycle on page cross."
  (multiple-value-bind (val xp?) (read-via cpu #'addr-absolute-y)
    (let ((r (logand val (cpu-sp cpu))))
      (setf (cpu-a cpu) r
            (cpu-x cpu) r
            (cpu-sp cpu) r)
      (update-zn cpu r))
    (+ 4 (if xp? 1 0))))

;;; ---------------------------------------------------------------------------
;;; Unstable high-byte store variants — AHX/SHA, SHX, SHY, TAS/SHS.
;;;
;;; The "canonical" behaviour stores (register-value AND (high(base)+1)).
;;; HIGH(BASE) is the high byte of the absolute address BEFORE indexing.
;;; These don't use any common addressing-mode helper because we need both
;;; the post-index address (for the write) and the pre-index high byte (for
;;; the AND mask).

(declaim (inline %high+1))

(defun %high+1 (base)
  "Compute (high-byte-of BASE + 1) masked to 8 bits.  Helper for unstable stores."
  (declare (type u16 base))
  (logand (1+ (ash base -8)) #xFF))

(defopcode #x9C shy (cpu)
  "SHY abs,X — UNSTABLE.  M[base+X] = Y AND (high(base)+1)."
  (let* ((base   (read-pc-word cpu))
         (addr   (logand (+ base (cpu-x cpu)) #xFFFF))
         (mask   (%high+1 base))
         (value  (logand (cpu-y cpu) mask)))
    (cpu-write-byte cpu addr value))
  5)

(defopcode #x9E shx (cpu)
  "SHX abs,Y — UNSTABLE.  M[base+Y] = X AND (high(base)+1)."
  (let* ((base   (read-pc-word cpu))
         (addr   (logand (+ base (cpu-y cpu)) #xFFFF))
         (mask   (%high+1 base))
         (value  (logand (cpu-x cpu) mask)))
    (cpu-write-byte cpu addr value))
  5)

(defopcode #x9F ahx-aby (cpu)
  "AHX / SHA abs,Y — UNSTABLE.  M[base+Y] = A AND X AND (high(base)+1)."
  (let* ((base   (read-pc-word cpu))
         (addr   (logand (+ base (cpu-y cpu)) #xFFFF))
         (mask   (%high+1 base))
         (value  (logand (cpu-a cpu) (cpu-x cpu) mask)))
    (cpu-write-byte cpu addr value))
  5)

(defopcode #x93 ahx-indy (cpu)
  "AHX / SHA (zp),Y — UNSTABLE.  M[base+Y] = A AND X AND (high(base)+1)
where BASE is the 16-bit pointer read from zero page."
  (let* ((zp    (read-pc-byte cpu))
         (lo    (cpu-read-byte cpu zp))
         (hi    (cpu-read-byte cpu (logand (1+ zp) #xFF)))
         (base  (logior lo (ash hi 8)))
         (addr  (logand (+ base (cpu-y cpu)) #xFFFF))
         (mask  (logand (1+ hi) #xFF))
         (value (logand (cpu-a cpu) (cpu-x cpu) mask)))
    (cpu-write-byte cpu addr value))
  6)

(defopcode #x9B tas (cpu)
  "TAS / SHS abs,Y — UNSTABLE.  SP = A AND X; M[base+Y] = SP AND (high(base)+1)."
  (let* ((base    (read-pc-word cpu))
         (addr    (logand (+ base (cpu-y cpu)) #xFFFF))
         (new-sp  (logand (cpu-a cpu) (cpu-x cpu)))
         (mask    (%high+1 base))
         (value   (logand new-sp mask)))
    (setf (cpu-sp cpu) new-sp)
    (cpu-write-byte cpu addr value))
  5)

;;; ---------------------------------------------------------------------------
;;; Duplicate SBC immediate.  Atari ROMs occasionally use $EB interchangeably
;;; with $E9 — behaviour is identical.

(defopcode #xEB sbc-imm-dup (cpu)
  "SBC #imm (undocumented duplicate of #xE9)."
  (multiple-value-bind (val) (read-via cpu #'addr-immediate)
    (do-sbc cpu val))
  2)

;;; ---------------------------------------------------------------------------
;;; Multi-byte / extra NOPs.
;;;
;;; Each variant consumes the right number of operand bytes and performs
;;; the effective-address read so that timing on memory-mapped I/O is
;;; preserved.  No registers or flags are touched.

(macrolet
    ;; 1-byte NOPs (implied, 2 cycles): no operand, no read.
    ((nop-imp (op)
       (let ((tag (intern (format nil "NOP-IMP-~2,'0X" op)
                          :atari800-cl.cpu)))
         `(defopcode ,op ,tag (cpu)
            (declare (ignore cpu)) 2))))
  (nop-imp #x1A) (nop-imp #x3A) (nop-imp #x5A)
  (nop-imp #x7A) (nop-imp #xDA) (nop-imp #xFA))

(macrolet
    ;; 2-byte NOPs taking an immediate operand (2 cycles).  Advance PC over
    ;; the operand but don't act on it.
    ((nop-imm (op)
       (let ((tag (intern (format nil "NOP-IMM-~2,'0X" op)
                          :atari800-cl.cpu)))
         `(defopcode ,op ,tag (cpu)
            (read-pc-byte cpu)
            2))))
  (nop-imm #x80) (nop-imm #x82) (nop-imm #x89)
  (nop-imm #xC2) (nop-imm #xE2))

(macrolet
    ;; Zero-page NOPs (3 cycles).  Read the addressed byte for I/O timing.
    ((nop-zp (op)
       (let ((tag (intern (format nil "NOP-ZP-~2,'0X" op)
                          :atari800-cl.cpu)))
         `(defopcode ,op ,tag (cpu)
            (multiple-value-bind (addr) (addr-zero-page cpu)
              (cpu-read-byte cpu addr))
            3))))
  (nop-zp #x04) (nop-zp #x44) (nop-zp #x64))

(macrolet
    ;; Zero-page,X NOPs (4 cycles).
    ((nop-zpx (op)
       (let ((tag (intern (format nil "NOP-ZPX-~2,'0X" op)
                          :atari800-cl.cpu)))
         `(defopcode ,op ,tag (cpu)
            (multiple-value-bind (addr) (addr-zero-page-x cpu)
              (cpu-read-byte cpu addr))
            4))))
  (nop-zpx #x14) (nop-zpx #x34) (nop-zpx #x54)
  (nop-zpx #x74) (nop-zpx #xD4) (nop-zpx #xF4))

;; Absolute NOP (4 cycles).
(defopcode #x0C nop-abs-0C (cpu)
  (multiple-value-bind (addr) (addr-absolute cpu)
    (cpu-read-byte cpu addr))
  4)

(macrolet
    ;; Absolute,X NOPs (4 + 1 on page cross).
    ((nop-abx (op)
       (let ((tag (intern (format nil "NOP-ABX-~2,'0X" op)
                          :atari800-cl.cpu)))
         `(defopcode ,op ,tag (cpu)
            (multiple-value-bind (addr xp?) (addr-absolute-x cpu)
              (cpu-read-byte cpu addr)
              (+ 4 (if xp? 1 0)))))))
  (nop-abx #x1C) (nop-abx #x3C) (nop-abx #x5C)
  (nop-abx #x7C) (nop-abx #xDC) (nop-abx #xFC))

;;; ---------------------------------------------------------------------------
;;; KIL / JAM / STP — the 12 hang opcodes.
;;;
;;; Real NMOS hardware locks the data bus on these — only a hardware
;;; RESET can recover.  We model that as:
;;;   1. set CPU-HALTED to T,
;;;   2. rewind PC by one so it points at the KIL byte again (mimicking the
;;;      "stuck fetching the same opcode forever" hardware behaviour),
;;;   3. signal an ILLEGAL-OPCODE condition so callers learn execution
;;;      stopped.  Re-entering STEP-CPU re-executes the KIL byte and
;;;      signals again — there is no recovery short of RESET-CPU.

(macrolet ((kil (op)
             (let ((tag (intern (format nil "KIL-~2,'0X" op)
                                :atari800-cl.cpu)))
               `(defopcode ,op ,tag (cpu)
                  (setf (cpu-halted cpu) t)
                  (let ((pc-of-kil (logand (1- (cpu-pc cpu)) #xFFFF)))
                    (setf (cpu-pc cpu) pc-of-kil)
                    (error 'illegal-opcode
                           :opcode ,op
                           :pc pc-of-kil))))))
  (kil #x02) (kil #x12) (kil #x22) (kil #x32)
  (kil #x42) (kil #x52) (kil #x62) (kil #x72)
  (kil #x92) (kil #xB2) (kil #xD2) (kil #xF2))

;;; ---------------------------------------------------------------------------
;;; Bookkeeping: identify documented vs illegal opcode slots.
;;;
;;; The dispatch table is now fully populated (256 slots), so the
;;; original DOCUMENTED-OPCODES (which just listed non-NIL slots) would
;;; return all 256.  Replace it with one that filters out
;;; *ILLEGAL-OPCODE-LIST*, and add a sibling ILLEGAL-OPCODES introspector.

(defparameter *illegal-opcode-list*
  '(;; KIL (12)
    #x02 #x12 #x22 #x32 #x42 #x52 #x62 #x72 #x92 #xB2 #xD2 #xF2
    ;; SLO (7)
    #x03 #x07 #x0F #x13 #x17 #x1B #x1F
    ;; RLA (7)
    #x23 #x27 #x2F #x33 #x37 #x3B #x3F
    ;; SRE (7)
    #x43 #x47 #x4F #x53 #x57 #x5B #x5F
    ;; RRA (7)
    #x63 #x67 #x6F #x73 #x77 #x7B #x7F
    ;; DCP (7)
    #xC3 #xC7 #xCF #xD3 #xD7 #xDB #xDF
    ;; ISC (7)
    #xE3 #xE7 #xEF #xF3 #xF7 #xFB #xFF
    ;; SAX (4)
    #x83 #x87 #x8F #x97
    ;; LAX (7) — including unstable LAX-imm
    #xA3 #xA7 #xAB #xAF #xB3 #xB7 #xBF
    ;; ANC (2)
    #x0B #x2B
    ;; ALR, ARR, XAA, AXS (1 each)
    #x4B #x6B #x8B #xCB
    ;; LAS, TAS (1 each)
    #xBB #x9B
    ;; AHX, SHX, SHY (4 total)
    #x93 #x9F #x9E #x9C
    ;; SBC duplicate
    #xEB
    ;; NOP-imp (6)
    #x1A #x3A #x5A #x7A #xDA #xFA
    ;; NOP-imm (5)
    #x80 #x82 #x89 #xC2 #xE2
    ;; NOP-zp (3)
    #x04 #x44 #x64
    ;; NOP-zpx (6)
    #x14 #x34 #x54 #x74 #xD4 #xF4
    ;; NOP-abs (1)
    #x0C
    ;; NOP-abx (6)
    #x1C #x3C #x5C #x7C #xDC #xFC)
  "Canonical list of all NMOS illegal/undocumented opcode bytes (105 total).")

(defun documented-opcodes ()
  "Return the list of officially documented NMOS 6502 opcode bytes installed.
There are 151 documented opcodes; this filters out everything registered in
*ILLEGAL-OPCODE-LIST*."
  (loop for i below 256
        when (and (svref *opcode-table* i)
                  (not (member i *illegal-opcode-list*)))
          collect i))

(defun illegal-opcodes ()
  "Return the list of installed illegal/undocumented opcode bytes (105 total)."
  (loop for i below 256
        when (and (svref *opcode-table* i)
                  (member i *illegal-opcode-list*))
          collect i))
