# Miscellaneous Improvements Plan

> **Status (2026-08-02): items 1, 2, 3, 6, 7, 8 done** (items 1-3, 8 via
> ROADMAP.md Phase 1; items 6-7 via ROADMAP.md Phase 6c — PAL register
> now reads the $0F NTSC pattern, read-side defaults deduped into
> %INIT-READ-REGS). Items 4-5, 9-11 remain open; see ROADMAP.md for
> where each is scheduled (item 4 -> Phase 12, item 5 -> Phase 8).

Everything from the project review that belongs to neither
SCANLINE_ACCURACY_PLAN.md nor PERFORMANCE_PLAN.md. Items are independent
unless a dependency is stated; each is its own commit. Ordered roughly by
value-for-effort.

## Ground rules

- Read `CLAUDE.md` first. No reader conditionals outside `src/compat.lisp`
  (item 8 is compat-internal and therefore allowed); `defstruct` over
  `defclass`; docstrings on exported symbols; `.asd` is `:serial t`.
- After every item run BOTH `./scripts/test-sbcl.sh` and
  `./scripts/test-lispworks.sh`; green before committing.

---

## 1. Opcode-table reload robustness

Problem: `*opcode-table-builder*` (`src/cpu-opcodes.lisp:252`) is a
`defparameter`. Re-loading `cpu-opcodes.lisp` alone in a live image creates
a FRESH builder array, installs it as `*opcode-table*`, and silently drops
the 105 illegal opcodes until `illegal.lisp` is also reloaded.

Fix: eliminate the builder indirection.
1. In `src/cpu.lisp`, change `*opcode-table*` to
   `(defvar *opcode-table* (make-array 256 :initial-element nil) ...)` —
   a `simple-vector` that exists from load time; same for
   `*opcode-mnemonic-table*` (move it to cpu.lisp as a `defvar`, since
   `machine.lisp` reads it and it must survive partial reloads too).
2. `DEFOPCODE` writes `(setf (svref *opcode-table* opcode) ...)` directly.
3. Delete `*opcode-table-builder*` and the final
   `(setf *opcode-table* *opcode-table-builder*)` from `cpu-opcodes.lisp`;
   update the comments that describe the builder dance, and the `defvar`
   beginner-note in `cpu.lisp` that explains why DEFVAR matters here.
4. `step-cpu`'s `(and *opcode-table* (svref ...))` guard can simplify to a
   plain `svref` since the table now always exists.
5. Tests: add to `tests/test-cpu-opcodes.lisp` — all 256 slots of
   `*opcode-table*` are non-NIL after load, and
   `(length (documented-opcodes))` = 151, `(length (illegal-opcodes))`
   = 105 (the introspection functions already exist).

## 2. Reset flag consistency (#x24 vs #x34)

`reset-cpu` (`src/cpu.lisp`) sets P to `#x24` (U+I) while
`machine-cold-reset` (`src/machine.lisp`) sets `#x34` (U+I+B). B is not a
real register bit — `status-byte-from-pull` forces it off — so the two
paths disagree about a phantom bit.

1. Change `machine-cold-reset` to `#x24` and align its docstring/comment.
2. Grep `#x34` in `tests/` first; update any assertion with a comment
   explaining that B exists only on pushed stack copies.
3. Add one test: after `machine-cold-reset`, `(cpu-flags cpu)` = `#x24`
   and equals the flags after bare `reset-cpu` on a synthetic vector.

## 3. Klaus Dormann functional test — stop skipping it

The suite's strongest CPU check currently skips (no binary in `roms/`).
1. Add `scripts/fetch-test-roms.sh`: download the prebuilt
   `6502_functional_test.bin` from the Klaus2m5/6502_65C02_functional_tests
   GitHub repository (`bin_files/6502_functional_test.bin` on the default
   branch is built with the config the test expects: org=0000,
   load_data_direct=1, 64 KiB image) into `roms/`, with checksum echo and
   a note about the project's license. `roms/` is gitignored, so this is
   per-machine setup, not a commit of the binary.
2. Verify the test passes on both implementations (it is slow —
   `max-instructions` is 200M; note expected runtime in the script).
3. Document the script in `CLAUDE.md`'s test section.

## 4. Tom Harte ProcessorTests harness (CPU accuracy ratchet)

