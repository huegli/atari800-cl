# Performance Log

Every optimization commit updates this log with before/after numbers from
BOTH implementations (SBCL and LispWorks), recorded via
`scripts/bench-sbcl.sh` / `scripts/bench-lispworks.sh`.  See the
"Benchmarking" section of `CLAUDE.md` for the harness workflow.

`realtime-x` = measured fps / 59.92 (NTSC realtime speedup; >1 means
faster than a real Atari 800 XL).

| date       | commit   | implementation | workload | fps     | realtime-x | notes                            |
|------------|----------|----------------|----------|---------|------------|----------------------------------|
| 2026-06-27 | b48d458  | sbcl           | nop      | 2025.69 | 33.807     | baseline (Phase 0 harness)       |
| 2026-06-27 | b48d458  | sbcl           | irq      | 1865.02 | 31.125     | baseline (Phase 0 harness)       |
| 2026-06-27 | b48d458  | lispworks      | nop      |  249.69 |  4.167     | baseline (Phase 0 harness)       |
| 2026-06-27 | b48d458  | lispworks      | irq      |  259.63 |  4.333     | baseline (Phase 0 harness)       |
| 2026-07-01 | 6fb2973  | sbcl           | nop      | 1960.73 | 32.722     | add :klaus workload              |
| 2026-07-01 | 6fb2973  | sbcl           | irq      | 1795.20 | 29.960     | add :klaus workload              |
| 2026-07-01 | 6fb2973  | sbcl           | klaus    | 1520.18 | 25.370     | klaus+PASS, 3252 frames          |
| 2026-07-01 | 6fb2973  | lispworks      | nop      |  250.10 |  4.174     | add :klaus workload              |
| 2026-07-01 | 6fb2973  | lispworks      | irq      |  267.26 |  4.460     | add :klaus workload              |
| 2026-07-01 | 6fb2973  | lispworks      | klaus    |  230.72 |  3.850     | klaus+PASS, 3252 frames          |
| 2026-07-02 | ff34cc4  | sbcl           | nop      | 2339.26 | 39.040     | Phase 1: optimize/ftype declarations |
| 2026-07-02 | ff34cc4  | sbcl           | irq      | 1938.09 | 32.345     | Phase 1: optimize/ftype declarations |
| 2026-07-02 | ff34cc4  | sbcl           | klaus    | 1737.45 | 28.996     | Phase 1, klaus+PASS, 3252 frames |
| 2026-07-02 | ff34cc4  | lispworks      | nop      |  652.88 | 10.896     | Phase 1: optimize/ftype declarations |
| 2026-07-02 | ff34cc4  | lispworks      | irq      |  620.48 | 10.355     | Phase 1: optimize/ftype declarations |
| 2026-07-02 | ff34cc4  | lispworks      | klaus    |  536.55 |  8.954     | Phase 1, klaus+PASS, 3252 frames |
| 2026-07-02 | df7875d  | sbcl           | nop      | 2618.63 | 43.702     | Phase 3: lazy RNG + POKEY-ADVANCE (mean of 3) |
| 2026-07-02 | df7875d  | sbcl           | irq      | 2174.30 | 36.287     | Phase 3: lazy RNG + POKEY-ADVANCE (mean of 3) |
| 2026-07-02 | df7875d  | sbcl           | klaus    | 1953.69 | 32.605     | Phase 3, klaus+PASS, 3252 frames (mean of 3) |
| 2026-07-02 | df7875d  | lispworks      | nop      |  665.44 | 11.105     | Phase 3: lazy RNG + POKEY-ADVANCE (mean of 3) |
| 2026-07-02 | df7875d  | lispworks      | irq      |  626.31 | 10.452     | Phase 3: lazy RNG + POKEY-ADVANCE (mean of 3) |
| 2026-07-02 | df7875d  | lispworks      | klaus    |  538.03 |  8.979     | Phase 3, klaus+PASS, 3252 frames (mean of 3) |
| 2026-07-02 | 3e9601d  | sbcl           | nop      | 2490.09 | 41.553     | Merge perf-plan into pixel-renderer (mean of 3) |
| 2026-07-02 | 3e9601d  | sbcl           | irq      | 2103.38 | 35.107     | Merge perf-plan into pixel-renderer (mean of 3) |
| 2026-07-02 | 3e9601d  | sbcl           | klaus    | 1891.91 | 31.574     | Merge perf-plan into pixel-renderer, klaus+PASS, 3252 frames (mean of 3) |
| 2026-07-02 | 3e9601d  | lispworks      | nop      |  647.52 | 10.805     | Merge perf-plan into pixel-renderer (mean of 3) |
| 2026-07-02 | 3e9601d  | lispworks      | irq      |  606.50 | 10.121     | Merge perf-plan into pixel-renderer (mean of 3) |
| 2026-07-02 | 3e9601d  | lispworks      | klaus    |  531.26 |  8.866     | Merge perf-plan into pixel-renderer, klaus+PASS, 3252 frames (mean of 3) |
| 2026-07-02 | c69772d  | sbcl           | nop      | 4005.57 | 66.849     | Scanline scheduler (mean of 3)   |
| 2026-07-02 | c69772d  | sbcl           | irq      | 4242.57 | 70.804     | Scanline scheduler (mean of 3)   |
| 2026-07-02 | c69772d  | sbcl           | klaus    | 3380.79 | 56.422     | Scanline sched, klaus+PASS, 3500 frames (mean of 3) |
| 2026-07-02 | c69772d  | lispworks      | nop      | 1019.84 | 17.020     | Scanline scheduler (mean of 3)   |
| 2026-07-02 | c69772d  | lispworks      | irq      | 1607.22 | 26.823     | Scanline scheduler (mean of 3)   |
| 2026-07-02 | c69772d  | lispworks      | klaus    |  999.91 | 16.688     | Scanline sched, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 273cfe4  | sbcl           | nop      | 3932.65 | 65.632     | Merge scanline scheduler into pixel-renderer (mean of 3) |
| 2026-08-02 | 273cfe4  | sbcl           | irq      | 4092.64 | 68.302     | Merge scanline scheduler into pixel-renderer (mean of 3) |
| 2026-08-02 | 273cfe4  | sbcl           | klaus    | 3297.65 | 55.035     | Merge scanline sched into pixel-renderer, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 273cfe4  | lispworks      | nop      |  962.02 | 16.055     | Merge scanline scheduler into pixel-renderer (mean of 3) |
| 2026-08-02 | 273cfe4  | lispworks      | irq      | 1542.98 | 25.751     | Merge scanline scheduler into pixel-renderer (mean of 3) |
| 2026-08-02 | 273cfe4  | lispworks      | klaus    |  971.21 | 16.209     | Merge scanline sched into pixel-renderer, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 0212cf6  | sbcl           | nop      | 3911.85 | 65.288     | ROADMAP Phase 3: WSYNC (mean of 3) |
| 2026-08-02 | 0212cf6  | sbcl           | irq      | 4166.01 | 69.520     | ROADMAP Phase 3: WSYNC (mean of 3) |
| 2026-08-02 | 0212cf6  | sbcl           | klaus    | 3345.24 | 55.828     | ROADMAP Phase 3, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 0212cf6  | lispworks      | nop      |  998.89 | 16.671     | ROADMAP Phase 3: WSYNC (mean of 3) |
| 2026-08-02 | 0212cf6  | lispworks      | irq      | 1583.20 | 26.421     | ROADMAP Phase 3: WSYNC (mean of 3) |
| 2026-08-02 | 0212cf6  | lispworks      | klaus    |  993.48 | 16.581     | ROADMAP Phase 3, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | e3c23bc  | sbcl           | nop      | 3929.98 | 65.577     | ROADMAP Phase 5: playfield DMA steal (mean of 3) |
| 2026-08-02 | e3c23bc  | sbcl           | irq      | 4128.94 | 68.907     | ROADMAP Phase 5: playfield DMA steal (mean of 3) |
| 2026-08-02 | e3c23bc  | sbcl           | klaus    | 3332.81 | 55.611     | ROADMAP Phase 5, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | e3c23bc  | lispworks      | nop      |  986.88 | 16.472     | ROADMAP Phase 5: playfield DMA steal (mean of 3) |
| 2026-08-02 | e3c23bc  | lispworks      | irq      | 1581.72 | 26.398     | ROADMAP Phase 5: playfield DMA steal (mean of 3) |
| 2026-08-02 | e3c23bc  | lispworks      | klaus    |  991.60 | 16.552     | ROADMAP Phase 5, klaus+PASS, 3500 frames (mean of 3) |

