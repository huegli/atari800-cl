# Plan: Add AESP + CLI Socket Protocols to atari800-cl

> **Reconciliation note (2026-06-08).** This plan was written before two
> changes that invalidate several of its preconditions. The **core
> architecture still holds** (4 new packages -- input/transport/aesp/
> cli-socket; input slots on PIA/GTIA/POKEY; mailbox + `%run-clocks`
> refactor in `machine.lisp`), and the emulator APIs it leans on still
> exist at the cited locations. What changed:
>
> 1. **The `atari800-cl.ipc` package was deleted**, not deprecated.
>    `src/ipc.lisp` and `tests/test-ipc.lisp` no longer exist, so every
>    "deprecate ipc" / "reuse the ipc lifecycle template" / "slot in
>    before ipc" reference below is obsolete. The lifecycle + socket-test
>    templates still exist **in git history** (before commit `57e237f`);
>    pull them from there, not from the tree.
> 2. **`usocket` and `flexi-streams` were removed from `:depends-on`**
>    (the asd now lists only `alexandria` + `bordeaux-threads`). This PR
>    therefore **does** add dependencies: re-add `usocket` (transport) and
>    `flexi-streams` (AESP `INFO` octet encoding, or substitute `babel`).
>    Every "no new dependencies" / "usocket already declared" claim below
>    is now false.
> 3. **Verification commands** in the plan are superseded -- use the
>    `fiveam:run!`-based, both-runtime commands in `CLAUDE.md` /
>    `README.md` (`asdf:test-system` returns `T` even on failure, and the
>    LispWorks binary here is `lw-console`). See the updated Verification
>    section.
>
> Individual stale lines are corrected inline below; this note is the
> summary.

## Context

