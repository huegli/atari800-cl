;;;; src/memory.lisp --- 64K address space for the Atari 800 XL.
;;;;
;;;; The Atari 800 XL has a 16-bit address bus, 64K of RAM, and overlaid
;;;; OS / BASIC ROM banks plus memory-mapped hardware registers (ANTIC,
;;;; GTIA, POKEY, PIA).  This file only implements a flat RAM array as a
;;;; scaffold; the bank-switching and I/O hooks land in subsequent commits.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; DEFCONSTANT defines a compile-time constant.  By CL convention,
;;;; constant names are wrapped in +PLUS-SIGNS+.
;;;;
;;;; DEFSTRUCT defines a record type (like a C struct or a Python dataclass).
;;;; It automatically generates:
;;;;   - A constructor function   (MAKE-MEMORY)
;;;;   - A type predicate         (MEMORY-P)
;;;;   - Slot accessor functions  (MEMORY-RAM, MEMORY-OS-ROM, MEMORY-BASIC-ROM)
;;;; Each slot has an initial value and a :TYPE declaration that the
;;;; compiler can use for optimisation and safety checks.
;;;;
;;;; DECLARE (inside a function body) provides local type hints to the
;;;; compiler.  (DECLARE (TYPE U16 ADDRESS)) promises that ADDRESS is a
;;;; 16-bit unsigned integer, letting the compiler generate faster code.
;;;;
;;;; SETF is CL's generalised assignment operator.  (SETF (AREF arr i) v)
;;;; sets the i-th element of array ARR to V; (SETF (MEMORY-OS-ROM m) x)
;;;; sets the OS-ROM slot of struct M to X.  SETF works with any "place"
;;;; (accessor), not just variables.

(in-package #:atari800-cl.memory)

;;; ---------------------------------------------------------------------------
;;; Address-space constants
;;;
;;; #x10000 is hexadecimal notation for 65536 (64 * 1024).  The #x prefix
;;; tells the Lisp reader to parse the number in base 16.

(defconstant +address-space-size+ #x10000
  "Total 6502 address space: 64 KiB.")

(defconstant +os-rom-base+ #xC000
  "Start of OS ROM area (with bank-switching, this can be RAM instead).")

(defconstant +basic-rom-base+ #xA000
  "Start of BASIC ROM area when BASIC is enabled.")

;;; ---------------------------------------------------------------------------
;;; Memory struct
;;;
;;; (OR NULL BYTE-VECTOR) means the slot can hold either NIL (no ROM loaded)
;;; or a byte vector.  This is CL's way of expressing an "optional" typed slot.

(defstruct memory
  "Atari 800 XL memory state.

RAM is the full 64K address space.  OS-ROM and BASIC-ROM hold the
contents of the corresponding ROM images and are overlaid on top of RAM
when the appropriate PORTB bits are set (handled in a later milestone)."
  (ram       (make-byte-vector +address-space-size+) :type byte-vector)
  (os-rom    nil :type (or null byte-vector))
  (basic-rom nil :type (or null byte-vector)))

;;; ---------------------------------------------------------------------------
;;; Read / write
;;;
;;; DECLAIM INLINE tells the compiler to inline these small, hot functions
;;; so every call to MEM-READ or MEM-WRITE avoids the overhead of a
;;; function call.  This matters because the CPU calls them millions of
;;; times per emulated second.
;;;
;;; AREF accesses an element of an array by index, like arr[i] in C.

(declaim (inline mem-read mem-write))

(defun mem-read (memory address)
  "Read a byte from ADDRESS in MEMORY."
  (declare (type memory memory)
           (type u16 address))
  (aref (memory-ram memory) address))

(defun mem-write (memory address value)
  "Write VALUE (a u8) to ADDRESS in MEMORY."
  (declare (type memory memory)
           (type u16 address)
           (type u8 value))
  (setf (aref (memory-ram memory) address) value))

;;; ---------------------------------------------------------------------------
;;; ROM loading
;;;
;;; LOAD-ROM is a thin wrapper around READ-BINARY-FILE (from compat.lisp).
;;; INSTALL-OS-ROM / INSTALL-BASIC-ROM store the loaded bytes into the
;;; struct and return the MEMORY object to allow method-chaining:
;;;   (install-basic-rom (install-os-rom mem os-bytes) basic-bytes)
;;;
;;; COERCE converts a sequence to a specific type.  Here it ensures that
;;; whatever the caller passes (list, general vector, etc.) becomes a
;;; BYTE-VECTOR (simple-array of unsigned-byte 8) for type safety.

(defun load-rom (pathname)
  "Read PATHNAME and return its contents as a byte vector."
  (read-binary-file pathname))

(defun install-os-rom (memory bytes)
  "Install BYTES as the OS ROM image."
  (setf (memory-os-rom memory) (coerce bytes 'byte-vector))
  memory)

(defun install-basic-rom (memory bytes)
  "Install BYTES as the BASIC ROM image."
  (setf (memory-basic-rom memory) (coerce bytes 'byte-vector))
  memory)

;;; ---------------------------------------------------------------------------
;;; Reset
;;;
;;; FILL is a standard CL function that sets every element of a sequence
;;; to the given value.  Here it zeros out RAM without touching the ROM
;;; images.

(defun reset-memory (memory)
  "Clear RAM contents (ROM images are preserved)."
  (fill (memory-ram memory) 0)
  memory)
