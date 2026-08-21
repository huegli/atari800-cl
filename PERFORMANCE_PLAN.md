# Performance & Benchmarking Plan

> **Status (2026-08-20): complete and merged to main.**
> Phase 0 (harness), Phase 1 (declarations), and Phase 3 (POKEY
> batching) shipped; Phase 2 (page-dispatch table) was implemented,
> measured, and rejected per its own <5% bar (LispWorks regressed).
> Phase 4 (profiling pass, ROADMAP.md Phase 18) is now done too: LispWorks
> was profiled first as instructed, and the gap it was meant to
> investigate -- LispWorks at roughly a quarter of SBCL's speed (`nop`
> ~950 vs ~3550 fps at the time this status was first written) -- is now
> understood rather than chased. The profile pinned the largest single
> cost (`POKEY-ADVANCE`'s array-slot accesses) to LispWorks 8.1.1's ARM64
> backend routing every checked array access through a generic dispatch
> call at `(safety 1)`, only inlining at `(safety 0)` -- which this
> plan's own safety floor forbids trading away; SBCL's ARM64 backend
> inlines the identical bounds-checked access at `(safety 1)`. A
> source-level follow-up (explicit array-element-type declarations on
> the hot POKEY locals) was implemented, benchmarked as flat noise, and
> confirmed by disassembly to change nothing, so it was reverted rather
> than committed. See `PERFORMANCE_LOG.md` ("ROADMAP Phase 18 --
> LispWorks profiling pass") for the full profile tables and disassembly
> evidence, and `ROADMAP.md` Phase 18 for the closing summary. Measured
> results live in `PERFORMANCE_LOG.md`, which also now carries
> non-optimization entries where a feature touched the hot path (POKEY
> serial output, the Phase 12 CPU fixes).

Goal: make the emulator measurably faster without sacrificing the project's
first two priorities (idiomatic portable CL; emulation accuracy). Every
optimization here must be justified by a benchmark delta and must keep the
suite green on BOTH implementations.

## Ground rules

- Read `CLAUDE.md` first. No reader conditionals outside `src/compat.lisp`;
  implementation-specific profiler/timing access goes through compat.
- MEASURE FIRST. Phase 0 (benchmark harness) must land before any
  optimization commit. Every optimization commit's message records the
  before/after numbers from both implementations.
- Safety floor: compiled code keeps `(safety 1)` minimum. Do not use
  `(safety 0)` anywhere -- this is a learning codebase and bounds checks
  stay on.
- Do not change modelled behaviour. If an optimization needs a semantic
  change, it belongs in SCANLINE_ACCURACY_PLAN.md instead.
- Ordering note: the single biggest win -- the scanline-granular scheduler --
  lives in SCANLINE_ACCURACY_PLAN.md Phase 1 (it is an accuracy enabler
  first). Run this plan's Phase 0 BEFORE that work so its speedup gets
  measured, then return here.

## Current known hot spots (from code reading, to be confirmed by profile)

- `%RUN-CLOCKS` (`src/machine.lisp`): 29,868 `antic-tick` + `pokey-tick`
  calls/frame; `antic-tick` re-caches its cpu/bus slots on every call and
  does real work only 1 call in 114. (Fixed by the scanline scheduler.)
- `BUS-READ` (`src/bus.lisp`): every CPU memory access walks up to five
  range tests, each consulting MMU predicates through `(or null ...)`
  slots, behind a `funcall` through the CPU's bus closure.
- `POKEY-TICK` (`src/pokey.lisp`): loops 4 channels and steps two LFSRs
  every cycle even when nothing can underflow for thousands of cycles.
- No `optimize` declarations anywhere: SBCL compiles at default policy, so
  the existing careful `type` declarations are underused.

---

## Phase 0 -- Benchmark harness (do this first)

1. Create `scripts/bench.lisp`: portable CL, loaded by both runner scripts.
   It must work WITHOUT real ROM images (roms/ is gitignored): build the
   machine via the same synthetic-ROM approach as
   `tests/test-helpers.lisp::%make-synthetic-os-rom` -- but note the test
   helpers live in the test system; either load `:atari800-cl/tests` and
   reuse them, or inline a minimal synthetic-ROM builder in the script
   (reset vector -> $C000, body all $EA NOPs). A NOP-sled is a reasonable
   baseline workload; optionally add a second workload with a busy loop +
   POKEY timer IRQs to exercise the interrupt path
   (`CLI` + IRQEN/STIMER setup, handler = `RTI`).
   Procedure: build machine, cold reset, run 60 warm-up frames, then time
   600 frames with `get-internal-real-time`, and print one machine-readable
   line per workload:
   `BENCH <workload> frames=600 seconds=<s> fps=<fps> realtime-x=<fps/59.92>`
2. Create `scripts/bench-sbcl.sh` and `scripts/bench-lispworks.sh` by
   copying the structure of `scripts/test-sbcl.sh` / `test-lispworks.sh`
   (they already solve the sandbox/ASDF/source-registry/mp:initialize
   problems -- reuse, don't reinvent). Exit 0 on completion.
3. Create `PERFORMANCE_LOG.md` with a table: date, commit, implementation,
   workload, fps, realtime-x, notes. Record the current baseline as the
   first rows.
4. Add a short "Benchmarking" section to `CLAUDE.md` pointing at the
   scripts and the log, with the rule "every optimization commit updates
   the log".

Tests: scripts run clean on both implementations; suite untouched.
Commit: "Add frame-rate benchmark harness and performance log".

---

## Phase 1 -- Optimization declarations + cheap slot/type fixes

1. Add `(declaim (optimize (speed 3) (safety 1) (debug 1)))` at the top of
   the hot files: `src/cpu.lisp`, `src/cpu-opcodes.lisp`, `src/illegal.lisp`,
   `src/bus.lisp`, `src/antic.lisp`, `src/pokey.lisp`, `src/machine.lisp`.
   Caveat to handle explicitly: `declaim` PROCLAIMS -- with `:serial t` it
   also affects every file compiled after it in the same session. That is
   acceptable here (the whole core wants this policy), but add a comment at
   the first declaim noting it, and put the same declaim in each hot file
   anyway so the policy survives recompiling a single file interactively.
2. Compile on SBCL and read the compiler notes (`./scripts/test-sbcl.sh`
   surfaces them during the build). Fix the cheap ones: missing `fixnum`
   declarations on loop counters, `(or null function)` funcall sites that
   benefit from a local `(the function ...)` binding AFTER an explicit null
   check. Do NOT chase every note -- stop where a fix would obscure the code.
3. Change the `cpu` struct slot `cycles` type from `(unsigned-byte 64)` to
   `fixnum` (`src/cpu.lisp`). Rationale: `(unsigned-byte 64)` raw slots are
   SBCL-specific goodness but may box on LispWorks; `fixnum` is fast on
   both and 62 bits of cycles is millennia of emulated time. Grep for
   declarations referencing the old type. Also audit `antic` slot
   `dl-offset (unsigned-byte 16)` arithmetic -- `(incf ... 2)` can
   transiently exceed the declared type at `(safety 1)`+`(speed 3)` on
   SBCL if it ever hits 65535; either widen to `fixnum` or mask after
   increment (check what values are actually reachable first).
4. Add `(declaim (ftype ...))` signatures for the hottest cross-file calls:
   `bus-read`, `bus-write`, `step-cpu`, `pokey-tick`/`pokey-advance`,
   `antic-tick` (e.g. `(function (bus (unsigned-byte 16)) (unsigned-byte
   8))`). Place each ftype directly above the defun it describes.
5. Benchmark on both implementations; record in PERFORMANCE_LOG.md.

Commit: "Add optimize/ftype declarations to the hot path".

---

## Phase 2 -- Page-dispatch table for BUS-READ/BUS-WRITE

Replace the per-access cond chain + MMU predicate calls with a 256-entry
per-page tag table rebuilt only when banking changes.

1. Design (in `src/bus.lisp`):
   - Add bus slots: `page-tags` -- `(simple-array (unsigned-byte 4) (256))`
     mapping page (high byte of address) -> small-integer tag; and
     `map-generation` -- fixnum of the last MMU generation the table was
     built for.
   - Tags (defconstants): `+pg-ram+ +pg-os-rom+ +pg-basic-rom+
     +pg-selftest+ +pg-gtia+ +pg-pokey+ +pg-pia+ +pg-antic+ +pg-open-bus+`.
     All current map regions are page-aligned (self-test $50-$57, BASIC
     $A0-$BF, OS low $C0-$CF, I/O $D0-$D7 one chip or open-bus page each,
     OS high $D8-$FF), so page granularity is exact -- assert this in a test.
   - `%REBUILD-PAGE-TABLE (bus)`: fills tags from the MMU predicates
     (`os-rom-mapped-p` etc.) and ROM-installed-ness, mirroring the
     current `bus-read` priority order exactly. A region whose ROM is not
     installed or whose chip closure is NIL degrades exactly as today
     (RAM / open-bus #xFF).
2. Invalidation: add a `generation` fixnum slot to the `mmu` struct
   (`src/mmu.lisp`), incremented by `mmu-write-portb` and `reset-mmu`.
   `bus-read`/`bus-write` compare `(mmu-generation mmu)` against
   `bus-map-generation` and lazily rebuild on mismatch -- one fixnum
   compare on the fast path, no new coupling (bus already owns the mmu
   reference; mmu stays bus-agnostic). ROM installs
   (`install-os-rom`/`install-basic-rom`) bump the bus's own generation
   stamp to force a rebuild too (or simply call `%rebuild-page-table`).
3. Rewrite `bus-read` as: check generation -> `(ecase (aref tags (ldb (byte
   8 8) address)) ...)` with one branch per tag, each branch the same code
   the current cond arm runs. Same for `bus-write` (RAM vs I/O vs
   ROM-shadow-writes-land-in-RAM is already the rule -- only the I/O pages
   differ). Keep `bus-read16`, peek/poke unchanged.
4. Correctness tests (in `tests/test-mmu.lisp` or a new
   `tests/test-bus-map.lisp` wired into the .asd):
   - Sweep test: for each PORTB value in `'(#xFF #xFE #xFD #x7F #x7D ...)`
     (cover all 8 combinations of the three banking bits) and each address
     in a boundary set ($4FFF $5000 $57FF $5800 $9FFF $A000 $BFFF $C000
     $CFFF $D000 $D0FF $D100 $D1FF $D200 $D300 $D400 $D500 $D7FF $D800
     $FFFF), assert `bus-read` returns the same value as a hand-written
     oracle that re-implements the old cond chain (copy the old code into
     the test as `%bus-read-reference`).
   - Banking flips take effect on the very next access (regression #5
     `portb-write-changes-rom-mapping-immediately` already covers this --
     it must pass unmodified).
5. Benchmark both implementations; record. Expected: measurable gain on
   memory-heavy workloads; if the gain is < ~5% on both, consider keeping
   the simpler cond chain and closing this phase as "measured, not worth
   it" -- that is a valid outcome and should be logged.

Commit: "Dispatch bus reads through a per-page tag table".

---

## Phase 3 -- POKEY batched advance (event skipping)

Prerequisite: `POKEY-ADVANCE (pokey cpu n)` exists (SCANLINE_ACCURACY_PLAN
Phase 1). This phase optimizes its internals from a per-cycle loop to
event skipping. Behaviour must be bit-identical.

1. Timer skipping: for each channel, cycles until its next sub-counter
   expiry is `sub-counter + divisor * timer-count` ... actually the next
   EVENT is the sub-counter expiry (`sub-counter` cycles away); underflow
   happens on the expiry where `timer-count` is 0. Compute
   `next-event = (min over channels of cycles-to-next-expiry)`; advance
   all sub-counters/timer-counts arithmetically by `(min n next-event)`
   without looping per cycle; process the expiry exactly as `pokey-tick`
   does (reload sub-counter, decrement or underflow+IRQ); repeat until N
   is consumed. Keep `pokey-tick` as `(pokey-advance pokey cpu 1)` so the
   existing tests keep their meaning.
2. RNG: the LFSRs currently step once per cycle. Stepping them inside the
   batched loop defeats the optimization, so make them LAZY: store
   `rng-cycle` (cycles the RNG is behind) and advance the LFSRs only when
   `pokey-random` is actually read -- step `(mod delta 131071)` /
   `(mod delta 511)` times for the 17/9-bit polys (period of an n-bit
   maximal LFSR is 2^n - 1; bounded work per read, and RANDOM reads are
   rare). Audit: nothing else in the codebase observes LFSR state except
   `pokey-random` and the reset function -- grep `poly17-state` /
   `poly9-state` (tests touch them; keep slot semantics "state as of the
   last sync" and add a `%sync-rng` helper tests can call).
3. Equivalence test (the important one), in `tests/test-pokey.lisp`:
   drive two POKEYs side by side -- one via N x `pokey-tick`, one via
   `pokey-advance` in random-sized chunks (use a fixed seed list, not
   `random`, for determinism) -- through a scripted sequence of register
   writes (AUDF/AUDCTL/IRQEN/STIMER changes at fixed cycle offsets) over
   ~50,000 cycles. After every chunk, assert IRQST, timer-counts,
   sub-counters, and `pokey-random` agree.
4. Benchmark; record. This phase matters most AFTER the scanline scheduler
   (when `pokey-advance` is called with multi-cycle N).

Commit: "Batch POKEY advancement with event skipping and lazy RNG".

---

## Phase 4 -- Profiling pass + follow-ups

1. Add compat-wrapped profiling helpers in `src/compat.lisp`:
   `WITH-PROFILING ((&key mode) &body body)` -- SBCL: `sb-sprof` statistical
   profile printed flat; LispWorks: `hcl:profile` or the `mp`-safe
   equivalent (consult LispWorks docs; if unavailable in the console image,
   make it a no-op with a warning). Export it. This is the ONE place
   implementation conditionals are allowed.
2. Profile the benchmark workloads on SBCL. Write findings into
   PERFORMANCE_LOG.md ("top 5 functions by samples, before/after").
3. Candidate follow-ups, only if the profile names them (do not do these
   speculatively):
   - `update-zn` flag traffic: compute Z/N into a local and write
     `cpu-flags` once instead of two read-modify-writes.
   - Opcode-handler `multiple-value-bind` overhead: verify SBCL stack-
     allocates the values (it should); only restructure if the profile
     disagrees.
   - The CPU's closure-based bus indirection (`funcall (cpu-bus-read cpu)`)
     is a deliberate architecture choice (bus-agnostic core). Do NOT
     replace it with direct calls; acceptable mitigation is declaring the
     slot `:type function` after construction-time wiring is guaranteed,
     plus the ftype declarations from Phase 1.
4. Set/record a target once numbers exist. Suggested framing: N x realtime
   on SBCL for the NOP workload, with the gap between SBCL and LispWorks
   documented rather than chased.

Commit: "Add profiling helpers; record post-optimization profile".

## Anti-goals

- No `(safety 0)`, no struct->vector rewrites, no macro-generated
  monolithic interpreter loop, no implementation-specific intrinsics
  outside compat. If a proposed change makes the code harder to read for
  a CL learner, the performance win has to be an order of magnitude, not
  percent -- otherwise reject it.
