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
| 2026-08-02 | b4e8d51  | sbcl           | nop      | 3509.97 | 58.578     | same-session re-baseline for review fixes (mean of 3) |
| 2026-08-02 | b4e8d51  | sbcl           | irq      | 3963.98 | 66.155     | same-session re-baseline for review fixes (mean of 3) |
| 2026-08-02 | b4e8d51  | lispworks      | nop      |  923.57 | 15.413     | same-session re-baseline for review fixes (mean of 3) |
| 2026-08-02 | b4e8d51  | lispworks      | irq      | 1460.45 | 24.374     | same-session re-baseline for review fixes (mean of 3) |
| 2026-08-02 | f7ca0d6  | sbcl           | nop      | 3451.22 | 57.598     | Phases 1-5 review fixes (mean of 3)  |
| 2026-08-02 | f7ca0d6  | sbcl           | irq      | 3883.83 | 64.817     | Phases 1-5 review fixes (mean of 3)  |
| 2026-08-02 | f7ca0d6  | sbcl           | display  |  525.50 |  8.770     | NEW workload: DMA-active + renderer (mean of 3) |
| 2026-08-02 | f7ca0d6  | sbcl           | klaus    | 3179.26 | 53.058     | Phases 1-5 review fixes, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | f7ca0d6  | lispworks      | nop      |  925.96 | 15.453     | Phases 1-5 review fixes (mean of 3)  |
| 2026-08-02 | f7ca0d6  | lispworks      | irq      | 1462.81 | 24.413     | Phases 1-5 review fixes (mean of 3)  |
| 2026-08-02 | f7ca0d6  | lispworks      | display  |   66.74 |  1.114     | NEW workload: DMA-active + renderer (mean of 3) |
| 2026-08-02 | f7ca0d6  | lispworks      | klaus    |  924.15 | 15.424     | Phases 1-5 review fixes, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | e4cce02   | sbcl          | nop      | 3500.02 | 58.412     | Renderer: span P/M + border fill (mean of 3) |
| 2026-08-02 | e4cce02   | sbcl          | irq      | 3688.69 | 61.560     | Renderer: span P/M + border fill (mean of 3) |
| 2026-08-02 | e4cce02   | sbcl          | display  | 1124.78 | 18.772     | Renderer: span P/M + border fill -- 2.14x (mean of 3) |
| 2026-08-02 | e4cce02   | sbcl          | klaus    | 3048.00 | 50.868     | Renderer opt, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | e4cce02   | lispworks     | nop      |  895.83 | 14.950     | Renderer: span P/M + border fill (mean of 3) |
| 2026-08-02 | e4cce02   | lispworks     | irq      | 1411.38 | 23.555     | Renderer: span P/M + border fill (mean of 3) |
| 2026-08-02 | e4cce02   | lispworks     | display  |  255.15 |  4.258     | Renderer: span P/M + border fill -- 3.82x (mean of 3) |
| 2026-08-02 | e4cce02   | lispworks     | klaus    |  905.07 | 15.105     | Renderer opt, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 01cc84b   | sbcl          | nop      | 3501.11 | 58.430     | Renderer: char color-pair hoist (mean of 3) |
| 2026-08-02 | 01cc84b   | sbcl          | irq      | 3716.16 | 62.019     | Renderer: char color-pair hoist (mean of 3) |
| 2026-08-02 | 01cc84b   | sbcl          | display  | 1931.61 | 32.236     | Renderer: char color-pair hoist -- +72% (mean of 3) |
| 2026-08-02 | 01cc84b   | sbcl          | klaus    | 3111.00 | 51.919     | Renderer char hoist, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 01cc84b   | lispworks     | nop      |  912.57 | 15.230     | Renderer: char color-pair hoist (mean of 3) |
| 2026-08-02 | 01cc84b   | lispworks     | irq      | 1442.17 | 24.069     | Renderer: char color-pair hoist (mean of 3) |
| 2026-08-02 | 01cc84b   | lispworks     | display  |  332.01 |  5.541     | Renderer: char color-pair hoist -- +30% (mean of 3) |
| 2026-08-02 | 01cc84b   | lispworks     | klaus    |  938.18 | 15.657     | Renderer char hoist, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 8255be7   | sbcl          | nop      | 3476.34 | 58.018     | ROADMAP Phase 6: P/M DMA + PRIOR (mean of 3) |
| 2026-08-02 | 8255be7   | sbcl          | irq      | 3706.60 | 61.859     | ROADMAP Phase 6: P/M DMA + PRIOR (mean of 3) |
| 2026-08-02 | 8255be7   | sbcl          | display  | 1923.10 | 32.094     | ROADMAP Phase 6: P/M DMA + PRIOR (mean of 3) |
| 2026-08-02 | 8255be7   | sbcl          | klaus    | 3116.40 | 52.009     | ROADMAP Phase 6, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-02 | 8255be7   | lispworks     | nop      |  929.82 | 15.518     | ROADMAP Phase 6: P/M DMA + PRIOR (mean of 3) |
| 2026-08-02 | 8255be7   | lispworks     | irq      | 1442.76 | 24.078     | ROADMAP Phase 6: P/M DMA + PRIOR (mean of 3) |
| 2026-08-02 | 8255be7   | lispworks     | display  |  325.74 |  5.436     | ROADMAP Phase 6: P/M DMA + PRIOR (mean of 3) |
| 2026-08-02 | 8255be7   | lispworks     | klaus    |  933.02 | 15.573     | ROADMAP Phase 6, klaus+PASS, 3500 frames (mean of 3) |

