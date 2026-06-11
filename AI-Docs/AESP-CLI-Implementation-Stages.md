# AESP + CLI — Multi-Stage Implementation Plan

Companion to [`AESP-CLI-Protocol-Plan.md`](./AESP-CLI-Protocol-Plan.md).
That doc is the *design* (what to build, byte layouts, message coverage);
this doc is the *staging* (in what order, with which gates, isolating the
risk). Authored 2026-06-08 against the post-IPC-removal tree.

## How this is grouped

The design doc's flat 12-step sequence collapses into **7 stages**,
organized around three principles:

1. **Isolate the two risky pieces** — LispWorks Unix-domain sockets, and
   the `machine.lisp` hot-path refactor — so a failure in either doesn't
   contaminate other work.
2. **Keep the existing suite green at *every* commit on *both* runtimes**
   (1254 checks as of this writing; SBCL + LispWorks; non-negotiable per
   `CLAUDE.md`).
3. After the shared foundation, **AESP (TCP) and CLI (Unix-socket) are
   independent tracks** with very different risk profiles — AESP needs
   only portable TCP and can land entirely before the Unix-socket risk is
   retired.

### Grounding notes (verified against current code)

- `machine-run-frame`'s `cpu-budget` is a **per-frame local**
  (`src/machine.lisp:184`). The design doc's "`%run-clocks` checks
  priority every 114 clocks and bails out" implies *mid-frame*
  abort-and-resume, which only works if `cpu-budget` survives across
  calls. That is an unflagged design fork — see **Decision 1**.
- `pia-read` / `gtia-read` / `pokey-read` are clean single-dispatch
  functions (`src/pia.lisp:56`, `src/gtia.lisp:102`, `src/pokey.lisp:219`),
  so input delegation is a trivial guarded wrapper in each — genuinely
  low-risk, as the design doc claims.

## Dependency graph

```
Stage 0 (spikes + deps) ─┬─> Stage 1 (compat + input-state)
                         │        │
                         │        ├─> Stage 2 (chip input delegation)   [pure]
                         │        │
                         │        └─> Stage 3 (machine mailbox/run-loop) [HIGH RISK]
                         │                 │
                         │                 ├─> Stage 4  AESP / TCP track  [low portability risk]
                         │                 │        transport(TCP) → codec → server
                         │                 │
                         └─ Spike A gates ─┴─> Stage 5  CLI / Unix track  [LW socket risk]
                                                  transport(unix) → parser → server
                                                          │
                                                          └─> Stage 6 (facade + docs + smoke)
```

The **long pole is Spike A** (LispWorks Unix-domain sockets). Because
AESP needs only portable TCP, Track A (Stage 4) can land before Track B's
risk is retired.

---

## Stage 0 — De-risk + unblock (~½ day) — ✅ COMPLETE (2026-06-08)

> **Status: done.** Deps re-added (`usocket` 0.8.8 + `flexi-streams`);
> full suite green on both runtimes (1254/1254); both spikes retired.
> The three open decisions are resolved (see below). Key findings:
>
> - **usocket has NO Unix-domain socket support** (0.8.8) — `socket-listen`
>   doesn't even accept `:protocol`. The design doc's "usocket
>   `:protocol :local` first" plan is dead. AESP uses **usocket TCP**
>   (validated round-trip on both runtimes); the CLI socket uses
>   **per-implementation primitives directly**:
>   - SBCL → `sb-bsd-sockets:local-socket` — validated round-trip.
>   - LispWorks → **FLI** `socket(AF_UNIX,SOCK_STREAM,0)`/`bind`/`listen`/
>     `accept` (libc via libSystem), then wrap the fd with
>     `(make-instance 'comm:socket-stream :socket fd :direction :io
>     :element-type 'base-char)` — validated round-trip.
> - **`sockaddr_un` is platform-specific:** Darwin has a leading
>   `sun_len` byte then a 1-byte family; Linux has a 2-byte family and no
>   `sun_len`. The LispWorks FLI helper needs a `#+darwin`/`#-darwin`
>   split (confined to `compat.lisp`; SBCL's `sb-bsd-sockets` handles this
>   internally, so only the LW path cares).
> - **Validated LW FLI reference** (the de-risking artifact, to port into
>   `compat.lisp` in Stage 1):
>
>   ```lisp
>   (fli:define-foreign-function (%socket "socket")
>       ((domain :int) (type :int) (protocol :int)) :result-type :int)
>   (fli:define-foreign-function (%bind "bind")
>       ((fd :int) (addr (:pointer (:unsigned :byte))) (len :int)) :result-type :int)
>   (fli:define-foreign-function (%listen "listen")
>       ((fd :int) (backlog :int)) :result-type :int)
>   (fli:define-foreign-function (%accept "accept")
>       ((fd :int) (addr (:pointer :void)) (len (:pointer :int))) :result-type :int)
>   ;; Darwin sockaddr_un: [sun_len][sun_family=1][path...]; addrlen = 2 + strlen(path)
>   ;; wrap accepted fd: (make-instance 'comm:socket-stream :socket fd
>   ;;                                  :direction :io :element-type 'base-char)
>   ```