The single best accuracy investment outside scanline work: per-opcode JSON
test vectors (~10k cases/opcode) with full before/after CPU+memory state.

1. Data acquisition: the `SingleStepTests/65x02` repository, `6502/v1/`
   directory (one JSON file per opcode, NMOS 6502 WITH decimal mode and
   illegal opcodes — exactly this project's target). The repo is large;
   do NOT vendor it. Convention: env var `ATARI800_CL_HARTE_TESTS` pointing
   at a local checkout's `6502/v1/` directory; tests skip gracefully when
   unset (mirror the Klaus skip pattern in `tests/test-cpu.lisp`).
2. JSON parsing: add a test-system-only dependency (edit
   `atari800-cl/tests` `:depends-on` in `atari800-cl.asd`; the runtime
   system stays dependency-light). Recommend `shasht` (portable, fast,
   maintained); `com.inuoe.jzon` is an acceptable alternative.
3. New file `tests/test-harte.lisp` (insert into the .asd after
   `test-cpu.lisp`), suite `harte-suite :in atari800-cl-suite`:
   - Harness: for each case — build `make-cpu` + `make-memory`,
     `attach-memory-bus`, load `initial` state (pc/s/a/x/y/p + ram pairs),
     `step-cpu` once, compare against `final` (registers + every ram pair)
     and compare the consumed cycle count against `(length cycles)`.
   - KIL opcodes: expect the `illegal-opcode` condition instead of normal
     completion; skip the state comparison (hardware jams).
   - Unstable opcodes ($8B XAA, $AB LAX-imm, the SHA/SHX/SHY/TAS family):
     the suite encodes one chosen "magic" behaviour that may not match this
     emulator's documented choice (see `src/illegal.lisp` header). Run
     them, but maintain an explicit skip-list constant with a comment per
     entry justifying the divergence. Start with the list empty and add
     only what actually fails for documented-unstable reasons.
   - Default depth: first 500 cases per opcode for suite speed; env var
     `ATARI800_CL_HARTE_FULL=1` runs all 10,000.
4. Triage workflow (write into the file header): a failure here is
   presumed a REAL emulator bug. Fix in `src/`, add a focused regression
   test in `tests/test-regressions.lisp` naming the opcode and case id,
   and only then consider the skip-list. Expected first finds: decimal-mode
   flag edges in ADC/SBC and page-cross cycle counts.
5. Document in `CLAUDE.md` (test section): how to fetch the data and run.

## 5. POKEY timer fidelity (period offsets + linked 16-bit channels)

Two known divergences from hardware (verify exact rules against the
Altirra Hardware Reference before coding; stated from memory):
- Reload offsets: a channel clocked at 1.79 MHz reloads with period
  AUDF+4 cycles (not AUDF+1); 16-bit linked pairs at 1.79 MHz use +7;
  the 64/15 kHz clocks keep +1 (in units of the divided clock).
- Linked channels: AUDCTL bit 4 joins channels 1+2 (2 is the high byte,
  clocked by 1's underflow), bit 3 joins 3+4. IRQs for a joined pair come
  from the HIGH channel's IRQEN bit (timer 2 / timer 4).

Steps:
1. Confirm the offset/link rules; record them in the `pokey.lisp` header.
2. Implement in `%channel-divisor` / underflow-reload path; linked mode
   makes channel 2's (resp. 4's) tick source "channel 1 (3) underflow"
   instead of a divisor — restructure `pokey-tick`'s per-channel loop
   accordingly.
3. EXISTING TESTS WILL CHANGE MEANING: `pokey-timer1-fires-irq-after-
   audf1+1-ticks` asserts N+1 at 1.79 MHz; with the confirmed rule it
   becomes N+4. Update the test name, docstring, and constants citing the
   reference. This is the main reason this item is staged alone.
4. New tests: 16-bit pair period = (256*AUDF2 + AUDF1 + 7) at 1.79 MHz
   (formula per the confirmed reference), IRQ raised via timer-2 bit;
   unlinked behaviour unchanged when bits 3/4 are clear.
5. If PERFORMANCE_PLAN Phase 3 (batched advance) already landed, update
   its equivalence test script to cover linked mode.

## 6. GTIA PAL register encoding — verify and fix

`gtia.lisp` returns 1 from the PAL register (offset 20) for "NTSC". Verify
against atari800's `gtia.c` / Altirra docs: the convention is a bit
PATTERN (commonly `$0F`-style "bits 1-3 set" for NTSC, low bits clear for
PAL), and OS revisions probe it for region timing. If the current value is
wrong, fix `%make-gtia-read-regs` + `reset-gtia` defaults and add a test
asserting the documented NTSC value with a comment citing the source.

## 7. GTIA reset/init deduplication

The read-side defaults (TRIG=1 x4, PAL, CONSOL=7) are spelled twice:
`%make-gtia-read-regs` and `reset-gtia` (`src/gtia.lisp`). Make
`reset-gtia` fill from one shared helper — e.g. `%init-read-regs (array)`
called by both — so item 6's value change has exactly one home. Tests:
existing `test-gtia.lisp` covers both paths; suite green is sufficient.

## 8. LispWorks `chmod-file` via FLI

`src/compat.lisp` `chmod-file` shells out to `/bin/chmod` on LispWorks
while `%getpid` two screens up already demonstrates the FLI pattern.
1. Add `(fli:define-foreign-function (%chmod "chmod") ((path (:reference-
   pass :ef-mb-string)) (mode :int)) :result-type :int)` (consult the
   existing `%c-socket` definitions for house style), call it from the
   `#+lispworks` branch, signal an error on non-zero return.
2. Test: `tests/test-compat.lisp` — create a temp file, chmod #o600,
   verify via `(logand (sb-posix:stat-mode ...))` on SBCL… SBCL already
   works; the LispWorks assertion can simply round-trip: chmod then check
   the file is still readable/writable by owner and the function returned
   the namestring. Keep it simple; the real check is "no shell-out".

## 9. Documentation drift sweep

1. `CLAUDE.md` "Development Plan" section still says "Prompt 12's optional
   Unix-socket IPC layer was later removed" — but `transport.lisp`,
   `aesp.lisp`, `cli-socket.lisp` are present (Stages 4c-6 re-added them).
   Rewrite the sentence to describe the current server stack and point at
   `CHANGES.md` for the history.
2. `README.md` "Known limitations": re-verify each bullet against the code
   after the recent fixes (POKEY IRQ de-assert, interrupt budget
   accounting) and as the scanline plan lands (WSYNC/DMA bullets must
   move from "not modelled" to "modelled" when they do).
3. `CHANGES.md`: add entries for the recent fix/idiom commits if the file's
   convention is release-notes-style (read it first and follow its format).
4. Grep docs for the renamed symbols (`flag-set?`, `run-cpu` with memory
   arg, `+color-clocks-per-scanline+` once the scanline plan renames it)
   and update examples.

## 10. ANTIC display-list latch semantics — document the simplification

Real ANTIC reloads its DL program counter from DLISTL/H only at JVB (the
shadow registers are just a latch); this emulator re-latches every VBI and
resets the DL offset on any DLISTL/H write mid-frame. Behaviourally close
for OS-standard lists (which always end in JVB) but not hardware-exact.
Near-term: add an honest comment block in `antic.lisp` at the VBI re-latch
and the DLISTL/H write cases describing the divergence. Actually changing
the behaviour belongs with SCANLINE_ACCURACY_PLAN Phase 4+ — note the
cross-reference in the comment.

## 11. Per-opcode cycle-count baseline test (skip if item 4 lands)

If the Harte harness (item 4) is adopted, cycle counts are covered there —
skip this. Otherwise: add `tests/test-cycle-counts.lisp` with a table of
(opcode, addressing-mode-setup, expected-base-cycles, page-cross-extra)
derived from the masswerk 6502 reference, executed via `make-cpu` +
`make-memory` fixtures. Cover at least: all page-cross-sensitive loads
(LDA/LDX/LDY abs,X/Y and (zp),Y), all branches (not-taken / taken /
taken+cross), RMW on abs,X, and JSR/RTS/BRK/RTI.

## Suggested order

1 → 2 → 9 (cheap, immediate) → 3 → 4 (the big ratchet) → 5 → 6+7 → 8 →
10 → 11(only if 4 skipped). Items 5 and 4 interact: land 4 first so POKEY
changes are made under a stronger CPU-correctness net (not that Harte
covers POKEY, but it pins the CPU while you touch IRQ delivery).