## ROADMAP Phase 12 -- CPU fixes are performance-neutral

The Tom Harte harness turned up three CPU bugs (unstable-store page-cross
address corruption, ARR decimal mode, JSR operand read order).  All three
sit on the instruction path, so they were measured the same way as any
hot-path change: interleaved runs against the immediately preceding
commit (3cfec39), means of 2.

| implementation | workload | 3cfec39 fps | with fixes | delta |
|----------------|----------|-------------|------------|-------|
| sbcl           | nop      | 3596.3      | 3540.5     | -1.6% |
| sbcl           | klaus    | 3220.5      | 3246.1     | +0.8% |

Both are inside this machine's run-to-run spread (nop varies ~1.5%
between identical runs), and the two move in opposite directions, so
there is no measurable cost.  Expected: the JSR change swaps one
16-bit operand read for two 8-bit reads on a single opcode, and the
other two fixes only add work on code paths that were already wrong.

Absolute numbers here are higher than the rows above them for the same
workloads -- those were taken while the machine was busy downloading and
parsing a gigabyte of test vectors.  Only the interleaved A/B pairs
within a section are comparable.

## POKEY serial output (SEROR/SEROC) -- implementation cost

Adding the serial transmitter puts one new test on POKEY's hottest
paths, so it is measured here even though it is a feature, not an
optimization.  Interleaved runs against the immediately preceding commit
(e699be2), means of 3 (SBCL) / 4 (LispWorks, discarding one contaminated
first run):

| implementation | workload | e699be2 fps | with serial | delta |
|----------------|----------|-------------|-------------|-------|
| sbcl           | nop      | 3354.8      | 3313.0      | -1.2% |
| sbcl           | irq      | 3864.8      | 3854.8      | -0.3% |
| sbcl           | display  | 1896.1      | 1899.6      | +0.2% |
| sbcl           | klaus    | 3035.4      | 2957.7      | -2.6% |
| lispworks      | nop      |  995.9      |  954.3      | -4.2% |
| lispworks      | irq      | 1572.8      | 1497.6      | -4.8% |
| lispworks      | display  |  346.0      |  343.5      | -0.7% |
| lispworks      | klaus    |  962.4      |  959.5      | -0.3% |

