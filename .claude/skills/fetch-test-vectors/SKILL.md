---
name: fetch-test-vectors
description: How to fetch and run the asset-gated CPU/ANTIC accuracy tests (Klaus Dormann functional test, Tom Harte SingleStepTests vectors, Acid800 hardware suite) for atari800-cl -- fetch scripts, env vars, subset flags, and strict mode.
---

# Asset-gated test vectors

The **Klaus Dormann 6502 functional test** (`tests/test-cpu.lisp`) runs if `roms/6502_functional_test.bin` exists (or `$ATARI800_CL_FUNCTIONAL_TEST` points to it), otherwise it skips gracefully. Run `./scripts/fetch-test-roms.sh` to download the prebuilt binary (org=0000, load_data_direct=1) from https://github.com/Klaus2m5/6502_65C02_functional_tests into `roms/`; it no-ops if the file is already present. The run is slow (max-instructions ~200M) -- a couple of minutes on SBCL, longer on LispWorks.

The **Tom Harte / SingleStepTests vectors** (`tests/test-harte.lisp`) are the
CPU accuracy ratchet: per-opcode JSON cases with full before/after CPU +
memory state and a cycle-by-cycle bus trace. The data is ~1 GB and is not
vendored; the harness skips unless `$ATARI800_CL_HARTE_TESTS` points at a
directory containing `<hex>.json` files (the SingleStepTests/65x02 repo's
`6502/v1` layout). `./scripts/fetch-harte.sh` (ROADMAP.md Phase 14) is the
one-command way to get them -- it fetches individual files straight from
`raw.githubusercontent.com` rather than `git clone`ing the ~1 GB repository
(whose `.git` history is bigger still), skips files already present so a
repeat or interrupted run resumes, and prints the `export
ATARI800_CL_HARTE_TESTS=...` line on success:

```sh
eval "$(./scripts/fetch-harte.sh --subset)"   # curated 8-file gate, ~30 MB
./scripts/test-sbcl.sh                        # 500 cases/opcode (~128k cases)

eval "$(./scripts/fetch-harte.sh)"            # all 256 opcode files, ~1 GB
ATARI800_CL_HARTE_FULL=1 ./scripts/test-sbcl.sh   # all 10,000 (~2.56M cases)
```

`--subset` picks opcodes covering addressing-mode diversity (indirect,
indirect-indexed, absolute-indexed, read-modify-write) and every illegal-
opcode family this project's Harte triage has ever named -- including the
three opcodes ($9C, $6B, $20) whose vectors found real CPU bugs during
Phase 12 -- so a fast pre-commit gate still gets the highest-value
regression coverage; `--subset N` takes the first N of that priority-
ordered list (capped at 8), and `--dir PATH` overrides the default
`.cache/harte/` (gitignored, like `roms/`). A manual `git clone` still
works if you want the full repository (e.g. to browse it) --
`ATARI800_CL_HARTE_TESTS` just needs to end up pointing at a `6502/v1`-
shaped directory either way.

A partial checkout works -- whichever `<hex>.json` files exist get tested.
**A failure here is presumed a real emulator bug**: fix it in `src/`, add a
focused regression test to `tests/test-regressions.lisp` naming the opcode
and case id, and only then consider the (currently empty) skip list. The
file header spells out the triage workflow.

**Acid800** (`tests/test-machine.lisp`'s `ACID800-*` tests) is the external
accuracy ratchet the CPU has always had via Harte but ANTIC never did: Avery
Lee's suite (MIT licensed) runs 20 standalone hardware-behavior programs (7
CPU + 13 ANTIC) against the real OS ROM and reads their Pass/FAIL text back
from screen memory. `./scripts/fetch-acid800.sh` fetches them into gitignored
`roms/acid800/` (no-op when already present):

```sh
./scripts/fetch-acid800.sh
./scripts/test-sbcl.sh
```

7 tests are required to pass (part of the normal green suite); the other 13
are individually documented, permanent skips in `+ACID800-KNOWN-ISSUES+`
(`tests/test-machine.lisp`, mirroring `+HARTE-SKIP-OPCODES+`'s convention) --
confirmed divergences from real hardware, most already tracked elsewhere
(README.md's Known Limitations, `SCANLINE_ACCURACY_PLAN.md`'s stretch Phase
4, `ROADMAP.md` Phase 20), a few (`cpu_bugs`'s NMI-hijacks-BRK gap, and four
ANTIC tests whose root cause isn't yet isolated) newly confirmed by this
harness. See `ROADMAP.md` Phase 24 and `CHANGES.md` for the full per-test
triage. These skip regardless of `ATARI800_CL_STRICT` -- they are permanent,
documented divergences, not missing assets.

Also see `CLAUDE.md`'s Build & Test Commands for the strict-mode skip
census (`ATARI800_CL_STRICT=1`), which turns asset-gated skips (including
these three) into failures.
