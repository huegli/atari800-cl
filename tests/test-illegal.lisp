;;;; tests/test-illegal.lisp --- Tests for NMOS 6502 illegal opcodes.
;;;;
;;;; Exercises the handlers installed by src/illegal.lisp.  Uses the same
;;;; bus harness (MAKE-TEST-CPU / WITH-CPU) defined in test-cpu-opcodes.lisp,
;;;; so this file just re-imports those helpers through the test package.
;;;;
;;;; --- FiveAM notes for beginners ---
;;;;
;;;; DEF-SUITE creates a new suite and :IN attaches it under
;;;; ATARI800-CL-SUITE so RUN-TESTS picks it up automatically.
;;;;
;;;; WITH-CPU (in test-cpu-opcodes.lisp) is a thin wrapper that binds CPU
;;;; and RAM from MAKE-TEST-CPU.  Both symbols live in the
;;;; ATARI800-CL/TESTS package, which is the package this file lives in,
;;;; so they're available without qualification.

(in-package #:atari800-cl/tests)

(def-suite illegal-opcodes
  :description "Tests for NMOS 6502 undocumented/illegal opcodes."
  :in atari800-cl-suite)

(in-suite illegal-opcodes)

;;; ---------------------------------------------------------------------------
;;; Dispatch table bookkeeping

(test illegal-opcode-list-has-105-entries
  "*ILLEGAL-OPCODE-LIST* must enumerate exactly 105 distinct NMOS illegals."
  (is (= 105 (length atari800-cl.cpu:*illegal-opcode-list*)))
  ;; Uniqueness guard: the list of distinct bytes equals the list itself.
  (is (= 105 (length (remove-duplicates
                      atari800-cl.cpu:*illegal-opcode-list*)))))

(test all-256-dispatch-slots-now-populated
  "After illegal.lisp loads, every byte 0..255 has a handler installed."
  (loop for i below 256
        do (is (svref atari800-cl.cpu:*opcode-table* i)
               "Opcode #x~2,'0X has no handler installed" i)))

(test documented-opcodes-still-151
  "Filtering illegal entries leaves the original 151 documented opcodes."
  (is (= 151 (length (atari800-cl.cpu:documented-opcodes)))))

(test illegal-opcodes-introspector
  "ILLEGAL-OPCODES returns the 105 installed illegal-opcode bytes."
  (let ((found (atari800-cl.cpu:illegal-opcodes)))
    (is (= 105 (length found)))
    ;; Every entry in the registered list must be reported back.
    (dolist (op atari800-cl.cpu:*illegal-opcode-list*)
      (is (member op found)
          "Illegal opcode #x~2,'0X not reported by ILLEGAL-OPCODES" op))))

;;; ---------------------------------------------------------------------------
;;; SLO  (ASL then ORA)

(test slo-zp-shifts-memory-then-ors-accumulator
  "SLO $zp: ASL memory (carry from old bit 7), then ORA result into A."
  (with-cpu (cpu ram :program (list #x07 #x10))   ; SLO $10
    (setf (aref ram #x10) #b10000001              ; old bit 7 set → carry
          (cpu-a cpu)      #x10
          (cpu-flags cpu)  #x24)                  ; U=1, I=1, C=0
    (let ((cycles (step-cpu cpu)))
      (is (= 5 cycles))
      ;; ASL of #b10000001 = #b00000010 (bit 0 was 1, bit 7 was 1).
      (is (= #b00000010 (aref ram #x10)))
      ;; Carry must reflect old bit 7.
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
      ;; A = #x10 OR #x02 = #x12
      (is (= #x12 (cpu-a cpu)))
      ;; Z=0, N=0 from final A
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+)))))

;;; ---------------------------------------------------------------------------
;;; RLA  (ROL then AND)

(test rla-zp-rotates-memory-then-ands-accumulator
  "RLA $zp: ROL memory (carry-in from C), then AND result into A."
  (with-cpu (cpu ram :program (list #x27 #x20))   ; RLA $20
    (setf (aref ram #x20) #x55                    ; #b01010101
          (cpu-a cpu)     #xAA
          (cpu-flags cpu) #x24)                   ; C=0 in
    ;; Set carry-in to ROL by setting C first.
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (let ((cycles (step-cpu cpu)))
      (is (= 5 cycles))
      ;; ROL #x55 with C=1 in: #b10101011 = #xAB; bit-7-out = 0 → carry cleared.
      (is (= #xAB (aref ram #x20)))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
      ;; AND: #xAA AND #xAB = #xAA
      (is (= #xAA (cpu-a cpu)))
      ;; N=1 (high bit of AA), Z=0
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+)))))

;;; ---------------------------------------------------------------------------
;;; SRE  (LSR then EOR)

(test sre-zp-shifts-memory-then-eors-accumulator
  "SRE $zp: LSR memory (carry from old bit 0), then EOR result into A."
  (with-cpu (cpu ram :program (list #x47 #x30))   ; SRE $30
    (setf (aref ram #x30) #b00000011              ; bit 0 set → carry
          (cpu-a cpu)     #xF0
          (cpu-flags cpu) #x24)
    (let ((cycles (step-cpu cpu)))
      (is (= 5 cycles))
      ;; LSR of #b00000011 = #b00000001
      (is (= #x01 (aref ram #x30)))
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
      ;; A = #xF0 XOR #x01 = #xF1
      (is (= #xF1 (cpu-a cpu))))))

;;; ---------------------------------------------------------------------------
;;; RRA  (ROR then ADC)

(test rra-zp-rotates-memory-then-adcs-accumulator
  "RRA $zp: ROR memory, then ADC the rotated value into A using new C."
  (with-cpu (cpu ram :program (list #x67 #x40))   ; RRA $40
    (setf (aref ram #x40) #b00000010              ; ROR → #b00000001, bit0 was 0 → C=0
          (cpu-a cpu)     #x10
          (cpu-flags cpu) #x24)
    (let ((cycles (step-cpu cpu)))
      (is (= 5 cycles))
      ;; ROR with C=0 in: bit 7 of result = 0, result = #x01, C out = 0.
      (is (= #x01 (aref ram #x40)))
      ;; ADC: A = #x10 + #x01 + C(=0) = #x11
      (is (= #x11 (cpu-a cpu)))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+)))))

;;; ---------------------------------------------------------------------------
;;; DCP  (DEC then CMP)

(test dcp-zp-decrements-memory-then-compares-with-a
  "DCP $zp: DEC memory, then CMP A against the new value."
  (with-cpu (cpu ram :program (list #xC7 #x50))   ; DCP $50
    (setf (aref ram #x50) #x05
          (cpu-a cpu)     #x04
          (cpu-flags cpu) #x24)
    (let ((cycles (step-cpu cpu)))
      (is (= 5 cycles))
      ;; Memory decremented to #x04.
      (is (= #x04 (aref ram #x50)))
      ;; CMP A=#x04 against M=#x04 → Z=1, C=1, N=0.
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))
      ;; A is unchanged by CMP.
      (is (= #x04 (cpu-a cpu))))))

;;; ---------------------------------------------------------------------------
;;; ISC  (INC then SBC)

(test isc-zp-increments-memory-then-sbcs-from-a
  "ISC $zp: INC memory, then SBC the new value from A (using current C)."
  (with-cpu (cpu ram :program (list #xE7 #x60))   ; ISC $60
    (setf (aref ram #x60) #x09
          (cpu-a cpu)     #x20
          (cpu-flags cpu) #x24)
    ;; Carry must be set going into SBC (no borrow).
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (let ((cycles (step-cpu cpu)))
      (is (= 5 cycles))
      ;; Memory: #x09 → #x0A
      (is (= #x0A (aref ram #x60)))
      ;; SBC: A = #x20 - #x0A - 0 = #x16
      (is (= #x16 (cpu-a cpu)))
      ;; C should remain set (no borrow occurred).
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+)))))

;;; ---------------------------------------------------------------------------
;;; LAX  (LDA + LDX)

(test lax-zp-loads-both-a-and-x
  "LAX $zp: A and X both receive the loaded byte; Z/N updated from it."
  (with-cpu (cpu ram :program (list #xA7 #x40))   ; LAX $40
    (setf (aref ram #x40) #x80
          (cpu-flags cpu) #x24)
    (let ((cycles (step-cpu cpu)))
      (is (= 3 cycles))
      (is (= #x80 (cpu-a cpu)))
      (is (= #x80 (cpu-x cpu)))
      ;; #x80 sets N, not Z.
      (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+)))))

(test lax-imm-loads-immediate-into-a-and-x
  "LAX #imm — unstable, but our canonical implementation sets A = X = imm."
  (with-cpu (cpu ram :program (list #xAB #x42))
    (declare (ignore ram))
    (setf (cpu-flags cpu) #x24)
    (let ((cycles (step-cpu cpu)))
      (is (= 2 cycles))
      (is (= #x42 (cpu-a cpu)))
      (is (= #x42 (cpu-x cpu))))))

;;; ---------------------------------------------------------------------------
;;; SAX  (A AND X → memory; no flags touched)

(test sax-zp-stores-and-of-a-and-x-without-touching-flags
  "SAX $zp writes A AND X to memory; flags are untouched."
  (with-cpu (cpu ram :program (list #x87 #x70))   ; SAX $70
    (setf (cpu-a cpu)     #xCC
          (cpu-x cpu)     #xAA
          (cpu-flags cpu) #x24)
    (let* ((flags-before (cpu-flags cpu))
           (cycles       (step-cpu cpu)))
      (is (= 3 cycles))
      ;; #xCC AND #xAA = #x88
      (is (= #x88 (aref ram #x70)))
      ;; Flags untouched (no Z, N, C update).
      (is (= flags-before (cpu-flags cpu))))))

;;; ---------------------------------------------------------------------------
;;; ANC  — A = A AND imm; C = N (bit 7 of result).

(test anc-sets-carry-equal-to-bit7
  "ANC #imm: A := A AND imm; carry copies bit 7 of the result."
  ;; Case 1: result has bit 7 set → N=1, C=1.
  (with-cpu (cpu ram :program (list #x0B #xF0))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xFF
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    (is (= #xF0 (cpu-a cpu)))
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+)))
  ;; Case 2: zero result → Z=1, C=0.
  (with-cpu (cpu ram :program (list #x2B #x00))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xFF
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    (is (= 0 (cpu-a cpu)))
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

;;; ---------------------------------------------------------------------------
;;; ALR  — A = A AND imm, then A = LSR A.

(test alr-and-then-lsr-flags
  "ALR #imm: AND then LSR.  C is the low bit of the AND result."
  (with-cpu (cpu ram :program (list #x4B #x03))   ; A AND $03 then LSR
    (declare (ignore ram))
    (setf (cpu-a cpu) #xFF
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    ;; AND: #xFF AND #x03 = #x03; LSR → #x01, C = old bit 0 = 1.
    (is (= #x01 (cpu-a cpu)))
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

;;; ---------------------------------------------------------------------------
;;; ARR  — A = A AND imm, then A = ROR A with carry-in.
;;;
;;; Flag quirks (binary mode):
;;;   N = bit 7 of result
;;;   Z = (result == 0)
;;;   C = bit 6 of result
;;;   V = bit 6 XOR bit 5 of result

(test arr-flag-quirks
  "ARR #imm: C from bit 6 of result, V from bit 6 XOR bit 5."
  ;; A=#xFF, imm=#xFF, C=0 in.  AND → #xFF, ROR with 0-in → #x7F.
  ;; Bit 6 of #x7F = 1, bit 5 = 1 → C=1, V=0.
  (with-cpu (cpu ram :program (list #x6B #xFF))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xFF
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    (is (= #x7F (cpu-a cpu)))
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-v+)))
  ;; A=#xFF, imm=#x80, C=0 in.  AND → #x80, ROR → #x40.
  ;; Bit 6 of #x40 = 1, bit 5 = 0 → C=1, V=1.
  (with-cpu (cpu ram :program (list #x6B #x80))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xFF
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    (is (= #x40 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-v+))))

;;; ---------------------------------------------------------------------------
;;; AXS / SBX  — X = (A AND X) - imm.  C = 1 if (A AND X) >= imm.

(test axs-subtracts-imm-from-a-and-x
  "AXS #imm: X := (A AND X) - imm; C set if no borrow."
  (with-cpu (cpu ram :program (list #xCB #x03))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x0F
          (cpu-x cpu) #x07            ; A AND X = #x07
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    ;; #x07 - #x03 = #x04, no borrow → C=1.
    (is (= #x04 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+)))
  ;; Borrow case: imm > A AND X.
  (with-cpu (cpu ram :program (list #xCB #x20))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x05
          (cpu-x cpu) #x05            ; A AND X = #x05
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    ;; #x05 - #x20 = #xE5 (wraps), borrow → C=0, N=1.
    (is (= #xE5 (cpu-x cpu)))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

;;; ---------------------------------------------------------------------------
;;; KIL / JAM / STP — unrecoverable halt.

(test all-twelve-kil-slots-have-handlers
  "Every KIL/JAM/STP byte has a non-NIL dispatch slot."
  (dolist (op '(#x02 #x12 #x22 #x32 #x42 #x52 #x62 #x72 #x92 #xB2 #xD2 #xF2))
    (is (svref atari800-cl.cpu:*opcode-table* op)
        "KIL opcode #x~2,'0X has no handler" op)))

(test kil-handler-signals-and-halts
  "Executing a KIL opcode signals ILLEGAL-OPCODE and sets cpu-halted."
  (with-cpu (cpu ram :program (list #x12))   ; KIL ($12)
    (declare (ignore ram))
    (signals atari800-cl.cpu:illegal-opcode (step-cpu cpu))
    (is-true (cpu-halted cpu))
    ;; PC must be rewound to point at the KIL byte (so a re-fetch re-hits it).
    (is (= #x0200 (cpu-pc cpu)))))

(test kil-is-unrecoverable
  "Stepping again after a KIL re-signals — there is no recovery short of reset."
  (with-cpu (cpu ram :program (list #x02))   ; KIL ($02)
    (declare (ignore ram))
    (signals atari800-cl.cpu:illegal-opcode (step-cpu cpu))
    (signals atari800-cl.cpu:illegal-opcode (step-cpu cpu))
    (is-true (cpu-halted cpu))))

;;; ---------------------------------------------------------------------------
;;; Multi-byte NOP cycle counts and PC advancement

(test nop-implied-undoc-cycles
  "All six undocumented 1-byte NOPs are 2 cycles."
  (dolist (op '(#x1A #x3A #x5A #x7A #xDA #xFA))
    (with-cpu (cpu ram :program (list op))
      (declare (ignore ram))
      (is (= 2 (step-cpu cpu))
          "NOP #x~2,'0X should be 2 cycles" op)
      ;; PC advanced by 1.
      (is (= #x0201 (cpu-pc cpu))))))

(test nop-immediate-2byte-cycles
  "Undocumented 2-byte immediate NOPs are 2 cycles and advance PC by 2."
  (dolist (op '(#x80 #x82 #x89 #xC2 #xE2))
    (with-cpu (cpu ram :program (list op #x55))
      (declare (ignore ram))
      (is (= 2 (step-cpu cpu)))
      (is (= #x0202 (cpu-pc cpu))))))

(test nop-zero-page-cycles
  "Undocumented zero-page NOPs are 3 cycles, PC += 2."
  (dolist (op '(#x04 #x44 #x64))
    (with-cpu (cpu ram :program (list op #x10))
      (declare (ignore ram))
      (is (= 3 (step-cpu cpu)))
      (is (= #x0202 (cpu-pc cpu))))))

(test nop-zero-page-x-cycles
  "Undocumented zero-page,X NOPs are 4 cycles, PC += 2."
  (dolist (op '(#x14 #x34 #x54 #x74 #xD4 #xF4))
    (with-cpu (cpu ram :program (list op #x10))
      (declare (ignore ram))
      (setf (cpu-x cpu) #x05)
      (is (= 4 (step-cpu cpu)))
      (is (= #x0202 (cpu-pc cpu))))))

(test nop-absolute-cycles
  "Undocumented $0C absolute NOP is 4 cycles, PC += 3."
  (with-cpu (cpu ram :program (list #x0C #x00 #x80))
    (declare (ignore ram))
    (is (= 4 (step-cpu cpu)))
    (is (= #x0203 (cpu-pc cpu)))))

(test nop-absolute-x-no-page-cross
  "Undocumented abs,X NOPs are 4 cycles when no page is crossed."
  (dolist (op '(#x1C #x3C #x5C #x7C #xDC #xFC))
    (with-cpu (cpu ram :program (list op #x10 #x20))   ; base $2010
      (declare (ignore ram))
      (setf (cpu-x cpu) #x05)            ; eff = $2015, same page
      (is (= 4 (step-cpu cpu)))
      (is (= #x0203 (cpu-pc cpu))))))

(test nop-absolute-x-page-cross-adds-cycle
  "Undocumented abs,X NOPs add +1 cycle when X causes a page cross."
  (dolist (op '(#x1C #x3C #x5C #x7C #xDC #xFC))
    (with-cpu (cpu ram :program (list op #xF0 #x20))   ; base $20F0
      (declare (ignore ram))
      (setf (cpu-x cpu) #x20)            ; eff = $2110 → crosses page
      (is (= 5 (step-cpu cpu)))
      (is (= #x0203 (cpu-pc cpu))))))

;;; ---------------------------------------------------------------------------
;;; SBC duplicate ($EB)

(test sbc-imm-duplicate-EB-matches-E9
  "$EB SBC #imm produces identical results to documented $E9."
  ;; Run the duplicate; compare against the canonical SBC immediate.
  (with-cpu (cpu1 ram1 :program (list #xEB #x10))
    (declare (ignore ram1))
    (setf (cpu-a cpu1) #x40 (cpu-flags cpu1) #x24)
    (atari800-cl.cpu:set-flag cpu1 atari800-cl.cpu:+flag-c+)
    (step-cpu cpu1)
    (with-cpu (cpu2 ram2 :program (list #xE9 #x10))
      (declare (ignore ram2))
      (setf (cpu-a cpu2) #x40 (cpu-flags cpu2) #x24)
      (atari800-cl.cpu:set-flag cpu2 atari800-cl.cpu:+flag-c+)
      (step-cpu cpu2)
      (is (= (cpu-a cpu1) (cpu-a cpu2)))
      (is (= (cpu-flags cpu1) (cpu-flags cpu2))))))

;;; ---------------------------------------------------------------------------
;;; NMOS RMW double-write quirk on the compound RMWs
;;; (SCANLINE_ACCURACY_PLAN.md Phase 5 item 1 / ROADMAP.md Phase 17):
;;; pinned with INSTALL-BUS-RECORDER so the exact bus trace is under test.

(test slo-zero-page-double-writes-unmodified-then-modified
  "SLO $10 (compound RMW, zero page) writes the unmodified byte, then the
shifted one, before ORing into A."
  (with-cpu (cpu ram :program (list #x07 #x10))   ; SLO $10
    (setf (aref ram #x10) #x81)
    (let ((recorder (install-bus-recorder cpu)))
      (is (= 5 (step-cpu cpu)))
      (let ((log (bus-recorder-log recorder)))
        (is (= 5 (length log)))
        (is (equal (list #x0010 #x81 :write) (aref log 3)))
        (is (equal (list #x0010 #x02 :write) (aref log 4)))))))

(test isc-absolute-double-writes-unmodified-then-modified
  "ISC $2000 (compound RMW: INC then SBC) writes the unmodified byte,
then the incremented one, before subtracting from A."
  (with-cpu (cpu ram :program (list #xEF #x00 #x20))   ; ISC $2000
    (setf (aref ram #x2000) #x0F
          (cpu-a cpu) #x20)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (let ((recorder (install-bus-recorder cpu)))
      (is (= 6 (step-cpu cpu)))
      (let ((log (bus-recorder-log recorder)))
        (is (= 6 (length log)))
        (is (equal (list #x2000 #x0F :write) (aref log 4)))
        (is (equal (list #x2000 #x10 :write) (aref log 5)))))))

;;; ---------------------------------------------------------------------------
;;; NMOS indexed-addressing dummy reads on the illegal opcodes
;;; (SCANLINE_ACCURACY_PLAN.md Phase 5 item 2 / ROADMAP.md Phase 17).

(test dcp-absolute-x-always-dummy-reads-then-double-writes
  "DCP $2000,X (compound RMW, no cross since X=$00) dummy-reads the
un-carried address unconditionally, reads, then double-writes the
decremented value."
  (with-cpu (cpu ram :program (list #xDF #x00 #x20))   ; DCP $2000,X
    (setf (cpu-x cpu) #x00
          (aref ram #x2000) #x05
          (cpu-a cpu) #x05)
    (let ((recorder (install-bus-recorder cpu)))
      (is (= 7 (step-cpu cpu)))
      (let ((log (bus-recorder-log recorder)))
        ;; log: opcode, low operand byte, high operand byte, dummy, real
        ;; read, write-unmodified, write-modified.
        (is (= 7 (length log)))
        (is (equal (list #x2000 #x05 :read)  (aref log 3)))  ; dummy
        (is (equal (list #x2000 #x05 :read)  (aref log 4)))  ; real read
        (is (equal (list #x2000 #x05 :write) (aref log 5)))  ; unmodified
        (is (equal (list #x2000 #x04 :write) (aref log 6)))) ; modified
      ;; DCP compares A (still $05) against the DECREMENTED value ($04):
      ;; A > value, so carry is set (no borrow) and zero is clear.
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+)))))

(test lax-indexed-indirect-dummy-reads-unindexed-pointer
  "LAX ($10,X) dummy-reads the UNINDEXED zero-page pointer address ($10)
before adding X, then fetches the 16-bit pointer from the indexed one."
  (with-cpu (cpu ram :program (list #xA3 #x10))   ; LAX ($10,X)
    (setf (cpu-x cpu) #x04
          (aref ram #x10) #xFF        ; dummy-read value (discarded)
          (aref ram #x14) #x00        ; pointer low byte
          (aref ram #x15) #x30        ; pointer high byte
          (aref ram #x3000) #x77)     ; target value
    (let ((recorder (install-bus-recorder cpu)))
      (is (= 6 (step-cpu cpu)))
      (is (= #x77 (cpu-a cpu)))
      (is (= #x77 (cpu-x cpu)))
      (let ((log (bus-recorder-log recorder)))
        ;; log: opcode, operand fetch, dummy (unindexed ptr), ptr-lo,
        ;; ptr-hi, real read.
        (is (= 6 (length log)))
        (is (equal (list #x0010 #xFF :read) (aref log 2)))
        (is (equal (list #x3000 #x77 :read) (aref log 5)))))))

(test nop-implied-illegal-dummy-reads-pc
  "The illegal 1-byte implied NOPs ($1A $3A $5A $7A $DA $FA) dummy-read
the current PC on their second cycle, like every other implied opcode."
  (dolist (op '(#x1A #x3A #x5A #x7A #xDA #xFA))
    (with-cpu (cpu ram :program (list op))
      (setf (aref ram #x0201) #x99)
      (let ((recorder (install-bus-recorder cpu)))
        (is (= 2 (step-cpu cpu)))
        (let ((log (bus-recorder-log recorder)))
          (is (= 2 (length log)))
          (is (equal (list #x0201 #x99 :read) (aref log 1))))))))
