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
