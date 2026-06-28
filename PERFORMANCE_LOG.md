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