The remaining cost is one fixnum slot read plus a branch per POKEY-TICK /
POKEY-ADVANCE call -- the "is the transmitter busy" test.  It lands
hardest on `nop`/`irq`, which are POKEY-dominated microbenchmarks; the
mixed workloads (`display`, `klaus`) are within noise.

**Rejected first shape: clocking the transmitter from channel 4's
underflows inside %EXPIRE-CHANNEL.**  That is the more literal model of
the hardware (the transmit clock really is channel 4's output), but
%EXPIRE-CHANNEL is inlined into both POKEY-TICK and POKEY-ADVANCE, so a
test there is paid on every underflow of every channel and bloats eight
inlined copies: SBCL lost 8.7% on `nop` and 3.7% on `klaus`.  Removing
just that hook restored baseline exactly (3350 vs 3362 nop), pinning the
cost on the hook rather than on the new struct slots.  A separate 4-9%
was traced to %RAISE-IRQ being called out of line from the underflow
path; that one is now `(declaim (inline %raise-irq))`.

The shipped shape keeps %EXPIRE-CHANNEL byte-identical to before and
runs the transmitter as a plain CPU-cycle countdown, charged once per
advance.  Timing is equivalent: the byte duration is computed from the
same channel-4 period (20 half-bits x (reload+1) x divisor), just
snapshotted when the byte starts shifting instead of tracked underflow
by underflow.

## ROADMAP Phase 9 -- POKEY audio synthesis

| date       | commit   | implementation | workload | fps     | realtime-x | notes                            |
|------------|----------|----------------|----------|---------|------------|----------------------------------|
| 2026-08-03 | (P9)     | sbcl           | nop      | 3112.11 | 51.938     | audio DETACHED (mean of 3)       |
| 2026-08-03 | (P9)     | sbcl           | irq      | 3664.67 | 61.159     | audio DETACHED (mean of 3)       |
| 2026-08-03 | (P9)     | sbcl           | display  | 1794.07 | 29.941     | audio DETACHED (mean of 3)       |
| 2026-08-03 | (P9)     | sbcl           | audio    | 1627.98 | 27.169     | audio ATTACHED, 4 channels voiced (mean of 3) |
| 2026-08-03 | (P9)     | sbcl           | klaus    | 2838.28 | 47.368     | audio DETACHED, klaus+PASS, 3500 frames (mean of 3) |
| 2026-08-03 | (P9)     | lispworks      | nop      |  890.10 | 14.855     | audio DETACHED (mean of 3)       |
| 2026-08-03 | (P9)     | lispworks      | irq      | 1374.62 | 22.941     | audio DETACHED (mean of 3)       |
| 2026-08-03 | (P9)     | lispworks      | display  |  311.39 |  5.197     | audio DETACHED (mean of 3)       |
| 2026-08-03 | (P9)     | lispworks      | audio    |  286.00 |  4.773     | audio ATTACHED, 4 channels voiced (mean of 3) |
| 2026-08-03 | (P9)     | lispworks      | klaus    |  890.21 | 14.857     | audio DETACHED, klaus+PASS, 3500 frames (mean of 3) |

**Detached cost (the number the phase had to prove).**  Session drift
made the raw before/after comparison useless again, so the pre-phase
commit (ee3c368) was benchmarked in a worktree and then A/B
INTERLEAVED with the new build, alternating runs to cancel drift:

| impl      | workload | pre-P9 (B) | post-P9 (A) | delta |
|-----------|----------|------------|-------------|-------|
| sbcl      | nop      | 3230.98    | 3096.49     | -4.2% |
| sbcl      | irq      | 3611.73    | 3597.57     | -0.4% |
| lispworks | nop      |  925.31    |  886.27     | -4.2% |
| lispworks | irq      | 1426.97    | 1404.21     | -1.6% |

Every A run fell below every B run on `nop` (both implementations),
while `irq` alternated -- so the `nop` delta is real and the `irq` one
is noise.  That is the
expected shape: the cost is one slot read plus branch per POKEY
advance, and `nop` is the maximum possible advance density (a 2-cycle
instruction means one advance per two emulated cycles), while every
other workload runs longer instructions or spends its time elsewhere.

The first implementation put that test INSIDE `pokey-advance`'s chunk
loop and cost ~7% on `nop`; hoisting it to one test per call, with the
two loop bodies generated from a shared MACROLET and a literal NIL
passed to the inlined `%EXPIRE-CHANNEL` so its audio branch folds away,
recovered roughly half of it.  What remains is the "exactly one NIL
check per advance" the ROADMAP sanctioned.

**Attached cost.**  The new `audio` workload voices all four channels
(two on the 1.79 MHz clock, so flip-flops are clocked every few cycles)
and drains once per frame: SBCL 1628 fps (52% of the detached NOP
sled, 27x realtime), LispWorks 286 fps (32%, 4.8x realtime).  Both
leave ample headroom over the 59.92 Hz target, so Phase 10 can stream
audio without a real-time risk.

## ROADMAP Phase 6 -- P/M DMA + full PRIOR priority

Hot-path phases 6a (per-line P/M fetch) and 6b (source-tag recording +
priority arbitration) benched together at the 6c commit.  All
workloads are neutral vs. the 01cc84b rows (SBCL display -0.4%, LW
-1.9%, others within the same spread): the display workload enables
neither DMACTL's P/M bits (no fetch runs) nor any GRAF register (the
P/M layer and the tag recording are both behind the per-row five-
register early-out), so the only new steady-state cost is that check.
A P/M-active bench row will come for free once a demo workload uses
sprites; the P/M-on decomposition variant from the renderer-
optimization session measured active-sprite compositing at ~9% of the
optimized frame.

