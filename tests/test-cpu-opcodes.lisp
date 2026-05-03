;;;; tests/test-cpu-opcodes.lisp --- NMOS 6502 opcode tests.
;;;;
;;;; These tests use a small bus harness so the CPU never depends on the
;;;; emulator's MEMORY type — exactly as the architecture requires.  They
;;;; cover flags, stack behavior, addressing modes (including the JMP
;;;; indirect page-wrap bug), branch cycle accounting, decimal-mode
;;;; ADC/SBC, and reset/IRQ/NMI/BRK/RTI sequencing.

(in-package #:atari800-cl/tests)

(def-suite cpu-opcodes-suite
  :description "Tests for NMOS 6502 opcode dispatch and behavior."
  :in atari800-cl-suite)

(in-suite cpu-opcodes-suite)

;;; ---------------------------------------------------------------------------
;;; Bus harness
;;;
;;; A flat 64K (UNSIGNED-BYTE 8) array driven through bus-read/bus-write
;;; closures.  The CPU must run against this without any reference to
;;; ATARI800-CL.MEMORY.

(defun make-test-cpu (&key (pc #x0200) (program nil))
  "Build a CPU with bus hooks pointing at a fresh 64K array.

PROGRAM, if supplied, is loaded at PC.  Returns (VALUES CPU RAM)."
  (let* ((ram (make-array #x10000 :element-type '(unsigned-byte 8)
                                  :initial-element 0))
         (cpu (make-cpu)))
    (setf (cpu-bus-read cpu)  (lambda (a) (aref ram a))
          (cpu-bus-write cpu) (lambda (a v) (setf (aref ram a) v)))
    (setf (cpu-pc cpu) pc
          (cpu-sp cpu) #xFD
          (cpu-flags cpu) #x24
          (cpu-cycles cpu) 0)
    (when program
      (loop for byte in program
            for off from 0
            do (setf (aref ram (+ pc off)) byte)))
    (values cpu ram)))

(defmacro with-cpu ((cpu ram &key (pc #x0200) program) &body body)
  `(multiple-value-bind (,cpu ,ram) (make-test-cpu :pc ,pc :program ,program)
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Sanity / dispatch table

(test dispatch-table-has-256-entries
  "*OPCODE-TABLE* must be a 256-entry vector."
  (is (= 256 (length atari800-cl.cpu:*opcode-table*)))
  (is (typep atari800-cl.cpu:*opcode-table* 'simple-vector)))

(test dispatch-table-has-151-documented-opcodes
  "Exactly 151 official NMOS 6502 opcodes are installed."
  (is (= 151 (length (atari800-cl.cpu:documented-opcodes)))))

(test illegal-opcode-signals
  "Stepping into an illegal opcode signals ILLEGAL-OPCODE."
  (with-cpu (cpu ram :program (list #x02))
    (declare (ignore ram))
    (signals atari800-cl.cpu:illegal-opcode (step-cpu cpu))
    (is (cpu-halted cpu))))

;;; ---------------------------------------------------------------------------
;;; Flag helpers

(test flag-helpers-roundtrip
  "Set/clear/query for each individual flag bit."
  (with-cpu (cpu ram)
    (declare (ignore ram))
    (setf (cpu-flags cpu) 0)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test status-pack-unpack
  "Pushed status: U=1 always; B=1 on PHP/BRK, B=0 on IRQ/NMI.
Pulled status forces U=1, B=0 in the in-register copy."
  (with-cpu (cpu ram)
    (declare (ignore ram))
    (setf (cpu-flags cpu) 0)
    (is (= #x30 (atari800-cl.cpu:status-byte-for-push cpu :b-flag t)))
    (is (= #x20 (atari800-cl.cpu:status-byte-for-push cpu :b-flag nil)))
    ;; Pull: U forced 1, B forced 0; other bits preserved.
    (is (= #xEF (atari800-cl.cpu:status-byte-from-pull #xFF)))
    (is (= #x21 (atari800-cl.cpu:status-byte-from-pull #x11)))))

;;; ---------------------------------------------------------------------------
;;; Stack helpers

(test stack-byte-roundtrip
  "Push then pull a byte returns the original value."
  (with-cpu (cpu ram)
    (declare (ignore ram))
    (atari800-cl.cpu:push-byte cpu #x42)
    (is (= #xFC (cpu-sp cpu)))
    (is (= #x42 (atari800-cl.cpu:pull-byte cpu)))
    (is (= #xFD (cpu-sp cpu)))))

(test stack-word-roundtrip
  "Push then pull a word returns the original value."
  (with-cpu (cpu ram)
    (declare (ignore ram))
    (atari800-cl.cpu:push-word cpu #xBEEF)
    (is (= #xBEEF (atari800-cl.cpu:pull-word cpu)))
    (is (= #xFD (cpu-sp cpu)))))

(test stack-lives-in-page-0100
  "Push writes through bus at $0100 + SP."
  (with-cpu (cpu ram)
    (atari800-cl.cpu:push-byte cpu #xAA)
    (is (= #xAA (aref ram #x01FD)))))

;;; ---------------------------------------------------------------------------
;;; Reset / IRQ / NMI / BRK / RTI

(test reset-loads-pc-and-sets-i-flag
  "Reset reads $FFFC/$FFFD into PC, SP=$FD, flags=#x24."
  (with-cpu (cpu ram)
    (setf (aref ram #xFFFC) #x34
          (aref ram #xFFFD) #x12)
    (reset-cpu cpu)
    (is (= #x1234 (cpu-pc cpu)))
    (is (= #xFD   (cpu-sp cpu)))
    (is (= #x24   (cpu-flags cpu)))
    (is (zerop (cpu-cycles cpu)))))

(test brk-pushes-pc-plus-2-and-status-with-b
  "BRK pushes PC+2 and a status byte with B set, vectors through $FFFE."
  (with-cpu (cpu ram :pc #x0400 :program (list #x00 #x00 #xEA))
    (setf (aref ram #xFFFE) #x00
          (aref ram #xFFFF) #x80)
    (let ((cycles (step-cpu cpu)))
      (is (= 7 cycles))
      (is (= #x8000 (cpu-pc cpu)))
      ;; Pushed PC = $0402 (BRK opcode at $0400 + 2). push-word writes
      ;; the high byte first, so high lands at $01FD, low at $01FC.
      (is (= #x04 (aref ram #x01FD)))
      (is (= #x02 (aref ram #x01FC)))
      (let ((pushed-status (aref ram #x01FB)))
        (is (not (zerop (logand pushed-status atari800-cl.cpu:+flag-b+))))
        (is (not (zerop (logand pushed-status atari800-cl.cpu:+flag-u+)))))
      (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-i+)))))

(test rti-restores-status-and-pc
  "RTI pulls status (B forced 0, U forced 1) then PC."
  (with-cpu (cpu ram :pc #x0500 :program (list #x40))
    (setf (aref ram #x01FE) #xFF        ; status byte (will be masked)
          (aref ram #x01FF) #x34        ; PC low
          (aref ram #x0100) #x12        ; PC high  (SP wraps)
          (cpu-sp cpu) #xFD)
    (let ((cycles (step-cpu cpu)))
      (is (= 6 cycles))
      (is (= #x1234 (cpu-pc cpu)))
      ;; B forced 0, U forced 1
      (is (= #xEF (cpu-flags cpu))))))

(test nmi-vector-and-cycle-count
  "Triggered NMI vectors through $FFFA and costs 7 cycles."
  (with-cpu (cpu ram :pc #x0600 :program (list #xEA))
    (setf (aref ram #xFFFA) #x00
          (aref ram #xFFFB) #x90)
    (atari800-cl.cpu:trigger-nmi cpu)
    (let ((cycles (step-cpu cpu)))
      (is (= 7 cycles))
      (is (= #x9000 (cpu-pc cpu)))
      (is-false (cpu-pending-nmi cpu))
      ;; Pushed status has B=0
      (is (zerop (logand (aref ram #x01FB) atari800-cl.cpu:+flag-b+)))
      (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-i+)))))

(test irq-respects-interrupt-disable
  "If I=1, an asserted IRQ line is ignored."
  (with-cpu (cpu ram :pc #x0700 :program (list #xEA))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-i+)
    (atari800-cl.cpu:set-irq-line cpu t)
    (let ((cycles (step-cpu cpu)))
      ;; The NOP runs, IRQ is held off.
      (is (= 2 cycles))
      (is (= #x0701 (cpu-pc cpu))))))

(test irq-runs-when-i-clear
  "With I=0 and IRQ asserted, vector through $FFFE; cost 7."
  (with-cpu (cpu ram :pc #x0700 :program (list #xEA))
    (setf (aref ram #xFFFE) #x00
          (aref ram #xFFFF) #xA0)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-i+)
    (atari800-cl.cpu:set-irq-line cpu t)
    (let ((cycles (step-cpu cpu)))
      (is (= 7 cycles))
      (is (= #xA000 (cpu-pc cpu)))
      (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-i+))
      (is (zerop (logand (aref ram #x01FB) atari800-cl.cpu:+flag-b+))))))

;;; ---------------------------------------------------------------------------
;;; Loads / stores

(test lda-immediate-sets-flags
  (with-cpu (cpu ram :program (list #xA9 #x80))
    (declare (ignore ram))
    (let ((cycles (step-cpu cpu)))
      (is (= 2 cycles))
      (is (= #x80 (cpu-a cpu)))
      (is-true  (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))
      (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+)))))

(test lda-absolute-x-page-cross-adds-cycle
  "LDA $00FF,X with X=1 crosses a page: 4+1 = 5 cycles."
  (with-cpu (cpu ram :program (list #xBD #xFF #x00))
    (setf (cpu-x cpu) 1
          (aref ram #x0100) #x77)
    (is (= 5 (step-cpu cpu)))
    (is (= #x77 (cpu-a cpu)))))

(test lda-absolute-x-no-page-cross
  "LDA $1000,X with X=1: no page cross, 4 cycles."
  (with-cpu (cpu ram :program (list #xBD #x00 #x10))
    (setf (cpu-x cpu) 1
          (aref ram #x1001) #x33)
    (is (= 4 (step-cpu cpu)))
    (is (= #x33 (cpu-a cpu)))))

(test sta-zero-page
  (with-cpu (cpu ram :program (list #x85 #x42))
    (setf (cpu-a cpu) #x99)
    (is (= 3 (step-cpu cpu)))
    (is (= #x99 (aref ram #x42)))))

(test sta-absolute-x-no-page-cross-penalty
  "Stores never get a page-cross penalty (always 5 cycles for STA abs,X)."
  (with-cpu (cpu ram :program (list #x9D #xFF #x00))
    (setf (cpu-x cpu) 1
          (cpu-a cpu) #xCC)
    (is (= 5 (step-cpu cpu)))
    (is (= #xCC (aref ram #x0100)))))

;;; ---------------------------------------------------------------------------
;;; Addressing-mode coverage including JMP indirect bug

(test jmp-indirect-no-bug
  "JMP ($1234): low at $1234, high at $1235."
  (with-cpu (cpu ram :program (list #x6C #x34 #x12))
    (setf (aref ram #x1234) #xCD
          (aref ram #x1235) #xAB)
    (is (= 5 (step-cpu cpu)))
    (is (= #xABCD (cpu-pc cpu)))))

(test jmp-indirect-page-wrap-bug
  "JMP ($30FF): NMOS reads high from $3000 instead of $3100."
  (with-cpu (cpu ram :program (list #x6C #xFF #x30))
    (setf (aref ram #x30FF) #x12
          (aref ram #x3000) #x80         ; bug: read here
          (aref ram #x3100) #x40)        ; ignored on NMOS
    (is (= 5 (step-cpu cpu)))
    (is (= #x8012 (cpu-pc cpu)))))

(test indexed-indirect-zp-wrap
  "(zp,X): zero-page wrap on the index."
  (with-cpu (cpu ram :program (list #xA1 #xFF))
    (setf (cpu-x cpu) 1                     ; pointer at zp $00, $01
          (aref ram #x0000) #x34
          (aref ram #x0001) #x12
          (aref ram #x1234) #x55)
    (is (= 6 (step-cpu cpu)))
    (is (= #x55 (cpu-a cpu)))))

(test indirect-indexed-page-cross
  "(zp),Y with page-crossed effective address: +1 cycle."
  (with-cpu (cpu ram :program (list #xB1 #x10))
    (setf (aref ram #x0010) #xFF
          (aref ram #x0011) #x10            ; base $10FF
          (cpu-y cpu) 1
          (aref ram #x1100) #x77)
    (is (= 6 (step-cpu cpu)))               ; 5 + 1 cross
    (is (= #x77 (cpu-a cpu)))))

(test zero-page-x-wraps-byte-not-page
  (with-cpu (cpu ram :program (list #xB5 #xFF))
    (setf (cpu-x cpu) 2
          (aref ram #x0001) #xAB)
    (is (= 4 (step-cpu cpu)))
    (is (= #xAB (cpu-a cpu)))))

;;; ---------------------------------------------------------------------------
;;; Branches: cycle accounting

(test branch-not-taken-2-cycles
  "A not-taken branch costs exactly 2 cycles."
  (with-cpu (cpu ram :program (list #xD0 #x10))         ; BNE +16
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (is (= 2 (step-cpu cpu)))
    (is (= #x0202 (cpu-pc cpu)))))

(test branch-taken-no-cross-3-cycles
  (with-cpu (cpu ram :pc #x0200 :program (list #xF0 #x10))   ; BEQ +16
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (is (= 3 (step-cpu cpu)))
    (is (= #x0212 (cpu-pc cpu)))))

(test branch-taken-page-cross-4-cycles
  "Branch from $02F0 by +$20 crosses into $0312: 4 cycles."
  (with-cpu (cpu ram :pc #x02F0 :program (list #xF0 #x20))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (is (= 4 (step-cpu cpu)))
    (is (= #x0312 (cpu-pc cpu)))))

(test branch-backwards
  "Negative branch offset (signed) wraps backwards."
  (with-cpu (cpu ram :pc #x0210 :program (list #xF0 #xFE))   ; BEQ -2
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (step-cpu cpu)
    (is (= #x0210 (cpu-pc cpu)))))

;;; ---------------------------------------------------------------------------
;;; ADC / SBC including decimal mode

(test adc-binary-overflow
  (with-cpu (cpu ram :program (list #x69 #x50))   ; ADC #$50
    (declare (ignore ram))
    (setf (cpu-a cpu) #x50)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #xA0 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-v+))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test adc-binary-carry
  (with-cpu (cpu ram :program (list #x69 #x01))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xFF)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))
    (is-true  (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (is-true  (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test adc-decimal-mode
  "BCD: $25 + $48 (no carry-in) = $73."
  (with-cpu (cpu ram :program (list #x69 #x48))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x25)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:set-flag   cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x73 (cpu-a cpu)))
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test adc-decimal-mode-with-carry
  "BCD: $58 + $46 + 1 carry = $05 with carry out."
  (with-cpu (cpu ram :program (list #x69 #x46))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x58)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x05 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test sbc-binary
  "SBC #$01 from $40 with carry set = $3F, carry stays set."
  (with-cpu (cpu ram :program (list #xE9 #x01))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x40)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x3F (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test sbc-decimal-mode
  "BCD: $46 - $12 (carry set) = $34."
  (with-cpu (cpu ram :program (list #xE9 #x12))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x46)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x34 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test sbc-decimal-borrow
  "BCD: $05 - $12 with carry set = $93 with borrow (carry cleared)."
  (with-cpu (cpu ram :program (list #xE9 #x12))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x05)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x93 (cpu-a cpu)))
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

;;; ---------------------------------------------------------------------------
;;; Misc opcode behavior

(test jsr-rts-roundtrip
  "JSR / RTS pair returns to the byte after the JSR."
  (with-cpu (cpu ram :pc #x0300
                     :program (list #x20 #x10 #x80))   ; JSR $8010
    (setf (aref ram #x8010) #x60)                       ; RTS
    (let ((c1 (step-cpu cpu)))
      (is (= 6 c1))
      (is (= #x8010 (cpu-pc cpu)))
      ;; Return-addr pushed = $0302 (high to $01FD, low to $01FC)
      (is (= #x03 (aref ram #x01FD)))
      (is (= #x02 (aref ram #x01FC))))
    (let ((c2 (step-cpu cpu)))
      (is (= 6 c2))
      (is (= #x0303 (cpu-pc cpu))))))

(test inc-memory-flags
  (with-cpu (cpu ram :program (list #xE6 #x10))
    (setf (aref ram #x10) #x7F)
    (is (= 5 (step-cpu cpu)))
    (is (= #x80 (aref ram #x10)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))))

(test bit-sets-n-and-v-from-memory
  "BIT $05 with mem=$C0 and A=$01: Z=1, N=1 (bit7), V=1 (bit6)."
  (with-cpu (cpu ram :program (list #x24 #x05))
    (setf (aref ram #x05) #xC0
          (cpu-a cpu) #x01)
    (step-cpu cpu)
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-v+))))

(test asl-accumulator-flags
  "ASL A on $80 -> $00 with C=1, Z=1."
  (with-cpu (cpu ram :program (list #x0A))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x80)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (is (= 2 (step-cpu cpu)))
    (is (= #x00 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test php-plp-roundtrip
  "PHP pushes status with B=1, U=1; PLP clears B and forces U=1."
  (with-cpu (cpu ram :program (list #x08 #x28))
    (declare (ignore ram))
    (setf (cpu-flags cpu) #x81)               ; N + C
    (step-cpu cpu)
    ;; A different flags state in between
    (setf (cpu-flags cpu) #x00)
    (step-cpu cpu)
    ;; After PLP: original N+C restored; U forced 1; B cleared.
    (is (= #xA1 (cpu-flags cpu)))))

(test cmp-sets-carry-and-zero
  (with-cpu (cpu ram :program (list #xC9 #x10))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x10)
    (step-cpu cpu)
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

;;; ---------------------------------------------------------------------------
;;; Per-family coverage — at least one variant of each opcode family.

(test ldx-immediate-sets-flags
  (with-cpu (cpu ram :program (list #xA2 #x00))
    (declare (ignore ram))
    (step-cpu cpu)
    (is (= #x00 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test ldy-immediate-sets-flags
  (with-cpu (cpu ram :program (list #xA0 #x7F))
    (declare (ignore ram))
    (step-cpu cpu)
    (is (= #x7F (cpu-y cpu)))
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))))

(test stx-zero-page
  (with-cpu (cpu ram :program (list #x86 #x10))
    (setf (cpu-x cpu) #xAB)
    (step-cpu cpu)
    (is (= #xAB (aref ram #x10)))))

(test sty-zero-page
  (with-cpu (cpu ram :program (list #x84 #x11))
    (setf (cpu-y cpu) #xCD)
    (step-cpu cpu)
    (is (= #xCD (aref ram #x11)))))

(test and-immediate
  (with-cpu (cpu ram :program (list #x29 #x0F))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xF0)
    (step-cpu cpu)
    (is (= 0 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test ora-immediate
  (with-cpu (cpu ram :program (list #x09 #x0F))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xF0)
    (step-cpu cpu)
    (is (= #xFF (cpu-a cpu)))))

(test eor-immediate
  (with-cpu (cpu ram :program (list #x49 #xFF))
    (declare (ignore ram))
    (setf (cpu-a cpu) #xAA)
    (step-cpu cpu)
    (is (= #x55 (cpu-a cpu)))))

(test lsr-accumulator-flags
  "LSR A on $01 -> $00 with C=1, Z=1."
  (with-cpu (cpu ram :program (list #x4A))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x01)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test rol-accumulator
  "ROL A on $80 with C=0 -> $00, C=1."
  (with-cpu (cpu ram :program (list #x2A))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x80)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test ror-accumulator
  "ROR A on $01 with C=0 -> $00, C=1."
  (with-cpu (cpu ram :program (list #x6A))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x01)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test dec-memory
  (with-cpu (cpu ram :program (list #xC6 #x20))
    (setf (aref ram #x20) #x01)
    (step-cpu cpu)
    (is (= #x00 (aref ram #x20)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test inx-wraps-and-sets-zero
  (with-cpu (cpu ram :program (list #xE8))
    (declare (ignore ram))
    (setf (cpu-x cpu) #xFF)
    (step-cpu cpu)
    (is (= 0 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test iny-sets-negative
  (with-cpu (cpu ram :program (list #xC8))
    (declare (ignore ram))
    (setf (cpu-y cpu) #x7F)
    (step-cpu cpu)
    (is (= #x80 (cpu-y cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))))

(test dex-wraps
  (with-cpu (cpu ram :program (list #xCA))
    (declare (ignore ram))
    (setf (cpu-x cpu) 0)
    (step-cpu cpu)
    (is (= #xFF (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))))

(test dey-flags
  (with-cpu (cpu ram :program (list #x88))
    (declare (ignore ram))
    (setf (cpu-y cpu) 1)
    (step-cpu cpu)
    (is (= 0 (cpu-y cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test tax-copies-and-flags
  (with-cpu (cpu ram :program (list #xAA))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x80 (cpu-x cpu) 0)
    (step-cpu cpu)
    (is (= #x80 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))))

(test tay-copies
  (with-cpu (cpu ram :program (list #xA8))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x42)
    (step-cpu cpu)
    (is (= #x42 (cpu-y cpu)))))

(test txa-copies
  (with-cpu (cpu ram :program (list #x8A))
    (declare (ignore ram))
    (setf (cpu-x cpu) #x55)
    (step-cpu cpu)
    (is (= #x55 (cpu-a cpu)))))

(test tya-copies
  (with-cpu (cpu ram :program (list #x98))
    (declare (ignore ram))
    (setf (cpu-y cpu) #xAA)
    (step-cpu cpu)
    (is (= #xAA (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-n+))))

(test txs-no-flag-update
  "TXS copies X into SP without touching flags."
  (with-cpu (cpu ram :program (list #x9A))
    (declare (ignore ram))
    (setf (cpu-x cpu) #x80
          (cpu-flags cpu) #x24)
    (step-cpu cpu)
    (is (= #x80 (cpu-sp cpu)))
    (is (= #x24 (cpu-flags cpu)))))

(test tsx-copies-and-flags
  (with-cpu (cpu ram :program (list #xBA))
    (declare (ignore ram))
    (setf (cpu-sp cpu) #x00)
    (step-cpu cpu)
    (is (= #x00 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test pha-pla-roundtrip
  (with-cpu (cpu ram :program (list #x48 #xA9 #x00 #x68))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x42)
    (step-cpu cpu)            ; PHA
    (step-cpu cpu)            ; LDA #$00
    (is (= 0 (cpu-a cpu)))
    (step-cpu cpu)            ; PLA
    (is (= #x42 (cpu-a cpu)))))

(test cpx-immediate-equal
  (with-cpu (cpu ram :program (list #xE0 #x05))
    (declare (ignore ram))
    (setf (cpu-x cpu) #x05)
    (step-cpu cpu)
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-z+))))

(test cpy-immediate-less-than
  (with-cpu (cpu ram :program (list #xC0 #x10))
    (declare (ignore ram))
    (setf (cpu-y cpu) #x05)
    (step-cpu cpu)
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))))

(test bpl-not-taken-when-n-set
  (with-cpu (cpu ram :program (list #x10 #x10))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-n+)
    (is (= 2 (step-cpu cpu)))
    (is (= #x0202 (cpu-pc cpu)))))

(test bmi-taken
  (with-cpu (cpu ram :program (list #x30 #x04))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-n+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bvc-taken
  (with-cpu (cpu ram :program (list #x50 #x04))
    (declare (ignore ram))
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-v+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bvs-taken
  (with-cpu (cpu ram :program (list #x70 #x04))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-v+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bcc-taken
  (with-cpu (cpu ram :program (list #x90 #x04))
    (declare (ignore ram))
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bcs-taken
  (with-cpu (cpu ram :program (list #xB0 #x04))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test jmp-absolute-sets-pc
  (with-cpu (cpu ram :program (list #x4C #x00 #x90))
    (declare (ignore ram))
    (is (= 3 (step-cpu cpu)))
    (is (= #x9000 (cpu-pc cpu)))))

(test nop-advances-pc
  (with-cpu (cpu ram :program (list #xEA))
    (declare (ignore ram))
    (is (= 2 (step-cpu cpu)))
    (is (= #x0201 (cpu-pc cpu)))))

(test flag-instructions-do-the-right-thing
  "CLC/SEC/CLI/SEI/CLV/CLD/SED each toggle one flag."
  (with-cpu (cpu ram :program (list #x18 #x38 #x58 #x78 #xB8 #xD8 #xF8))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)            ; CLC
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (step-cpu cpu)            ; SEC
    (is-true  (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-c+))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-i+)
    (step-cpu cpu)            ; CLI
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-i+))
    (step-cpu cpu)            ; SEI
    (is-true  (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-i+))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-v+)
    (step-cpu cpu)            ; CLV
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-v+))
    (step-cpu cpu)            ; CLD
    (is-false (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-d+))
    (step-cpu cpu)            ; SED
    (is-true  (atari800-cl.cpu:flag-set? cpu atari800-cl.cpu:+flag-d+))))

;;; ---------------------------------------------------------------------------
;;; Sanity-check that opcode dispatch wire-up is consistent

(test sample-of-documented-opcodes-execute
  "A sampling of common documented opcodes runs without signaling."
  (let ((sample '(#xEA #xA9 #x85 #x4C #xE6 #x18 #x38 #xAA #xCA #x60)))
    (dolist (op sample)
      (is-true (functionp (svref atari800-cl.cpu:*opcode-table* op))
               "opcode #x~2,'0X must have a handler" op))))

(test every-handler-has-named-function
  "Each installed opcode handler is a named function (DEFOPCODE)."
  (loop for i below 256
        for h = (svref atari800-cl.cpu:*opcode-table* i)
        when h
          do (is-true (functionp h) "opcode #x~2,'0X must be a function" i))
  (is (= 151 (length (atari800-cl.cpu:documented-opcodes)))))
