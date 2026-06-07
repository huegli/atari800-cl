;;;; src/irq.lisp --- NMI / IRQ routing layer.
;;;;
;;;; The 6502 CPU is the central interrupt target on the Atari 800 XL.
;;;; Two pending lines drive it: NMI (non-maskable) and IRQ (maskable
;;;; by the I flag).  The chips assert these by setting
;;;; CPU-PENDING-NMI / CPU-PENDING-IRQ; the machine scheduler must
;;;; service them at every clock tick BEFORE running the next CPU
;;;; instruction.  The helpers below are the indirection point the
;;;; scheduler uses; they call into the CPU package's service-* functions.

(in-package #:atari800-cl.irq)

(defun check-and-dispatch-nmi (cpu)
  "Service a pending NMI on CPU, if any.  Returns T iff an NMI was serviced.

NMI is non-maskable: the I flag is irrelevant.  Servicing pushes the
current PC and status (with B clear), sets I to disable further IRQs,
and vectors through $FFFA/$FFFB."
  (when (cpu-pending-nmi cpu)
    (service-nmi cpu)
    t))

(defun check-and-dispatch-irq (cpu)
  "Service a pending IRQ on CPU iff the I flag is clear.  Returns T iff an
IRQ was serviced.

The IRQ line is level-sensitive — the caller (the chip that asserted
it) is responsible for clearing CPU-PENDING-IRQ when its own latch is
acknowledged, otherwise the next tick re-services it immediately."
  (when (and (cpu-pending-irq cpu)
             (not (flag-set? cpu +flag-i+)))
    (service-irq cpu)
    t))
