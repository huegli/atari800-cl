;;;; src/irq.lisp --- NMI / IRQ routing layer.
;;;;
;;;; The 6502 CPU is the central interrupt target on the Atari 800 XL.
;;;; Two pending lines drive it: NMI (non-maskable) and IRQ (maskable
;;;; by the I flag).  The chips assert these by setting
;;;; CPU-PENDING-NMI / CPU-PENDING-IRQ; STEP-CPU services them itself
;;;; before each instruction fetch and returns the 7-cycle entry cost,
;;;; which is how the machine scheduler accounts for interrupt time.
;;;; The helpers below expose the same dispatch as a standalone routing
;;;; API for tests and alternative drivers that step the CPU manually;
;;;; note that servicing through them bypasses any caller-side cycle
;;;; budgeting (SERVICE-NMI/IRQ only increment CPU-CYCLES).

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
             (not (flag-set-p cpu +flag-i+)))
    (service-irq cpu)
    t))
