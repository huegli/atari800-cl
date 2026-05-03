;;;; src/memory.lisp --- 64K address space for the Atari 800 XL.
;;;;
;;;; The Atari 800 XL has a 16-bit address bus, 64K of RAM, and overlaid
;;;; OS / BASIC ROM banks plus memory-mapped hardware registers (ANTIC,
;;;; GTIA, POKEY, PIA).  This file only implements a flat RAM array as a
;;;; scaffold; the bank-switching and I/O hooks land in subsequent commits.

(in-package #:atari800-cl.memory)

(defconstant +address-space-size+ #x10000
  "Total 6502 address space: 64 KiB.")

(defconstant +os-rom-base+ #xC000
  "Start of OS ROM area (with bank-switching, this can be RAM instead).")

(defconstant +basic-rom-base+ #xA000
  "Start of BASIC ROM area when BASIC is enabled.")

(defstruct memory
  "Atari 800 XL memory state.

RAM is the full 64K address space.  OS-ROM and BASIC-ROM hold the
contents of the corresponding ROM images and are overlaid on top of RAM
when the appropriate PORTB bits are set (handled in a later milestone)."
  (ram      (make-byte-vector +address-space-size+) :type byte-vector)
  (os-rom   nil :type (or null byte-vector))
  (basic-rom nil :type (or null byte-vector)))

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

(defun reset-memory (memory)
  "Clear RAM contents (ROM images are preserved)."
  (fill (memory-ram memory) 0)
  memory)
