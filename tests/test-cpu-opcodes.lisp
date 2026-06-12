;;;; tests/test-cpu-opcodes.lisp --- NMOS 6502 opcode tests.
;;;;
;;;; These tests use a small bus harness so the CPU never depends on the
;;;; emulator's MEMORY type — exactly as the architecture requires.  They
;;;; cover flags, stack behavior, addressing modes (including the JMP
;;;; indirect page-wrap bug), branch cycle accounting, decimal-mode
;;;; ADC/SBC, and reset/IRQ/NMI/BRK/RTI sequencing.
;;;;
;;;; --- Common Lisp / FiveAM notes for beginners ---
;;;;
;;;; Test structure:
;;;;   1. Create a fresh CPU + 64K RAM array with MAKE-TEST-CPU
;;;;   2. Load a short program (list of opcode bytes) at a known PC
;;;;   3. Execute instructions with STEP-CPU
;;;;   4. Assert results with IS, IS-TRUE, IS-FALSE, SIGNALS
;;;;
;;;; The WITH-CPU macro (defined below) is a convenience wrapper around
;;;; MAKE-TEST-CPU that uses MULTIPLE-VALUE-BIND to bind both the CPU
;;;; and the RAM array in one form.
;;;;
;;;; (DECLARE (IGNORE RAM)) tells the compiler we intentionally don't
;;;; use the RAM variable in that test — suppresses a "variable unused"
;;;; warning.  Many tests only interact with the CPU through the bus hooks
;;;; and never need to read/write RAM directly.
;;;;
;;;; SIGNALS is a FiveAM macro that asserts a specific condition type
;;;; is signalled:
;;;;   (signals illegal-opcode (step-cpu cpu))
;;;; passes if STEP-CPU signals an ILLEGAL-OPCODE condition.
;;;;
;;;; DOLIST iterates over a list:
;;;;   (dolist (op '(#xEA #xA9)) ...) runs the body with OP bound to
;;;;   each element in turn.

(in-package #:atari800-cl/tests)

(def-suite cpu-opcodes-suite
  :description "Tests for NMOS 6502 opcode dispatch and behavior."
  :in atari800-cl-suite)

(in-suite cpu-opcodes-suite)

;;; ---------------------------------------------------------------------------
;;; Bus harness
;;;
;;; Instead of using the MEMORY struct from the emulator, we create a raw
;;; 64K byte array and wire it to the CPU through closures (anonymous
;;; functions).  This tests the CPU in isolation — exactly as the bus-agnostic
;;; architecture intends.
;;;
;;; MAKE-TEST-CPU returns two values (VALUES CPU RAM) which callers receive
;;; with MULTIPLE-VALUE-BIND.

(defun make-test-cpu (&key (pc #x0200) (program nil))
  "Build a CPU with bus hooks pointing at a fresh 64K array.

PROGRAM, if supplied, is a list of bytes loaded starting at PC.
Returns (VALUES CPU RAM) — two values.

Example:
  (multiple-value-bind (cpu ram)
      (make-test-cpu :pc #x0200 :program (list #xA9 #x42))
    ;; cpu is ready with LDA #$42 at $0200
    ...)"
  (let* ((ram (make-array #x10000 :element-type '(unsigned-byte 8)
                                  :initial-element 0))
         (cpu (make-cpu)))
    ;; Install closures as bus hooks: the CPU reads/writes through these
    ;; anonymous functions, which capture the RAM array.
    (setf (cpu-bus-read cpu)  (lambda (a) (aref ram a))
          (cpu-bus-write cpu) (lambda (a v) (setf (aref ram a) v)))
    ;; Set up initial register state (same as after a reset).
    (setf (cpu-pc cpu) pc
          (cpu-sp cpu) #xFD
          (cpu-flags cpu) #x24       ; U=1, I=1
          (cpu-cycles cpu) 0)
    ;; If a program was provided, load its bytes into RAM at PC.
    (when program
      (loop for byte in program
            for off from 0
            do (setf (aref ram (+ pc off)) byte)))
    ;; Return both the CPU and the RAM as multiple values.
    (values cpu ram)))

(defmacro with-cpu ((cpu ram &key (pc #x0200) program) &body body)
  "Convenience macro: bind CPU and RAM from MAKE-TEST-CPU, then run BODY.
Expands to a MULTIPLE-VALUE-BIND form."
  `(multiple-value-bind (,cpu ,ram) (make-test-cpu :pc ,pc :program ,program)
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Sanity / dispatch table

(test dispatch-table-has-256-entries
  "*OPCODE-TABLE* must be a 256-entry vector (one slot per possible opcode byte)."
  (is (= 256 (length atari800-cl.cpu:*opcode-table*)))
  ;; SIMPLE-VECTOR is a CL type: a fixed-size, non-adjustable vector of
  ;; general Lisp objects.
  (is (typep atari800-cl.cpu:*opcode-table* 'simple-vector)))

(test dispatch-table-has-151-documented-opcodes
  "Exactly 151 official NMOS 6502 opcodes are installed."
  (is (= 151 (length (atari800-cl.cpu:documented-opcodes)))))

(test illegal-opcode-signals
  "Stepping into an illegal opcode signals ILLEGAL-OPCODE and halts the CPU."
  (with-cpu (cpu ram :program (list #x02))    ; $02 is not a documented opcode
    (declare (ignore ram))
    ;; SIGNALS asserts that the given condition type is raised.
    (signals atari800-cl.cpu:illegal-opcode (step-cpu cpu))
    ;; After the error, the CPU's HALTED flag should be set.
    (is (cpu-halted cpu))))

;;; ---------------------------------------------------------------------------
;;; Flag helpers

(test flag-helpers-roundtrip
  "Set/clear/query for each individual flag bit."
  (with-cpu (cpu ram)
    (declare (ignore ram))
    (setf (cpu-flags cpu) 0)                    ; clear all flags
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

(test status-pack-unpack
  "Pushed status: U=1 always; B=1 on PHP/BRK, B=0 on IRQ/NMI.
Pulled status forces U=1, B=0 in the in-register copy."
  (with-cpu (cpu ram)
    (declare (ignore ram))
    (setf (cpu-flags cpu) 0)
    ;; PHP/BRK push: both U (#x20) and B (#x10) set → #x30
    (is (= #x30 (atari800-cl.cpu:status-byte-for-push cpu :b-flag t)))
    ;; IRQ/NMI push: U set, B clear → #x20
    (is (= #x20 (atari800-cl.cpu:status-byte-for-push cpu :b-flag nil)))
    ;; Pull: U forced 1, B forced 0; other bits preserved.
    ;; #xFF with U=1 and B=0 → #xEF
    (is (= #xEF (atari800-cl.cpu:status-byte-from-pull #xFF)))
    ;; #x11 (C + B set) → #x21 (C + U set, B cleared)
    (is (= #x21 (atari800-cl.cpu:status-byte-from-pull #x11)))))

;;; ---------------------------------------------------------------------------
;;; Stack helpers

(test stack-byte-roundtrip
  "Push then pull a byte returns the original value."
  (with-cpu (cpu ram)
    (declare (ignore ram))
    (atari800-cl.cpu:push-byte cpu #x42)
    ;; SP decremented from $FD to $FC after pushing one byte.
    (is (= #xFC (cpu-sp cpu)))
    (is (= #x42 (atari800-cl.cpu:pull-byte cpu)))
    ;; SP restored to $FD after pulling.
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
    ;; Push a byte; SP starts at $FD, so it writes at $01FD.
    (atari800-cl.cpu:push-byte cpu #xAA)
    ;; Verify directly in the RAM array (not through the CPU).
    (is (= #xAA (aref ram #x01FD)))))

;;; ---------------------------------------------------------------------------
;;; Reset / IRQ / NMI / BRK / RTI

(test reset-loads-pc-and-sets-i-flag
  "Reset reads $FFFC/$FFFD into PC, SP=$FD, flags=#x24."
  (with-cpu (cpu ram)
    ;; Write the reset vector into RAM.
    (setf (aref ram #xFFFC) #x34
          (aref ram #xFFFD) #x12)
    (reset-cpu cpu)                     ; re-reads the vector from RAM
    (is (= #x1234 (cpu-pc cpu)))
    (is (= #xFD   (cpu-sp cpu)))
    (is (= #x24   (cpu-flags cpu)))    ; U=1, I=1
    (is (zerop (cpu-cycles cpu)))))

(test brk-pushes-pc-plus-2-and-status-with-b
  "BRK pushes PC+2 and a status byte with B set, vectors through $FFFE."
  ;; Program: BRK at $0400, padding byte at $0401, NOP at $0402.
  (with-cpu (cpu ram :pc #x0400 :program (list #x00 #x00 #xEA))
    ;; Set up the IRQ/BRK vector to point to $8000.
    (setf (aref ram #xFFFE) #x00
          (aref ram #xFFFF) #x80)
    (let ((cycles (step-cpu cpu)))
      (is (= 7 cycles))               ; BRK takes 7 cycles
      (is (= #x8000 (cpu-pc cpu)))    ; jumped to IRQ vector
      ;; Pushed return PC = $0402 (BRK at $0400, skip 1 padding byte).
      ;; PUSH-WORD writes high byte first: high at $01FD, low at $01FC.
      (is (= #x04 (aref ram #x01FD))) ; high byte of return PC
      (is (= #x02 (aref ram #x01FC))) ; low byte of return PC
      ;; Pushed status byte should have B=1 and U=1.
      (let ((pushed-status (aref ram #x01FB)))
        (is (not (zerop (logand pushed-status atari800-cl.cpu:+flag-b+))))
        (is (not (zerop (logand pushed-status atari800-cl.cpu:+flag-u+)))))
      ;; I flag should be set after BRK (interrupts disabled).
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-i+)))))

(test rti-restores-status-and-pc
  "RTI pulls status (B forced 0, U forced 1) then PC."
  ;; Program: RTI at $0500.  We manually set up the stack with a status
  ;; byte and return PC.
  (with-cpu (cpu ram :pc #x0500 :program (list #x40))  ; #x40 = RTI
    ;; Manually place values on the stack (SP=$FD, so stack grows down):
    ;;   $01FE = status byte
    ;;   $01FF = PC low
    ;;   $0100 = PC high (wraps around the 256-byte stack page)
    (setf (aref ram #x01FE) #xFF        ; status byte (will be masked)
          (aref ram #x01FF) #x34        ; PC low
          (aref ram #x0100) #x12        ; PC high (SP wraps)
          (cpu-sp cpu) #xFD)
    (let ((cycles (step-cpu cpu)))
      (is (= 6 cycles))
      (is (= #x1234 (cpu-pc cpu)))
      ;; #xFF with B forced 0 and U forced 1 → #xEF
      (is (= #xEF (cpu-flags cpu))))))

(test nmi-vector-and-cycle-count
  "Triggered NMI vectors through $FFFA and costs 7 cycles."
  (with-cpu (cpu ram :pc #x0600 :program (list #xEA))  ; NOP
    ;; Set up NMI vector to point to $9000.
    (setf (aref ram #xFFFA) #x00
          (aref ram #xFFFB) #x90)
    ;; Trigger NMI (edge-triggered: latched until serviced).
    (atari800-cl.cpu:trigger-nmi cpu)
    (let ((cycles (step-cpu cpu)))
      (is (= 7 cycles))
      (is (= #x9000 (cpu-pc cpu)))     ; jumped to NMI vector
      (is-false (cpu-pending-nmi cpu))  ; NMI cleared after servicing
      ;; Pushed status has B=0 (hardware interrupt, not BRK).
      (is (zerop (logand (aref ram #x01FB) atari800-cl.cpu:+flag-b+)))
      ;; I flag set after servicing NMI.
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-i+)))))

(test irq-respects-interrupt-disable
  "If I=1, an asserted IRQ line is ignored."
  (with-cpu (cpu ram :pc #x0700 :program (list #xEA))  ; NOP
    (declare (ignore ram))
    ;; Set I flag (interrupts disabled) and assert IRQ.
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-i+)
    (atari800-cl.cpu:set-irq-line cpu t)
    (let ((cycles (step-cpu cpu)))
      ;; The NOP runs normally because IRQ is masked by I=1.
      (is (= 2 cycles))
      (is (= #x0701 (cpu-pc cpu))))))

(test irq-runs-when-i-clear
  "With I=0 and IRQ asserted, vector through $FFFE; cost 7."
  (with-cpu (cpu ram :pc #x0700 :program (list #xEA))
    ;; Set up IRQ vector to $A000.
    (setf (aref ram #xFFFE) #x00
          (aref ram #xFFFF) #xA0)
    ;; Clear I flag (interrupts enabled) and assert IRQ.
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-i+)
    (atari800-cl.cpu:set-irq-line cpu t)
    (let ((cycles (step-cpu cpu)))
      (is (= 7 cycles))
      (is (= #xA000 (cpu-pc cpu)))
      ;; I flag set after servicing IRQ.
      (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-i+))
      ;; Pushed status has B=0 (hardware interrupt).
      (is (zerop (logand (aref ram #x01FB) atari800-cl.cpu:+flag-b+))))))

;;; ---------------------------------------------------------------------------
;;; Loads / stores

(test lda-immediate-sets-flags
  "LDA #$80: loads $80 into A, sets N=1, Z=0."
  (with-cpu (cpu ram :program (list #xA9 #x80))  ; LDA #$80
    (declare (ignore ram))
    (let ((cycles (step-cpu cpu)))
      (is (= 2 cycles))                           ; immediate mode: 2 cycles
      (is (= #x80 (cpu-a cpu)))
      (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))
      (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+)))))

(test lda-absolute-x-page-cross-adds-cycle
  "LDA $00FF,X with X=1 crosses a page: 4+1 = 5 cycles."
  (with-cpu (cpu ram :program (list #xBD #xFF #x00))  ; LDA $00FF,X
    (setf (cpu-x cpu) 1
          (aref ram #x0100) #x77)                      ; effective address $0100
    (is (= 5 (step-cpu cpu)))                          ; 4 base + 1 page cross
    (is (= #x77 (cpu-a cpu)))))

(test lda-absolute-x-no-page-cross
  "LDA $1000,X with X=1: no page cross, 4 cycles."
  (with-cpu (cpu ram :program (list #xBD #x00 #x10))  ; LDA $1000,X
    (setf (cpu-x cpu) 1
          (aref ram #x1001) #x33)                      ; effective address $1001
    (is (= 4 (step-cpu cpu)))
    (is (= #x33 (cpu-a cpu)))))

(test sta-zero-page
  "STA $42: stores A into zero-page address $42."
  (with-cpu (cpu ram :program (list #x85 #x42))  ; STA $42
    (setf (cpu-a cpu) #x99)
    (is (= 3 (step-cpu cpu)))
    (is (= #x99 (aref ram #x42)))))

(test sta-absolute-x-no-page-cross-penalty
  "Stores never get a page-cross penalty (always 5 cycles for STA abs,X)."
  (with-cpu (cpu ram :program (list #x9D #xFF #x00))  ; STA $00FF,X
    (setf (cpu-x cpu) 1
          (cpu-a cpu) #xCC)
    (is (= 5 (step-cpu cpu)))                         ; always 5, no page-cross bonus
    (is (= #xCC (aref ram #x0100)))))

;;; ---------------------------------------------------------------------------
;;; Addressing-mode coverage including JMP indirect bug

(test jmp-indirect-no-bug
  "JMP ($1234): low at $1234, high at $1235 — normal case."
  (with-cpu (cpu ram :program (list #x6C #x34 #x12))  ; JMP ($1234)
    (setf (aref ram #x1234) #xCD
          (aref ram #x1235) #xAB)
    (is (= 5 (step-cpu cpu)))
    (is (= #xABCD (cpu-pc cpu)))))

(test jmp-indirect-page-wrap-bug
  "JMP ($30FF): NMOS reads high byte from $3000 instead of $3100.
This is a well-known hardware bug in the original NMOS 6502."
  (with-cpu (cpu ram :program (list #x6C #xFF #x30))  ; JMP ($30FF)
    (setf (aref ram #x30FF) #x12       ; low byte
          (aref ram #x3000) #x80       ; bug: high byte read from $3000
          (aref ram #x3100) #x40)      ; correct location (ignored on NMOS)
    (is (= 5 (step-cpu cpu)))
    (is (= #x8012 (cpu-pc cpu)))))     ; $8012, not $4012

(test indexed-indirect-zp-wrap
  "(zp,X): zero-page wrap on the index."
  ;; LDA ($FF,X) with X=1 → pointer at zp $00,$01 (wraps from $FF+1=$00)
  (with-cpu (cpu ram :program (list #xA1 #xFF))  ; LDA ($FF,X)
    (setf (cpu-x cpu) 1
          (aref ram #x0000) #x34       ; pointer low byte
          (aref ram #x0001) #x12       ; pointer high byte
          (aref ram #x1234) #x55)      ; value at effective address
    (is (= 6 (step-cpu cpu)))
    (is (= #x55 (cpu-a cpu)))))

(test indirect-indexed-page-cross
  "(zp),Y with page-crossed effective address: +1 cycle."
  ;; LDA ($10),Y: pointer at zp $10,$11 gives base $10FF; Y=1 → $1100 (page cross)
  (with-cpu (cpu ram :program (list #xB1 #x10))  ; LDA ($10),Y
    (setf (aref ram #x0010) #xFF      ; pointer low
          (aref ram #x0011) #x10      ; pointer high → base $10FF
          (cpu-y cpu) 1               ; effective address = $10FF + 1 = $1100
          (aref ram #x1100) #x77)
    (is (= 6 (step-cpu cpu)))         ; 5 base + 1 page cross
    (is (= #x77 (cpu-a cpu)))))

(test zero-page-x-wraps-byte-not-page
  "Zero-page,X addressing wraps within the zero page (8-bit wrap, not 16-bit)."
  ;; LDA $FF,X with X=2 → address = ($FF + 2) AND $FF = $01
  (with-cpu (cpu ram :program (list #xB5 #xFF))  ; LDA $FF,X
    (setf (cpu-x cpu) 2
          (aref ram #x0001) #xAB)     ; $FF + 2 = $101, wraps to $01
    (is (= 4 (step-cpu cpu)))
    (is (= #xAB (cpu-a cpu)))))

;;; ---------------------------------------------------------------------------
;;; Branches: cycle accounting

(test branch-not-taken-2-cycles
  "A not-taken branch costs exactly 2 cycles."
  (with-cpu (cpu ram :program (list #xD0 #x10))  ; BNE +16
    (declare (ignore ram))
    ;; Set Z flag so BNE (Branch if Not Equal) is NOT taken.
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (is (= 2 (step-cpu cpu)))
    ;; PC advanced past the 2-byte instruction (opcode + offset).
    (is (= #x0202 (cpu-pc cpu)))))

(test branch-taken-no-cross-3-cycles
  "A taken branch within the same page costs 3 cycles (2 base + 1 taken)."
  (with-cpu (cpu ram :pc #x0200 :program (list #xF0 #x10))  ; BEQ +16
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (is (= 3 (step-cpu cpu)))
    ;; $0202 (after consuming the 2-byte instruction) + $10 = $0212
    (is (= #x0212 (cpu-pc cpu)))))

(test branch-taken-page-cross-4-cycles
  "Branch from $02F0 by +$20 crosses into $0312: 4 cycles (2+1+1)."
  (with-cpu (cpu ram :pc #x02F0 :program (list #xF0 #x20))  ; BEQ +32
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (is (= 4 (step-cpu cpu)))
    ;; $02F2 + $20 = $0312 (crosses from page $02 to page $03)
    (is (= #x0312 (cpu-pc cpu)))))

(test branch-backwards
  "Negative branch offset (signed) wraps backwards."
  ;; BEQ -2: offset $FE is interpreted as signed -2.
  ;; PC after consuming instruction = $0212, branch target = $0212 - 2 = $0210.
  (with-cpu (cpu ram :pc #x0210 :program (list #xF0 #xFE))  ; BEQ -2
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-z+)
    (step-cpu cpu)
    ;; Branches back to the start of the BEQ instruction (infinite loop).
    (is (= #x0210 (cpu-pc cpu)))))

;;; ---------------------------------------------------------------------------
;;; ADC / SBC including decimal mode

(test adc-binary-overflow
  "ADC: $50 + $50 = $A0 with overflow (two positives yielding negative)."
  (with-cpu (cpu ram :program (list #x69 #x50))  ; ADC #$50
    (declare (ignore ram))
    (setf (cpu-a cpu) #x50)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)  ; no carry in
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-d+)  ; binary mode
    (step-cpu cpu)
    (is (= #xA0 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-v+))   ; overflow
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))   ; negative
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+)))) ; no carry

(test adc-binary-carry
  "ADC: $FF + $01 = $00 with carry out."
  (with-cpu (cpu ram :program (list #x69 #x01))  ; ADC #$01
    (declare (ignore ram))
    (setf (cpu-a cpu) #xFF)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))  ; carry
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+)))) ; zero

(test adc-decimal-mode
  "BCD: $25 + $48 (no carry-in) = $73."
  (with-cpu (cpu ram :program (list #x69 #x48))  ; ADC #$48
    (declare (ignore ram))
    (setf (cpu-a cpu) #x25)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:set-flag   cpu atari800-cl.cpu:+flag-d+)  ; decimal mode
    (step-cpu cpu)
    (is (= #x73 (cpu-a cpu)))         ; 25 + 48 = 73 in BCD
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

(test adc-decimal-mode-with-carry
  "BCD: $58 + $46 + 1 carry = $05 with carry out (105 in decimal)."
  (with-cpu (cpu ram :program (list #x69 #x46))  ; ADC #$46
    (declare (ignore ram))
    (setf (cpu-a cpu) #x58)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)    ; carry in
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-d+)    ; decimal mode
    (step-cpu cpu)
    (is (= #x05 (cpu-a cpu)))         ; 58 + 46 + 1 = 105 → $05 with carry
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

(test sbc-binary
  "SBC #$01 from $40 with carry set = $3F, carry stays set (no borrow)."
  (with-cpu (cpu ram :program (list #xE9 #x01))  ; SBC #$01
    (declare (ignore ram))
    (setf (cpu-a cpu) #x40)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)    ; C=1 means no borrow
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-d+)  ; binary mode
    (step-cpu cpu)
    (is (= #x3F (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

(test sbc-decimal-mode
  "BCD: $46 - $12 (carry set, no borrow) = $34."
  (with-cpu (cpu ram :program (list #xE9 #x12))  ; SBC #$12
    (declare (ignore ram))
    (setf (cpu-a cpu) #x46)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x34 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

(test sbc-decimal-borrow
  "BCD: $05 - $12 with carry set = $93 with borrow (carry cleared)."
  (with-cpu (cpu ram :program (list #xE9 #x12))  ; SBC #$12
    (declare (ignore ram))
    (setf (cpu-a cpu) #x05)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-d+)
    (step-cpu cpu)
    (is (= #x93 (cpu-a cpu)))         ; BCD underflow
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

;;; ---------------------------------------------------------------------------
;;; Misc opcode behavior

(test jsr-rts-roundtrip
  "JSR / RTS pair returns to the byte after the JSR."
  ;; Program at $0300: JSR $8010 (3 bytes), then whatever follows.
  (with-cpu (cpu ram :pc #x0300
                     :program (list #x20 #x10 #x80))  ; JSR $8010
    ;; Put RTS at the target address.
    (setf (aref ram #x8010) #x60)                      ; RTS
    (let ((c1 (step-cpu cpu)))
      (is (= 6 c1))                    ; JSR takes 6 cycles
      (is (= #x8010 (cpu-pc cpu)))     ; jumped to target
      ;; JSR pushed (PC-1) = $0302 (high byte first).
      (is (= #x03 (aref ram #x01FD))) ; high byte
      (is (= #x02 (aref ram #x01FC)))) ; low byte
    (let ((c2 (step-cpu cpu)))
      (is (= 6 c2))                    ; RTS takes 6 cycles
      ;; RTS pulls $0302 and adds 1 → $0303 (byte after the JSR).
      (is (= #x0303 (cpu-pc cpu))))))

(test inc-memory-flags
  "INC $10: increments memory and updates Z/N flags."
  (with-cpu (cpu ram :program (list #xE6 #x10))  ; INC $10
    (setf (aref ram #x10) #x7F)       ; $7F + 1 = $80 (sets N)
    (is (= 5 (step-cpu cpu)))
    (is (= #x80 (aref ram #x10)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

(test bit-sets-n-and-v-from-memory
  "BIT $05 with mem=$C0 and A=$01: Z=1, N=1 (bit7), V=1 (bit6).
BIT is special: Z is set from (A AND mem), but N and V come from the
memory value's bits 7 and 6 directly."
  (with-cpu (cpu ram :program (list #x24 #x05))  ; BIT $05
    (setf (aref ram #x05) #xC0        ; bits 7 and 6 set
          (cpu-a cpu) #x01)            ; A AND $C0 = 0, so Z=1
    (step-cpu cpu)
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-v+))))

(test asl-accumulator-flags
  "ASL A on $80 -> $00 with C=1, Z=1."
  (with-cpu (cpu ram :program (list #x0A))  ; ASL A
    (declare (ignore ram))
    (setf (cpu-a cpu) #x80)            ; bit 7 set → goes to carry
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (is (= 2 (step-cpu cpu)))
    (is (= #x00 (cpu-a cpu)))          ; $80 shifted left = $00
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test php-plp-roundtrip
  "PHP pushes status with B=1, U=1; PLP clears B and forces U=1."
  ;; Program: PHP ($08) followed by PLP ($28).
  (with-cpu (cpu ram :program (list #x08 #x28))
    (declare (ignore ram))
    (setf (cpu-flags cpu) #x81)        ; N + C
    (step-cpu cpu)                     ; PHP: pushes #xB1 (N+C+B+U)
    ;; Change flags to something different before pulling.
    (setf (cpu-flags cpu) #x00)
    (step-cpu cpu)                     ; PLP: pulls and masks
    ;; After PLP: original N+C restored; U forced 1; B cleared.
    ;; #x81 | U(#x20) = #xA1, B cleared
    (is (= #xA1 (cpu-flags cpu)))))

(test cmp-sets-carry-and-zero
  "CMP #$10 with A=$10: C=1 (A >= operand), Z=1 (A == operand)."
  (with-cpu (cpu ram :program (list #xC9 #x10))  ; CMP #$10
    (declare (ignore ram))
    (setf (cpu-a cpu) #x10)
    (step-cpu cpu)
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

;;; ---------------------------------------------------------------------------
;;; Per-family coverage — at least one variant of each opcode family.

(test ldx-immediate-sets-flags
  "LDX #$00: loads 0 into X, sets Z=1."
  (with-cpu (cpu ram :program (list #xA2 #x00))  ; LDX #$00
    (declare (ignore ram))
    (step-cpu cpu)
    (is (= #x00 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test ldy-immediate-sets-flags
  "LDY #$7F: loads $7F into Y, N=0 (bit 7 clear)."
  (with-cpu (cpu ram :program (list #xA0 #x7F))  ; LDY #$7F
    (declare (ignore ram))
    (step-cpu cpu)
    (is (= #x7F (cpu-y cpu)))
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

(test stx-zero-page
  "STX $10: stores X register to zero-page address $10."
  (with-cpu (cpu ram :program (list #x86 #x10))  ; STX $10
    (setf (cpu-x cpu) #xAB)
    (step-cpu cpu)
    (is (= #xAB (aref ram #x10)))))

(test sty-zero-page
  "STY $11: stores Y register to zero-page address $11."
  (with-cpu (cpu ram :program (list #x84 #x11))  ; STY $11
    (setf (cpu-y cpu) #xCD)
    (step-cpu cpu)
    (is (= #xCD (aref ram #x11)))))

(test and-immediate
  "AND #$0F: $F0 AND $0F = $00, Z=1."
  (with-cpu (cpu ram :program (list #x29 #x0F))  ; AND #$0F
    (declare (ignore ram))
    (setf (cpu-a cpu) #xF0)
    (step-cpu cpu)
    (is (= 0 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test ora-immediate
  "ORA #$0F: $F0 OR $0F = $FF."
  (with-cpu (cpu ram :program (list #x09 #x0F))  ; ORA #$0F
    (declare (ignore ram))
    (setf (cpu-a cpu) #xF0)
    (step-cpu cpu)
    (is (= #xFF (cpu-a cpu)))))

(test eor-immediate
  "EOR #$FF: $AA XOR $FF = $55."
  (with-cpu (cpu ram :program (list #x49 #xFF))  ; EOR #$FF
    (declare (ignore ram))
    (setf (cpu-a cpu) #xAA)
    (step-cpu cpu)
    (is (= #x55 (cpu-a cpu)))))

(test lsr-accumulator-flags
  "LSR A on $01 -> $00 with C=1, Z=1."
  (with-cpu (cpu ram :program (list #x4A))  ; LSR A
    (declare (ignore ram))
    (setf (cpu-a cpu) #x01)            ; bit 0 → carry
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test rol-accumulator
  "ROL A on $80 with C=0 -> $00, C=1."
  (with-cpu (cpu ram :program (list #x2A))  ; ROL A
    (declare (ignore ram))
    (setf (cpu-a cpu) #x80)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))          ; $80 rotated left with C=0 in → $00
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

(test ror-accumulator
  "ROR A on $01 with C=0 -> $00, C=1."
  (with-cpu (cpu ram :program (list #x6A))  ; ROR A
    (declare (ignore ram))
    (setf (cpu-a cpu) #x01)
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x00 (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

(test dec-memory
  "DEC $20: decrements $01 to $00, Z=1."
  (with-cpu (cpu ram :program (list #xC6 #x20))  ; DEC $20
    (setf (aref ram #x20) #x01)
    (step-cpu cpu)
    (is (= #x00 (aref ram #x20)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test inx-wraps-and-sets-zero
  "INX: $FF + 1 wraps to $00, Z=1."
  (with-cpu (cpu ram :program (list #xE8))  ; INX
    (declare (ignore ram))
    (setf (cpu-x cpu) #xFF)
    (step-cpu cpu)
    (is (= 0 (cpu-x cpu)))            ; wraps to 0
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test iny-sets-negative
  "INY: $7F + 1 = $80, N=1 (sign bit set)."
  (with-cpu (cpu ram :program (list #xC8))  ; INY
    (declare (ignore ram))
    (setf (cpu-y cpu) #x7F)
    (step-cpu cpu)
    (is (= #x80 (cpu-y cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

(test dex-wraps
  "DEX: 0 - 1 wraps to $FF, N=1."
  (with-cpu (cpu ram :program (list #xCA))  ; DEX
    (declare (ignore ram))
    (setf (cpu-x cpu) 0)
    (step-cpu cpu)
    (is (= #xFF (cpu-x cpu)))         ; wraps to $FF
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

(test dey-flags
  "DEY: 1 - 1 = 0, Z=1."
  (with-cpu (cpu ram :program (list #x88))  ; DEY
    (declare (ignore ram))
    (setf (cpu-y cpu) 1)
    (step-cpu cpu)
    (is (= 0 (cpu-y cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test tax-copies-and-flags
  "TAX: copies A to X, sets N from the value."
  (with-cpu (cpu ram :program (list #xAA))  ; TAX
    (declare (ignore ram))
    (setf (cpu-a cpu) #x80 (cpu-x cpu) 0)
    (step-cpu cpu)
    (is (= #x80 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

(test tay-copies
  "TAY: copies A to Y."
  (with-cpu (cpu ram :program (list #xA8))  ; TAY
    (declare (ignore ram))
    (setf (cpu-a cpu) #x42)
    (step-cpu cpu)
    (is (= #x42 (cpu-y cpu)))))

(test txa-copies
  "TXA: copies X to A."
  (with-cpu (cpu ram :program (list #x8A))  ; TXA
    (declare (ignore ram))
    (setf (cpu-x cpu) #x55)
    (step-cpu cpu)
    (is (= #x55 (cpu-a cpu)))))

(test tya-copies
  "TYA: copies Y to A, sets N from the value."
  (with-cpu (cpu ram :program (list #x98))  ; TYA
    (declare (ignore ram))
    (setf (cpu-y cpu) #xAA)
    (step-cpu cpu)
    (is (= #xAA (cpu-a cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-n+))))

(test txs-no-flag-update
  "TXS copies X into SP without touching flags."
  (with-cpu (cpu ram :program (list #x9A))  ; TXS
    (declare (ignore ram))
    (setf (cpu-x cpu) #x80
          (cpu-flags cpu) #x24)        ; flags should remain unchanged
    (step-cpu cpu)
    (is (= #x80 (cpu-sp cpu)))
    (is (= #x24 (cpu-flags cpu)))))    ; flags untouched

(test tsx-copies-and-flags
  "TSX: copies SP to X, sets Z/N from the value."
  (with-cpu (cpu ram :program (list #xBA))  ; TSX
    (declare (ignore ram))
    (setf (cpu-sp cpu) #x00)
    (step-cpu cpu)
    (is (= #x00 (cpu-x cpu)))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test pha-pla-roundtrip
  "PHA pushes A; PLA pulls it back (even after A changes in between)."
  ;; Program: PHA, LDA #$00, PLA
  (with-cpu (cpu ram :program (list #x48 #xA9 #x00 #x68))
    (declare (ignore ram))
    (setf (cpu-a cpu) #x42)
    (step-cpu cpu)            ; PHA: push #x42
    (step-cpu cpu)            ; LDA #$00: A becomes 0
    (is (= 0 (cpu-a cpu)))
    (step-cpu cpu)            ; PLA: pull #x42 back into A
    (is (= #x42 (cpu-a cpu)))))

(test cpx-immediate-equal
  "CPX #$05 with X=$05: C=1 (X >= operand), Z=1 (equal)."
  (with-cpu (cpu ram :program (list #xE0 #x05))  ; CPX #$05
    (declare (ignore ram))
    (setf (cpu-x cpu) #x05)
    (step-cpu cpu)
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (is-true (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-z+))))

(test cpy-immediate-less-than
  "CPY #$10 with Y=$05: C=0 (Y < operand)."
  (with-cpu (cpu ram :program (list #xC0 #x10))  ; CPY #$10
    (declare (ignore ram))
    (setf (cpu-y cpu) #x05)
    (step-cpu cpu)
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))))

;;; --- Branch instruction variants ---

(test bpl-not-taken-when-n-set
  "BPL (Branch if Positive): not taken when N=1."
  (with-cpu (cpu ram :program (list #x10 #x10))  ; BPL +16
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-n+)
    (is (= 2 (step-cpu cpu)))
    (is (= #x0202 (cpu-pc cpu)))))

(test bmi-taken
  "BMI (Branch if Minus): taken when N=1."
  (with-cpu (cpu ram :program (list #x30 #x04))  ; BMI +4
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-n+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bvc-taken
  "BVC (Branch if Overflow Clear): taken when V=0."
  (with-cpu (cpu ram :program (list #x50 #x04))  ; BVC +4
    (declare (ignore ram))
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-v+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bvs-taken
  "BVS (Branch if Overflow Set): taken when V=1."
  (with-cpu (cpu ram :program (list #x70 #x04))  ; BVS +4
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-v+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bcc-taken
  "BCC (Branch if Carry Clear): taken when C=0."
  (with-cpu (cpu ram :program (list #x90 #x04))  ; BCC +4
    (declare (ignore ram))
    (atari800-cl.cpu:clear-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test bcs-taken
  "BCS (Branch if Carry Set): taken when C=1."
  (with-cpu (cpu ram :program (list #xB0 #x04))  ; BCS +4
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)
    (is (= #x0206 (cpu-pc cpu)))))

(test jmp-absolute-sets-pc
  "JMP $9000: sets PC to the absolute address."
  (with-cpu (cpu ram :program (list #x4C #x00 #x90))  ; JMP $9000
    (declare (ignore ram))
    (is (= 3 (step-cpu cpu)))
    (is (= #x9000 (cpu-pc cpu)))))

(test nop-advances-pc
  "NOP: does nothing except advance PC by 1 and take 2 cycles."
  (with-cpu (cpu ram :program (list #xEA))  ; NOP
    (declare (ignore ram))
    (is (= 2 (step-cpu cpu)))
    (is (= #x0201 (cpu-pc cpu)))))

(test flag-instructions-do-the-right-thing
  "CLC/SEC/CLI/SEI/CLV/CLD/SED each toggle exactly one flag."
  ;; Program: CLC SEC CLI SEI CLV CLD SED (7 single-byte instructions)
  (with-cpu (cpu ram :program (list #x18 #x38 #x58 #x78 #xB8 #xD8 #xF8))
    (declare (ignore ram))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-c+)
    (step-cpu cpu)            ; CLC — clear carry
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (step-cpu cpu)            ; SEC — set carry
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-c+))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-i+)
    (step-cpu cpu)            ; CLI — clear interrupt disable
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-i+))
    (step-cpu cpu)            ; SEI — set interrupt disable
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-i+))
    (atari800-cl.cpu:set-flag cpu atari800-cl.cpu:+flag-v+)
    (step-cpu cpu)            ; CLV — clear overflow
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-v+))
    (step-cpu cpu)            ; CLD — clear decimal mode
    (is-false (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-d+))
    (step-cpu cpu)            ; SED — set decimal mode
    (is-true  (atari800-cl.cpu:flag-set-p cpu atari800-cl.cpu:+flag-d+))))

;;; ---------------------------------------------------------------------------
;;; Sanity-check that opcode dispatch wire-up is consistent

(test sample-of-documented-opcodes-execute
  "A sampling of common documented opcodes has handlers installed."
  ;; DOLIST iterates over the list, binding OP to each element.
  (let ((sample '(#xEA #xA9 #x85 #x4C #xE6 #x18 #x38 #xAA #xCA #x60)))
    (dolist (op sample)
      ;; FUNCTIONP returns T if its argument is a function object.
      (is-true (functionp (svref atari800-cl.cpu:*opcode-table* op))
               "opcode #x~2,'0X must have a handler" op))))

(test every-handler-has-named-function
  "Each installed opcode handler is a named function (from DEFOPCODE),
and there are exactly 151 documented opcodes."
  ;; LOOP iterates over all 256 slots; WHEN filters to non-NIL entries.
  (loop for i below 256
        for h = (svref atari800-cl.cpu:*opcode-table* i)
        when h
          do (is-true (functionp h) "opcode #x~2,'0X must be a function" i))
  (is (= 151 (length (atari800-cl.cpu:documented-opcodes)))))