## ROADMAP Phase 5 — playfield DMA steal implementation cost

None of the bench workloads (nop/irq/klaus) ever write DMACTL, so
%DISPLAY-ACTIVE-P stays false throughout and PLAYFIELD-DMA-CYCLES /
the DL-fetch accounting never run beyond their cheap early-exit guards.
Klaus still PASSes at the same 3500-frame count (confirming no steal
was added to that workload). Measured delta vs. the Phase 3 (WSYNC)
baseline (mean of 3, same machine):

| implementation | workload | Phase 3 fps | Phase 5 fps | delta  |
|-----------------|----------|-------------|-------------|--------|
| sbcl            | nop      | 3911.85     | 3929.98     | +0.5%  |
| sbcl            | irq      | 4166.01     | 4128.94     | -0.9%  |
| sbcl            | klaus    | 3345.24     | 3332.81     | -0.4%  |
| lispworks       | nop      |  998.89     |  986.88     | -1.2%  |
| lispworks       | irq      | 1583.20     | 1581.72     | -0.1%  |
| lispworks       | klaus    |  993.48     |  991.60     | -0.2%  |

All within run-to-run noise, as expected.

## ROADMAP Phase 3 — WSYNC implementation cost

WSYNC adds one `ANTIC-CONSUME-WSYNC` call (an inline read-and-clear of
a boolean slot) per instruction inside `%RUN-CLOCKS`'s inner loop, plus
a `CASE` branch in `ANTIC-WRITE`. Neither of these benchmark workloads
(nop/irq/klaus) ever writes $D40A, so the check is pure overhead with
the flag always false. Measured delta vs. the pre-WSYNC baseline (mean
of 3, same machine, immediately before this change):