The user wants `atari800-cl` to speak the two wire protocols that the
[Attic](https://github.com/huegli/attic) project defines in its
`docs/PROTOCOL.md`:

1. **AESP** -- Attic's binary protocol over **three TCP ports**
   (control 47800 bidirectional, video 47801 server-push, audio 47802
   server-push). 8-byte big-endian header (`0xAE50` magic, version 1,
   1-byte type, 4-byte length) + payload up to 16 MB. Carries control
   messages, input events, and (eventually) BGRA frames + PCM audio.

2. **CLI/GUI socket** -- Attic's text protocol over a Unix-domain socket.
   Newline-terminated `CMD:<verb> [args]` -> `OK:<data>` / `ERR:<msg>`;
   multi-line replies use the 0x1E record separator; async `EVENT:<type>`
   messages can arrive unsolicited.

Together they let an external GUI/CLI/web client drive a headless
emulator. We want the same surface on `atari800-cl` so it can plug into
the same ecosystem of front-ends.

### Decisions already taken with the user

| Decision | Choice |
| --- | --- |
| Scope | **Phased MVP** -- only the messages/commands that map to APIs the emulator already has. Video frame payloads, audio PCM payloads, debugger, disk/SIO/BASIC/state/screenshot are explicitly deferred. |
| Interop goal | **Spec-compatible only** (follow `PROTOCOL.md` byte-exactly). No requirement that the real Swift AtticGUI/AtticCLI connect successfully. |
| Existing `atari800-cl.ipc` | ~~Deprecate~~ **Already removed** (commit `57e237f`). No deprecation work remains; the 56-byte snapshot is gone. |
| Socket library | **usocket for TCP only** (AESP). Re-added to `:depends-on` in Stage 0, along with **flexi-streams** for octet encoding. **Unix-domain sockets are NOT done via usocket** -- a Stage-0 spike confirmed usocket 0.8.8 has no local-socket support; the CLI socket uses `sb-bsd-sockets:local-socket` (SBCL) / FLI AF_UNIX + `comm:socket-stream` (LispWorks). See `AESP-CLI-Implementation-Stages.md` Stage 0. |
| Implementation verification | **Every step is verified on both SBCL and LispWorks** before moving to the next. The full FiveAM suite must be green on both implementations at every commit boundary. This is non-negotiable per CLAUDE.md ("Primary target is LispWorks; also supports SBCL"). |

### Preconditions (revised 2026-06-08)

- ~~`usocket` and `flexi-streams` are already in `:depends-on`.~~
  **No longer true** -- `:depends-on` is now just `alexandria` +
  `bordeaux-threads`. This PR re-adds `usocket` and `flexi-streams`.
- `machine-run-frame` (`src/machine.lisp:176`+) is still a single
  `dotimes` over `+clocks-per-frame+`; refactoring into a `%run-clocks`
  helper with an early-exit predicate is mechanical. *(Verified current.)*
- ~~`src/ipc.lisp` demonstrates the lifecycle template ...~~ **File
  deleted.** The template (`unwind-protect`, close-listener-to-unblock-
  accept, timeout-then-destroy-thread) lives in git history before
  commit `57e237f` (`git show 57e237f^:src/ipc.lisp`); copy it from
  there for `aesp.lisp` / `cli-socket.lisp`.
- The `atari-machine` struct (`src/machine.lisp:19`+) is still a plain
  `defstruct`; adding new slots is straightforward. *(Verified current.)*

---

## Final approach

### New packages (4)

All new files slot into `atari800-cl.asd` **after `machine` and before
`main`** (the load chain now ends `... machine main`; there is no longer
an `ipc` file at the bottom). Because `package.lisp` declares every
package up front, `pia`/`gtia`/`pokey` can reference `atari800-cl.input`
symbols even though `input.lisp` loads after them.

| File | Package | Purpose |
| --- | --- | --- |
| `src/input.lisp` | `:atari800-cl.input` | Single mutex-guarded `input-state` struct holding current keyboard, joystick (2 ports), console-keys, paddle (x4) state. Setters called from socket reader threads; getters called from the emulator thread when PIA / GTIA / POKEY read their input registers. |
| `src/transport.lisp` | `:atari800-cl.transport` | TCP listen/accept/close via `usocket`; Unix-domain listen/accept/close delegate to `:atari800-cl.compat` (usocket has no local-socket support -- see Stage-0 spike). All implementation/platform reader conditionals stay in `compat.lisp` per the CLAUDE.md invariant. |
| `src/aesp.lisp` | `:atari800-cl.aesp` | AESP binary codec + 3-port server (control/video/audio). Pure codec is unit-testable without sockets. |
| `src/cli-socket.lisp` | `:atari800-cl.cli-socket` | Line-protocol verb dispatcher on a Unix-domain socket at `/tmp/atari800-cl-<pid>.sock` (mode 0600). Pure parser is unit-testable without sockets. |

### Modified source files

| File | Change |
| --- | --- |
| `src/machine.lisp` | Add slots to `atari-machine`: `running-p`, `mailbox`, `input`, `priority-pending-flag`. Refactor `machine-run-frame` body into `%run-clocks (machine n &key abort-pred)`; `machine-run-frame` becomes a one-liner that calls it with `+clocks-per-frame+`. Add `command-mailbox` + `machine-command` structs, `mailbox-enqueue` / `mailbox-drain` / `mailbox-wait`. Add `machine-run-loop (machine &key stop-flag)` -- driver that switches between calling `machine-run-frame` and `bt:condition-wait` based on `running-p`, and drains the mailbox each frame boundary. Add `attach-input`. Existing tests stay green because `priority-pending-flag` is never set in test code and `machine-run-frame` retains its current signature. |
| `src/pia.lisp` | Add `(input nil)` slot to `pia` struct. In `pia-read`, when `input` is non-NIL and offset = 0, return `(input-pia-porta input)` instead of the static latch. Export `pia-input`, `attach-pia-input`. |
| `src/gtia.lisp` | Add `(input nil)` slot. In `gtia-read`, offsets 16..19 return `(input-gtia-trig input n)` and offset 31 returns `(input-gtia-consol input)` when `input` is non-NIL. Export `gtia-input`, `attach-gtia-input`. |
| `src/pokey.lisp` | Add `(input nil)` slot. In `pokey-read`, offsets 0..7 -> POT, 9 -> KBCODE, 15 -> SKSTAT, all delegate to the input-state when present. Export `pokey-input`, `attach-pokey-input`. |
| `src/compat.lisp` | Add: `current-process-id` (SBCL `sb-posix:getpid`, LispWorks `system::getpid`), `chmod-file path mode` (SBCL `sb-posix:chmod`, LispWorks `system:call-system "/bin/chmod"`), `delete-file-if-exists`, and **mandatory** Unix-domain socket helpers `open-unix-listener` / `accept-unix-client` / `open-unix-client`. **Per the Stage-0 spike, do NOT attempt usocket for these** -- implement directly: SBCL via `sb-bsd-sockets:local-socket`; LispWorks via an FLI wrapper for `socket(AF_UNIX, SOCK_STREAM, 0)` + `bind`/`listen`/`accept`, wrapping the accepted fd with `(make-instance 'comm:socket-stream :socket fd :direction :io :element-type 'base-char)`. `sockaddr_un` layout differs by platform (`#+darwin` has a leading `sun_len` byte; Linux does not), so the LW path needs a `#+darwin`/`#-darwin` split. All `#+sbcl`/`#+lispworks`/`#+darwin` reader conditionals stay confined here. |
| `src/package.lisp` | New `defpackage` forms for the four new packages; extend `:atari800-cl.compat` / `:atari800-cl.machine` / `:atari800-cl.pia` / `:atari800-cl.gtia` / `:atari800-cl.pokey` exports. |
| `src/main.lisp` | Re-export public entry points on the `:atari800-cl` facade: `start-aesp-server`, `stop-aesp-server`, `start-cli-socket`, `stop-cli-socket`, `start-machine`, `stop-machine`. |
| `atari800-cl.asd` | Insert the four new src files between `machine` and `main`; add the matching new test files before `test-regressions`. **Re-add `usocket` and `flexi-streams` to `:depends-on`** (they were removed with IPC). |
| `README.md`, `CHANGES.md` | Document the two new protocol surfaces. (No `ipc.lisp` deprecation note -- it's already gone; CHANGES already records its removal.) |

### Threading model

- **One emulator thread** owns the `atari-machine` struct. While
  `running-p` is true it loops `machine-run-frame`; when false it
  `condition-wait`s on the mailbox condvar.
- **One acceptor thread** per listener (3 AESP + 1 CLI = 4 total).
- **One reader thread** per accepted client. Each reader either answers
  directly (e.g. `PING`, input forwarding to `input-state`) or posts a
  `machine-command` to the shared mailbox with a per-command latch and
  blocks until the emulator thread fills the reply slot.
- **High-priority commands** (`pause`, `resume`, `reset`, `quit`) set
  `priority-pending-flag`; `%run-clocks` checks it every 114 clocks
  (one scanline) and bails out so the mailbox drains within ~63 us.
- **Write fan-out**: each client has its own write-lock so AESP push
  channels (video/audio, currently empty) can safely send from the
  emulator thread without colliding with reader-thread responses.
- **Backpressure**: mailbox soft-cap 1024 entries -> reply `ERR:Server
  busy` / AESP `ERROR 0x04` rather than block the emulator.

Pattern follows the old `src/ipc.lisp` acceptor (acceptor with
`unwind-protect`, close-listener-to-unblock-accept, timeout-then-
destroy-thread) -- now only in git history: `git show 57e237f^:src/ipc.lisp`.

### AESP message coverage (MVP)

| Type | Direction | Behavior |
| --- | --- | --- |
| `PING` 0x00 / `PONG` 0x01 | C->S / S->C | direct |
| `PAUSE` 0x02, `RESUME` 0x03, `RESET` 0x04 | C->S | mailbox high-priority -> ACK 0x0F |
| `STATUS` 0x05 | C->S | direct, 1-byte payload |
| `INFO` 0x06 | C->S | direct, hand-built JSON via `format` + `flexi-streams:string-to-octets` (no cl-json dep) |
| `KEY_DOWN` 0x40, `KEY_UP` 0x41, `JOYSTICK` 0x42, `CONSOLE_KEYS` 0x43, `PADDLE` 0x44 | C->S | direct -> `input-set-*` -> ACK |
| `VIDEO_SUBSCRIBE` 0x63 / `_UNSUBSCRIBE` 0x64 | C->S | mark subscriber; on subscribe immediately reply `FRAME_CONFIG` 0x62 (384, 240, 4, 60). **No FRAME_RAW/DELTA sent in MVP.** |
| `AUDIO_SUBSCRIBE` 0x83 / `_UNSUBSCRIBE` 0x84 | C->S | mark subscriber; reply `AUDIO_CONFIG` 0x81 (44100, 8, 1). **No AUDIO_PCM in MVP.** |
| `MOUNT` 0x08 | C->S | `[unit][read-only][path...]` -> mailbox -> `atari800-cl.hostdev:mount-disk-file` -> ACK, or `ERROR` 0x3F with `+aesp-err-mount-failed+` (0x06) |
| `UNMOUNT` 0x09 | C->S | `[unit]` -> mailbox -> `atari800-cl.hostdev:unmount-disk` -> ACK |
| `LOAD_XEX` 0x0A | C->S | `[unit][read-only][path...]` -> mailbox -> `atari800-cl.hostdev:load-xex` (synthesizes a bootable ATR from an XEX/OBX file in memory) -> ACK, or `ERROR` 0x06 |
| Any other type | C->S | reply `ERROR` 0x3F with `+aesp-err-not-implemented+` (0x05) |
| `BOOT_FILE` 0x07 | -- | **deferred** -- distinct from `MOUNT`/`LOAD_XEX` above: would stream file bytes from the client rather than name a path the server reads itself (ROADMAP.md Phase 16, revised, stage 16e added the path-based pair; `BOOT_FILE` itself is still unimplemented) |

PIA PORTA encoding: AESP `JOYSTICK` gives 5 bits per port; PIA PORTA packs
joystick 0 in the low nibble (direction bits active-low) and joystick 1
in the high nibble; the trigger bit lives on GTIA TRIG0/TRIG1. The
`input-pia-porta` and `input-gtia-trig` getters perform that mapping.

### CLI command coverage (MVP)

`ping`, `version`, `pause`, `resume`, `step [count]`, `reset [cold|warm]`,
`status`, `read $ADDR COUNT`, `write $ADDR HEX,HEX,...`,
`fill $START $END $VALUE`, `registers`, `registers REG=$VAL ...`,
`mount UNIT PATH`, `unmount UNIT`, `loadxex PATH [UNIT]` (defaults to
D1:), `quit`. The last three (ROADMAP.md Phase 16, revised, stage 16e)
drive the same `atari800-cl.hostdev` entry points as the AESP `MOUNT`/
`UNMOUNT`/`LOAD_XEX` messages above -- a bad unit, missing file, or
malformed ATR/XEX signals an ordinary error inside the mailbox thunk,
which the CLI's catch-all turns into `ERR:<message>` (no special-casing
needed, unlike AESP's fixed-payload `ERROR` reply).

Everything else (the entire `basic`/`dos` namespace, `boot`, `screen`,
`disassemble`, `assemble`, `breakpoint *`, `drives`, `state save`/`load`,
`screenshot`, `inject *`, `shutdown`) is dispatched to a single fallback
handler that replies `ERR:Not implemented`. The verb table is a
`defparameter *cli-verbs*` alist so each future verb becomes a one-line
addition.

`step` is capped at 65535 instructions per call (single mailbox round-
trip would otherwise stall the emulator).

### Reused existing utilities

- `src/machine.lisp:121-149` (`machine-trace-step`) -- basis for the
  `step` verb's response builder.
- `src/machine.lisp:151-171` (`machine-portb-state`, `machine-scanline`,
  `machine-pending-interrupts`) -- for the `status` verb and AESP `INFO`.
- `bus-peek-ram` (`src/bus.lisp:110`) / `bus-poke-ram` (`:115`) --
  read/write/fill verbs.
- `cpu-{a,x,y,sp,flags,pc}` accessors -- `registers` verb.
- **(git history)** `git show 57e237f^:src/ipc.lisp` -- lifecycle template
  for both new servers (acceptor `unwind-protect`, listener-close to
  unblock accept, timeout wait + `bt:destroy-thread` fallback,
  socket-file cleanup).
- **(git history)** `git show 57e237f^:tests/test-ipc.lisp` -- fixture
  template for socket tests (per-test temp socket path, `unwind-protect`
  server stop).

---

## Tests

New FiveAM suites under `tests/`, all hung off the existing
`atari800-cl-suite` root in `tests/test-suite.lisp`:

| Suite | File | Coverage |
| --- | --- | --- |
| `input-suite` | `tests/test-input.lisp` | Defaults, every setter/getter, PORTA encoding, concurrent-writers smoke test. |
| `aesp-codec-suite` | `tests/test-aesp.lisp` (child) | `encode-aesp-message` byte-exactness, header round-trip, bad-magic and oversize-length raise `aesp-protocol-error`. |
| `aesp-server-suite` | `tests/test-aesp.lisp` (child) | Boot the server on a free port triple in 47900-47999 (skip on bind failure), connect a usocket client, exercise PING, KEY_DOWN, JOYSTICK, CONSOLE_KEYS, PAUSE/RESUME, STATUS, VIDEO_SUBSCRIBE->FRAME_CONFIG, AUDIO_SUBSCRIBE->AUDIO_CONFIG, unknown type -> ERROR. Assert clean shutdown with active client. New test files are registered in the asd before `test-regressions` (there is no longer a `test-ipc` to anchor on). |
| `cli-parse-suite` | `tests/test-cli-socket.lisp` (child) | `parse-cli-command`, `parse-hex-address`, `parse-hex-byte-list`, `parse-register-assignments`. |
| `cli-server-suite` | `tests/test-cli-socket.lisp` (child) | Boot server on a random `/tmp/atari800-cl-test-*.sock` path; exercise every MVP verb; assert that an unknown verb returns `ERR:unknown command "..."` and a deferred verb returns `ERR:Not implemented`. |
| (additions) | `tests/test-pia.lisp`, `tests/test-gtia.lisp`, `tests/test-pokey.lisp` | One new test each that attaches an `input-state` and verifies the matching register read reflects it. |

Gates and fixtures:
- **AESP suite runs on both SBCL and LispWorks** -- TCP via usocket is
  portable; no implementation gating.
- **CLI suite runs on both SBCL and LispWorks** -- Unix-domain socket
  support is *mandatory* in `compat.lisp` (see Modified source files).
  The suite does not `skip` based on implementation. If usocket can't
  bind locally on the running LispWorks build, the compat FLI fallback
  takes over; if *both* paths fail, the test *fails* (does not skip) so
  the gap surfaces immediately.
- Port-conflict failures `skip` rather than fail (so CI stays green on
  noisy hosts).
- Every fixture uses `unwind-protect` so the server stops even on
  assertion failure (mirroring the old `tests/test-ipc.lisp` --
  `git show 57e237f^:tests/test-ipc.lisp`).

---

## Implementation sequence (recommended)

0. `atari800-cl.asd`: re-add `usocket` + `flexi-streams` to
   `:depends-on` (removed when IPC was deleted; needed from step 1 on).
1. `compat.lisp` additions (`current-process-id`, `chmod-file`,
   `delete-file-if-exists`, Unix-domain socket helpers including the
   LispWorks FLI fallback).
2. `input.lisp` + `package.lisp` + `tests/test-input.lisp`.
3. PIA / GTIA / POKEY `input` slot wiring + their new tests.
4. **High-risk step**: `machine.lisp` mailbox / `%run-clocks` /
   `machine-run-loop`. Commit alone; run full existing suite.
5. `transport.lisp`.
6. `aesp.lisp` codec only + `aesp-codec-suite`.
7. `aesp.lisp` server + `aesp-server-suite`.
8. `cli-socket.lisp` parser only + `cli-parse-suite`.
9. `cli-socket.lisp` server + `cli-server-suite`.
10. README/CHANGES updates. *(No `ipc.lisp` deprecation banner -- the
    file is gone.)*
11. `main.lisp` re-exports; manual smoke test (sec. Verification).

**Each step ends with a green run of the section Verification commands (the
`fiveam:run!`-based form, not bare `asdf:test-system`) on *both* SBCL and
LispWorks before moving on.** If either implementation
fails, fix it before continuing -- don't accumulate cross-impl debt.
A failure on one implementation is treated identically to a failure on
the other; neither is a second-class target.

---

## Verification

### Run the test suite

**Run on both implementations at every step boundary.** A passing run
on one is not sufficient. Use the canonical exit-code-propagating
commands from `CLAUDE.md` / `README.md` -- **not** bare
`asdf:test-system`, which returns `T` even when tests fail.

SBCL:
```sh
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

LispWorks (the console image here is `lw-console`; `-eval` forms are
read before the init file loads Quicklisp, so load `setup.lisp` first
and defer the `ql:` symbol):
```sh
lw-console -eval '(load "~/quicklisp/setup.lisp")' \
           -eval '(funcall (read-from-string "ql:quickload") :atari800-cl/tests)' \
           -eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

Or just the new suites (same form in both implementations):
```lisp
(fiveam:run! 'atari800-cl/tests::input-suite)
(fiveam:run! 'atari800-cl/tests::aesp-suite)
(fiveam:run! 'atari800-cl/tests::cli-socket-suite)
```

### Manual smoke test

```sh
# Terminal 1: start the emulator with both servers.
sbcl --eval '(ql:quickload :atari800-cl)' \
     --eval '(defparameter *m* (a800:make-machine))' \
     --eval '(defparameter *aesp* (a800:start-aesp-server *m*))' \
     --eval '(defparameter *cli*  (a800:start-cli-socket  *m*))'

# Terminal 2: AESP PING via socat (8-byte header, no payload).
printf '\xAE\x50\x01\x00\x00\x00\x00\x00' | \
  socat - TCP:127.0.0.1:47800 | xxd
# Expect: AE 50 01 01 00 00 00 00  (magic, ver=1, PONG=0x01, len=0)

# Terminal 3: CLI ping.
printf 'CMD:ping\n' | \
  socat - "UNIX-CONNECT:/tmp/atari800-cl-$(pgrep -n sbcl).sock"
# Expect: OK:pong
```

---

## Critical files to be modified

- `/Users/nikolai/quicklisp/local-projects/atari800-cl/src/machine.lisp` (struct, `%run-clocks` refactor, mailbox, `machine-run-loop`)
- `/Users/nikolai/quicklisp/local-projects/atari800-cl/src/pia.lisp`,
  `src/gtia.lisp`,
  `src/pokey.lisp` (input slot + register-read delegation -- same pattern in each)
- `/Users/nikolai/quicklisp/local-projects/atari800-cl/src/compat.lisp` (process-id, chmod, file delete, optional Unix-socket helpers)
- `/Users/nikolai/quicklisp/local-projects/atari800-cl/src/package.lisp`
- `/Users/nikolai/quicklisp/local-projects/atari800-cl/src/main.lisp`
- `/Users/nikolai/quicklisp/local-projects/atari800-cl/atari800-cl.asd` (insert 4 new src files + new test files; **re-add `usocket` + `flexi-streams` to `:depends-on`**)
- `/Users/nikolai/quicklisp/local-projects/atari800-cl/README.md`,
  `CHANGES.md`

## Explicitly deferred (NOT in this PR)

Video frame payloads (FRAME_RAW/DELTA), audio PCM payloads, BOOT_FILE,
debugger surfaces (step-over, until, breakpoints, disasm/asm),
disk/SIO/ATR/DOS, BASIC commands, state save/load, screenshot, AKEY_*
table semantics. *(Removal of `ipc.lisp` is no longer deferred -- it has
already been deleted.)*

(*Note: LispWorks Unix-domain socket support is **in scope** for this
PR -- it was previously listed as deferred but is now mandatory per the
both-implementations verification requirement.*)
