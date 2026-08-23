---
name: run-tests
description: How to run the atari800-cl test suite via the sandbox-safe wrapper scripts -- why they exist, the EPERM sandbox listener caveat, ATARI800_CL_STRICT / skip-census asset-gated tests, the asdf:test-system exit-code gotcha, and legacy manual SBCL/LispWorks shell invocations.
---

# Running tests

These scripts are designed for both normal shells and restricted sandbox
execution environments. They deliberately avoid relying on `.sbclrc`,
LispWorks init-file side effects, or Quicklisp writing to
`~/quicklisp/local-projects/system-index.txt`. Instead they:

- register this repository and the installed Quicklisp software tree directly
  with ASDF via `asdf:initialize-source-registry`;
- redirect ASDF/FASL output into `.cache/fasls/` inside the repository via
  `asdf:initialize-output-translations`, because some sandboxes forbid writes
  to `~/.cache/common-lisp`;
- run `atari800-cl/tests::run-tests` (a thin wrapper around `fiveam:run!`
  plus a skip census, see below) directly for the shell exit status, because
  `asdf:test-system` can return successfully even when FiveAM reports failed
  checks;
- run the LispWorks test body inside `mp:initialize-multiprocessing`, because
  batch LispWorks images otherwise signal `Cannot create processes before
  multiprocessing is initialized` when tests create threads; and
- allow `QUICKLISP_SOFTWARE=/path/to/software` if the dependency tree is not
  at the default `~/quicklisp/dists/quicklisp/software`.

Sandbox caveat: some tool sandboxes deny listener creation with `EPERM` for
both TCP loopback sockets and Unix-domain sockets, even under `/tmp` and inside
the repository. The live AESP TCP server tests, CLI Unix socket server tests,
and Unix socket roundtrip test probe this capability and skip themselves when
listener bind is prohibited. On an unrestricted local shell these tests should
run normally.

**Strict mode and the skip census (ROADMAP.md Phase 21).** Every run prints
a `Skip census:` block after FiveAM's own report -- one `SKIPPED: <test>
(<reason>)` line per skipped check, or `(none)` -- so an asset-gated test
that silently skipped can never hide inside a bare "N checks, 1 skip"
count; `grep SKIPPED` a saved log to see exactly what did not run and why.
Three tests are asset-gated this way: the Klaus functional test, the Tom
Harte vectors, and the real-ROM boot tests. Set `ATARI800_CL_STRICT=1` (any
non-empty value) to turn those skips into failures instead -- the gate to
run on a machine that is supposed to have the assets before calling a phase
done:
```sh
ATARI800_CL_STRICT=1 ./scripts/test-sbcl.sh
```
Without the ROMs or vectors present, strict mode fails exactly those tests
by design -- it is meant to be run only once you believe the assets are in
place, not as the default CI posture.

**Checked-build audit (ROADMAP.md Phase 26).** `src/compat.lisp`'s
`FAST-AREF` macro is the one place `(safety 0)` is allowed in this
tree: a scoped LispWorks-only array-access fast path used at a small,
proof-commented set of hot call sites in `src/pokey.lisp` and
`src/renderer.lisp`. Setting `ATARI800_CL_CHECKED_AREF` to any
non-empty value at compile time forces `FAST-AREF`'s LispWorks
expansion back to the fully-checked SBCL form (`(aref (the type array)
index)`) at every one of those call sites -- the audit build that
proves the carve-out has not silently corrupted anything the ordinary
unchecked build's tests wouldn't catch:
```sh
ATARI800_CL_CHECKED_AREF=1 ./scripts/test-lispworks.sh
```
Because the checked/unchecked choice is baked into the fasl at
macroexpansion time, ASDF's timestamp-based recompilation will not by
itself notice the env var changing between runs -- a checked run
launched right after an ordinary run could silently reuse stale
unchecked fasls otherwise. `scripts/test-lispworks.lisp` (and, for
symmetry, `scripts/test-sbcl.sh`, where the var is a no-op since SBCL's
`FAST-AREF` expansion never varies) routes `ATARI800_CL_CHECKED_AREF`
runs to a separate `.cache/fasls-checked/` ASDF output-translation
directory instead of the ordinary `.cache/fasls/`, guaranteeing a
from-scratch recompile under the checked expansion every time and
never conflating the two caches. This is only an audit tool, not the
default posture -- SBCL is fully checked unconditionally on every run
regardless of this variable, and the ordinary (unchecked) LispWorks
build is what `./scripts/test-lispworks.sh` runs without it.

> **Exit-code gotcha:** `asdf:test-system` returns `T` even when tests
> *fail*, so it is useless for shell/CI exit codes. Always key the exit
> status off `fiveam:run!`, which returns `T` only when every check
> passes. The commands below do this (exit 0 = all pass, 1 = failure).

Legacy manual shell form for **SBCL** (`.sbclrc` loads Quicklisp before `--eval`; prefer `./scripts/test-sbcl.sh` for automation):
```sh
sbcl --non-interactive \
     --eval '(ql:quickload :atari800-cl/tests)' \
     --eval '(uiop:quit (if (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :atari800-cl-suite :atari800-cl/tests)) 0 1))'
```

Legacy manual shell form for **LispWorks** (the console image is `lw-console` in
`$PATH`; prefer `./scripts/test-lispworks.sh` for automation). Two LispWorks-isms matter here:
- Command-line `-eval` forms are *read* before the init file loads
  Quicklisp, so load `setup.lisp` first and defer non-CL symbols
  (`ql:`, `fiveam:`) with `read-from-string`.
- **Multiprocessing is initialized asynchronously at startup.** If
  `-eval` forms create threads before it's ready you get *"Cannot create
  processes before multiprocessing is initialized"* -- and **every
  threaded test (mailbox/run-loop, AESP/CLI servers, sockets) fails
  intermittently.** Run the suite inside `mp:initialize-multiprocessing`
  so threads are safe. (The REPL already runs under multiprocessing, so
  an interactive `(asdf:test-system ...)` is fine -- this only bites batch
  `-eval` runs.)
```sh
lw-console -eval '(mp:initialize-multiprocessing "ci" ()
                    (lambda ()
                      (load "~/quicklisp/setup.lisp")
                      (funcall (read-from-string "ql:quickload") :atari800-cl/tests)
                      (lw:quit :status
                        (if (funcall (read-from-string "fiveam:run!")
                                     (read-from-string "atari800-cl/tests::atari800-cl-suite"))
                            0 1))))'
```

Run a single FiveAM test by name:
```lisp
(fiveam:run! 'atari800-cl/tests::reset-loads-pc-from-vector)
```

Run a single test suite (e.g. just the CPU opcode tests):
```lisp
(fiveam:run! 'atari800-cl/tests::cpu-opcode-suite)
```
