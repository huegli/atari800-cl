;;;; src/package.lisp --- Package definitions for atari800-cl.
;;;;
;;;; The emulator is split across a set of internal packages, layered
;;;; bottom-up (see CLAUDE.md for the full list):
;;;;
;;;;   atari800-cl.compat   — implementation portability layer
;;;;   atari800-cl.memory   — 64K address space and memory map
;;;;   atari800-cl.cpu      — 6502 CPU core
;;;;   atari800-cl.bus/.mmu — system bus + bank switching
;;;;   atari800-cl.<chip>   — pia, antic, gtia, pokey, irq
;;;;   atari800-cl.machine  — top-level machine + frame scheduler
;;;;   atari800-cl          — public façade re-exporting user-facing API
;;;;
;;;; Internal packages keep their symbols private; only :atari800-cl
;;;; exports a stable public API.
;;;;
;;;; --- Common Lisp notes for beginners ---
;;;;
;;;; A "package" in Common Lisp is a namespace for symbols (names).
;;;; DEFPACKAGE declares which symbols a package exports (makes public)
;;;; and which other packages it imports from.
;;;;
;;;; (:USE #:cl) means "import all exported symbols from the CL package",
;;;; which gives us standard functions like DEFUN, LET, LOOP, etc.
;;;;
;;;; (:USE #:atari800-cl.compat) means "also import all exports from our
;;;; compat package", so we can write U8 instead of ATARI800-CL.COMPAT:U8.
;;;;
;;;; (:EXPORT #:symbol) makes SYMBOL accessible to other packages that
;;;; :USE this one, or via the PACKAGE:SYMBOL qualified syntax.
;;;;
;;;; The #: prefix (e.g. #:cl, #:make-cpu) creates an "uninterned symbol"
;;;; — a symbol not belonging to any package.  This is conventional in
;;;; DEFPACKAGE because it avoids accidentally interning symbols into the
;;;; current package as a side effect of reading the form.  It is purely
;;;; a hygiene measure; :CL (a keyword) would also work but is less idiomatic.

;; We define our packages in CL-USER, the standard "scratch" package that
;; exists in every Common Lisp environment.
(in-package #:cl-user)

;;; ---------------------------------------------------------------------------
;;; atari800-cl.compat — Portability layer
;;;
;;; This is the lowest-level package.  It only :USE's #:cl (standard CL)
;;; and exports type aliases (U8, U16, BYTE-VECTOR), threading helpers,
;;; and binary I/O wrappers.

(defpackage #:atari800-cl.compat
  (:use #:cl)
  (:documentation
   "Portability layer hiding LispWorks/SBCL implementation differences.")
  (:export #:*implementation*
           #:implementation-name
           #:make-byte-vector
           #:byte-vector
           #:u8
           #:u16
           #:make-lock
           #:with-lock
           #:make-thread
           #:join-thread
           #:thread-alive-p
           #:destroy-thread
           #:current-thread
           #:make-condition-variable
           #:condition-wait
           #:condition-notify
           #:read-binary-file
           #:write-binary-file
           #:without-gc-warnings
           ;; Process / filesystem helpers
           #:current-process-id
           #:delete-file-if-exists
           #:chmod-file
           ;; Unix-domain stream sockets
           #:unix-listener
           #:unix-listener-p
           #:unix-listener-path
           #:open-unix-listener
           #:accept-unix-client
           #:open-unix-client
           #:close-unix-listener))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.input — Host input state
;;;
;;; A single mutex-guarded struct holding the current keyboard, joystick,
;;; console-key, and paddle state.  Loaded early (right after compat) so the
;;; PIA / GTIA / POKEY register-read paths can delegate to its getters.
;;; Setters are called from socket reader threads; getters from the emulator
;;; thread — hence the lock.

(defpackage #:atari800-cl.input
  (:use #:cl #:atari800-cl.compat)
  (:documentation "Thread-safe host input state (keyboard / joystick / console / paddles).")
  (:export #:input-state
           #:make-input-state
           #:input-state-p
           ;; Setters (called from socket reader threads)
           #:input-set-joystick
           #:input-set-console
           #:input-set-paddle
           #:input-set-key
           #:input-set-break
           ;; Getters (called from the emulator thread by PIA/GTIA/POKEY)
           #:input-pia-porta
           #:input-gtia-trig
           #:input-gtia-consol
           #:input-pokey-pot
           #:input-pokey-kbcode
           #:input-pokey-skstat
           ;; Keyboard/BREAK IRQ arming (consumed by POKEY; ROADMAP.md Phase 13)
           #:input-consume-key-irq
           #:input-consume-break-irq))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.memory — 64K address space
;;;
;;; Depends on compat for the U8/U16/BYTE-VECTOR types.  Exports the
;;; MEMORY struct and its accessor functions.

(defpackage #:atari800-cl.memory
  (:use #:cl #:atari800-cl.compat)
  (:documentation "64K address space, RAM/ROM banks, and memory-mapped I/O hooks.")
  (:export #:memory
           #:make-memory
           #:mem-read
           #:mem-write
           #:load-rom
           #:install-os-rom
           #:install-basic-rom
           #:reset-memory))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.cpu — 6502 CPU core
;;;
;;; Depends on both compat (types) and memory (for ATTACH-MEMORY-BUS).
;;; The export list is large because we expose the full register file,
;;; flag constants, interrupt vectors, and the opcode dispatch table.
;;; Constants follow the CL convention of +PLUS-SIGNS+ for named constants
;;; (defined with DEFCONSTANT) and *EARMUFFS* for special variables
;;; (defined with DEFPARAMETER or DEFVAR).

(defpackage #:atari800-cl.cpu
  (:use #:cl #:atari800-cl.compat #:atari800-cl.memory)
  (:documentation "6502 CPU core: registers, flags, instruction decode and step.")
  (:export #:cpu
           #:make-cpu
           #:reset-cpu
           #:step-cpu
           #:run-cpu
           #:cpu-pc
           #:cpu-a
           #:cpu-x
           #:cpu-y
           #:cpu-sp
           #:cpu-flags
           #:cpu-cycles
           #:cpu-bus-read
           #:cpu-bus-write
           #:cpu-pending-irq
           #:cpu-pending-nmi
           #:cpu-halted
           #:attach-memory-bus
           #:trigger-nmi
           #:set-irq-line
           #:flag-set-p
           #:set-flag
           #:clear-flag
           #:set-flag-to
           #:status-byte-for-push
           #:status-byte-from-pull
           #:push-byte
           #:pull-byte
           #:push-word
           #:pull-word
           ;; Flag-bit constants (DEFCONSTANT, hence +plus-sign+ naming)
           #:+flag-c+ #:+flag-z+ #:+flag-i+ #:+flag-d+
           #:+flag-b+ #:+flag-u+ #:+flag-v+ #:+flag-n+
           ;; Interrupt vector addresses
           #:+nmi-vector+ #:+reset-vector+ #:+irq-vector+
           ;; Opcode dispatch table and introspection
           #:*opcode-table*
           #:*opcode-mnemonic-table*
           #:documented-opcodes
           #:illegal-opcodes
           #:*illegal-opcode-list*
           #:illegal-opcode
           ;; Interrupt service functions (used by IRQ routing layer)
           #:service-nmi
           #:service-irq))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.mmu — Memory Management Unit (PORTB bank-switching)
;;;
;;; Owns the PORTB shadow register and the OS/BASIC/self-test ROM mapping
;;; predicates.  The PIA writes here whenever software writes PORTB at
;;; $D301; the bus consults these predicates on every read.

(defpackage #:atari800-cl.mmu
  (:use #:cl #:atari800-cl.compat)
  (:documentation "Atari 800 XL PORTB-driven memory bank switching.")
  (:export #:mmu
           #:make-mmu
           #:mmu-portb
           #:mmu-write-portb
           #:reset-mmu
           #:os-rom-mapped-p
           #:basic-rom-mapped-p
           #:selftest-mapped-p
           #:portb-decode
           #:+portb-os-rom-mask+
           #:+portb-basic-rom-mask+
           #:+portb-selftest-mask+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.bus — Atari 800 XL system bus and memory map
;;;
;;; The CPU talks through BUS-READ / BUS-WRITE.  The bus owns 64K RAM,
;;; the OS and BASIC ROM images, a reference to the MMU, and per-chip
;;; dispatch closures that get installed when individual chips are
;;; attached (PIA, GTIA, POKEY, ANTIC — added in later milestones).

(defpackage #:atari800-cl.bus
  (:use #:cl #:atari800-cl.compat #:atari800-cl.mmu)
  (:documentation "Atari 800 XL system bus: memory map and I/O dispatch.")
  (:export #:bus
           #:make-bus
           #:bus-ram
           #:bus-os-rom
           #:bus-basic-rom
           #:bus-mmu
           #:bus-read
           #:bus-write
           #:bus-read16
           #:install-os-rom
           #:install-basic-rom
           #:attach-mmu
           #:bus-peek-ram
           #:bus-poke-ram
           ;; Chip object back-pointers
           #:bus-gtia #:bus-pokey #:bus-pia #:bus-antic
           ;; Per-chip dispatch closures (installed by chip attach functions)
           #:bus-gtia-read-fn  #:bus-gtia-write-fn
           #:bus-pokey-read-fn #:bus-pokey-write-fn
           #:bus-pia-read-fn   #:bus-pia-write-fn
           #:bus-antic-read-fn #:bus-antic-write-fn
           ;; Region constants
           #:+selftest-base+   #:+selftest-end+
           #:+basic-rom-base+  #:+basic-rom-end+
           #:+os-rom-low-base+ #:+os-rom-low-end+
           #:+io-base+         #:+io-end+
           #:+os-rom-high-base+ #:+os-rom-high-end+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.pia — 6520 PIA (joystick input + PORTB → MMU output)
;;;
;;; The PIA owns PORTA/DDRA at $D300, PORTB/DDRB at $D301 (each pair
;;; selected by bit 2 of the matching control register) and PACTL/PBCTL
;;; at $D302/$D303.  A write to PORTB propagates to the attached MMU so
;;; bank-switching takes effect on the next bus access.

(defpackage #:atari800-cl.pia
  (:use #:cl #:atari800-cl.compat #:atari800-cl.mmu #:atari800-cl.bus)
  (:documentation "Atari 800 XL PIA (6520-compatible).")
  (:export #:pia
           #:make-pia
           #:pia-porta #:pia-ddra
           #:pia-portb #:pia-ddrb
           #:pia-pactl #:pia-pbctl
           #:pia-mmu
           #:pia-input
           #:pia-read
           #:pia-write
           #:reset-pia
           #:attach-pia
           #:attach-pia-input))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.antic — Display list / DMA engine for the 800 XL
;;;
;;; Scanline-oriented model: ANTIC-TICK advances one CPU cycle (114 per
;;; scanline; a real NTSC line is 228 color clocks at twice the CPU
;;; rate), performs display-list parsing on the correct scanline
;;; boundaries, lumps DRAM refresh and P/M DMA steals at cycle 0 of each
;;; scanline, and raises NMI lines for DLI and VBI events.

(defpackage #:atari800-cl.antic
  (:use #:cl #:atari800-cl.compat #:atari800-cl.bus #:atari800-cl.cpu)
  (:documentation "Atari 800 XL ANTIC video controller (NTSC scanline timing).")
  (:export #:antic
           #:make-antic
           #:antic-registers
           #:antic-dlist-pointer
           #:antic-dl-offset
           #:antic-scanline
           #:antic-line-cycle
           #:antic-dmactl
           #:antic-nmien
           #:antic-nmist
           #:antic-current-mode
           #:antic-mode-scanlines-remaining
           #:antic-dli-armed
           #:antic-jvb-wait
           #:antic-frame-count
           #:antic-stolen-cycles
           #:antic-tick
           #:antic-begin-scanline
           #:antic-end-scanline
           #:antic-read
           #:antic-write
           #:antic-wsync-pending
           #:antic-consume-wsync
           #:antic-pm-write-fn
           #:reset-antic
           #:attach-antic
           #:mode-line-scanlines
           #:playfield-dma-cycles
           #:bytes-per-screen-row
           #:+scanlines-per-frame+
           #:+cpu-cycles-per-scanline+
           #:+active-start-scanline+
           #:+vbi-scanline+
           #:+dram-refresh-cycles+
           #:+nmi-dli+ #:+nmi-vbi+
           ;; Rendering support
           #:antic-scan-y
           #:antic-screen-data-ptr
           #:antic-render-screen-data-ptr
           #:+reg-chbase+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.gtia — GTIA (player/missile + collision latches + console)
;;;
;;; GTIA registers occupy $D000-$D0FF.  The write side accepts HPOS,
;;; size, graphics, color, priority, HITCLR, and CONSOL (speaker)
;;; values.  The read side returns collision latches, console keys,
;;; triggers, and the PAL/NTSC indicator.

(defpackage #:atari800-cl.gtia
  (:use #:cl #:atari800-cl.compat #:atari800-cl.bus)
  (:documentation "Atari 800 XL GTIA chip (player/missile + collisions).")
  (:export #:gtia
           #:make-gtia
           #:gtia-write-regs
           #:gtia-read-regs
           #:gtia-pf-tag-row
           #:gtia-pm-mask-row
           #:gtia-read
           #:gtia-write
           #:gtia-record-collision
           #:gtia-clear-collisions
           #:gtia-input
           #:reset-gtia
           #:attach-gtia
           #:attach-gtia-input
           ;; Register offsets (write side)
           #:+w-hposp0+ #:+w-hposm0+ #:+w-sizep0+ #:+w-sizem+
           #:+w-grafp0+ #:+w-grafm+
           #:+w-colpm0+ #:+w-colpf0+ #:+w-colbk+
           #:+w-prior+  #:+w-vdelay+ #:+w-gractl+
           #:+w-hitclr+ #:+w-consol+
           ;; Register offsets (read side)
           #:+r-m0pf+ #:+r-p0pf+ #:+r-m0p+ #:+r-p0p+
           #:+r-trig0+ #:+r-pal+ #:+r-consol+
           #:+pal-register-ntsc+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.pokey — POKEY (timers + IRQ + audio + serial + keyboard)
;;;
;;; This file models POKEY's timer-based IRQ generation, the polynomial
;;; RNG used by the RANDOM register, and the IRQEN/IRQST latch protocol.
;;; Audio output and serial I/O are register-only stubs.

(defpackage #:atari800-cl.pokey
  (:use #:cl #:atari800-cl.compat #:atari800-cl.bus #:atari800-cl.cpu)
  (:documentation "Atari 800 XL POKEY — timers, IRQ, RNG, audio scaffolding.")
  (:export #:pokey
           #:make-pokey
           #:pokey-audf #:pokey-audc
           #:pokey-audctl #:pokey-skctl
           #:pokey-irqen #:pokey-irqst
           #:pokey-timer-counts #:pokey-sub-counters
           #:pokey-poly17-state #:pokey-poly9-state
           #:pokey-kbcode
           #:pokey-input
           #:pokey-tick
           #:pokey-advance
           #:pokey-read #:pokey-write
           #:pokey-random
           #:reset-pokey
           #:attach-pokey
           #:attach-pokey-input
           #:+irq-timer1+ #:+irq-timer2+ #:+irq-timer4+
           #:+irq-other-key+ #:+irq-break-key+
           ;; Serial output transmitter (SEROUT + SEROR/SEROC interrupts)
           #:pokey-serial-out-shift #:pokey-serial-out-holding
           #:pokey-serial-out-cycles
           #:+irq-serial-out-done+ #:+irq-serial-out-needed+
           #:+skctl-transmit-mode+
           #:+serial-frame-bits+ #:+serial-half-bits-per-byte+
           ;; PENDING bitmask (ROADMAP.md Phase 22)
           #:pokey-pending
           #:+pokey-pending-serial-tx+ #:+pokey-pending-audio+
           #:+pokey-pending-key+
           ;; Audio hooks (installed by src/audio.lisp's ATTACH-AUDIO)
           #:pokey-audio
           #:pokey-audio-advance-fn #:pokey-audio-underflow-fn
           ;; Shared polynomial-counter primitive + tap/period constants
           #:step-lfsr
           #:+poly4-tap+ #:+poly5-tap+ #:+poly9-tap+ #:+poly17-tap+
           #:+poly4-period+ #:+poly5-period+
           #:+poly9-period+ #:+poly17-period+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.audio — POKEY audio synthesis (ROADMAP.md Phase 9)
;;;
;;; Everything downstream of a POKEY counter underflow: the per-channel
;;; output flip-flops, the polynomial distortion generators, and the
;;; mixer that turns them into mono 8-bit PCM at ~44.7 kHz.  Loads AFTER
;;; pokey (whose STEP-LFSR builds the poly tables and whose struct holds
;;; the attachment) and BEFORE machine (which exposes the facade).

(defpackage #:atari800-cl.audio
  (:use #:cl #:atari800-cl.compat #:atari800-cl.pokey)
  (:documentation "POKEY audio synthesis: four-channel PCM at ~44.7 kHz.")
  (:export #:audio-unit
           #:make-audio-unit
           #:audio-unit-pokey
           #:audio-advance
           #:audio-channel-underflow
           #:audio-drain
           #:reset-audio-unit
           #:attach-audio
           #:+audio-sample-rate+
           #:+audio-cycles-per-sample+
           #:+audio-centre-level+))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.irq — NMI / IRQ routing helpers
;;;
;;; Thin wrappers for servicing whichever interrupt the chips have
;;; asserted.  STEP-CPU performs the same dispatch internally (and the
;;; machine scheduler relies on that for cycle accounting); these remain
;;; for tests and drivers that step the CPU manually.

(defpackage #:atari800-cl.irq
  (:use #:cl #:atari800-cl.compat #:atari800-cl.cpu)
  (:documentation "Atari 800 XL interrupt routing.")
  (:export #:check-and-dispatch-nmi
           #:check-and-dispatch-irq))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.renderer — Per-scanline NTSC pixel renderer
;;;
;;; Depends on ANTIC (for display-list state) and GTIA (for color/sprite
;;; registers).  Produces 24-bit RGB pixels into a 384×240 framebuffer.

(defpackage #:atari800-cl.renderer
  (:use #:cl #:atari800-cl.compat #:atari800-cl.bus
        #:atari800-cl.antic #:atari800-cl.gtia)
  (:documentation "Per-scanline NTSC pixel renderer: palette, playfield, P/M graphics.")
  (:export #:make-framebuffer
           #:render-scanline
           #:+framebuffer-width+
           #:+framebuffer-height+
           #:atari-color->r
           #:atari-color->g
           #:atari-color->b))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.machine — Top-level NTSC scheduler
;;;
;;; Owns the CPU plus every chip (mmu, bus, pia, antic, gtia, pokey)
;;; and runs the frame-loop that pumps them in lockstep.  This is the
;;; real Atari 800 XL machine that the public façade drives.

(defpackage #:atari800-cl.machine
  (:use #:cl #:atari800-cl.compat
        #:atari800-cl.cpu #:atari800-cl.bus #:atari800-cl.mmu
        #:atari800-cl.pia #:atari800-cl.antic #:atari800-cl.gtia
        #:atari800-cl.pokey #:atari800-cl.audio #:atari800-cl.irq)
  (:documentation "Atari 800 XL top-level machine + frame scheduler.")
  (:export #:atari-machine
           #:make-atari-machine
           #:atari-machine-cpu  #:atari-machine-bus
           #:atari-machine-mmu  #:atari-machine-pia
           #:atari-machine-antic #:atari-machine-gtia
           #:atari-machine-pokey
           #:atari-machine-frame-count
           #:atari-machine-running-p
           #:atari-machine-input
           #:atari-machine-mailbox
           #:machine-run-frame
           #:machine-cold-reset
           #:machine-install-roms
           #:machine-attach-audio
           #:machine-audio-drain
           #:load-rom-file
           #:+clocks-per-frame+
           ;; Concurrency: mailbox + run loop + host input
           #:%run-clocks
           #:command-mailbox
           #:make-command-mailbox
           #:mailbox-enqueue
           #:mailbox-drain
           #:mailbox-wait
           #:mailbox-full
           #:machine-submit
           #:machine-run-loop
           #:machine-runner
           #:machine-runner-p
           #:start-machine
           #:stop-machine
           #:attach-input
           ;; Debug / REPL instrumentation
           #:machine-trace-step
           #:machine-portb-state
           #:machine-scanline
           #:machine-pending-interrupts
           ;; Rendering hooks
           #:atari-machine-scanline-fn
           #:atari-machine-post-frame-fn))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.transport — Socket transport (TCP via usocket; Unix via compat)

(defpackage #:atari800-cl.transport
  (:use #:cl #:atari800-cl.compat)
  (:documentation "Socket transport for the protocol servers: binary TCP
(usocket) and text Unix-domain (compat).")
  (:export #:tcp-listen #:tcp-listener-port #:tcp-accept #:tcp-connect
           #:tcp-stream #:tcp-close
           #:unix-listen #:unix-accept #:unix-connect #:unix-close))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.aesp — AESP binary protocol (codec + 3-port server)
;;;
;;; 8-byte big-endian header (magic 0xAE50, version 1, 1-byte type, 4-byte
;;; length) + payload.  The pure codec is unit-testable without sockets; the
;;; server drives the machine via its command mailbox.

(defpackage #:atari800-cl.aesp
  (:use #:cl #:atari800-cl.compat #:atari800-cl.transport
        #:atari800-cl.input #:atari800-cl.machine)
  (:documentation "AESP binary protocol codec and TCP server.")
  (:export ;; Codec
           #:aesp-protocol-error
           #:encode-aesp-message
           #:decode-aesp-header
           #:read-aesp-message
           #:write-aesp-message
           #:+aesp-magic+ #:+aesp-version+ #:+aesp-header-size+
           #:+aesp-max-payload+
           ;; Message-type constants
           #:+aesp-ping+ #:+aesp-pong+
           #:+aesp-pause+ #:+aesp-resume+ #:+aesp-reset+
           #:+aesp-status+ #:+aesp-info+ #:+aesp-ack+ #:+aesp-error+
           #:+aesp-key-down+ #:+aesp-key-up+ #:+aesp-joystick+
           #:+aesp-console-keys+ #:+aesp-paddle+
           #:+aesp-frame-raw+
           #:+aesp-frame-config+ #:+aesp-video-subscribe+ #:+aesp-video-unsubscribe+
           #:+aesp-audio-pcm+
           #:+aesp-audio-config+ #:+aesp-audio-subscribe+ #:+aesp-audio-unsubscribe+
           #:+aesp-err-server-busy+ #:+aesp-err-not-implemented+
           ;; Server
           #:aesp-server #:aesp-server-p
           #:start-aesp-server #:stop-aesp-server
           #:aesp-server-control-port #:aesp-server-video-port
           #:aesp-server-audio-port))

;;; ---------------------------------------------------------------------------
;;; atari800-cl.cli-socket — Text CLI/GUI line protocol over a Unix socket
;;;
;;; Newline-terminated `CMD:<verb> [args]` requests -> `OK:<data>` / `ERR:<msg>`
;;; replies.  The parser is pure and socket-free; the server drives the
;;; machine via its command mailbox.

(defpackage #:atari800-cl.cli-socket
  (:use #:cl #:atari800-cl.compat #:atari800-cl.transport #:atari800-cl.machine)
  (:documentation "Attic-style text CLI line protocol over a Unix socket.")
  (:export ;; Parser
           #:cli-parse-error
           #:parse-cli-command
           #:parse-hex-address
           #:parse-hex-byte-list
           #:parse-register-assignments
           ;; Dispatch + server
           #:*cli-verbs*
           #:dispatch-cli-line
           #:cli-server #:cli-server-p #:cli-server-path
           #:start-cli-socket #:stop-cli-socket))

;;; ---------------------------------------------------------------------------
;;; atari800-cl — Public facade
;;;
;;; This package :USE's only #:cl — it does NOT :USE the internal packages.
;;; Instead, src/main.lisp calls internal functions with fully-qualified
;;; names (e.g. atari800-cl.machine:make-atari-machine).  This keeps the
;;; public API surface small and explicit: only the symbols listed in
;;; :EXPORT are part of the stable contract.
;;;
;;; (:NICKNAMES #:a800) lets users type A800:MAKE-MACHINE as a shorthand.

(defpackage #:atari800-cl
  (:use #:cl)
  (:nicknames #:a800)
  (:documentation
   "Public API for the atari800-cl headless Atari 800 XL emulator.")
  (:export #:make-machine
           #:reset-machine
           #:step-machine
           #:run-machine
           #:run-frame
           #:machine-frame-count
           ;; Audio
           #:machine-attach-audio
           #:machine-audio-drain
           #:+audio-sample-rate+
           #:load-os-rom
           #:load-basic-rom
           ;; Background run loop + protocol servers
           #:start-machine
           #:stop-machine
           #:start-aesp-server
           #:stop-aesp-server
           #:start-cli-socket
           #:stop-cli-socket
           #:*version*))