## Renderer optimization -- per-character color-pair hoisting

With P/M compositing fixed, decomposition showed glyph rendering as
the display frame's dominant term (71% SBCL / 60% LispWorks): a mode
CASE dispatch plus three palette lookups per output pixel.  A char row
has at most two colors, both fixed per character, so both RGB triples
are now resolved once per character and the glyph loop only stores
bytes.  display mean of 3: SBCL 1124.8 -> 1931.6 fps (+72%), LispWorks
255.2 -> 332.0 fps (+30%).  Cumulative over the whole optimization
pass (vs. the f7ca0d6 rows): SBCL 3.68x, LispWorks 4.97x (~1.1x
realtime -> ~5.5x).  nop/irq/klaus unchanged within session noise.

Prototype-methodology note for future sessions: measuring a renderer
variant by LOADing a redefinition source file works on SBCL (LOAD
compiles) but silently runs INTERPRETED on LispWorks -- the LW
prototype of this change benched at 2.5 fps until recompiled.  Use
COMPILE-FILE + LOAD (or bench the committed code) on LispWorks.

Remaining display-frame profile after both renderer commits (SBCL /
LispWorks, from the same-image decomposition): CPU+chips emulation
~0.20 / ~0.81 ms, playfield render now the remainder -- further
candidates are per-row glyph batching and cheaper border fills, but
Phase 6b's PRIOR rewrite will restructure these loops anyway (it must
emit per-pixel source tags), so fold further playfield tuning into
that phase rather than optimizing twice.

## Renderer optimization -- span-based P/M compositing + border-only fill

Decomposing the display workload (scanline callback stubbed vs. P/M
layer stubbed) showed P/M compositing at 52% (SBCL) / 67% (LispWorks)
of the whole frame with NO P/M objects enabled: 92,160 non-inlined
per-pixel %PM-PIXEL-COLOR calls per frame, each re-reading all 8
objects' loop-invariant registers.  The fix: row-level early-out (all
GRAF registers zero -> five register reads and done) + span painting
(each enabled object paints its own <= 32-column span,
lowest-priority first).  Also: the full-row background flood is now
borders-only on playfield lines (320 of 384 pixels were being flooded
and immediately overwritten), and renderer.lisp carries the explicit
hot-path optimize declaim like the other hot files.