| implementation | workload | before fps | after fps | delta  |
|-----------------|----------|------------|-----------|--------|
| sbcl            | nop      | 3958.70    | 3911.85   | -1.2%  |
| sbcl            | irq      | 4134.09    | 4166.01   | +0.8%  |
| sbcl            | klaus    | 3363.96    | 3345.24   | -0.6%  |
| lispworks       | nop      |  995.04    |  998.89   | +0.4%  |
| lispworks       | irq      | 1577.58    | 1583.20   | +0.4%  |
| lispworks       | klaus    |  983.34    |  993.48   | +1.0%  |

All deltas are within run-to-run noise (compare to the ±1-3% spread
across repeated runs of the same commit elsewhere in this log) — the
per-instruction WSYNC check is effectively free, as expected.

## Merge atari800-cl-perf-plan into pixel-renderer (3e9601d)

Merged the performance branch (Phase 1 declarations + Phase 3 POKEY
batching) into the pixel-renderer branch and re-benchmarked the combined
tree. The renderer is not on the per-clock hot path (it runs once per
scanline from `%RUN-CLOCKS`'s line-end callback), so the merge is
expected to be neutral vs. the df7875d perf-only numbers. Measured delta
vs. df7875d (mean of 3, same machine):

| implementation | workload | df7875d fps | 3e9601d fps | delta  |
|----------------|----------|-------------|-------------|--------|
| sbcl           | nop      | 2618.63     | 2490.09     | -4.9%  |
| sbcl           | irq      | 2174.30     | 2103.38     | -3.3%  |
| sbcl           | klaus    | 1953.69     | 1891.91     | -3.2%  |
| lispworks      | nop      |  665.44     |  647.52     | -2.7%  |
| lispworks      | irq      |  626.31     |  606.50     | -3.2%  |
| lispworks      | klaus    |  538.03     |  531.26     | -1.3%  |

The small across-the-board regression is run-to-run variance, not a real
cost from the merge: the renderer's per-scanline callback is only invoked
for active scanlines 8-247, and in these three workloads the display list
is blank (nop/irq) or OS-driven (klaus) so the callback either does no
playfield work or is not installed (the bench harness builds machines
without an AESP server, so `atari-machine-scanline-fn` is NIL and the
callback is a single `WHEN` check per line). The df7875d numbers were
taken on the perf branch without the renderer source loaded; the
combined tree loads `src/renderer.lisp` but does not call into it during
benchmarks. Conclusion: merge is neutral modulo variance; no follow-up
needed.

## Merge scanline scheduler into pixel-renderer (273cfe4)

Merged main (scanline-granular scheduler, c69772d) into the renderer
branch. The renderer's line-start screen-pointer snapshot and end-of-line
screen-pointer/scan-y advancement moved into the shared
%BEGIN-SCANLINE-EVENTS / %END-SCANLINE-EVENTS helpers, so both drivers
(per-cycle ANTIC-TICK and the scanline API) carry them; the machine's
per-scanline render callback now fires after ANTIC-END-SCANLINE.
Measured delta vs. the renderer-less c69772d rows (mean of 3, same
machine):

| implementation | workload | c69772d fps | 273cfe4 fps | delta  |
|----------------|----------|-------------|-------------|--------|
| sbcl           | nop      | 4005.57     | 3932.65     | -1.8%  |
| sbcl           | irq      | 4242.57     | 4092.64     | -3.5%  |
| sbcl           | klaus    | 3380.79     | 3297.65     | -2.5%  |
| lispworks      | nop      | 1019.84     |  962.02     | -5.7%  |
| lispworks      | irq      | 1607.22     | 1542.98     | -4.0%  |
| lispworks      | klaus    |  999.91     |  971.21     | -2.9%  |

A small consistent cost (2-6%), on par with run-to-run variance but
uniformly negative, so some of it is likely real: the rendering
bookkeeping (screen-pointer snapshot, display-active check + mode decode
for the pointer/scan-y advancement, and the per-line SCANLINE-FN NIL
check) now executes once per scanline inside the shared line events even
when no renderer is attached. Bench machines install no AESP server, so
the callback itself never runs. Acceptable — the scheduler's headline
gains (e.g. LispWorks irq 626 -> 1543 fps vs. the pre-scheduler renderer
branch) dwarf it; revisit only if a profile ever shows the line events
hot.

## Scanline scheduler note — fps gain includes an accuracy correction

c69772d (SCANLINE_ACCURACY_PLAN.md Phase 1) restructures the frame loop
from per-clock to per-scanline: ~260 antic/pokey calls per frame instead
of ~60,000, and POKEY-ADVANCE finally runs with multi-cycle N, which is
where its Phase 3 event skipping pays off (LispWorks irq +157%).  Two
caveats when comparing these rows against earlier ones:

- Part of the fps gain (~7%) is an ACCURACY correction, not pure
  optimization: the old per-clock loop suppressed only one budget cycle
  per line when ANTIC reported a steal, granting the CPU 113
  cycles/line regardless of the real steal.  The new scheduler charges
  the full steal (105 cycles/line at the default 9-cycle refresh + P/M
  steal), so each frame simply executes fewer instructions.  The Klaus
  workload confirms the same total work: 3500 frames x 27,510 granted
  cycles ~= 3252 frames x the old ~29,600.
- The Klaus workload's frame-boundary stuck-PC trap detection had to be
  hardened in the same commit (confirm traps at instruction
  granularity): the deterministic per-frame cycle grant can alias a
  long-running test loop's period, producing a false FAIL at a PC that
  is not a trap.

## Phase 3 note — POKEY-TICK does not delegate to POKEY-ADVANCE

Phase 3's first cut made `pokey-tick` a thin `(pokey-advance pokey cpu 1)`
wrapper.  Measured through that path, LispWorks lost 18-26% frame rate
across all workloads (nop 652.88 -> ~481) and SBCL was flat: at N = 1 the
event-skipping bookkeeping (extra call, chunk MIN, loop setup) costs more
than the two LFSR steps it saves.  Final shape: `pokey-tick` keeps its own
flat per-cycle loop with the lazy-RNG win only, `pokey-advance` keeps
event skipping for the multi-cycle callers the scanline scheduler will
add, and both share `%expire-channel` with a 50,000-cycle equivalence
test pinning them together.  That version is what df7875d ships (SBCL
+12%, LispWorks +0.3-1.9%).

## Phase 2 — page-dispatch table (rejected, not committed)

PERFORMANCE_PLAN.md Phase 2 proposed replacing BUS-READ/BUS-WRITE's
priority-COND chain with a per-page tag table (256-entry array, one tag
per address high byte), rebuilt lazily off an MMU generation counter.
Implemented in full (page tags, MMU generation, eager rebuild on ROM
install/MMU attach, a dedicated equivalence-vs-oracle test suite), 1596/1596
checks passed on both implementations — but the benchmark delta didn't
clear the plan's own bar ("if the gain is < ~5% on both ... keep the
simpler cond chain"), so the change was reverted and never committed;
`src/bus.lisp`/`src/mmu.lisp` are back to the Phase 1 (ff34cc4) cond chain.

Mean of 4 runs each, vs. the ff34cc4 Phase 1 baseline above:

| implementation | workload | ff34cc4 fps | Phase 2 fps (mean) | delta  |
|-----------------|----------|-------------|---------------------|--------|
| sbcl            | nop      | 2339.26     | 2415.66             | +3.3%  |
| sbcl            | irq      | 1938.09     | 1949.57             | +0.6%  |
| sbcl            | klaus    | 1737.45     | 1715.08             | -1.3%  |
| lispworks       | nop      |  652.88     |  630.77             | -3.4%  |
| lispworks       | irq      |  620.48     |  591.30             | -4.7%  |
| lispworks       | klaus    |  536.55     |  506.71             | -5.6%  |

SBCL's gain was marginal/noise-level (nop's +3.3% was the only value that
stayed consistently positive across repeats; irq and klaus are within
run-to-run variance). LispWorks — the project's primary target per
CLAUDE.md — regressed consistently across all three workloads. Likely
cause: the original COND chain already short-circuits cheaply in these
workloads (`bus-os-rom`/`bus-basic-rom` being NIL, or address ranges
failing the first `AND` term immediately), so it wasn't as expensive as
the plan assumed, while the tag-table path adds a fixed per-access cost
(generation compare + array read + ECASE) that LispWorks apparently
doesn't optimize as well as SBCL does. Conclusion: not worth the added
complexity; Phase 2 is closed without merging.