**Goal:** retire the two unknowns and re-enable dependencies before any
product code.

- **Spike A — LispWorks Unix-domain socket (THE long pole).** In a
  throwaway scratch file, try `usocket` with `:protocol :local` on both
  SBCL and `lw-console`. If LispWorks' usocket build can't bind locally,
  prototype the fallback: `sb-bsd-sockets:local-socket` on SBCL, an FLI
  `socket(AF_UNIX,…)/bind/listen/accept` wrapper on LispWorks.
  **Deliverable: a decision + the working `open-unix-listener` /
  `accept-unix-client` / `open-unix-client` signatures** that Stage 1
  implements for real. If the FLI path is deep, discover it here — before
  anything depends on it.
- **Spike B — abort granularity** (see Decision 1). Recommended:
  **frame-granularity for MVP** (no `cpu-budget` slot; ~16.7 ms
  worst-case command latency, fine for pause/resume/reset).
- **Re-add deps:** `usocket`, `flexi-streams` to
  `atari800-cl.asd :depends-on` (trivial; unblocks Stages 4–5).

**Gate:** deps `ql:quickload` clean on both runtimes; suite still green on
both; spike findings written down. No risky product code committed yet.

## Stage 1 — Foundation: compat + input-state (~1 day) — ✅ COMPLETE (2026-06-08)

> **Status: done.** `compat.lisp` gained `current-process-id`,
> `delete-file-if-exists`, `chmod-file`, and the Unix-socket helpers
> (`open-unix-listener` / `accept-unix-client` / `open-unix-client` /
> `close-unix-listener`, with the `unix-listener` struct) — the Stage-0
> FLI spike ported into product code. `src/input.lisp` (`:atari800-cl.input`)
> adds the mutex-guarded `input-state` with all setters/getters; loaded
> early (after `compat`). New `input-suite` + compat tests (incl. a real
> Unix-socket round-trip). Suite **1289/1289 green on both runtimes**
> (was 1254; +35).

**Goal:** portability primitives + the shared input model.

- `src/compat.lisp`: `current-process-id`, `chmod-file`,
  `delete-file-if-exists`, and the Unix-socket helpers **as decided in
  Spike A** (all `#+sbcl`/`#+lispworks` confined here per the CLAUDE.md
  invariant).
- `src/input.lisp` (`:atari800-cl.input`): mutex-guarded `input-state`
  struct; setters (`input-set-key`, `-joystick`, `-console`, `-paddle`)
  and getters (`input-pia-porta`, `input-gtia-trig`, `input-gtia-consol`,
  `input-pokey-pot`, `-kbcode`, `-skstat`).
- `src/package.lisp`: new `:atari800-cl.input` package + compat exports.
- `tests/test-input.lisp` → `input-suite`: defaults, every setter/getter,
  PORTA bit-packing, concurrent-writers smoke.

> **Refinement (Decision 2):** load `input.lisp` **early** (right after
> `compat`), not "after machine." It has zero emulator dependencies, and
> loading it before `pia/gtia/pokey` removes the design doc's subtle
> reliance on package pre-declaration for forward references.

**Gate:** `input-suite` green on both; full suite green on both.

## Stage 2 — Chip input delegation (~½ day, pure) — ✅ COMPLETE (2026-06-10)