display workload, mean of 3, vs. the f7ca0d6 rows: SBCL 525.5 ->
1124.8 fps (2.14x, projection was ~2x), LispWorks 66.7 -> 255.2 fps
(3.82x, projection was ~3x; ~1.1x realtime -> ~4.3x realtime, restoring
headroom for Phase 6 priority work and Phase 9 audio).  nop/irq/klaus
moved -3..-5% -- consistent with this session's steady downward drift
(see the b4e8d51 re-baseline note above), and those workloads never
enter the changed code (render path only).  P/M semantics are pinned
by four new renderer tests (overlap priority, sizing, missile
geometry, edge clipping); suite 1842/1842 on both implementations.

## Phases 1-5 review fixes -- map-mode/WSYNC corrections + display workload

The review-fix commits (map-mode hardware geometry/steal tables, WSYNC
deficit clamp + stale-flag consume) touch the hot path, so both rules-3
runs were done -- with one methodology note: measured fps this session
is 5-10% below the e3c23bc rows across ALL workloads on BOTH
implementations, including code paths the fixes never touch.  To
separate machine drift from real cost, b4e8d51 (the pre-fix tree) was
re-benchmarked in a worktree in the SAME session (rows above): against
that baseline the fixes are neutral -- SBCL nop -1.7% / irq -2.0%
(inside the run-to-run spread of the three samples), LispWorks nop and
irq +0.2%.  The nop/irq/klaus workloads never enable DMACTL, so the
map-mode table changes never execute there; the only new always-on work
is one ANTIC-CONSUME-WSYNC call per %RUN-CLOCKS invocation (once per
frame) and the MIN in the (rare) stall clamp.

The NEW `display` workload (24-line mode-2 DL, DMACTL $22, renderer
attached via the scanline callback -- the first bench to exercise the
DMA-active steal accounting and per-line rendering) has no "before"
row; its f7ca0d6 rows are the baseline for future renderer/DMA work.
Note the cost of rendering: ~6.6x slower than nop on SBCL (525 fps) and
~14x on LispWorks (67 fps ~ 1.11x realtime -- close to the realtime
floor; renderer optimization is a candidate before Phase 6's per-pixel
priority work lands on top of it).

## ROADMAP Phase 5 -- playfield DMA steal implementation cost

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

## ROADMAP Phase 3 -- WSYNC implementation cost

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

All deltas are within run-to-run noise (compare to the +/-1-3% spread
across repeated runs of the same commit elsewhere in this log) -- the
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
the callback itself never runs. Acceptable -- the scheduler's headline
gains (e.g. LispWorks irq 626 -> 1543 fps vs. the pre-scheduler renderer
branch) dwarf it; revisit only if a profile ever shows the line events
hot.

## Scanline scheduler note -- fps gain includes an accuracy correction

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

## Phase 3 note -- POKEY-TICK does not delegate to POKEY-ADVANCE

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

## Phase 2 -- page-dispatch table (rejected, not committed)

PERFORMANCE_PLAN.md Phase 2 proposed replacing BUS-READ/BUS-WRITE's
priority-COND chain with a per-page tag table (256-entry array, one tag
per address high byte), rebuilt lazily off an MMU generation counter.
Implemented in full (page tags, MMU generation, eager rebuild on ROM
install/MMU attach, a dedicated equivalence-vs-oracle test suite), 1596/1596
checks passed on both implementations -- but the benchmark delta didn't
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
run-to-run variance). LispWorks -- the project's primary target per
CLAUDE.md -- regressed consistently across all three workloads. Likely
cause: the original COND chain already short-circuits cheaply in these
workloads (`bus-os-rom`/`bus-basic-rom` being NIL, or address ranges
failing the first `AND` term immediately), so it wasn't as expensive as
the plan assumed, while the tag-table path adds a fixed per-access cost
(generation compare + array read + ECASE) that LispWorks apparently
doesn't optimize as well as SBCL does. Conclusion: not worth the added
complexity; Phase 2 is closed without merging.
