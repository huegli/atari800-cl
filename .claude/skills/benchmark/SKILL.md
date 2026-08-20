---
name: benchmark
description: How to run and interpret the atari800-cl frame-rate benchmark harness (bench-sbcl.sh / bench-lispworks.sh) -- workloads, output format, and tuning variables.
---

# Benchmarking

Frame-rate benchmark harness for measuring optimization deltas. Works
without real ROM images (synthetic NOP/IRQ workloads built inline).

```sh
./scripts/bench-sbcl.sh
./scripts/bench-lispworks.sh
```

Each prints one machine-readable line per workload:
`BENCH <workload> frames=600 seconds=<s> fps=<fps> realtime-x=<fps/59.92>`.
Five workloads: `nop` (NOP-sled baseline), `irq` (busy loop + POKEY
timer 1 IRQs exercising the interrupt path), `display` (NOP sled with a
24-line mode-2 display list fetched by ANTIC -- DMA-active steal
accounting -- and the pixel renderer attached via the scanline callback),
`audio` (NOP sled with POKEY audio synthesis attached and all four
channels voiced, draining per frame -- every other workload runs with
audio detached, so the pair of rows shows both that the no-audio path
stays free and what synthesis costs), and `klaus` (the Klaus Dormann
functional test as a CPU-heavy load; skips if the binary is absent).
Tune via `atari800-cl.bench:*warmup-frames*` / `*measured-frames*`.

See `CLAUDE.md`'s Key Conventions for the rule that every optimization
commit updates `PERFORMANCE_LOG.md` with before/after numbers from both
implementations.