> **Status: done.** PIA/GTIA/POKEY each got an `(input nil)` slot,
> `attach-*-input`, and guarded read delegation: `pia-read` offset 0 →
> `input-pia-porta`; `gtia-read` offsets 16-19/31 → `input-gtia-trig`/
> `-consol` (`+r-trig0+`/`+r-consol+` confirmed at #x10/#x1F); `pokey-read`
> offsets 0-3/9/15 → `input-pokey-pot`/`-kbcode`/`-skstat`. Input getters
> referenced qualified (`atari800-cl.input:`); new `*-input` accessors +
> `attach-*-input` exported. One delegation test per chip suite. Suite
> **1304/1304 green on both runtimes** (was 1289; +15).

**Goal:** PIA/GTIA/POKEY reads reflect injected input.

- Add `(input nil)` slot + `attach-*-input` + exports to `pia.lisp`,
  `gtia.lisp`, `pokey.lisp`.
- Guarded delegation in each read: `pia-read` offset 0; `gtia-read`
  offsets 16–19 (TRIG0–3) and 31 (CONSOL) — *confirm the
  `+r-trig0+`/`+r-consol+` constants*; `pokey-read` offsets 0–7 (POT),
  9 (KBCODE), 15 (SKSTAT).
- One new test each in `test-pia/gtia/pokey.lisp`.

**Gate:** new register tests green; full suite green on both.
**Independent of all socket work** — can run in parallel with Stage 3.

## Stage 3 — Machine concurrency core (~1–2 days, HIGH RISK, commit alone) — ✅ COMPLETE (2026-06-10)

> **Status: done.** `atari-machine` gained `running-p`, `mailbox`, `input`,
> `priority-pending-flag`. `machine-run-frame` was split into `%run-clocks
> (machine n &key abort-pred)` (frame-granular abort hook, unused by the
> default loop per Decision 1) + a one-line `machine-run-frame` — the
> refactor is correctness-neutral, the prior 1304 checks did not move.
> Added the `command-mailbox` + `machine-command` structs, the
> `mailbox-full` condition, `mailbox-enqueue/-drain/-wait`, `machine-submit`
> (post-and-block, re-signals thunk errors, soft-cap → `mailbox-full`),
> `machine-run-loop` (drain → run-frame-or-park), and `attach-input` (wires
> PIA/GTIA/POKEY). Condition-variable wrappers added to `compat`. New
> machine-suite tests incl. threaded run-loop submit / pause-resume /
> error-propagation, **green and stable on both runtimes (1320/1320; +16,
> 3× repeat clean)**.

**Goal:** the mailbox + run-loop the servers post commands to. The one
stage that touches the emulator hot path and the existing tests.

- `atari-machine` slots: `running-p`, `mailbox`, `input`,
  `priority-pending-flag` (+ `cpu-budget` only if Decision 1 =
  scanline-granularity).
- Refactor `machine-run-frame` body → `%run-clocks (machine n &key
  abort-pred)`; `machine-run-frame` becomes a one-line call with
  `+clocks-per-frame+`. **Existing signature and behavior preserved** so
  the current checks don't move.
- `command-mailbox` + `machine-command` structs; `mailbox-enqueue` /
  `-drain` / `-wait` (soft-cap 1024 → busy); `machine-run-loop (machine
  &key stop-flag)`; `attach-input`.

**Gate (the critical one):** full existing suite **must stay green** on
both runtimes — the refactor is correctness-neutral. Commit in isolation
so any regression bisects to exactly this change.

## Stage 4 — AESP / TCP track (~2–3 days, low portability risk) — ✅ COMPLETE (2026-06-10)

> **Status: done.** **4a** `transport.lisp` — binary TCP via usocket
> (+ Unix delegates to compat for Stage 5). **4b** `aesp.lisp` codec —
> 8-byte big-endian header, type/error constants (eval-when-wrapped),
> encode/decode/read/write, `aesp-protocol-error`; `aesp-codec-suite`
> byte-exact. **4c** `aesp.lisp` server — 3 TCP listeners (control/video/
> audio), per-client acceptor+reader threads, control dispatch (PING→PONG;
> PAUSE/RESUME/RESET via mailbox→ACK; STATUS/INFO direct; input events →
> input-state→ACK; VIDEO/AUDIO_SUBSCRIBE→CONFIG; unknown→ERROR), clean
> shutdown (close-listener/close-clients/join-or-destroy, mirroring the
> historical ipc template). `aesp-server-suite` boots on **ephemeral
> ports (0)** — no port-conflict skip — and round-trips every control
> message over a real loopback usocket client. compat gained
> `thread-alive-p`/`destroy-thread`. Suite **1359/1359 green on both
> runtimes** (was 1331; +28); LispWorks 3× clean.

Three sub-commits, each green on both:

- **4a `transport.lisp`** — `usocket` TCP listen/accept/close wrappers
  (+ Unix wrappers delegating to Stage-1 compat).
- **4b `aesp.lisp` codec** + `aesp-codec-suite` — pure, **byte-exact**
  encode/decode of the 8-byte big-endian header (`0xAE50`, ver 1, type,
  len); bad-magic / oversize → `aesp-protocol-error`. These byte-exact
  tests are the safety net for spec compatibility.
- **4c `aesp.lisp` server** + `aesp-server-suite` — 3-port server; boot
  on a free triple in 47900–47999 (skip on bind conflict); exercise PING,
  input events, PAUSE/RESUME/RESET (→ mailbox), STATUS, INFO,
  VIDEO/AUDIO_SUBSCRIBE → CONFIG, unknown → ERROR; assert clean shutdown
  with an active client.

**Gate:** codec + server suites green on both; full suite green. Delivers
a working AESP surface **without depending on the Unix-socket risk.**

## Stage 5 — CLI / Unix-socket track (~2 days, gated on Spike A) — ✅ COMPLETE (2026-06-10)

> **Status: done.** **5a** `cli-socket.lisp` parser — `parse-cli-command`
> (strips `CMD:`, tokenizes), `parse-hex-address` ($/0x/bare),
> `parse-hex-byte-list`, `parse-register-assignments`, `cli-parse-error`;
> `cli-parse-suite`. **5b** server — Unix-domain listener via the compat
> helpers (socket file chmod 0600), acceptor + per-client reader; line
> protocol `CMD:<verb>` → `OK:`/`ERR:`. Verbs: ping, version, pause,
> resume, reset, status, step [n], read $ADDR N, write $ADDR HEX,…,
> fill $S $E $V, registers [REG=$V…], quit; `*cli-verbs*` alist + a
> deferred-verb list (→ `ERR:Not implemented`), unknown → `ERR:unknown
> command`. State-mutating verbs run through the mailbox. `cli-server-suite`
> exercises every verb over a real Unix socket on a unique per-test path.
> Suite **1398/1398 green on both runtimes** (was 1375; +23); LispWorks
> 5× clean. (Replaced a non-portable `#\Rs` literal with `(code-char #x1E)`.)
>
> Note on flakes: the intermittent LispWorks failures seen here were
> later root-caused in Stage 6 — a multiprocessing-init race in the batch
> `-eval` test command, not contention or a logic bug. See the Stage 6
> flake note; fixed by wrapping the run in `mp:initialize-multiprocessing`.

Two sub-commits:

- **5a `cli-socket.lisp` parser** + `cli-parse-suite` — pure:
  `parse-cli-command`, `parse-hex-address`, `parse-hex-byte-list`,
  `parse-register-assignments`; the `*cli-verbs*` alist
  (one-line-per-future-verb).
- **5b `cli-socket.lisp` server** + `cli-server-suite` — Unix socket at
  `/tmp/atari800-cl-<pid>.sock` (mode 0600); every MVP verb; unknown →
  `ERR:unknown command`, deferred → `ERR:Not implemented`. `step` capped
  at 65535.

**Gate:** both suites green on both runtimes. Per the design doc, the CLI
suite **fails (not skips)** if neither usocket-local nor the compat FLI
fallback works on the running impl — so any LispWorks socket gap surfaces
loudly here (but should already be retired by Spike A).

## Stage 6 — Facade + docs + smoke (~½ day) — ✅ COMPLETE (2026-06-10)

> **Status: done.** `machine.lisp` gained `start-machine`/`stop-machine`
> (a background `machine-run-loop` thread behind a `machine-runner`
> handle). The `a800` façade re-exports `start-machine`/`stop-machine`,
> `start-aesp-server`/`stop-aesp-server`, `start-cli-socket`/
> `stop-cli-socket`. README documents both protocol surfaces (new
> "Protocol servers" section, deps table, layout, status); CHANGES
> summarizes the effort. **End-to-end façade smoke passes on both
> runtimes** — start machine + both servers, drive an AESP PING→PONG and
> CLI ping/resume/status over real sockets, machine free-runs frames.
> (socat isn't installed here; the in-process smoke uses real loopback
> TCP + Unix sockets across threads — equivalent.) Final suite
> **1398/1398, green on both** SBCL 2.6.5 and LispWorks 8.1.1.
>
> **Flake — ROOT-CAUSED and fixed (was misdiagnosed as environmental).**
> The intermittent LispWorks failures seen across Stages 4–6 were a
> single deterministic cause: **LispWorks initializes multiprocessing
> asynchronously at startup, and batch `-eval` forms can create threads
> before it's ready** → *"Cannot create processes before multiprocessing
> is initialized"*, failing every threaded test at once. The REPL/here-doc
> runs always had MP up (hence always green); only `-eval` runs raced,
> which looked load-correlated. The library code is correct (MP is always
> up in a real app). Fix: the documented LispWorks batch command now wraps
> the run in `mp:initialize-multiprocessing` — deterministic 1398/1398
> across repeated runs. CLAUDE.md / README updated.

- `src/main.lisp` re-exports: `start-aesp-server`/`stop-…`,
  `start-cli-socket`/`stop-…`, `start-machine`/`stop-machine` on `a800`.
- `README.md` + `CHANGES.md`: document both surfaces.
- Manual smoke test (the socat PING / `CMD:ping` recipes from the design
  doc's Verification section).

**Gate:** final full suite green on both; manual smoke passes.

---

## Risk register

| Risk | Stage | Mitigation |
| --- | --- | --- |
| LispWorks Unix-domain sockets (FLI) | 0 / 1 / 5 | **Spike A first**; AESP track is independent so this never blocks Stage 4 |
| Hot-path refactor regresses CPU timing | 3 | Preserve `machine-run-frame` signature/behavior; isolated commit; no-regression gate on existing checks |
| Threading races (mailbox / condvar / write fan-out) | 3 / 4c / 5b | Per-client write-lock; mailbox latch per command; `unwind-protect` lifecycle from the historical ipc template (`git show 57e237f^:src/ipc.lisp`) |
| AESP byte-layout drift from spec | 4b | Byte-exact codec suite before any server work |
| Port / socket conflicts flake CI | 4c / 5b | Port-conflict → `skip`; per-test temp socket paths |

## Decisions (RESOLVED 2026-06-08)

1. **Abort granularity → frame-granularity for MVP.** No `cpu-budget`
   slot; `%run-clocks`' `abort-pred` is checked at frame boundaries.
   Worst-case command latency ≈ one frame (~16.7 ms), fine for
   pause/resume/reset. Scanline-granularity (~63 µs) is a later refinement
   if needed.
2. **`input.lisp` load position → early** (right after `compat`, before
   `pia`). Avoids the forward-reference subtlety.
3. **Octet encoding → `flexi-streams`** (re-added in Stage 0;
   `flexi-streams:string-to-octets` for the AESP `INFO` payload).

### Spike A resolution (the long pole)

usocket does **not** provide Unix-domain sockets — CLI transport uses
`sb-bsd-sockets:local-socket` (SBCL) and an FLI AF_UNIX wrapper +
`comm:socket-stream` (LispWorks), both validated end-to-end. AESP uses
usocket TCP, validated on both runtimes. See the Stage 0 status callout
for the FLI reference and the Darwin/Linux `sockaddr_un` caveat.

## Per-commit verification (every stage)

Use the `fiveam:run!`-based, exit-code-propagating commands from
`CLAUDE.md` / `README.md` on **both** runtimes — not bare
`asdf:test-system` (returns `T` even on failure):

```sh
# SBCL
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'

# LispWorks
lw-console -eval '(load "~/quicklisp/setup.lisp")' \
           -eval '(funcall (read-from-string "ql:quickload") :atari800-cl/tests)' \
           -eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```
