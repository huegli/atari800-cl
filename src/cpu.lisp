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

(in-package #:atari800-cl.cpu)

;;; ---------------------------------------------------------------------------
;;; Status-register flag bits (NV-BDIZC)

(defconstant +flag-c+ #x01)
(defconstant +flag-z+ #x02)
(defconstant +flag-i+ #x04)
(defconstant +flag-d+ #x08)
(defconstant +flag-b+ #x10)
(defconstant +flag-u+ #x20)
(defconstant +flag-v+ #x40)
(defconstant +flag-n+ #x80)

;;; ---------------------------------------------------------------------------
;;; CPU state
;;;
;;; PENDING-NMI is edge-triggered: the bus controller sets it and the CPU
;;; clears it after servicing.  PENDING-IRQ is level-sensitive: the bus
;;; controller keeps it true while the line is asserted.

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
  (sp          #xFD :type u8)
  (flags       #x24 :type u8)
  (cycles      0    :type (unsigned-byte 64))
  (bus-read    nil :type (or null function))
  (bus-write   nil :type (or null function))
  (pending-irq nil :type boolean)
  (pending-nmi nil :type boolean)
  (halted      nil :type boolean))

;;; ---------------------------------------------------------------------------
;;; Bus access helpers

(declaim (inline cpu-read-byte cpu-write-byte))

(defun cpu-read-byte (cpu address)
  (declare (type cpu cpu) (type u16 address))
  (funcall (cpu-bus-read cpu) (logand address #xFFFF)))

(defun cpu-write-byte (cpu address value)
  (declare (type cpu cpu) (type u16 address) (type u8 value))
  (funcall (cpu-bus-write cpu)
           (logand address #xFFFF)
           (logand value #xFF)))

(defun cpu-read-word (cpu address)
  (declare (type cpu cpu) (type u16 address))
  (let ((lo (cpu-read-byte cpu address))
        (hi (cpu-read-byte cpu (logand (1+ address) #xFFFF))))
    (logior lo (ash hi 8))))

(defun attach-memory-bus (cpu memory)
  "Wire a MEMORY object's MEM-READ/MEM-WRITE into CPU's bus hooks."
  (declare (type cpu cpu) (type memory memory))
  (setf (cpu-bus-read cpu)
        (lambda (addr) (mem-read memory addr))
        (cpu-bus-write cpu)
        (lambda (addr value) (mem-write memory addr value)))
  cpu)

;;; ---------------------------------------------------------------------------
;;; Flag helpers

(declaim (inline flag-set? set-flag clear-flag set-flag-to))

(defun flag-set? (cpu mask)
  (declare (type cpu cpu) (type u8 mask))
  (not (zerop (logand (cpu-flags cpu) mask))))

(defun set-flag (cpu mask)
  (declare (type cpu cpu) (type u8 mask))
  (setf (cpu-flags cpu) (logand #xFF (logior (cpu-flags cpu) mask))))

(defun clear-flag (cpu mask)
  (declare (type cpu cpu) (type u8 mask))
  (setf (cpu-flags cpu) (logand #xFF (logandc2 (cpu-flags cpu) mask))))

(defun set-flag-to (cpu mask bool)
  (if bool (set-flag cpu mask) (clear-flag cpu mask)))

(defun update-zn (cpu value)
  "Set Z and N from the low 8 bits of VALUE; return the masked byte."
  (declare (type cpu cpu))
  (let ((v (logand value #xFF)))
    (set-flag-to cpu +flag-z+ (zerop v))
    (set-flag-to cpu +flag-n+ (not (zerop (logand v #x80))))
    v))

(defun status-byte-for-push (cpu &key (b-flag t))
  "Pushed status byte: U is always 1; B is 1 for PHP/BRK, 0 for IRQ/NMI."
  (let ((s (logior (cpu-flags cpu) +flag-u+)))
    (if b-flag
        (logior s +flag-b+)
        (logand s (logandc2 #xFF +flag-b+)))))

(defun status-byte-from-pull (byte)
  "Pulled status: force U=1 and B=0 in the in-register copy."
  (logand (logior byte +flag-u+)
          (logandc2 #xFF +flag-b+)))

;;; ---------------------------------------------------------------------------
;;; Stack helpers (page $0100, post-decrement on push, pre-increment on pull)

(declaim (inline push-byte pull-byte))

(defun push-byte (cpu value)
  (declare (type cpu cpu) (type u8 value))
  (cpu-write-byte cpu (logior #x0100 (cpu-sp cpu)) value)
  (setf (cpu-sp cpu) (logand (1- (cpu-sp cpu)) #xFF)))

(defun pull-byte (cpu)
  (declare (type cpu cpu))
  (setf (cpu-sp cpu) (logand (1+ (cpu-sp cpu)) #xFF))
  (cpu-read-byte cpu (logior #x0100 (cpu-sp cpu))))

(defun push-word (cpu word)
  "Push a 16-bit word, high byte first."
  (declare (type cpu cpu) (type u16 word))
  (push-byte cpu (logand (ash word -8) #xFF))
  (push-byte cpu (logand word #xFF)))

(defun pull-word (cpu)
  (declare (type cpu cpu))
  (let ((lo (pull-byte cpu))
        (hi (pull-byte cpu)))
    (logior lo (ash hi 8))))

;;; ---------------------------------------------------------------------------
;;; Reset / IRQ / NMI

(defconstant +nmi-vector+   #xFFFA)
(defconstant +reset-vector+ #xFFFC)
(defconstant +irq-vector+   #xFFFE)

(defun reset-cpu (cpu &optional memory)
  "Apply 6502 reset semantics.

If MEMORY is supplied, also wire CPU's bus hooks to that memory.  The
two-argument call shape matches the original scaffold API."
  (declare (type cpu cpu))
  (when memory
    (attach-memory-bus cpu memory))
  (let* ((lo (cpu-read-byte cpu +reset-vector+))
         (hi (cpu-read-byte cpu (1+ +reset-vector+))))
    (setf (cpu-pc cpu)        (logior lo (ash hi 8))
          (cpu-a  cpu)        0
          (cpu-x  cpu)        0
          (cpu-y  cpu)        0
          (cpu-sp cpu)        #xFD
          (cpu-flags cpu)     #x24
          (cpu-cycles cpu)    0
          (cpu-pending-irq cpu) nil
          (cpu-pending-nmi cpu) nil
          (cpu-halted cpu)    nil))
  cpu)

(defun service-nmi (cpu)
  (declare (type cpu cpu))
  (push-word cpu (cpu-pc cpu))
  (push-byte cpu (status-byte-for-push cpu :b-flag nil))
  (set-flag cpu +flag-i+)
  (setf (cpu-pc cpu) (cpu-read-word cpu +nmi-vector+))
  (incf (cpu-cycles cpu) 7)
  (setf (cpu-pending-nmi cpu) nil))

(defun service-irq (cpu)
  (declare (type cpu cpu))
  (push-word cpu (cpu-pc cpu))
  (push-byte cpu (status-byte-for-push cpu :b-flag nil))
  (set-flag cpu +flag-i+)
  (setf (cpu-pc cpu) (cpu-read-word cpu +irq-vector+))
  (incf (cpu-cycles cpu) 7))

(defun trigger-nmi (cpu) (setf (cpu-pending-nmi cpu) t) cpu)
(defun set-irq-line (cpu level) (setf (cpu-pending-irq cpu) (and level t)) cpu)

;;; ---------------------------------------------------------------------------
;;; PC fetch helpers and addressing modes
;;;
;;; Each addressing-mode helper returns (VALUES EFFECTIVE-ADDR
;;; PAGE-CROSSED?).  The opcode handler decides whether to read or write
;;; at the address and whether the +1 cycle for a page cross applies.

(declaim (inline read-pc-byte read-pc-word page-crossed?))

(defun read-pc-byte (cpu)
  (declare (type cpu cpu))
  (let ((b (cpu-read-byte cpu (cpu-pc cpu))))
    (setf (cpu-pc cpu) (logand (1+ (cpu-pc cpu)) #xFFFF))
    b))

(defun read-pc-word (cpu)
  (declare (type cpu cpu))
  (let ((lo (read-pc-byte cpu))
        (hi (read-pc-byte cpu)))
    (logior lo (ash hi 8))))

(defun page-crossed? (base offset-addr)
  (/= (logand base #xFF00) (logand offset-addr #xFF00)))

(defun addr-immediate (cpu)
  (let ((addr (cpu-pc cpu)))
    (setf (cpu-pc cpu) (logand (1+ addr) #xFFFF))
    (values addr nil)))

(defun addr-zero-page (cpu)
  (values (read-pc-byte cpu) nil))

(defun addr-zero-page-x (cpu)
  (values (logand (+ (read-pc-byte cpu) (cpu-x cpu)) #xFF) nil))

(defun addr-zero-page-y (cpu)
  (values (logand (+ (read-pc-byte cpu) (cpu-y cpu)) #xFF) nil))

(defun addr-absolute (cpu)
  (values (read-pc-word cpu) nil))

(defun addr-absolute-x (cpu)
  (let* ((base (read-pc-word cpu))
         (addr (logand (+ base (cpu-x cpu)) #xFFFF)))
    (values addr (page-crossed? base addr))))

(defun addr-absolute-y (cpu)
  (let* ((base (read-pc-word cpu))
         (addr (logand (+ base (cpu-y cpu)) #xFFFF)))
    (values addr (page-crossed? base addr))))

(defun addr-indirect (cpu)
  "JMP indirect with the NMOS page-wrap bug: if the operand low byte is
$FF, the high byte of the destination is fetched from the same page."
  (let* ((ptr (read-pc-word cpu))
         (lo  (cpu-read-byte cpu ptr))
         (hi-addr (logior (logand ptr #xFF00)
                          (logand (1+ ptr) #x00FF)))
         (hi  (cpu-read-byte cpu hi-addr)))
    (values (logior lo (ash hi 8)) nil)))

(defun addr-indexed-indirect (cpu)
  "(zp,X): pointer fetched from zero page with byte-wrap on the index."
  (let* ((zp  (logand (+ (read-pc-byte cpu) (cpu-x cpu)) #xFF))
         (lo  (cpu-read-byte cpu zp))
         (hi  (cpu-read-byte cpu (logand (1+ zp) #xFF))))
    (values (logior lo (ash hi 8)) nil)))

(defun addr-indirect-indexed (cpu)
  "(zp),Y: pointer at ZP, ZP+1 (zero-page wrap), then add Y."
  (let* ((zp   (read-pc-byte cpu))
         (lo   (cpu-read-byte cpu zp))
         (hi   (cpu-read-byte cpu (logand (1+ zp) #xFF)))
         (base (logior lo (ash hi 8)))
         (addr (logand (+ base (cpu-y cpu)) #xFFFF)))
    (values addr (page-crossed? base addr))))

(defun addr-relative (cpu)
  "Return the branch target for a relative offset (signed byte)."
  (let* ((off (read-pc-byte cpu))
         (s   (if (>= off #x80) (- off #x100) off)))
    (values (logand (+ (cpu-pc cpu) s) #xFFFF) nil)))

;;; ---------------------------------------------------------------------------
;;; Fetch / decode / dispatch

(define-condition illegal-opcode (error)
  ((opcode :initarg :opcode :reader illegal-opcode-opcode)
   (pc     :initarg :pc     :reader illegal-opcode-pc))
  (:report (lambda (c s)
             (format s "Illegal/undocumented 6502 opcode #x~2,'0X at PC=#x~4,'0X"
                     (illegal-opcode-opcode c)
                     (illegal-opcode-pc     c)))))

(defvar *opcode-table* nil
  "256-entry SIMPLE-VECTOR populated by src/cpu-opcodes.lisp.
Each element is either NIL (illegal opcode) or a function of one
argument (CPU) that returns the number of cycles consumed.")

(defun step-cpu (cpu &optional memory)
  "Execute one instruction, returning the number of cycles consumed.
Services pending NMI/IRQ before fetching the next opcode."
  (declare (type cpu cpu))
  (when (and memory (null (cpu-bus-read cpu)))
    (attach-memory-bus cpu memory))
  (cond
    ((cpu-pending-nmi cpu)
     (service-nmi cpu)
     7)
    ((and (cpu-pending-irq cpu) (not (flag-set? cpu +flag-i+)))
     (service-irq cpu)
     7)
    (t
     (let* ((pc-at-fetch (cpu-pc cpu))
            (opcode (read-pc-byte cpu))
            (handler (and *opcode-table* (svref *opcode-table* opcode))))
       (unless handler
         (setf (cpu-halted cpu) t)
         (error 'illegal-opcode :opcode opcode :pc pc-at-fetch))
       (let ((cycles (funcall handler cpu)))
         (incf (cpu-cycles cpu) cycles)
         cycles)))))

(defun run-cpu (cpu &optional memory &key (cycles 0))
  "Run the CPU.

If CYCLES is 0, execute exactly one instruction and return its cycle
count.  Otherwise run until at least CYCLES cycles have elapsed since
this call began, returning the total cycles executed during the call."
  (declare (type cpu cpu))
  (when (and memory (null (cpu-bus-read cpu)))
    (attach-memory-bus cpu memory))
  (if (zerop cycles)
      (step-cpu cpu)
      (let ((target (+ (cpu-cycles cpu) cycles))
            (start  (cpu-cycles cpu)))
        (loop while (< (cpu-cycles cpu) target)
              do (step-cpu cpu))
        (- (cpu-cycles cpu) start))))
