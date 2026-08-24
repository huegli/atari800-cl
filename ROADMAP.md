# Roadmap -- EdVenture-first accuracy, rendering, and audio

> **Status (2026-08-02): Phases 1-5 done and committed to main** (suite
> green on both implementations throughout; benchmarked at each
> hot-path phase -- see `PERFORMANCE_LOG.md`). **Post-phase correction
> (2026-08-02):** Phase 5 originally rejected `SCANLINE_ACCURACY_PLAN.md`'s
> map-mode (8-14) byte table in favor of this project's own renderer --
> that call was backwards. The plan's table matched real hardware
> (each mode's pixel width x bits per pixel / 8); it was the RENDERER
> whose map-mode geometry was wrong (mode 8 drawn as 40 bytes of 1bpp
> instead of 10 bytes of 2bpp, mode E as 20 bytes instead of 40, etc.).
> A follow-up commit restored the hardware byte counts, fixed the
> renderer's map-mode geometry/colors to match, and made map modes
> fetch on the first scanline of a mode line only (ANTIC line-buffers
> them), per the Altirra Hardware Reference.
>
> **Phase 6 done (2026-08-02)**, three commits as planned: ANTIC P/M
> DMA into GTIA (double-line PMBASE masks #xFC, not this document's
> #xF8 -- 1K boundary per the Altirra HRM), full PRIOR priority via
> GTIA-owned playfield source tags (fifth player = missiles rendered
> as playfield 3, the atari800 model; multicolor OR; the priority
> orderings below still carry their CONFIRM flag), and the GTIA
> cleanups (PAL register now the $0F NTSC pattern; reset defaults
> deduped).
>
> **Phase 7 done (2026-08-03)**: GTIA color modes 9/10/11 render over
> ANTIC mode F, selected per scanline from PRIOR bits 6-7. Mode 10's
> nibbles 9-15 (clamped to COLBK) keep this document's CONFIRM flag.
> One limitation newly pinned by test: the 128-entry palette collapses
> mode 9's 16 luminances into 8 pairs -- the color bytes are
> hardware-correct, so a 256-entry palette would recover them.
>
> **Phase 8 done (2026-08-03)**: POKEY reload offsets (AUDF+4 at
> 1.79 MHz, +7 for linked pairs, AUDF+1 on the divided clocks) and
> linked 16-bit channels with the IRQ taken from the high channel.
> The period figures keep their CONFIRM flag -- implemented as this
> plan states them, recorded in `src/pokey.lisp`'s header.
> Phase 9 (POKEY audio synthesis) is next, and its frequencies now
> come out right the first time.
>
> **Phase 9 done (2026-08-03)**: `src/audio.lisp` synthesises four
> POKEY channels (poly4/5/9/17 distortion + volume-only mode) into
> mono 8-bit PCM at 44,744 Hz, attached on demand through function
> slots on the POKEY struct. Detached machines pay one slot read and
> branch per POKEY advance -- measured at ~4% on the `nop` workload
> (the maximum possible advance density: one advance per 2-cycle
> instruction) and within noise everywhere else, via an interleaved
> A/B against the pre-phase commit; see `PERFORMANCE_LOG.md`.
> **Phase 10 done (2026-08-03)**: AUDIO_PCM streams over the AESP audio
> port and `scripts/capture-audio.py` writes WAVs. Two deviations, both
> deliberate: the message code is the protocol's own `0x80` (this
> document's `#x85` was explicitly a fallback for "if the protocol
> defines none" -- `tools/protocol-comparison/protocol_spec.py` defines
> `AUDIO_PCM` = `0x80`), and the attach/detach decision is made by the
> post-frame hook on the emulator thread rather than in the
> subscribe path under the server lock, because acceptor threads must
> not touch the machine. Phase 11 (A/V recording tooling) is next.
>
> **Phase 11 done (2026-08-07)**: `scripts/record.sh` takes a `.asm` or
> `.xex` to an mp4 in one command; `scripts/capture-video.py` writes the
> numbered frame sequence and `scripts/aesp_client.py` now holds the
> protocol codec all three capture scripts share. `scripts/runner.lisp`
> also prints `AESP_AUDIO` -- the three ports are ephemeral and not
> adjacent, so recording needs it stated. Acceptance met: 300 frames of
> `asm/edvent02_rasterbars.asm` -> a 5.0 s 384x240 h264+AAC file;
> `--selftest` covers the 10-frame smoke case. Phase 12 (Tom Harte
> ProcessorTests harness) is next.
>
> **Phase 12 done (2026-08-07)**: `tests/test-harte.lisp` runs the
> SingleStepTests/65x02 vectors, env-gated on `ATARI800_CL_HARTE_TESTS`
> and skipping without them. It found three real CPU bugs, all fixed
> with regressions in `tests/test-regressions.lisp`: the unstable stores
> did not corrupt the destination address on a page cross, ARR ignored
> decimal mode, and JSR read its high operand byte before pushing rather
> than after (one case in 2.56M). XAA / LAX #imm now use the `$EE` magic
> constant the vectors encode, so the skip list stays EMPTY: all 256
> opcodes pass at full depth -- 2,560,000 cases, zero failures, on both
> implementations. That closes the original twelve-phase plan.
>
> **Next tranche added (2026-08-07): Phases 13-20.** With the EdVenture
> workflow shipped end to end (assemble -> boot -> capture -> mp4) and
> the CPU pinned by the Harte vectors, the emulator's remaining gaps are
> no longer about video content: the machine boots to BASIC but cannot
> be typed at, has no disk, and its bus-level timing is unverified.
> Phases 13-20 are ordered payoff-for-effort, not by theme; 13 is the
> recommended start (small, and it makes the machine interactive), 14
> and 15 are cheap hygiene, 16 is the next substantial feature.
>
> **Amended (2026-08-07) after a critique of the Phases 1-12 execution.**
> Ground rule 2 gains a strict gate (env-gated skips become failures on
> the machine that has the assets), rule 3 now prescribes
> `scripts/bench-ab.sh` (the interleaved A/B method that survived
> session drift, promoted from prose in `PERFORMANCE_LOG.md` to a
> command), and a new rule 9 makes the post-phase review and the
> cycle-ledger tests mandatory. Four phases appended: 21 (strict test
> gate + skip census), 22 (POKEY pending-work bitmask -- land BEFORE 13
> and 16a so their hooks join it), 23 (CONFIRM retirement), 24 (Acid800
> gate -- run before 17). Recommended order is now 21, 22, 13, 14/15/23,
> 24, 16, 17, then the rest as listed.
>
> **Phase 21 done (2026-08-11)**: `%SKIP-OR-FAIL` (`tests/test-helpers.lisp`)
> replaces the bare `SKIP` calls in the Klaus, Harte, and real-ROM boot
> tests; `$ATARI800_CL_STRICT=1` turns those skips into failures. Verified
> on this machine (Klaus binary and both ROM images present, no Harte
> checkout): lenient runs unchanged, strict runs execute and pass Klaus
> and both boot tests for real and fail only on the genuinely-absent Harte
> vectors, on both implementations. `RUN-TESTS` (`tests/test-suite.lisp`,
> now what both test scripts call) also prints a grep-able skip census
> after every run.
>
> **Phase 22 done (2026-08-14)**: `src/pokey.lisp` gains a `PENDING`
> fixnum consolidating the serial-transmitter and audio-attached checks
> (previously two independent slot reads on every `POKEY-TICK` /
> `POKEY-ADVANCE` call) into one slot read plus cheap `LOGTEST`s; bits 2
> and 3 are reserved for Phase 13's key-pending and Phase 16a's
> serial-rx. `POKEY-TICK-VS-ADVANCE-EQUIVALENCE` now runs the scripted
> 50,000-cycle comparison under all four bit combinations (neither,
> audio, serial, both), not just the all-zero case. Measured with the
> new `scripts/bench-ab.sh` against the pre-phase commit (rule 3):
> nothing regressed on either implementation; two clean improvements
> (LispWorks `nop` +8.5%, SBCL `audio` +8.9%), the rest positive but
> noisy at this sample size -- see `PERFORMANCE_LOG.md`.
>
> **Phase 13 done (2026-08-19)**: keyboard/BREAK IRQs claim `PENDING`
> bit 2 (`+POKEY-PENDING-KEY+`), set/cleared by `ATTACH-POKEY-INPUT`
> exactly like the audio bit -- a deliberate deviation from this
> document's literal "flag set through the input plumbing" wording (see
> the +POKEY-PENDING-KEY+ comment in `src/pokey.lisp`): having
> `INPUT-SET-KEY` write the bit directly would race the emulator
> thread's own clears of bits 0/1, a lost-update with no lock to stop
> it. The bit instead just gates whether `INPUT` is attached; the actual
> per-keystroke event lives in two new one-shot flags inside
> `INPUT-STATE`'s own lock (`INPUT-CONSUME-KEY-IRQ` /
> `-BREAK-IRQ`), drained every advance while attached -- safe because
> that only happens in real interactive use, never in a bench workload.
> `+IRQ-OTHER-KEY+` (`$40`) / `+IRQ-BREAK-KEY+` (`$80`) were confirmed by
> reading `TIRQ` in `Atari_XL_OS_Rev.2.asm` directly, not just taken
> from the plan; the plan's SKSTAT bit2/bit3 claim was checked the same
> way and turned out to be wrong -- the existing bit2-only
> implementation already matched the real OS's own VBI debounce logic
> (per `minimal-xl`'s documented phase 4), so `input-pokey-skstat` was
> left unchanged. The acceptance test (`REAL-OS-BOOTS-AND-TYPES-PRINT-2-
> PLUS-2`) types real POKEY key codes -- read from the OS's own TCKD
> table, verified empirically against the real ROM -- through an
> attached `INPUT-STATE` after booting to `READY`, and asserts `4`
> lands in screen memory once BASIC evaluates `PRINT 2+2`. Not
> benchmarked fresh: the new code path is strictly inside `PENDING`'s
> nonzero branch, gated by a bit no bench workload ever sets, so it is
> provably zero-cost in every measured workload by construction: a live
> `bench-ab.sh` attempt was abandoned when the host's load average hit
> 74 from unrelated activity.
>
> **Phase 14 done (2026-08-20)**: `scripts/fetch-harte.sh` fetches
> individual `<hex>.json` files straight from
> `raw.githubusercontent.com/SingleStepTests/65x02` rather than `git
> clone`ing the ~1 GB repository, into gitignored `.cache/harte/` by
> default; already-present files are skipped, so an interrupted or
> repeated run resumes rather than re-fetching. `--subset [N]` fetches
> a curated, priority-ordered list of up to 8 opcodes (~30 MB) chosen
> for addressing-mode diversity plus every illegal-opcode family this
> project's Harte triage has named -- including the three opcodes
> ($9C, $6B, $20) whose vectors found real bugs in Phase 12, listed
> first so a smaller N keeps the highest-value coverage. Verified
> end-to-end: a fetched 4-file subset round-tripped through both
> `./scripts/test-sbcl.sh` (green, skip census clean) and
> `ATARI800_CL_STRICT=1 ./scripts/test-sbcl.sh` (100% pass, 0 skip --
> the first time a strict run has gone fully green in this project's
> history, Harte included, on a machine with no full checkout). One
> deviation from the initial one-line xargs-based parallel-fetch
> attempt: `export -f` + `xargs -P` + `bash -c` proved fragile in this
> sandbox (functions leaking into stdout instead of the environment),
> so the script fetches sequentially instead -- simpler and more
> portable, at the cost of wall-clock time on a full 256-file fetch.
>
> **Phase 15 done (2026-08-20)**: `CLAUDE.md`'s "not modelled" list and
> Development Plan paragraph were both stale -- "keyboard scanning" and
> "the serial/SIO bus" as blanket unmodelled claims (Phase 13 modelled
> keyboard/BREAK IRQs; serial output has been modelled since before this
> tranche, only receive is still absent), and "Prompt 12's Unix-socket
> IPC layer was later removed" without ever mentioning the much larger
> AESP/CLI stack that replaced it and is now core to the project. Fixed
> both, and found two more drift items while re-verifying README.md's
> "Known limitations" against the code per the plan's own instruction:
> `README.md`'s feature list undersold host input (didn't mention IRQ
> delivery), and its unmodelled-features line still listed "paddles"
> alongside light pen even though paddles have been fully modelled since
> the AESP/CLI stage work. Also closed a CHANGES.md gap (the ANTIC modes
> 4/5 renderer fix, landed alongside the AESP video protocol fix, had no
> entry of its own) and swept for the plan's named renamed symbols
> (`flag-set?`, `run-cpu` with a memory arg,
> `+color-clocks-per-scanline+`) -- no live drift found; every hit was
> either the plan's own text or a historical record of the rename.
> `MISC_IMPROVEMENTS_PLAN.md` item 9 marked done.
>
> **Phase 23 done (2026-08-20)**: checked all three standing CONFIRM
> flags against the `atari800` emulator's own C source
> (`atari800/atari800` on GitHub). POKEY's reload offsets
> (`src/pokey.lisp`) and the PRIOR priority orderings
> (`src/renderer.lisp`) both CONFIRMED correct as implemented --
> `pokeysnd.c`'s reload code matches exactly, and hand-tracing
> `antic.c`'s `ANTIC_SetPrior` bit logic for each one-hot PRIOR byte
> reduces to the same four orderings already coded. GTIA mode 10's
> nibbles 9-15 were actually WRONG: the old code clamped every nibble
> above 8 to COLBK, but `antic.c`'s `DRAW_AN_GTIA10` lookup table shows
> 9-11 collapse to COLBK while 12-15 repeat COLPF0-3 -- a hardware
> quirk, not a clamp. Fixed (new `%GTIA-MODE10-REGISTER-OFFSET`); the
> existing test had pinned the wrong behavior and now asserts the
> correct one. No flag survives as a bare CONFIRM. Verified on both
> implementations, lenient and strict (with the Phase-14-fetched Harte
> subset): 2112 checks, 0 fail, 0 skip, exit 0 -- fully green including
> Harte.
>
> **Phase 24 done (2026-08-20)**: `scripts/fetch-acid800.sh` fetches
> Avery Lee's MIT-licensed Acid800 suite (a 216 KB 7z from
> virtualdub.org) and unpacks the 7 CPU + 13 ANTIC standalone `.xex`
> tests into gitignored `roms/acid800/`. `tests/test-machine.lisp`
> boots the real OS to READY, injects each test via the existing
> XEX-loading mechanism (`scripts/xex-loader.lisp`, loaded dynamically),
> and reads its "Pass"/"FAIL" text back from screen memory. One real bug
> found and fixed: ANTIC offsets $06/$08 have no backing register on
> real hardware and should float to $FF on read; this emulator returned
> $00 (`antic_default`). The other 12 failures are documented, permanent
> skips in `+ACID800-KNOWN-ISSUES+` (mirrors `+HARTE-SKIP-OPCODES+`) --
> `antic_wsync`/`antic_dmapattern`/`antic_dlitiming` directly confirm the
> already-documented WSYNC-cycle-105 and DMA-steal-position
> simplifications; `antic_dlistwrap` confirms the VBI display-list
> re-latch gap (Phase 20); `cpu_illegal` confirms the Tom Harte vectors'
> `$EE` LAX #imm constant disagrees with Acid800's own (both are real
> chips; ROADMAP Phase 12's choice to follow Harte stands); `cpu_bugs`
> is a newly-confirmed architectural gap (a concurrent NMI cannot hijack
> a BRK's vector, because this CPU core checks pending-NMI only between
> whole instructions); `cpu_clisei` is the suite's own self-skip; four
> ANTIC tests (`antic_vcount`, `antic_pmdma`, `antic_charcontrol`,
> `antic_hiresbug`) fail for reasons not yet isolated. README.md's Known
> Limitations gained bullets for all of the newly-confirmed items.
> Verified fully green on both implementations, lenient and strict, with
> the Phase-14 Harte subset present: 2135 checks, 2122 pass, 13 skip
> (all named/reasoned), 0 fail, exit 0. Phase 16 (SIO + virtual disk) is
> next per the recommended order.
>
> **Phase 16 done (2026-08-20)**, the revised host-disk-bridge plan, in
> four commits: "Host bridge: bridge device + ATR disk images (16a+16b)",
> "Host bridge: XEX/OBX loading (16d)", "Host bridge: mount API +
> protocol (16e)", and this integration pass (16c's minimal-xl side
> landed independently in the submodule at commit `446eb6a`, "Phase 15 -
> SIOV host-bridge fast path"; this repo's pointer bump is part of this
> commit). `src/hostdev.lisp`'s `$D1xx` bridge (16a/16b, already done)
> plus `src/xex.lisp`'s in-memory XEX/OBX-to-ATR synthesis (16d) plus the
> facade/AESP/CLI mount surface (16e) all landed green individually; this
> pass wired minimal-xl's own `SIOV` probe in and proved the whole chain
> boots real software. `tests/test-machine.lisp`'s acceptance tests --
> `HOSTDEV-BOOTS-MINIMAL-XL-AND-REACHES-EDVENTURE` (ATR mount) and
> `HOSTDEV-LOAD-XEX-BOOTS-MINIMAL-XL-AND-REACHES-EDVENTURE` (`LOAD-XEX`,
> no `.atr` file at all) -- both passed on the first real run: minimal-xl's
> OS ROM cold-boots, its cold-start's unconditional disk-boot attempt
> (`RST5`/`BTD`) finds the bridge signature at `$D1FE`, the DCB write to
> `$D1FF` executes instantly, `xexboot.bin`'s loader streams edventure's
> segments in through `DSKINV`, and the CPU ends up executing inside
> edventure's own $8000-$BFE0 address range (read directly from
> `edventure.obx`'s segment headers via `%OBX-SEGMENT-RANGE`, so the
> check needs no `.lab` file) well within the frame budget. No emulator
> bug needed fixing -- the bridge's DCB dispatch (16a) and ATR sector
> mapping (16b) were exercised end to end exactly as written. Verified
> fully green on both implementations: lenient 2362 pass / 14 skip
> (Harte plus the 13 already-named Acid800 items) / 0 fail; strict (with
> `minimal-xl/` assets present, `$ATARI800_CL_HARTE_TESTS` still unset)
> 2362 pass / 13 skip / 1 fail, the pre-existing `HARTE-PROCESSOR-TESTS`
> exception only. Phase 25 (SIO receive path + serial-wire disk) can
> reuse this bridge's ATR/XEX plumbing as one implementation alongside a
> real serial model, per that phase's own notes.
>
> **Phase 17 done (2026-08-20)**, four commits: the trace-comparison
> harness itself (`62c9510`), the two NMOS bus quirks it specified --
> "CPU: RMW double-write (unmodified value first)" (`17e8600`) and "CPU:
> indexed-addressing dummy reads at the un-carried address" (`5a7e987`,
> which grew to cover the whole family of previously-unmodelled dummy
> reads the full corpus exposed, not only indexed addressing) -- and
> dropping the `ATARI800_CL_HARTE_TRACE` gate now that both are in. The
> full 2,560,000-case corpus passes the complete cycle-by-cycle trace
> comparison on both SBCL and LispWorks, and `ATARI800_CL_STRICT=1` runs
> are fully green on both -- zero failures. Acid800's known-issues list
> (Phase 24) is unchanged: none of `cpu_bugs` or the four unisolated
> ANTIC failures were caused by these quirks. `SCANLINE_ACCURACY_PLAN.md`
> Phase 5 items 1-2 are done; items 3-5 remain open. See `CHANGES.md`
> and `PERFORMANCE_LOG.md` for the full writeup, including the accepted
> hot-path cost of the dummy-read commit.
>
> **Phase 18 done (2026-08-20)**: profiled LispWorks first (per this
> phase's own amendment), then SBCL, on the `nop`/`irq`/`display`/`audio`
> benchmark workloads via a new `with-profiling`-wrapped scratchpad
> driver (thousands of samples per run). The profile named something the
> plan's own candidate list didn't: on `nop`/`irq`, `POKEY-ADVANCE` is
> the single largest self-time cost on BOTH implementations, but far
> more disproportionately on LispWorks (69%/49% inclusive on
> nop/irq) than SBCL (36%/29%) -- and LispWorks' breakdown showed the gap
> concentrated in `SYSTEM::AREF1`/`SYSTEM::SET-AREF1`/
> `SYSTEM:SVREF-NO-CHECK$I-VECTOR$FIXNUM`, LispWorks' generic,
> runtime-dispatching array accessors. `src/pokey.lisp`'s hot array slots
> (`SUB-COUNTERS`, `TIMER-COUNTS`, `AUDF`) already carry defstruct `:type
> (simple-array fixnum (4))` declarations, so as the plan's step 3
> anticipates for "struct accessor dispatch," the follow-up added
> explicit local `(simple-array fixnum (4))` type declarations at every
> hot AREF/SETF-AREF site in `%EXPIRE-CHANNEL`, `POKEY-TICK`,
> `POKEY-ADVANCE`, and `%TIMER-RELOAD-VALUE`. `scripts/bench-ab.sh` (5
> pairs, both implementations) showed no separation from noise on any
> workload, and disassembling `POKEY-ADVANCE` before/after the change
> showed byte-identical `AREF1`/`SET-AREF1` call counts (30/12) -- the
> declaration provably changed nothing. An isolated microbenchmark
> pinned why: on this LispWorks 8.1.1 ARM64 build, `(aref (the
> (simple-array fixnum (4)) arr) i)` compiles to an out-of-line call to
> `SYSTEM::AREF1` at `(safety 1)` regardless of how precisely the type is
> declared, and only inlines to a direct bounds-checked load at `(safety
> 0)`; SBCL's ARM64 backend inlines the same bounds-checked access at
> `(safety 1)` (confirmed by disassembly on both). `src/renderer.lisp`'s
> framebuffer accesses, which already carry equivalent explicit
> declarations, show the identical dispatch pattern in the LispWorks
> `display` profile (`SET-AREF1` alone was 37% self time) -- corroborating
> that this is systemic, not a POKEY-specific oversight. Since
> CLAUDE.md's safety floor (`(safety 1)` minimum, `(safety 0)` nowhere)
> forecloses the one compiler lever that changes this, the change was
> reverted rather than committed (`src/pokey.lisp` is unchanged from
> `3017eaa`) and the gap is documented rather than chased, per this
> phase's own suggested framing. The plan's other listed candidates
> (`update-zn` flag traffic, opcode-handler `multiple-value-bind`
> overhead, bus-closure `:type function` declarations) are non-issues:
> none appears as a separable hot function in either profile, and the
> bus closures already carry `:type (or null function)` from Phase 1.
> Post-pass numbers (mean of 3, same machine): SBCL `nop` ~2850 fps
> (~47.6x NTSC realtime); LispWorks `nop` ~769-857 fps (~12.8-14.3x
> realtime) depending on in-session warmth -- LispWorks runs at roughly
> 27-30% of SBCL's throughput, essentially unchanged from this phase's
> opening `~950 vs ~3550` framing (absolute numbers drift session to
> session; the ratio is the stable quantity). See `PERFORMANCE_LOG.md`
> for the full per-workload profile tables and disassembly evidence.
>
> **Phase 19 done (2026-08-23)**: widened `+atari-rgb-palette+` from 128
> entries indexed by `(color >> 1)` to 256 entries indexed directly by
> the color byte, so luminance is the full 4-bit field instead of 3 bits
> with bit 0 discarded. The Y-per-step formula (13 per luminance step,
> base 8) was chosen so every even luminance reproduces the old table's
> RGB exactly, keeping every existing caller (which only ever writes
> bit-0-clear color bytes) unchanged. GTIA mode 9's 16 nibble values now
> render 16 distinct luminances instead of collapsing into 8 pairs;
> `GTIA-MODE-9-LUMINANCE-PAIRS-COLLAPSE` is replaced by
> `GTIA-MODE-9-RECOVERS-16-LUMINANCES`. See `CHANGES.md` for the full
> writeup.
>
> **Phase 20 done (2026-08-23)**: documentation only, per
> `MISC_IMPROVEMENTS_PLAN.md` item 10. Added an honest comment block in
> `src/antic.lisp` at the VBI re-latch (`%BEGIN-SCANLINE-EVENTS`) and the
> DLISTL/DLISTH write cases (`ANTIC-WRITE`) describing how this
> emulator's re-latch-every-VBI model diverges from hardware's
> JVB-gated latch, cross-referencing `SCANLINE_ACCURACY_PLAN.md` Phase 4+
> where changing the behaviour belongs and `ACID800-ANTIC-DLISTWRAP` as
> the test that already exercises the divergence. No behavioural change.

A complete, ordered execution plan covering the four open work streams:
scanline accuracy (WSYNC, DMA stealing), renderer fidelity (P/M DMA,
priority, GTIA modes), POKEY audio synthesis + streaming, and the
miscellaneous hardening items. Ordered for the **EdVenture video
workflow**: the near-term goal is producing assembly-programming video
content, so phases that unlock visible/audible demo material (raster
effects, correct visuals, sound, A/V capture) come before pure
correctness ratchets.

This plan is written to be executed phase-by-phase by an AI coding
agent without further design input. Each phase states its goal, exact
steps, tests, verification commands, and commit message. Where a
hardware number is marked **CONFIRM**, cross-check it against the
Altirra Hardware Reference Manual or the atari800 emulator source if
possible; if you cannot verify it, implement the value as stated here
and say so in the commit message.

## Ground rules (apply to every phase)

1. Read `CLAUDE.md` first. Key constraints: no reader conditionals
   outside `src/compat.lisp`; `defstruct` over `defclass`; verbose
   docstrings on exported symbols; the `.asd` is `:serial t` so file
   order matters.
2. After every phase run BOTH `./scripts/test-sbcl.sh` and
   `./scripts/test-lispworks.sh`. Both must exit 0 before committing.
   The suite currently passes 2058 checks plus 1 skip on both (the skip
   is the Harte test with no vector data present; 2315 checks with it).
   Once Phase 21 lands, also run `ATARI800_CL_STRICT=1
   ./scripts/test-sbcl.sh` on this machine: strict mode turns the
   env-gated skips (Klaus, Harte, real-ROM boot, later the ATR boot and
   typing tests) into failures, so a phase cannot go green while the
   tests that need local assets silently skip. Sandbox and CI runs stay
   lenient; the strict run is the done-gate on the machine that rule 8
   says has the ROMs.
3. **Benchmark rule**: any phase touching the hot path
   (`src/machine.lisp` `%run-clocks`, `src/antic.lisp` scanline events,
   `src/pokey.lisp` tick/advance, `src/renderer.lisp` per-line work)
   must measure with `./scripts/bench-ab.sh <pre-phase-ref>`, which
   builds the baseline in a git worktree and INTERLEAVES baseline and
   working-tree runs (B-A-B-A) so session drift hits both sides
   equally, then add its paired-delta table plus a short note to
   `PERFORMANCE_LOG.md`. Treat a delta as real only when the runs
   separate cleanly (every A run on one side of every B run -- the
   script reports CLEAN/MIXED per workload); absolute fps values are
   comparable only within one bench-ab session, so do not extend the
   longitudinal table at the top of the log. (The old
   three-runs-before/three-after method is retired: session drift
   defeated it twice -- see the log's Phase 9 and Phase 12 notes.)
   Phases 3, 5, 6, and 9 were the original tranche's hot-path phases;
   of the open work, 18 and 22 are.
4. Each phase gets a `CHANGES.md` entry at the TOP of the file (the log
   is newest-first) and updates the status header of whichever plan
   document it advances (`SCANLINE_ACCURACY_PLAN.md`,
   `MISC_IMPROVEMENTS_PLAN.md`, this file).
5. Commit per phase (or per sub-item where a phase lists multiple
   commits) directly on `main` with the stated commit message. Never
   push unless the user asks.
6. New timing/rendering behaviour gets a FiveAM test in the matching
   `tests/test-*.lisp` child suite; concrete bug fixes also get a
   regression test in `tests/test-regressions.lisp`.
7. If a Lisp file fails to compile with an unmatched-parenthesis style
   error, diagnose with a paren-counting script (walk the file counting
   depth per top-level form) BEFORE re-running the full suite -- do not
   guess-and-rerun.
8. ROM images live in `roms/` (gitignored). `ATARIXL.ROM`,
   `ATARIBAS.ROM`, and `6502_functional_test.bin` are already present
   on this machine.
9. **Review rule**: after the suite is green and before a phase is
   declared done, review the phase's full diff against hardware
   references and first principles -- the plan text is itself under
   review, not the standard to review against. A plan sentence that
   asserts emulator-bookkeeping semantics ("clamping to 0 is
   deliberate", "X cannot happen here") is a claim with the same
   standing as a CONFIRM-flagged hardware number: verify it or pin it
   with a test before trusting it. Any phase touching `%run-clocks` or
   cycle accounting must include at least one ledger test asserting an
   exact cycle total over a multi-line window, computed on paper, not
   recorded from a run of the code. (Precedent: the Phases 1-5 review
   caught the WSYNC clamp forgiving a budget deficit -- commit 21e6749
   -- after this plan had specified that clamp as deliberate.)

## Phase overview and dependencies

| Phase | Title                                        | Depends on | Hot path | Status |
|-------|----------------------------------------------|------------|----------|--------|
| 1     | Cheap hardening batch (4 small commits)      | --          | no       | done   |
| 2     | Rename: color clocks -> CPU cycles            | --          | no       | done   |
| 3     | WSYNC ($D40A)                                | 2          | yes      | done   |
| 4     | Raster-bars demo + rendered acceptance test  | 3          | no       | done   |
| 5     | Playfield DMA steal tables                   | 3          | yes      | done   |
| 6     | P/M DMA, full priority, GTIA cleanups        | --          | yes      | done   |
| 7     | GTIA modes 9/10/11                           | 6          | no       | done   |
| 8     | POKEY timer fidelity                         | --          | no       | done   |
| 9     | POKEY audio synthesis core                   | 8          | yes      | done   |
| 10    | AESP audio streaming + WAV capture           | 9          | no       | done   |
| 11    | A/V recording tooling (`record.sh` -> mp4)    | 4, 10      | no       | done   |
| 12    | Tom Harte ProcessorTests harness             | --          | no       | done   |
| 13    | POKEY keyboard IRQ (typing into BASIC)       | 22         | no       | done   |
| 14    | `fetch-harte.sh` + fast subset gate          | 12         | no       | done   |
| 15    | Documentation drift sweep (misc item 9)      | --          | no       | done   |
| 16    | Host disk bridge + virtual disk (revised)    | 21         | no       | done   |
| 17    | Harte bus-trace comparison                   | 12         | yes      | done   |
| 18    | LispWorks profiling pass                     | --          | yes      | done   |
| 19    | 256-entry palette (GTIA mode 9 luminances)   | 7          | no       | open   |
| 20    | ANTIC display-list latch note (misc item 10) | --          | no       | open   |
| 21    | Strict test gate + skip census               | --          | no       | done   |
| 22    | POKEY pending-work bitmask                   | --          | yes      | done   |
| 23    | CONFIRM retirement pass                      | --          | no       | done   |
| 24    | Acid800 gate (CPU + ANTIC subsets)           | 21         | no       | done   |
| 25    | SIO receive path + serial-wire disk          | 13, 16, 22 | no       | deferred |
| 26    | LispWorks fast-path array access             | 18         | yes      | done   |
| 27    | Idle benchmark workloads (idle, serve)       | --          | no       | done   |
| 28    | AESP push economics (gate, reuse, dedup)     | 27         | yes      | done   |
| 29    | Dirty-frame render skip (conditional)        | 27, 28     | yes      | open   |
| 30    | Deferred POKEY advance                       | 27         | yes      | done   |
| 31    | Spin-loop fast-forward (conditional, opt-in) | 28, 30     | yes      | open   |

Phases 6/7/8 are independent of 3/5 and can be reordered if blocked.
Phase 12 is independent of everything and can run any time; it is last
of the original tranche only because it produces no video-visible
payoff.

Of the 13-20 tranche, only the original 16 depended on another new
phase (13's interrupt plumbing, for the serial-receive plan now
deferred to 25); the revised 16 (host disk bridge) needs only Phase
21's strict gate for its boot test. 17 is
what turns SCANLINE_ACCURACY_PLAN.md's stretch Phase 5 from guesswork
into a checkable target, so run it before attempting those quirks.

The 21-24 amendments adjust the recommended order: 21 first (it makes
the real-ROM tests un-skippable on this machine before the phases that
lean on them), 22 before 13 and 25a (their per-advance POKEY hooks
join the bitmask instead of adding two more branch tests to the hot
path -- the Phases 1-12 pattern was one such test per feature, each
individually measured and shrugged at), 24 before 17 (Acid800's ANTIC
subset is the first external check the Phase 5 steal tables and Phase
3 WSYNC have ever faced; 17 deepens the CPU's already-strongest
evidence), and 23 alongside 14/15 as hygiene.

---

## Phase 1 -- Cheap hardening batch

Four small, independent fixes from `MISC_IMPROVEMENTS_PLAN.md` (its
items 1, 2, 8, 3). One commit each, in this order. Full step-by-step
detail lives in that plan -- follow it exactly; summary:

1. **Opcode-table reload robustness** (misc item 1): eliminate
   `*opcode-table-builder*` (`src/cpu-opcodes.lisp:252`); make
   `*opcode-table*` and `*opcode-mnemonic-table*` load-time `defvar`s
   in `src/cpu.lisp`; `DEFOPCODE` writes `(setf (svref *opcode-table*
   op) ...)` directly. Test: all 256 slots non-NIL after load; 151
   documented + 105 illegal via the existing introspection functions.
   Commit: "Install opcodes directly into *OPCODE-TABLE*; drop the builder".
2. **Reset flag consistency** (misc item 2): `machine-cold-reset` sets
   P to `#x34`; change to `#x24` to match `reset-cpu` (B is not a real
   register bit). Grep `#x34` in `tests/` and update. Test: flags equal
   `#x24` after both reset paths.
   Commit: "Cold reset sets P to #x24, matching RESET-CPU".
3. **LispWorks `chmod-file` via FLI** (misc item 8): replace the
   `/bin/chmod` shell-out in `src/compat.lisp` with an
   `fli:define-foreign-function` following the existing `%getpid` /
   socket FLI style in the same file. Test in `tests/test-compat.lisp`.
   Commit: "compat: chmod-file via FLI on LispWorks".
4. **`scripts/fetch-test-roms.sh`** (misc item 3): download
   `bin_files/6502_functional_test.bin` from the
   Klaus2m5/6502_65C02_functional_tests GitHub repo into `roms/`
   (skip with a message if already present), echo a checksum, note the
   license. Document in `CLAUDE.md`'s test section.
   Commit: "Add fetch-test-roms.sh for the Klaus functional test binary".

Done when: suite green on both implementations after each commit; four
commits on main; `MISC_IMPROVEMENTS_PLAN.md` gets a status header
(like the other plans') marking items 1, 2, 3, 8 done.

---

## Phase 2 -- Rename: color clocks -> CPU cycles

`SCANLINE_ACCURACY_PLAN.md` Phase 0, previously skipped. The 114-unit
the code calls "color clocks" is actually CPU cycles (a real NTSC line
is 228 color clocks = 114 CPU cycles); hardware docs quote CPU cycle
numbers 0-113, and Phases 3-5 will start using them.

1. Rename `+color-clocks-per-scanline+` -> `+cpu-cycles-per-scanline+`
   (defined in `src/antic.lisp`, exported via `src/package.lisp`).
   Grep for every use: `src/antic.lisp`, `src/machine.lisp` (the
   `%run-clocks` line loop), `tests/test-antic.lisp`,
   `tests/test-regressions.lisp`, possibly `src/renderer.lisp` and
   `scripts/bench.lisp`.
2. Rename the `antic` struct slot `color-clock` -> `line-cycle`
   (accessor `antic-color-clock` -> `antic-line-cycle`; update
   `src/package.lisp` exports and all callers -- note `antic-tick` and
   its callers/tests use it).
3. Sweep comments/docstrings in `antic.lisp`, `machine.lisp`,
   `main.lisp` that say "color clock" for the 114-unit; reword as
   "CPU cycles (114 per line; a real line is 228 color clocks at twice
   the CPU rate)". Keep `+clocks-per-frame+` = 29,868 but fix its
   docstring.
4. Update the stale wording in `CLAUDE.md` and `README.md` ("29,868
   NTSC color clocks" -> "29,868 CPU clock cycles").

Pure rename: no behaviour change, no benchmark needed. Suite must be
green untouched (check counts stay 1450/1450).
Commit: "Rename ANTIC's line unit from color clocks to CPU cycles".
Update `SCANLINE_ACCURACY_PLAN.md` status header: Phase 0 done.

---

## Phase 3 -- WSYNC ($D40A)  [hot path -> benchmark]

`SCANLINE_ACCURACY_PLAN.md` Phase 2, adapted to the merged scanline
scheduler. The single most important register for raster effects;
every DLI handler starts with `STA WSYNC`. Semantics: a write halts
the CPU until cycle 105 of the current line; THIS phase stalls to
end-of-line (the 105-cycle refinement belongs to the plan's Phase 4).

1. `src/antic.lisp`: add struct slot `wsync-pending` (boolean,
   default NIL). In `ANTIC-WRITE`, add a `+reg-wsync+` case ($0A,
   mirrored across $D4xx -- the offset constant already exists) that
   sets it. Add and export `ANTIC-CONSUME-WSYNC (antic)` --
   read-and-clear, returns the old value. Clear the slot in
   `reset-antic`.
2. `src/machine.lisp` `%run-clocks`: inside the per-line instruction
   loop, after each successful `step-cpu` (and its `pokey-advance`),
   check `(antic-consume-wsync antic)`; if true, `(setf cpu-budget 0)`
   and terminate the inner instruction loop for this line. The
   existing "top POKEY up to exactly this line's cycle count" step
   already advances POKEY through the stalled remainder -- verify that
   and say so in a comment. Clamping `cpu-budget` to 0 (not merely
   subtracting) is deliberate: real WSYNC freezes the CPU regardless
   of any budget surplus carried from previous lines; do not let
   surplus leak past the stall. Document in the `%run-clocks`
   docstring.
3. Note in a comment: WSYNC via read-modify-write instructions
   (`DEC WSYNC` double-write) is out of scope until the NMOS bus-quirk
   phase; `antic-tick` (the per-cycle reference path) does NOT consume
   WSYNC -- scheduler-only behaviour, documented at
   `antic-consume-wsync`.

Tests (`tests/test-antic.lisp` unit + `tests/test-regressions.lisp`
machine-level):
- Unit: `antic-write` to $D40A sets the flag; `antic-consume-wsync`
  returns T then NIL; `reset-antic` clears it.
- Machine-level (use `%make-synthetic-os-rom` + `%poke` from
  `tests/test-helpers.lisp`): reset code `STA $D40A` then `STA $00`
  (bytes `8D 0A D4  85 00`, with A pre-loaded non-zero via `LDA #$xx`
  first). Run exactly one scanline via `%run-clocks` (114 cycles);
  assert RAM $00 unchanged (CPU stalled after the WSYNC store). Run
  one more line; assert the marker was written.
- Back-to-back `STA WSYNC / STA WSYNC`: the second stalls to the NEXT
  line's end (assert a following marker write lands only after the
  second extra line).

Benchmark before/after (rule 3); expect ~ neutral (one flag check per
instruction). Log rows + note in `PERFORMANCE_LOG.md`.
Commit: "Implement WSYNC: CPU stalls to end of scanline".
Update `SCANLINE_ACCURACY_PLAN.md` status: Phase 2 done.

---

## Phase 4 -- Raster-bars demo + rendered acceptance test

The EdVenture payoff for Phase 3: a classic WSYNC raster-color demo,
verified end-to-end through the real renderer, providing camera-ready
material and pinning WSYNC + per-line rendering together.

1. `asm/edvent02_rasterbars.asm` (MADS syntax; follow
   `asm/hello.asm` / `asm/edvent01.asm` house style and the XEX
   conventions used there). Program outline (self-contained, no OS
   calls -- the XEX runner loads it and jumps to its run address):
   - Disable IRQs (`SEI`), set up a display list of blank lines +
     ~100 mode-2 or blank lines + JVB in low RAM; point DLISTL/H
     ($D402/3) at it; DMACTL ($D400) = $22.
   - Main loop: wait for VCOUNT ($D40B) to reach the top of the active
     region, then a tight loop of ~64 iterations: `STA $D40A` (WSYNC),
     write an incrementing color value to COLBK ($D01A), `INC` the
     value (adding 16 per line cycles the hue), repeat. Then loop
     forever.
2. Build + run + capture:
   `./scripts/mads-build.sh asm/edvent02_rasterbars.asm` then
   `./scripts/atari-run.sh <xex> -frames 30 -o /tmp/rasterbars.png`
   (check the scripts' actual flag spellings first -- see their usage
   headers). The PNG must show horizontal color bands.
3. Automated acceptance (this is the committed test, the PNG check is
   manual): add a regression test that pokes an equivalent machine-code
   loop into RAM via `%poke` (WSYNC + COLBK increment per line), runs
   one frame with a framebuffer attached (see
   `tests/test-renderer.lisp` for how the renderer tests construct
   machine + framebuffer), and asserts >= 32 consecutive active rows
   whose row-color (sample pixel x=0, the border/background column)
   differs from the previous row's. This fails if WSYNC stops
   stalling, if the render callback fires at the wrong time, or if
   per-line register latching breaks.
4. Add a short "Raster effects" example paragraph to `README.md`
   pointing at the asm file and the run command.

Commit: "Add WSYNC raster-bars demo and rendered acceptance test".

---

## Phase 5 -- Playfield DMA steal tables  [hot path -> benchmark]

`SCANLINE_ACCURACY_PLAN.md` Phase 3, verbatim -- follow that plan
section's five numbered steps, its bytes-per-line table, its test
list, and its guard rails. Summary of what lands:

- `PLAYFIELD-DMA-CYCLES (mode-byte dmactl first-line-p)` pure function
  + data tables in `src/antic.lisp` (narrow/normal/wide from DMACTL
  bits 0-1; text modes fetch names on the first line of a mode line
  and font bytes every line; map modes fetch data on the first line
  only -- table values marked CONFIRM in the plan).
- DL instruction fetch cost charged (1 cycle + 2 for LMS operand + 2
  for JMP/JVB operand) -- `process-dl-instruction` already knows the
  byte count.
- Wired into `%begin-scanline-events` so BOTH the scheduler and
  `antic-tick` see identical steals; steal clamped/asserted < 114.
- The frame-budget regression test from the plan (24 mode-2 lines +
  JVB, DMACTL $22, assert total CPU cycles in the computed band) --
  this pins the whole model.

Extra care (post-renderer): the renderer's screen-pointer advancement
in `%end-scanline-events` and this phase's fetch accounting both key
off mode/first-line state -- keep them consistent; add one test that a
24-line mode-2 frame still renders the same pixels after this phase
(render a frame before/after is not possible in one test -- instead
assert the renderer test suite is untouched and add a
mode-2-with-DMA-steal render test).

Klaus workload note: heavier steal per line means fewer CPU cycles per
frame; the `klaus` bench workload's frame count may need adjusting
(see the `PERFORMANCE_LOG.md` scanline-scheduler note for precedent --
same total instruction count, more frames). Update `scripts/bench.lisp`
if the Klaus run stops PASSing purely due to frame count.

Benchmark + log (expect a further "speedup" that is really the CPU
getting fewer cycles/frame -- note it as the scheduler note did).
Commit: "Model ANTIC playfield and display-list DMA cycle stealing".
Update `SCANLINE_ACCURACY_PLAN.md` status: Phase 3 done.

---

## Phase 6 -- P/M DMA, full GTIA priority, GTIA cleanups  [hot path -> benchmark]

Makes player/missile graphics work the way real programs use them
(ANTIC-fetched, not just poked GRAF registers) and finishes the
priority model. Three commits.

**6a -- ANTIC -> GTIA P/M DMA data path.**
Currently ANTIC accounts P/M DMA *cycles* but never fetches the data;
the renderer reads only the GRAFP/GRAFM registers the program poked.
Real hardware: when DMACTL ($D400) bit 3 (players) / bit 2 (missiles)
is set AND GRACTL ($D01D) bit 1 (players) / bit 0 (missiles) enables
receive, ANTIC fetches one byte per object per line and delivers it to
GTIA's GRAF registers.
1. Addressing (**CONFIRM** against Altirra/atari800): base =
   `(ash (logand pmbase #xF8) 8)` from PMBASE ($D407). DMACTL bit 4
   selects resolution: single-line (bit 4 = 1): missiles at
   base+768+scanline, player p at base+1024+256*p+scanline;
   double-line (bit 4 = 0): missiles at base+384+(scanline>>1),
   player p at base+512+128*p+(scanline>>1). Mask addresses to 16
   bits.
2. Implement `%fetch-pm-graphics (antic)` in `src/antic.lisp`, called
   from `%begin-scanline-events` during the active region when the
   DMACTL bits are set; it needs the GTIA -- chips don't reference each
   other's packages (see `CLAUDE.md` bus design), so follow the
   existing closure pattern: give ANTIC a `pm-write-fn` function slot
   that `machine.lisp` wires to a closure storing into the GTIA's
   write-register array (GRAFP0-3 offsets $0D-$10, GRAFM $11), gated
   on GRACTL bits inside the closure. Wire it in `make-atari-machine`.
3. Tests (`tests/test-antic.lisp` + `tests/test-gtia.lisp`): poke a
   recognizable byte pattern into P/M RAM, enable DMACTL+GRACTL, run
   `antic-begin-scanline` on a known scanline, assert the GRAF
   registers; assert no delivery when GRACTL is clear (cycles still
   stolen -- that's DMACTL's job); double-line uses scanline>>1.
Commit: "ANTIC fetches P/M graphics into GTIA when DMA is enabled".

**6b -- Full P/M <-> playfield priority.**
Replace `%render-pm-layer`'s simplification (`src/renderer.lisp:348`,
which skips P/M entirely when PRIOR bit 1 is set). Implement PRIOR
($D01B / GTIA write offset $1B... use the existing `+w-prior+`
constant) properly:
1. Priority select bits 0-3 (exactly one normally set -- **CONFIRM**
   the four orderings against Altirra/atari800 `gtia.c`; the standard
   table, top priority first:
   - PRIOR bit 0: P0 P1 P2 P3 PF0 PF1 PF2 PF3 BAK
   - PRIOR bit 1: P0 P1 PF0 PF1 PF2 PF3 P2 P3 BAK
   - PRIOR bit 2: PF0 PF1 PF2 PF3 P0 P1 P2 P3 BAK
   - PRIOR bit 3: PF0 PF1 P0 P1 P2 P3 PF2 PF3 BAK).
   The renderer must therefore know WHICH playfield register produced
   each pixel, not just its color: have the playfield renderers
   (`%render-char-mode`, `%render-bitmap-mode`) also fill a per-row
   scratch array of source tags (BAK/PF0-3), stored in a new slot on
   the framebuffer-owning struct or passed down from
   `render-scanline`; then `%render-pm-layer` arbitrates per pixel.
2. Bit 4: fifth player -- the four missiles combine into one "player"
   colored COLPF3 instead of their player's color.
3. Bit 5: multicolor players -- overlapping P0/P1 (and P2/P3) OR their
   color registers.
4. Bits 6-7 (GTIA modes) are Phase 7; leave a `;; Phase 7` comment.
5. Tests (`tests/test-renderer.lisp`): one test per priority ordering
   (poke a player over a playfield pixel, assert which color wins);
   fifth-player; multicolor OR.
Commit: "Renderer: full PRIOR priority, fifth player, multicolor players".

**6c -- GTIA register cleanups** (misc items 6 + 7): verify the PAL
register value against atari800 `gtia.c` (`$0F`-pattern for NTSC --
**CONFIRM**); dedupe `%make-gtia-read-regs` / `reset-gtia` defaults
into one `%init-read-regs` helper; test the documented NTSC value.
Commit: "GTIA: correct PAL register encoding; dedupe reset defaults".

Benchmark after 6a (per-line fetch work) + log.
Update `MISC_IMPROVEMENTS_PLAN.md` status: items 6, 7 done.

---

## Phase 7 -- GTIA modes 9/10/11

The GTIA color modes (16 luminances / 9 colors / 16 hues), selected by
PRIOR bits 6-7 on top of an ANTIC mode F fetch. Used by many demos and
paint programs; visually striking -> good video material.

1. In `render-scanline` (`src/renderer.lisp`), read PRIOR bits 6-7:
   0 = normal, 1 = mode 9, 2 = mode 10, 3 = mode 11 (**CONFIRM**
   mapping: bit6=1&bit7=0 -> 9? -- check atari800 `gtia.c`; get this
   right before coding the dispatch).
2. When a GTIA mode is active and the ANTIC mode is F: each screen
   byte holds two 4-bit nibbles; each nibble is one wide pixel (4
   output columns at our 320-px playfield scale -> 80 wide pixels).
   - Mode 9: nibble = luminance; hue from COLBK's hue bits. Output
     color byte: `(logior (logand colbk #xF0) (ash nibble 1))` --
     verify against the palette function's bit layout (hue bits 7-4,
     luminance bits 3-1) and adjust so nibble 0-15 maps onto the 8
     luminance levels sensibly (nibble's low bit lands in bit 0,
     which the palette ignores -- that halves the levels; document).
   - Mode 10: nibble 0-8 selects a color REGISTER: 0-3 -> COLPM0-3,
     4-7 -> COLPF0-3, 8 -> COLBK (9-15: **CONFIRM** behaviour, commonly
     repeats PF/BAK).
   - Mode 11: nibble = hue; luminance from COLBK's luminance bits
     (nibble 0 renders as COLBK-luminance gray/black -- **CONFIRM**).
3. GTIA modes apply per-line (PRIOR can change mid-frame via DLI --
   per-line granularity is what our renderer already provides). ANTIC
   modes other than F with GTIA bits set produce garbage on hardware;
   render as normal mode and document.
4. Tests: for each mode, poke two known screen bytes, one frame,
   assert the exact RGB triples of the 8 affected output columns
   (compute expected values through `atari-color->r/g/b`).

Commit: "Renderer: GTIA modes 9/10/11".

---

## Phase 8 -- POKEY timer fidelity

`MISC_IMPROVEMENTS_PLAN.md` item 5, verbatim -- follow its five steps:
reload offsets (+4 at 1.79 MHz, +7 for linked 16-bit pairs at
1.79 MHz, +1 on the 64/15 kHz clocks -- **CONFIRM**), AUDCTL bit 4/3
channel linking with IRQs from the high channel, the existing
timer-test renames (N+1 -> N+4 with reference citations), the 16-bit
pair period test, and the batched-advance equivalence test update
(PERFORMANCE_PLAN Phase 3 landed, so `pokey-advance`'s event skipping
MUST be updated in the same commit to honor links/offsets -- the
50,000-cycle `pokey-tick`==`pokey-advance` equivalence test is the
net; extend it to a linked-channel configuration).

This precedes audio synthesis so the audible frequencies come out
right the first time.
Commit: "POKEY: hardware reload offsets and linked 16-bit channels".
Update `MISC_IMPROVEMENTS_PLAN.md` status: item 5 done.

---

## Phase 9 -- POKEY audio synthesis core  [hot path -> benchmark]

Turn register state into samples. Design decisions are made here --
implement as specified.

**Output format**: mono, unsigned 8-bit, one sample every 40 CPU
cycles -> 1,789,772.5 / 40 = **44,744 Hz** nominal (746-747 samples per
NTSC frame; 29,868 / 40 = 746.7).

1. New file `src/audio.lisp`, package `:atari800-cl.audio`, inserted
   in the `.asd` and `src/package.lisp` AFTER `pokey` and BEFORE
   `machine` (`:serial t` -- order matters). Core struct
   `audio-unit`: sample buffer (growable or fixed 2048 with a fill
   pointer), cycle accumulator, per-channel output-bit state, poly
   counters.
2. Synthesis model (per CPU cycle, but batched -- see step 4):
   - Channel clocking: reuse the timer state Phase 8 solidified -- a
     channel's square-wave flip-flop toggles on counter underflow.
     Distortion (AUDC bits 5-7) gates the toggle through the poly
     sequences: pure tone (AUDC high bits `101`/`111` variants),
     poly4, poly5-gated, poly17/poly9 noise (AUDCTL bit 7 selects
     9-bit). Implement the poly sequences as precomputed bit vectors
     (poly4 len 15, poly5 len 31, poly9 len 511, poly17 len 131071)
     generated at load time with the same feedback taps the RNG in
     `pokey.lisp` uses -- factor the tap logic into one shared helper
     rather than duplicating constants.
   - Volume-only mode (AUDC bit 4): channel output = volume,
     unconditionally.
   - Sample = `128 + sum over channels (if output-bit-set: +vol,
     else: -vol) * 2` clamped to 0-255 (four channels x 15 max
     volume x 2 = 120 swing each side -- fits).
   - AUDCTL high-pass filters (bits 1-2) and two-tone serial mode:
     NOT in this phase; document in the file header as out of scope.
3. API (exported): `make-audio-unit`, `audio-drain (unit)` -> fresh
   `(simple-array (unsigned-byte 8))` of the samples accumulated since
   the last drain (and resets the buffer), `+audio-sample-rate+`.
4. Wiring: add an optional `audio` slot to the `pokey` struct. In
   `pokey-advance` (and `pokey-tick`), when the slot is non-NIL,
   advance the audio unit by the same N cycles -- the audio unit steps
   channel counters itself OR (simpler, preferred) observes the
   channel underflows POKEY already computes: add a per-channel
   underflow hook the audio unit consumes. Choose the design that
   keeps the no-audio path cost at exactly one NIL check per
   advance -- benchmark to prove it (rule 3), since machines without
   audio attached (all current tests/benches) must not regress.
5. Facade: `a800:machine-attach-audio` / `machine-audio-drain` (via
   `src/machine.lisp` + `src/main.lisp`).
6. Tests (`tests/test-audio.lisp`, new suite `audio-suite :in
   atari800-cl-suite`, added to `.asd` + `tests/test-suite.lisp`
   pattern):
   - Frame sample count: one `machine-run-frame` with audio attached
     yields 746 or 747 samples.
   - Pure tone: channel 1 at 1.79 MHz, AUDF1 chosen for a period of
     exactly K samples; assert the drained buffer's flip period is K
     (count samples between level transitions).
   - Volume-only: constant buffer at the expected DC value.
   - Silence (all volumes 0): constant 128s.

Benchmark + log (audio detached AND attached rows -- label them).
Commit: "POKEY audio synthesis: four-channel PCM at 44.7 kHz".

---

## Phase 10 -- AESP audio streaming + WAV capture

1. `src/aesp.lisp`: consult `tools/protocol-comparison` and the Attic
   `PROTOCOL.md` conventions already mirrored in this file for the
   audio-frame message type; if the protocol defines one, use its
   code, else define `+aesp-audio-frame+ #x85` (next to the existing
   `#x81-#x84` audio codes) and document the payload: raw u8 mono
   samples, length = sample count. Update `%audio-config-payload` to
   declare rate 44744, format u8, channels 1 (read its current layout
   first and keep it wire-compatible).
2. Server wiring: mirror `%push-video-frame` -- the machine's
   `post-frame-fn` (already installed by the AESP server) additionally
   drains the audio unit and pushes to `audio-clients` (add the slot
   parallel to `video-clients`, subscribe handling parallel to video).
   Attach an audio unit to the machine when the first audio subscriber
   arrives (or unconditionally at server start -- simpler, costs ~0
   when nobody drains... no: the synthesis itself costs; attach on first
   subscribe, detach on last unsubscribe; guard with the server lock).
3. `scripts/capture-audio.py`: like `capture-screenshot.py` but on the
   audio port -- subscribe, collect N frames' samples, write a WAV via
   Python's `wave` module (44744 Hz, 1 channel, 1 byte/sample).
4. Tests (`tests/test-aesp.lisp`): codec roundtrip of an audio frame;
   server test in the existing live-server pattern (they self-skip in
   sandboxes) -- subscribe, run a frame via the mailbox, assert an
   AUDIO_FRAME arrives with 746-747 bytes.

Commit: "Stream POKEY audio over AESP; add WAV capture script".

---

## Phase 11 -- A/V recording tooling (the EdVenture deliverable)

One command from `.asm` to a watchable `.mp4`.

1. `scripts/capture-video.py`: subscribe to the AESP video port,
   capture N frames as numbered PNGs into a temp dir (reuse
   `capture-screenshot.py`'s frame-decode code -- refactor the shared
   parts into `scripts/aesp_client.py` imported by all three capture
   scripts rather than copy-pasting).
2. `scripts/record.sh <file.asm|file.xex> [-frames N] [-o out.mp4]`:
   orchestrates -- build with `mads-build.sh` if given `.asm`; start
   the emulator + servers via the same mechanism `atari-run.sh` uses
   (read it first; reuse, don't reimplement); run `capture-video.py`
   and `capture-audio.py` concurrently for N frames; assemble with
   `ffmpeg -framerate 59.92 -i frame%05d.png -i audio.wav -c:v libx264
   -pix_fmt yuv420p -c:a aac out.mp4` (guard: if `ffmpeg` is absent,
   leave the PNG sequence + WAV and print the assemble command).
3. Acceptance (manual, document in the script header): `./scripts/
   record.sh asm/edvent02_rasterbars.asm -frames 300 -o /tmp/rb.mp4`
   -> a 5-second video of animated raster bars. Automated smoke: a
   `--dry-run`-less run of 10 frames producing >= 10 PNGs and a WAV of
   >= 7460 samples; add it to the script as `--selftest` if easy,
   otherwise verify manually and note in the commit message.
4. README: replace/extend the screenshot paragraph with the one-liner
   recording workflow.

Commit: "One-shot A/V recording: asm -> mp4 via AESP capture".

---

## Phase 12 -- Tom Harte ProcessorTests harness

`MISC_IMPROVEMENTS_PLAN.md` item 4, verbatim -- follow its five steps
exactly (env-var-gated data at `ATARI800_CL_HARTE_TESTS`, `shasht`
JSON dependency on the TEST system only, `tests/test-harte.lisp` with
`harte-suite`, KIL/unstable handling, 500-cases-per-opcode default
with `ATARI800_CL_HARTE_FULL=1`, triage workflow in the file header).

Expect real bugs to surface (decimal-mode edges, page-cross cycles).
Fix each in `src/`, add a named regression test, keep the skip-list
empty unless a divergence is documented-unstable. Budget multiple
sessions; land the harness (skipping gracefully) in one commit, bug
fixes in follow-up commits.

Commit: "Add Tom Harte ProcessorTests harness (harte-suite)".
Then: one commit per bug found, message "Fix <opcode> <defect> (Harte case <id>)".
Update `MISC_IMPROVEMENTS_PLAN.md` status: item 4 done (and item 11
marked obsolete).

---

## Phase 13 -- POKEY keyboard IRQ (typing into BASIC)

The machine boots to BASIC's `Ready` but cannot be typed at. AESP
`KEY_DOWN` already reaches `input-set-key`, which only makes `KBCODE`
readable -- and the XL OS reads `KBCODE` from an interrupt handler,
dispatched off IRQEN bit 6. POKEY has no such source: `+irq-timer1/2/4+`
and the two serial-output bits are the whole set. Same shape as the
SEROR/SEROC work, and it turns "boots to BASIC" into "type a program
and RUN it".

1. `src/pokey.lisp`: add `+irq-other-key+` (`#x40`) and
   `+irq-break-key+` (`#x80`), per the XL OS's own `TIRQ` dispatch table
   (`minimal-xl/Atari_XL_OS_Rev.2.asm`) -- the same source that settled
   the timer-4 and serial bits in the POKEY serial commit.
2. Raise the key IRQ when a key is latched, not on a timer: the input
   state is written from socket reader threads, so POKEY cannot poll it
   safely. Give `pokey` a "key pending" flag set through the existing
   input plumbing (`attach-pokey-input` path) and consumed on the next
   `pokey-advance` from the emulator thread, which then calls
   `%raise-irq` with `+irq-other-key+`. Keep the idle cost to the same
   one-slot-read test the serial transmitter pays -- benchmark it
   (rule 3).
3. SKSTAT: bit 2 (shift held) and bit 3 (a key is down) are what the OS
   debounce path reads; `input-pokey-skstat` already composes a value,
   so extend it rather than adding a second source of truth.
4. BREAK: bit 7 is a separate IRQ and sets `BRKKEY` ($11) via the OS
   handler. Wire it the same way; it is what lets a test stop a runaway
   BASIC program.

Tests: unit (`tests/test-pokey.lisp`) that a latched key with IRQEN bit
6 set clears the IRQST bit and asserts the CPU line, and does neither
when the bit is clear. End-to-end (`tests/test-machine.lisp`, alongside
the real-ROM boot tests, skipping without ROMs): boot to `Ready`, drive
the key codes for `PRINT 2+2` and RETURN through the input state, run
frames, then assert `4` appears in screen memory. That last test is the
real acceptance criterion -- it exercises keyboard IRQ, the OS editor,
and BASIC in one shot.

Commit: "POKEY keyboard IRQ: the OS editor now sees keystrokes".

---

## Phase 14 -- `scripts/fetch-harte.sh` + fast subset gate

The Harte harness is only as useful as its data is easy to get; right
now that is a README paragraph rather than a command.

1. `scripts/fetch-harte.sh`, modelled on `scripts/fetch-test-roms.sh`:
   fetch `SingleStepTests/65x02` `6502/v1` into a gitignored directory
   (default `.cache/harte/`), no-op when already present, print the
   `export ATARI800_CL_HARTE_TESTS=...` line to eval. Prefer a sparse or
   per-file fetch over cloning the whole ~1 GB repository.
2. `--subset N` (default for the pre-commit case): fetch only N opcode
   files chosen to cover the addressing modes and the illegal families,
   so a fast gate is ~30 MB instead of a gigabyte. The harness already
   tests whichever files exist, so nothing in `tests/` changes.
3. Document both modes in `CLAUDE.md`'s test section next to the
   existing Harte paragraph.

Commit: "Add fetch-harte.sh for the SingleStepTests vectors".

---

## Phase 15 -- Documentation drift sweep

`MISC_IMPROVEMENTS_PLAN.md` item 9, which has drifted further since it
was written -- partly because of the phases above:

- `CLAUDE.md`'s Project Overview still lists "the serial/SIO bus,
  keyboard scanning" as unmodelled; the serial-output half now is, and
  Phase 13 changes the keyboard half.
- `CLAUDE.md`'s Development Plan paragraph still says Prompt 12's
  Unix-socket layer "was later removed" while `src/cli-socket.lisp`,
  `src/transport.lisp` and `src/aesp.lisp` are all present.
- The rest of misc item 9's list (README limitation bullets, renamed
  symbols in examples).

Cheap, and it keeps the file that steers every future session honest.
Do it as one commit, after Phase 13 so the keyboard wording lands once.

Commit: "Documentation drift sweep".

---

## Phase 16 (revised) -- Host disk bridge: ATR/XEX/OBX via minimal-xl

> Revised 2026-08-20. The original Phase 16 (POKEY serial receive +
> byte-level SIO device dispatch) moved to Phase 25, deferred: the
> project's stated scope is the CPU, ANTIC and GTIA, with POKEY/PIA
> only as far as sound and keyboard -- SIO fidelity is explicitly not
> a goal. Status entries and cross-references written before this
> date refer to that plan as "Phase 16" / "16a"; Phase 22's PENDING
> bit 3 stays reserved for what is now 25a.

Same goal as before -- the machine loads real software from disk
images instead of hand-assembled demos -- but reached without
emulating the serial wire. The `minimal-xl/` submodule is an OS we
control: it already has polled read-only SIO through `SIOV`/`DSKINV`
(its phase 11), the standard disk boot (phase 12), and
`tools/xexboot.asm` + `tools/xex2atr.py`, which pack any XEX/OBX into
a bootable ATR (phase 13) -- verified end-to-end with edventure under
atari800. Instead of building POKEY's receive side so the OS can talk
to a virtual drive byte-by-byte, give the emulator a memory-mapped
**host bridge** and teach minimal-xl's `SIOV` to use it when present.

Put the bridge in the `$D1xx` page -- the XL's Parallel Bus Interface
range, which real hardware used for exactly this class of device
(parallel-bus disks like the Black Box; Altirra models its hook
devices the same way). So this is a plausible peripheral, not an
emulator trap: no CPU patching, no escape opcodes, just one more
device registering read/write closures into the bus like the four
chips do.

Stage it; do not attempt one commit. And write the acceptance test
FIRST: the boot test lands in `tests/test-machine.lisp` --
strict-gated (Phase 21) and skipping -- in the same commit as 16a, so
the phase is done when that test stops skipping and passes, not when
the sub-items feel complete. (Lesson from Phases 1-12: the PIA and
serial-transmitter showstoppers survived twelve green phases because
no phase gated on booting the real ROMs.)

**16a -- bridge device.** `src/hostdev.lisp` (insert in the `.asd`
after the chips, before `machine`): a signature register at `$D1FE`
that reads back a magic byte so the OS can detect the bridge (absent
bridge reads as the usual open-bus value), and a "go" register at
`$D1FF`. On a go write, read the standard DCB from `$0300`
(DDEVIC/DUNIT/DCOMND/DSTATS/DBUFLO-HI/DBYT/DAUX1-2), perform the
operation against the mounted image, copy data through the bus
closures, and set the DCB status byte -- zero cycles of serial
traffic, zero new POKEY hot-path work. Wire it in
`make-atari-machine`. Testable in isolation: poke a DCB, write the go
register, assert the buffer.

**16b -- ATR disk images.** Unchanged from the original plan: parse
the 16-byte ATR header (magic `$0296`, sector size, image size), map
sector numbers to file offsets (remembering the first three sectors
are 128 bytes even on double-density images), and serve READ (`$52`)
and STATUS (`$53`) first; WRITE (`$50`/`$57`) after, behind an
explicit read-only default.

**16c -- minimal-xl bridge probe.** A submodule phase (its phase 15):
at the top of `SIOV`, probe the `$D1FE` signature; if the bridge
answers, write the go register and return its status; otherwise fall
through to the existing polled serial path, so the ROM stays fully
functional on real hardware and stock atari800. Commit in the
submodule with its own `make test` smoke run, then bump the submodule
pointer here.

**16d -- XEX/OBX loading.** Port `tools/xex2atr.py` to Lisp (small:
prepend the assembled `xexboot.bin` boot sectors, patch the
last-data-sector word at offsets 9/10, pad to 128-byte sectors).
`a800:load-xex` synthesizes a bootable ATR *in memory* and mounts it;
XEX and OBX (same format, MADS's extension) then cost zero new 6502
code, and INIT-per-segment semantics come from xexboot rather than
being reimplemented. Commit the assembled `xexboot.bin` under
`fixtures/` with a provenance note (it is this project's own code,
rebuilt via the submodule's Makefile -- the `roms/` gitignore rule is
about copyrighted images). The existing direct-injection loader in
`scripts/xex-loader.lisp` stays for the test harness; the ATR route
is the user-facing path because it exercises the real boot protocol.

**16e -- API + protocol.** `a800:mount-disk` / `unmount-disk` /
`load-xex` on the facade, an AESP control message to mount from a
client, and `mount` / `loadxex` verbs on the CLI socket.

Acceptance: with `minimal_os.rom` (built from the submodule; the test
skips -- strict-fails -- when the ROM is absent) and the edventure ATR
mounted, a cold boot reaches the game's entry point; and `load-xex`
on `edventure.obx` gets there with no ATR at all. `scripts/record.sh`
can film it. This replaces the original DOS 2.5 menu gate on purpose:
DOS boots via the standard protocol but leans on real-OS internals
minimal-xl does not provide -- the real-OS DOS boot returns as Phase
25's acceptance. Note the bridge sidesteps `SIOV`'s own read-only /
128-byte-sector limits (the host does the transfer), but software
that bypasses `SIOV` to do raw serial I/O is out of scope until 25.

Commits: one per stage, message "Host bridge: <stage>" (the submodule
commit follows minimal-xl's own conventions).

---

## Phase 17 -- Harte bus-trace comparison

> **Done (2026-08-20)**, four commits total. `62c9510` ("Harte harness:
> compare the cycle-by-cycle bus trace") landed steps 1-3 as planned
> (recording bus, trace comparison, gated behind
> `ATARI800_CL_HARTE_TRACE`). Step 4's two quirks then landed one commit
> each: `17e8600` ("CPU: RMW double-write (unmodified value first)") and
> `5a7e987` ("CPU: indexed-addressing dummy reads at the un-carried
> address") -- the second one grew beyond its name once the FULL 2.56M-
> case corpus was run under the trace comparison: 157 of 256 opcodes
> were still mismatching after the RMW fix alone, all from the same
> family of previously-unmodelled dummy reads (implied/accumulator
> opcodes, PHA/PHP/PLA/PLP, JSR/RTS/RTI, BRK's signature byte, taken
> branches) that the plan's step 2 named only the indexed-addressing
> case of. A fourth commit then dropped the `ATARI800_CL_HARTE_TRACE`
> gate: trace comparison always runs now. Verified fully green on both
> SBCL and LispWorks with the full corpus and `ATARI800_CL_STRICT=1`:
> zero failures. Re-ran Acid800 (Phase 24); no `+ACID800-KNOWN-ISSUES+`
> entry moved -- `cpu_bugs` and the four unisolated ANTIC failures are
> confirmed still failing for their existing documented reasons, not
> related to these quirks. See `CHANGES.md` and `PERFORMANCE_LOG.md`
> ("ROADMAP Phase 17 -- NMOS bus quirks") for the full writeup and
> benchmark numbers -- the dummy-read commit is a real, accepted
> hot-path regression (SBCL -7% to -10% on throughput-bound workloads),
> not chased per CLAUDE.md's correctness-over-performance priority.
> `SCANLINE_ACCURACY_PLAN.md` Phase 5 items 1-2 are done via this phase;
> items 3-5 (interrupt poll timing, SEI/CLI/PLP delay, BRK/NMI hijack)
> remain open.

The vectors carry a full cycle-by-cycle bus trace -- `[address, value,
"read"|"write"]` per cycle -- and `tests/test-harte.lisp` currently uses
only its LENGTH, as the cycle count. Comparing the trace itself turns
the harness from "right answer in the right number of cycles" into
"right accesses in the right order", which is exactly the evidence
SCANLINE_ACCURACY_PLAN.md's stretch Phase 5 needs.

1. Give the harness an optional recording bus: wrap the CPU's
   `cpu-bus-read` / `cpu-bus-write` closures to log `(addr value kind)`
   per access (the scanline plan's Phase 5 already calls for such a stub
   -- write it once, in `tests/test-helpers.lisp`, and share it).
2. Compare against the vector's `cycles` array. Expect immediate,
   informative failures: the RMW double-write (write unmodified, then
   modified) and the indexed dummy reads are both unmodelled today, and
   both show up as a wrong access at a known index rather than as a
   wrong result.
3. Gate it behind its own env var (`ATARI800_CL_HARTE_TRACE=1`) until
   the quirks are implemented, so the default run stays green while the
   work proceeds.
4. Then implement SCANLINE_ACCURACY_PLAN.md Phase 5 items 1 and 2
   against it, one commit each, and drop the gate.

Commit: "Harte harness: compare the cycle-by-cycle bus trace".

---

## Phase 18 -- LispWorks profiling pass  [hot path -> benchmark]

> **Done (2026-08-20)**: profiled LispWorks first, then SBCL, on the
> `nop`/`irq`/`display`/`audio` workloads. The profile named
> `POKEY-ADVANCE`'s array-slot accesses as disproportionately expensive
> on LispWorks (69%/49% inclusive on nop/irq vs. SBCL's 36%/29%),
> traced in the LispWorks breakdown to `SYSTEM::AREF1`/`SET-AREF1`
> generic dispatch. Adding explicit local `(simple-array fixnum (4))`
> type declarations at the hot AREF sites (`%EXPIRE-CHANNEL`,
> `POKEY-TICK`, `POKEY-ADVANCE`, `%TIMER-RELOAD-VALUE`) measured as flat
> noise (`bench-ab.sh`, 5 pairs, both implementations) and, confirmed by
> disassembly, changed nothing: LispWorks 8.1.1's ARM64 backend calls
> out to `SYSTEM::AREF1` for any checked array access at `(safety 1)`
> regardless of declared type, only inlining at `(safety 0)` -- which
> CLAUDE.md's safety floor forbids. SBCL's ARM64 backend inlines the
> identical bounds-checked access at `(safety 1)` (verified by
> disassembly). The change was reverted, not committed; the gap is
> documented rather than chased, per this phase's own framing. Full
> profile tables, the disassembly evidence, and post-pass numbers are in
> `PERFORMANCE_LOG.md` ("ROADMAP Phase 18 -- LispWorks profiling pass").

`PERFORMANCE_PLAN.md` Phase 4, which remains open, aimed at the
implementation this project calls primary. LispWorks runs at roughly a
quarter of SBCL's speed (`nop` ~950 vs ~3550 fps), and every
optimization so far was measured on both but DESIGNED against SBCL's
behaviour -- the bus dispatch and `%expire-channel` in particular may
land very differently there.

Follow that plan's four steps (compat-wrapped profiling helpers,
profile the workloads, act only on what the profile names, record the
findings). The one addition: profile LispWorks FIRST, and treat the
SBCL/LispWorks gap as the thing being investigated rather than an
accepted constant.

Commit: per follow-up the profile justifies, each with
`PERFORMANCE_LOG.md` rows.

Follow-up: Phase 26 revisits this phase's `SYSTEM::AREF1` finding with
a narrowly scoped `(safety 0)` carve-out for the profile-named hot
array accesses.

---

## Phase 19 -- 256-entry palette

> **Done (2026-08-23)**: widened `+atari-rgb-palette+` from 128 entries
> indexed by `(color >> 1)` to 256 entries indexed directly by the color
> byte, so luminance is the full 4-bit field (bits 3-0) instead of 3
> bits with bit 0 discarded. The Y-per-step formula (13 per luminance
> step, base 8) was chosen so every even luminance reproduces the old
> table's RGB exactly, keeping every existing caller (which only ever
> writes bit-0-clear color bytes) unchanged. GTIA mode 9's 16 nibble
> values now render 16 distinct luminances instead of collapsing into 8
> pairs; `GTIA-MODE-9-LUMINANCE-PAIRS-COLLAPSE` is replaced by
> `GTIA-MODE-9-RECOVERS-16-LUMINANCES`, and `PALETTE-BIT0-IGNORED` is
> replaced by `PALETTE-BIT0-SELECTS-DISTINCT-LUMINANCE`. See
> `CHANGES.md` for the full writeup.

Phase 7 pinned a limitation by test: the 128-entry palette collapses
GTIA mode 9's 16 luminances into 8 pairs. The color bytes the renderer
computes are already hardware-correct, so this is a palette-table
change plus the tests that currently assert the collapsed values.

Widen the table to 256 entries (hue 4 bits x luminance 4 bits), update
`atari-color->r/g/b` and their callers, and update the mode-9 renderer
test to assert 16 distinct luminances.

Commit: "Renderer: 256-entry palette recovers mode 9's 16 luminances".

---

## Phase 20 -- ANTIC display-list latch note

> **Done (2026-08-23)**: documentation only, per
> `MISC_IMPROVEMENTS_PLAN.md` item 10. Added an honest comment block in
> `src/antic.lisp` at the VBI re-latch (`%BEGIN-SCANLINE-EVENTS`) and the
> DLISTL/DLISTH write cases (`ANTIC-WRITE`) describing how this
> emulator's re-latch-every-VBI model diverges from hardware's
> JVB-gated latch, cross-referencing `SCANLINE_ACCURACY_PLAN.md` Phase
> 4+ where changing the behaviour belongs and `ACID800-ANTIC-DLISTWRAP`
> as the test that already exercises the divergence. No behavioural
> change; 2513 checks pass on both SBCL and LispWorks.

`MISC_IMPROVEMENTS_PLAN.md` item 10, unchanged: an honest comment block
in `src/antic.lisp` at the VBI re-latch and the DLISTL/H write cases,
describing how this emulator's re-latch-every-VBI model diverges from
hardware (which reloads only at JVB), and cross-referencing
SCANLINE_ACCURACY_PLAN.md Phase 4+ where changing the behaviour
belongs. Documentation only.

Commit: "Document the ANTIC display-list latch simplification".

---

## Phase 21 -- Strict test gate + skip census

Phases 1-12 went green while the machine could not boot the real OS:
the tests that matter most (Klaus, Harte, real-ROM boot) are env-gated
and self-skipping, so a suite pass proves least exactly where the
stakes are highest. The PIA register-map and missing-serial-transmitter
showstoppers were found by unplanned work between Phases 10 and 11, not
by any phase's gate. Make the skips impossible to not notice.

1. `tests/test-helpers.lisp`: `%skip-or-fail (reason)` -- when
   `ATARI800_CL_STRICT` is set (non-empty), FAIL with the reason;
   otherwise skip as today. Convert the Klaus, Harte, and real-ROM
   boot tests to it, and use it for every future env-gated test (the
   Phase 13 typing test, Phase 16 ATR boot, Phase 24 Acid800).
2. Skip census: `./scripts/test-sbcl.sh` and `test-lispworks.sh` echo
   one `SKIPPED: <test> (<reason>)` line per skipped test after the
   run -- both already inspect the `fiveam:run!` result list for the
   exit code, so the skipped entries are in hand. Holes stay visible
   in every transcript instead of hiding inside "N checks, 1 skip".
3. This makes ground rule 2's strict sentence operative: on this
   machine (rule 8 says the ROMs are present), a phase is done only
   when the strict run also exits 0.

Tests: the helper itself (strict env var -> failure recorded; unset ->
skip), in `tests/test-compat.lisp` or a small new group -- exercise it
via a dummy test body, not by unsetting real assets.

Commit: "Strict test gate: env-gated skips fail under ATARI800_CL_STRICT".

---

## Phase 22 -- POKEY pending-work bitmask  [hot path -> benchmark]

Serial output cost -1.2% to -4.8% depending on workload, the audio
slot cost -4.2% on `nop`, and Phases 13 and 25a (serial receive,
originally numbered 16a) each plan to add another "one slot read plus
branch" to `pokey-advance`. Four independent per-advance branch tests
where one will do. Consolidate BEFORE 13 and 25a land, so their flags
join the mask for free instead of repeating the measure-and-shrug
cycle.

1. One fixnum slot `pokey-pending` on the `pokey` struct: bit 0 =
   serial transmitter active, bit 1 = audio attached, bits 2-3
   reserved for key-pending (Phase 13) and serial receive (Phase 25a).
   The fast path in `pokey-advance` / `pokey-tick` tests `(zerop
   pending)` ONCE per call; nonzero branches to a NOT-inlined cold
   function that dispatches on the set bits. The audio advance moves
   into the cold function too -- audio is a do-work-every-advance bit
   where the others are event flags, but both shapes live behind the
   same single test.
2. Setters maintain the mask: `machine-attach-audio` (and detach)
   toggles bit 1, transmitter start/finish toggles bit 0. Keep
   `%expire-channel` untouched -- the serial commit's log entry records
   why hooks in there cost 8-9%.
3. The 50,000-cycle `pokey-tick` == `pokey-advance` equivalence test
   must run under several mask states (audio attached, serial
   mid-byte, both at once) so the consolidation cannot silently
   diverge the two paths.
4. Measure with `./scripts/bench-ab.sh` (rule 3) against the
   pre-phase commit; expect to recover part of the ~4% `nop` cost.
   Log the paired-delta table either way -- a null result is still a
   result, and it caps the cost of Phases 13 and 25a at zero new
   hot-path branches.

Commit: "POKEY: consolidate per-advance hooks into one pending-work bitmask".

---

## Phase 23 -- CONFIRM retirement pass

The CONFIRM flag means "verify against a reference"; after twelve
phases it functions as a footnote. The status headers above admit the
PRIOR priority orderings, mode 10's nibbles 9-15, and the POKEY reload
offsets all still carry theirs. Retire every flag still standing:
`grep -rn CONFIRM src/ *.md` (currently `src/pokey.lisp:55`,
`src/renderer.lisp:74`, `src/renderer.lisp:413`, plus the flags this
file and the other plan documents carry).

For each one, either:

- (a) verify it against the Altirra Hardware Reference Manual or the
  atari800 source -- the PRIOR orderings and mode-10 nibble behaviour
  against `gtia.c`'s priority tables, the reload offsets and poly taps
  against `pokey.c` -- replace the flag with a file+line citation
  comment, and add a test asserting the confirmed value where one does
  not already pin it; or
- (b) if it genuinely cannot be verified from those sources, record it
  in README.md's known-limitations list as a documented-unverified
  value and say which sources were checked.

No flag survives as a bare CONFIRM. This is an hour or two of
cross-reading the original phases already asked for and nobody did.

Commit: "Retire the CONFIRM flags: citations and tests, or documented
divergence".

---

## Phase 24 -- Acid800 gate (CPU + ANTIC subsets)

The CPU has an external ratchet (Harte); ANTIC, GTIA, and POKEY are
tested only against this emulator's own model -- their tests assert
the implementation back at itself. Acid800 under the real OS ROM is
the cheapest external check available and has been "aspirational" in
the definition of done long enough. Run it BEFORE Phase 17: the ANTIC
subset is the first outside evidence the Phase 5 steal tables and
Phase 3 WSYNC have ever faced, where 17 only deepens the CPU's
already-strongest evidence.

1. `scripts/fetch-acid800.sh`, modelled on `fetch-test-roms.sh`:
   download the Acid800 test suite into `roms/acid800/` (gitignored),
   no-op when present, note the license and source URL.
2. Env-gated tests in `tests/test-machine.lisp`'s real-ROM group,
   strict-gated via Phase 21's `%skip-or-fail`: load each test XEX via
   the existing XEX loader (`scripts/xex-loader.lisp` mechanism), run
   frames, and read the pass/fail state from screen memory the way the
   boot test reads `Ready`.
3. CPU subset first -- expected to pass given Harte; a failure here is
   information about the BUS or interrupt timing, which
   per-instruction vectors cannot see. Then the ANTIC subset. Triage
   failures the Harte way: presumed real emulator bugs, fix in `src/`,
   regression test per fix, skip only with a documented reason.
4. Move the definition-of-done bullet from "aspirational" to gated on
   whichever subsets pass, and list the ones that do not yet in
   README.md's limitations.

Commit: "Add the Acid800 harness: CPU and ANTIC subsets under the real OS".

---

## Phase 25 -- SIO receive path + serial-wire disk (deferred)

> This is the original Phase 16 plan, deferred on 2026-08-20 when the
> revised Phase 16 (host disk bridge) replaced it: SIO fidelity is not
> a primary project goal, and the bridge delivers disk loading without
> the serial wire. It remains the right plan if byte-level SIO ever
> matters (real-OS DOS boot, software doing raw serial I/O, cassette).
> Phase 22 reserved POKEY PENDING bit 3 for 25a's serial receive.
> Nothing in Phase 16 precludes this: the bridge and the serial path
> coexist, since minimal-xl falls back to polled serial SIO when the
> bridge is absent and the real OS never probes the bridge at all.

With a device that answers on the wire, the machine boots DOS under
the real OS ROM. The OS already sends a complete command frame and
times out waiting for a reply -- the missing half is everything after
that.

Stage it; do not attempt one commit. And write the acceptance test
FIRST: the DOS-menu boot test lands in `tests/test-machine.lisp`'s
real-ROM group -- strict-gated (Phase 21) and skipping -- in the same
commit as 25a, so the phase is done when that test stops skipping and
passes, not when the sub-items feel complete. (Lesson from Phases
1-12: the PIA and serial-transmitter showstoppers survived twelve
green phases because no phase gated on booting the real ROMs.)

**25a -- serial receive.** POKEY's input side: SERIN, the
serial-input-ready IRQ (IRQEN bit 5), and the SKSTAT framing/overrun
bits. Mirror the transmitter's structure in `src/pokey.lisp` (a
cycle countdown clocked from the same channel-4 period) so the two
halves stay symmetrical. The per-advance hook joins the Phase 22
PENDING bitmask as bit 3.

**25b -- device dispatch.** A `src/sio.lisp` device layer that watches
the transmitted command frame (device id, command, aux1/2, checksum),
and replies with ACK / COMPLETE / data frames on the receive side, with
the inter-frame delays the OS expects. Devices register by id, so the
disk is one implementation rather than the only one -- and Phase 16b's
ATR image layer is reused as-is behind it.

**25c -- API.** The Phase 16e mount API already exists by now; this
stage only routes a mounted image to the serial device layer as well,
so the same `a800:mount-disk` serves both the bridge and the wire.

Acceptance: with a DOS 2.5 ATR mounted and the real OS ROM, a cold
boot reaches the DOS menu, and `scripts/record.sh` can film it. Add a
boot test in the `tests/test-machine.lisp` real-ROM group, skipping
when no ATR is present.

Commits: one per stage, message "SIO: <stage>".

---

## Phase 26 -- LispWorks fast-path array access  [hot path -> benchmark]

> **Done (2026-08-23)**, four commits: `963f0ee` (26a/26b, the
> `FAST-AREF` compat macro plus the `PERFORMANCE_PLAN.md` safety-rule
> carve-out), `e254142` (26c-1, `src/pokey.lisp`'s channel-array hot
> path), `5acef18` (26c-2, `src/renderer.lisp`'s framebuffer scanline
> hot path), and this close-out. Both conversions measured CLEAN on
> LispWorks with `scripts/bench-ab.sh` (5+ pairs) and stayed inside
> noise on SBCL, per commit, as the phase's acceptance criteria
> require; cumulative working-tree-vs-baseline LispWorks gains: `nop`
> +134.0%, `irq` +75.5%, `display` +231.3%, `audio` +159.3% (all
> CLEAN), against a +30% `nop` aspirational target. Close-out
> verification: full suite green on both implementations unchecked
> (sbcl 2503/2489/14/0, lispworks 2506/2492/14/0 -- checks/pass/skip/
> fail) and LispWorks green again with `ATARI800_CL_CHECKED_AREF=1`
> forcing every `FAST-AREF` site back to fully checked (2543/2527/16/0,
> confirmed to actually recompile from scratch). Re-profiling `nop` and
> `display` with the same `hcl` methodology Phase 18 used confirmed
> `SYSTEM::SET-AREF1` -- 10-37% self time across Phase 18's profiles --
> no longer appears anywhere in either workload's Phase 26 profile, and
> `SYSTEM::AREF1` fell from a top-5 entry (18% self on `nop`) to 4-5%
> self on both. New SBCL/LispWorks fps ratios: `nop` 1.44x (was ~3.4x
> at Phase 18), `irq` 1.41x, `display` 2.06x, `audio` 2.20x. Neither
> converted file is CPU-adjacent, so the full-corpus Harte re-run this
> phase's item 4 conditions on was not required; the Harte tests the
> unchecked-build suite run already carries stayed green throughout.
> See `PERFORMANCE_LOG.md`'s "ROADMAP Phase 26" section for the full
> A/B tables, the re-profile tables, and the SBCL `display` +20-24%
> side effect (from the conversion's bound-assertion additions, not
> from `FAST-AREF` itself, which is a no-op macro on SBCL) explained in
> detail there.

Phase 18's profiling pass ended with a diagnosis and no lever: on the
LispWorks 8.1.1 ARM64 build, every checked array access compiles to an
out-of-line `SYSTEM::AREF1` / `SET-AREF1` call at `(safety 1)` no
matter how precisely the type is declared, and those calls are where
the SBCL/LispWorks gap concentrates (4 of the top 5 self-time entries
on the LispWorks `nop` profile; `SET-AREF1` alone 37% of `display`).
The only thing that inlines the access is `(safety 0)`, which
`PERFORMANCE_PLAN.md`'s blanket safety floor forbids. This phase
replaces the blanket rule with a narrow, auditable carve-out: `(safety
0)` ONLY at the profile-named hot array accesses, only on LispWorks,
behind a compat macro that keeps every other access -- and the whole
of SBCL -- fully checked.

**26a -- the `fast-aref` compat macro.** In `src/compat.lisp` (the one
file allowed implementation conditionals):

1. `(fast-aref type array index)` and its `setf` expansion, where
   TYPE is the literal array type, e.g. `(simple-array fixnum (4))`.
   - SBCL expansion: `(aref (the type array) index)` -- checked,
     unchanged semantics; SBCL already inlines this at `(safety 1)`,
     so the macro is behaviorally and performance-wise an identity.
   - LispWorks expansion: the same access wrapped in `(locally
     (declare (optimize (safety 0) (speed 3) #| debug per file |#))
     ...)` with the array and index both `the`-asserted.
2. Checked mode: when the environment variable
   `ATARI800_CL_CHECKED_AREF` is non-empty at COMPILE time, the
   LispWorks expansion becomes identical to the SBCL one (fully
   checked). This is the audit switch: a checked LispWorks build must
   be one env var away, and the fasl cache must not conflate the two
   (verify a checked run after an unchecked one actually recompiles;
   if it does not, key the expansion off a feature pushed by the test
   script and document the rebuild step).
3. Verbose docstring stating the contract: a `fast-aref` call site
   MUST make its index provably in range by construction -- masked
   (`logand`), loop-bounded over `length`, or typed to the array's
   exact dimension -- and MUST carry a one-line comment naming the
   proof. No exceptions; an access that cannot state its proof stays
   plain `aref`.
4. Unit tests in `tests/test-compat.lisp`: read/write through
   `fast-aref` on both expansions, values and setf semantics identical
   to `aref`; macroexpansion shape per implementation.

Commit: "compat: fast-aref, a scoped LispWorks (safety 0) array access".

**26b -- amend the safety rule.** `PERFORMANCE_PLAN.md`'s ground rule
("Do not use `(safety 0)` anywhere") and Anti-goals bullet ("No
`(safety 0)`") gain the carve-out in place: `(safety 0)` exists ONLY
inside `fast-aref`'s LispWorks expansion; call sites must satisfy the
proof-comment contract; everything else keeps the `(safety 1)` floor,
and SBCL keeps it everywhere. Note the checked-mode env var next to
the rule. Same commit as 26a (the rule change and the mechanism it
licenses land together), and cite this phase.

**26c -- convert the profile-named sites, one commit per file,
measured.** In the order the Phase 18 profile ranks them:

1. `src/pokey.lisp` -- the 4-slot `(simple-array fixnum (4))` accesses
   in `%EXPIRE-CHANNEL`, `POKEY-TICK`, `POKEY-ADVANCE`,
   `%TIMER-RELOAD-VALUE` (30 AREF1 + 12 SET-AREF1 calls in
   `POKEY-ADVANCE`'s disassembly). Index proof: channel indices are
   already 0-3 by construction; make it explicit with `(logand ch 3)`
   where it is not already a constant.
2. `src/renderer.lisp` -- the framebuffer/scanline row writes behind
   `SET-AREF1` (37% self time on `display`). Index proof: loop bounds
   against the row length; assert the framebuffer's exact dimensions
   once per scanline, not per pixel.
3. Further sites ONLY if a fresh profile names them (the obvious
   candidate is the bus RAM array, whose `u16` index is in range by
   type -- but do not convert it on speculation; profile first).

Each conversion commit: `./scripts/bench-ab.sh` against the previous
commit, 5+ pairs, BOTH implementations. Acceptance per commit: SBCL
within noise (the macro is an identity there -- any SBCL movement
means the macro is wrong, not that SBCL got faster), LispWorks
improvement separated from noise. A conversion that does not separate
from noise on LispWorks gets reverted, not kept -- the carve-out must
pay for its audit burden site by site. `PERFORMANCE_LOG.md` rows
either way.

**26d -- verification and close-out.**

1. Full suite green on both implementations, unchecked build.
2. Full LispWorks suite green AGAIN with `ATARI800_CL_CHECKED_AREF=1`
   (the checked build is the bounds-check audit; document the
   invocation in the run-tests skill).
3. Re-profile LispWorks `nop`/`display` with `with-profiling`: the
   `AREF1`/`SET-AREF1` share must visibly drop at the converted sites;
   record the new top-5 tables and the new SBCL/LispWorks ratio in
   `PERFORMANCE_LOG.md`, updating Phase 18's "documented rather than
   chased" framing to point here.
4. If any converted file is CPU-adjacent (it should not be -- POKEY
   and renderer are the targets), re-run the full-corpus Harte trace
   on SBCL; the ratchet stays at zero failures regardless.
5. ROADMAP status entry + table row, CHANGES.md entry, ASCII-only.

Risks, stated plainly: `(safety 0)` array writes that miss their range
proof corrupt the image silently instead of signaling. The mitigations
are structural -- the macro is the only door, every call site carries
a written proof, the checked build re-runs the whole suite with bounds
checks on, and SBCL (which runs the same suite) keeps full checking
everywhere, so an index bug fails loudly there even when LispWorks
would corrupt. A site whose proof depends on a value crossing a struct
slot or function boundary should mask defensively at the use site --
one `logand` costs less than the call it replaces.

Aspirational target (not a gate): recover a meaningful slice of the
gap on `nop` -- the profile puts ~2/3 of LispWorks' `nop` time under
`POKEY-ADVANCE` with array dispatch dominating it, so +30% LispWorks
`nop` fps is plausible; log whatever materializes.

Commits: as listed per stage.

---

## Phases 27-31 -- Idle-operation tranche (shared ground rules)

An idle machine -- one spinning in a tight loop and/or displaying an
unchanging screen, e.g. parked at the BASIC READY prompt while served
over AESP -- currently pays full price every frame for work whose
output cannot differ from the previous frame's. Reading the code (not
profiling -- Phase 27 adds the measurement) identifies four layers of
idle waste:

1. Full CPU emulation of ~29,868 clocks of busy-wait code per frame.
2. `POKEY-ADVANCE` called after every instruction from `%RUN-CLOCKS`,
   even when no timer IRQ is enabled and audio is detached; the
   Phase 26 close-out profile still has it at 28% LispWorks / 32%
   SBCL self time on `nop`.
3. All 240 `RENDER-SCANLINE` calls re-render an unchanged screen; the
   `scanline-fn` wired by `START-AESP-SERVER` runs even with zero
   video clients connected.
4. `%PUSH-VIDEO-FRAME` allocates and fills a fresh ~322 KB BGRA
   payload via `%RGB24->BGRA32-CROPPED` BEFORE checking the client
   list, then sends identical bytes to every client every frame; the
   runner's serve loop paces with a fixed `(sleep 0.016)`.

Shared rules for the tranche, inherited from Phase 26's discipline:
every hot-path commit is measured with `scripts/bench-ab.sh` against
the previous commit, 5+ interleaved pairs, BOTH implementations;
`PERFORMANCE_LOG.md` gets rows either way; a change that does not
separate from noise where its claim says it should gets reverted, not
kept. Suites green on SBCL and LispWorks after every commit (checked
LispWorks build too if a commit touches a `FAST-AREF` site). All new
`FAST-AREF` call sites carry the Phase 26 proof-comment contract.
Markdown stays ASCII-only.

Execution order: 27 -> 28 -> 30 unconditionally; 29 and 31 are
conditional on what the re-measured idle profile still shows after
that, in that order.

---

## Phase 27 -- Idle benchmark workloads

> **Done (2026-08-23)**, commits `0f0a561` (27a, the `idle` workload:
> `MAKE-IDLE-ROM`'s `JMP *` spin under the static mode-2 display
> setup) and `6bc8aba` (27b, the `serve` workload: the same machine
> pushed through a real in-process AESP server to one draining video
> client, with the EPERM skip path). 27c baseline recorded in
> `PERFORMANCE_LOG.md`: sbcl `idle` 1858 / `serve` 558 fps, lispworks
> `idle` 1003 / `serve` 229 fps -- `idle` tracks `display` as
> predicted, and the push path costs 2.3-3.4x the rest of the frame,
> confirming Phase 28's target. Suites green on both implementations.

Measurement first: none of the five existing workloads has the idle
shape. `nop` executes a NOP sled (memory-crossing work every 2
cycles, no renderer), `display` renders but also runs the sled, and
nothing at all exercises the AESP push path, where most of the
layer-3/4 waste lives. This phase adds two workloads and records the
tranche's baseline. No hot-path changes; no acceptance deltas.

**27a -- the `idle` workload.** In `scripts/bench.lisp`:

1. `MAKE-IDLE-ROM`: build with `%MAKE-ROM` like `MAKE-NOP-ROM`, but
   the reset code is a single `JMP *` (opcode `#x4C` targeting its own
   address) and the NMI/IRQ vectors point at plain `RTI` stubs. This
   is the canonical parked-machine CPU load.
2. Register `:idle` in `RUN-BENCHMARKS` (and its docstring / default
   workload list): run `MAKE-IDLE-ROM` with
   `%SETUP-DISPLAY-WORKLOAD` as the `:setup-fn`, so the machine
   displays the same static 24-line mode-2 screen every frame with
   the pixel renderer attached -- spin loop + unchanging screen.
3. Expected shape (verify, do not assume): `idle` fps should land
   near `display` fps today, because rendering dominates once the
   CPU is just spinning.

**27b -- the `serve` workload.** Same machine setup as `:idle`, plus
the AESP push path:

1. In the workload setup, `START-AESP-SERVER` on host 127.0.0.1 with
   all three ports 0 (OS-assigned; read back from the accessors),
   then connect ONE video client via the compat TCP layer and start a
   background thread that loops `READ-AESP-MESSAGE`, discarding
   payloads, until told to stop. Measure `MACHINE-RUN-FRAME`
   throughput with the post-frame push active. Teardown:
   stop the drain thread, close the client, `STOP-AESP-SERVER`.
2. Sandbox caveat: `TCP-LISTEN` can fail with EPERM in the sandboxed
   environment (the run-tests skill documents the same issue for the
   test suite). The workload must catch listener startup failure and
   SKIP with a printed reason, exactly as `:klaus` skips when its
   binary is missing. `bench-ab.sh` already renders a workload
   missing on the baseline side as "new workload"; that is fine.
3. Update the `benchmark` skill file
   (`.claude/skills/benchmark/SKILL.md`) with both new workloads.

**27c -- baseline rows.** Run `./scripts/bench-sbcl.sh` and
`./scripts/bench-lispworks.sh`; record `idle` and `serve` fps for
both implementations in `PERFORMANCE_LOG.md` as the tranche baseline.
If practical, also note allocation per served frame (SBCL: consing
reported by `TIME` around a frame loop; LispWorks: `EXTENDED-TIME` or
`ROOM` deltas) -- the ~322 KB/frame payload allocation predicts
roughly 19 MB/s of garbage at 60 fps, worth confirming before
Phase 28 claims to remove it.

Suites green on both implementations (nothing in `src/` changes, but
run them anyway -- the bench file is loaded by the harness scripts).

Commits: `bench: idle workload (JMP-self + static display)`,
`bench: serve workload (AESP push path with one video client)`.

---

## Phase 28 -- AESP push economics  [hot path -> benchmark]

> **Done (2026-08-23)**, commits `5784523` (28a gating), `f4900d8`
> (28b payload-buffer reuse), `a8d7851` (28c unchanged-frame dedup),
> `f2a0b2f` (28d deadline pacing), each bench-ab'd per the tranche
> rules; new AESP server tests in `tests/test-aesp.lisp`. Cumulative
> vs the Phase 27 tip: `serve` +70.7% CLEAN on sbcl (563 -> 961 fps)
> and +22.8% CLEAN on lispworks (232 -> 285 fps); every other
> workload within noise on both implementations. One instructive
> mid-phase catch: 28b's first cut passed the output buffer as an
> undeclared parameter and CLEANLY regressed sbcl `serve` -26% --
> generic AREF dispatch cost more than the allocation it removed --
> fixed by declaring the buffer types (amended into `f4900d8`; full
> story in `PERFORMANCE_LOG.md`). Suites green on both
> implementations after every commit.

Output-side only: nothing in this phase touches emulation state, so
there is zero accuracy risk (GTIA collisions live in `src/gtia.lisp`;
the renderer is pure presentation). The one contract to respect is
spelled out in `%PUSH-AUDIO-FRAME`'s docstring: the Nth `AUDIO_PCM`
pairs with the Nth `FRAME_RAW`, and A/V capture depends on that 1:1
cadence -- so dedup may skip WORK, never FRAMES.

**28a -- gate rendering and conversion on subscribers.**

1. Give `AESP-SERVER` a `video-active-p` boolean (or use the client
   count), updated under the server lock in `%REGISTER-VIDEO-CLIENT`
   / `%UNREGISTER-VIDEO-CLIENT`.
2. The `scanline-fn` closure wired in `START-AESP-SERVER` early-returns
   when no video client is connected (one slot read per scanline, 240
   per frame -- negligible; verify with the `display` workload
   staying in noise).
3. `%PUSH-VIDEO-FRAME` snapshots the client list FIRST and returns
   before any conversion when it is empty.
4. A client that connects mid-frame would otherwise see one partially
   rendered frame: set a `needs-full-render` flag in
   `%REGISTER-VIDEO-CLIENT` that forces rendering for the next full
   frame before the first push to that client. Mirror the shape of
   the existing `%SYNC-AUDIO-ATTACHMENT` mechanism, which already
   solves the same connect/disconnect problem for audio.

**28b -- reuse the FRAME_RAW payload buffer.**

1. Preallocate a `payload-buffer` slot on `AESP-SERVER` of size
   `(* +aesp-frame-raw-width+ 240 4)`; add
   `%RGB24->BGRA32-INTO` (same loop as `%RGB24->BGRA32-CROPPED`,
   writing into the supplied buffer) and use it from
   `%PUSH-VIDEO-FRAME`.
2. BEFORE reusing, verify the write path does not retain the payload
   after `WRITE-AESP-MESSAGE` returns (writes are synchronous on the
   emulator thread; read `WRITE-AESP-MESSAGE` and the transport code
   in `src/transport.lisp` to confirm no queuing keeps a reference).
   State the finding in the commit message.

**28c -- dedup unchanged frames at the push boundary.**

1. Keep a `prev-frame` copy of the RGB framebuffer plus a
   `payload-valid-p` flag on the server. After the frame's render, an
   `%FRAME-UNCHANGED-P` function byte-compares the framebuffer
   against `prev-frame` (plain `AREF` first; convert to `FAST-AREF`
   with a loop-bound proof only if a profile names the loop).
2. Unchanged and `payload-valid-p` -> skip the copy and the
   conversion, resend the cached payload to every client (resending
   preserves the 1:1 A/V pairing and client cadence; suppressing
   frames entirely is out of scope and would need a protocol note in
   the Attic project's docs/PROTOCOL.md first). Changed -> copy the
   framebuffer into `prev-frame`, convert once into the payload
   buffer, send.
3. Keep the comparison behind `%FRAME-UNCHANGED-P` as a single seam:
   Phase 29, if it lands, replaces the byte compare with a free
   dirty flag, and that swap should be one line.
4. Honest cost note for the log: the compare touches 2x ~276 KB on
   changed frames -- the win only materializes on unchanged frames,
   which is exactly the idle case. `serve` must improve; `display`
   (no AESP attached) must stay in noise.

**28d -- deadline-corrected serve pacing.** In `scripts/runner.lisp`
`RUN-FRAMES-AND-SERVE`: replace the fixed `(sleep 0.016)` with a
deadline accumulator -- `next-deadline += 1/59.92 s` per frame, sleep
`(max 0 (- deadline now))`, and clamp the deadline to now when behind
so a slow stretch does not trigger a catch-up spiral. This is a
pacing-correctness fix, not a throughput claim: verify by eye that a
served session holds ~59.92 fps; exclude it from bench-ab claims.
(`MACHINE-RUN-LOOP` itself needs no change -- it already parks on the
mailbox condvar when paused.)

Acceptance per commit: bench-ab vs the previous commit, 5+ pairs,
both implementations. `serve` improves where the stage claims it
(28a with zero clients connected is not measurable by `serve`, which
always has one client -- its claim is covered by `idle` staying flat
and the code being obviously gated; 28b and 28c must move `serve`),
and `nop`/`irq`/`display`/`audio` stay within noise on BOTH
implementations -- nothing in this phase touches emulation. Suites
green both implementations. `PERFORMANCE_LOG.md` rows per commit.

Commits: `aesp: gate rendering and conversion on video subscribers`,
`aesp: reuse the FRAME_RAW payload buffer`,
`aesp: dedup unchanged frames at the push boundary`,
`runner: deadline-corrected serve pacing`.

---

## Phase 29 -- Dirty-frame render skip  [hot path -> benchmark]  (conditional)

> **Gate evaluated (2026-08-23): GO.** Re-profiled the `idle` workload
> on both implementations with the Phase 18/26/30 methodology
> (`atari800-cl.compat:with-profiling` around a warmed-up machine, a
> throwaway scratchpad driver, sized to land at roughly 15-18s of wall
> clock -- not committed to src/).
>
> LispWorks (16000 frames, 15.65s, 1022 fps, 1248 samples), top 5 by
> self ("top"):
>
> | rank | function | self / incl |
> |------|----------|--------------|
> | 1 | %RENDER-CHAR-MODE | 19% / 40% |
> | 2 | BUS-READ | 9% / 9% |
> | 3 | %RUN-CLOCKS | 6% / 100% |
> | 4 | SYSTEM::LOGBITP$FIXNUM$FIXNUM | 5% / 5% |
> | 5 | SVREF-NO-CHECK$I-VECTOR$FIXNUM | 4% / 4% |
>
> (`RENDER-SCANLINE` itself: 2% self / 43% incl -- it is the frame's
> single largest inclusive consumer, `%RUN-CLOCKS`'s 100% aside, since
> that is the whole per-line loop.)
>
> SBCL (35000 frames, 17.15s, 2041 fps, 1786 samples over 8.93s of
> sampled CPU time), top 5 by self:
>
> | rank | function | self / total |
> |------|----------|---------------|
> | 1 | %RENDER-CHAR-MODE | 28.1% / 38.1% |
> | 2 | BUS-READ | 19.1% / 19.1% |
> | 3 | STEP-CPU | 8.8% / 39.0% |
> | 4 | %RUN-CLOCKS | 7.4% / 99.9% |
> | 5 | ASH | 6.4% / 6.4% |
>
> (`RENDER-SCANLINE`: 5.1% self / 43.2% total.)
>
> Combined renderer self time (`RENDER-SCANLINE` + `%RENDER-CHAR-MODE`
> + `%CHAR-ROW-BITS`, the framebuffer writes now folded into
> `%RENDER-CHAR-MODE`'s own self time by Phase 26's `FAST-AREF`
> inlining rather than showing as separate `%WRITE-RGB`/`%FILL-SPAN`
> entries): 24% of all samples on LispWorks (301/1248), 35% on SBCL
> (627/1786). `RENDER-SCANLINE`'s inclusive share lands within a point
> of each other on the two implementations (43% LispWorks, 43.2%
> SBCL) despite very different absolute fps and very different
> per-implementation array-access costs -- the renderer is not a
> LispWorks-specific artifact here, it is genuinely half of the idle
> frame's cost on both hosts. `%RENDER-CHAR-MODE` is the #1 self-time
> entry on SBCL and tied for #1 on LispWorks; nothing CPU-side (the
> whole point of `idle`'s bare `JMP *` spin) comes close. Verdict:
> **GO** -- the renderer dominates `idle` on both implementations,
> exactly the condition this gate's opening paragraph names, and it
> agrees with the fps-ratio framing from the Phase 30 close-out (idle
> at 54%/43% of `nop`).
>
> **29a instrumentation (GO, so this ran).** Booted the checked-in
> ROMs (`roms/ATARIXL.ROM` / `roms/ATARIBAS.ROM` -- an Altirra-compatible
> OS/BASIC image; screen banner reads "Altirra 8K BASIC 1.59", the
> same ROMs `tests/test-machine.lisp`'s real-ROM tests use) to the
> BASIC READY prompt (reached by frame 200), ran 120 more settle
> frames (to frame 320), then snapshotted all 64K of RAM every frame
> for 600 frames and diffed page-by-page (byte-content diff, not
> write-tracking) against the previous frame's snapshot -- a
> throwaway SBCL scratchpad script, not committed. ANTIC state at
> settle: display list at $9C20 (page $9C) -- confirmed by walking
> the DL bytes directly (`70 70 70 42 40 9C 02 02 ... 41 20 9C`: three
> blank-line codes, mode-2+LMS with operand $9C40, 23 more mode-2
> lines, then JVB back to $9C20); the LMS operand $9C40 (page $9C)
> matches the SAVMSC ($58/$59) shadow exactly; CHBASE register $E0 ->
> character set base $E000 (page $E0). Screen data spans $9C40-$9DBF
> (24 rows x 40 cols = 960 bytes), pages $9C-$9E.
>
> Census result: of 256 pages, exactly **2 ever changed** across all
> 600 frames -- page $00 (zero page: RTCLOK's jiffy counter and the
> ATRACT attract-mode counter both live there) and page $01 (the 6502
> hardware stack, whose residual bytes after VBI's register
> pushes/pops differ frame to frame) -- both dirty in 600/600 frames,
> every other page byte-identical in every one of the 600 frames.
> Pages $9C through $A0 (display list + screen RAM) and $E0-$E3
> (charset) were dirty in **0/600** frames -- the hypothesis 29a was
> scoped to confirm held exactly. This is a *stronger* result than
> the phase's own opening hypothesis text predicted ("OS shadow pages
> 0/2/3 written every VBI"): pages $02 and $03 did not change at all
> during this run; only zero page and the stack page ticked. OS
> attract-mode timekeeping does tick every frame (confirmed via zero
> page), it just does not spill into as many pages as the phase
> guessed.
>
> Design implication for 29b/29c: page granularity is confirmed
> necessary and sufficient -- a single global "any RAM write"
> boolean would see pages $00/$01 churn every frame and never signal
> clean, exactly the failure mode the phase's opening paragraph
> warns about, while a per-page map correctly excludes $00/$01 from
> the watched set (nothing there feeds ANTIC/GTIA) and sees the
> DL/screen/charset pages stay clean. The always-dirty set measured
> here (2 pages, not the predicted 3) means the dirty map's false-busy
> rate at idle is even lower than the roadmap anticipated -- no
> change to the 29b/29c design is indicated, only a tighter empirical
> bound on it.
>
> Phase 29 itself (29b/29c/29d, the actual dirty-map implementation)
> has not run; this evaluation is the gate plus 29a's analysis-only
> instrumentation, per spec. The phase stays open in the table below.

Gate: run this phase ONLY if, after Phases 27/28/30, a fresh profile
of the `idle` workload (Phase 18 methodology) still shows
`RENDER-SCANLINE` / `%RENDER-CHAR-MODE` dominating. If `idle` fps is
already near `nop` fps on both implementations, close the phase with
a not-needed status note instead.

The idea: track, per frame, whether anything that feeds the renderer
changed; when nothing did, skip all 240 `RENDER-SCANLINE` calls and
feed `%FRAME-UNCHANGED-P` (Phase 28c) for free. The risk: the
tracking store sits on the bus RAM write path, which is hot -- the
Phase 22 lesson (an extra inner-loop test once cost ~7% on `nop`)
applies, and the acceptance criteria below treat any `nop`/`irq`
movement as a veto.

**29a -- instrument first (throwaway, not committed to src).** Under
the real OS ROM parked at the READY prompt, establish which 256-byte
pages RAM writes actually touch per frame over ~600 frames (a scratch
script may wrap or copy the bus write path; it does not ship).
Hypothesis to confirm before building anything: the display list,
screen RAM, and charset pages are untouched frame-to-frame at READY,
while OS shadow pages (0/2/3) are written every VBI -- which is
exactly why a single global "any RAM write" boolean is useless and
page granularity is the minimum. Record the findings in the phase
status note.

**29b -- per-page dirty map.** `src/bus.lisp`: add a 256-entry
`(simple-array (unsigned-byte 8) (256))` page-dirty vector; the RAM
write path gains ONE store,
`(setf (aref dirty (ldb (byte 8 8) addr)) 1)` (a `FAST-AREF`
candidate with the index provably in range by `(ldb (byte 8 8) ...)`
construction -- carry the proof comment). Chip-register writes that
affect rendering set a single `regs-dirty` boolean from their
EXISTING (cold) write closures instead: enumerate the registers in
the commit message -- ANTIC `DMACTL/CHACTL/DLISTL/DLISTH/HSCROL/
VSCROL/PMBASE/CHBASE`, GTIA colors `COLPM0-3/COLPF0-3/COLBK`, `PRIOR`,
`GRAFP0-3/GRAFM`, `HPOSP0-3/HPOSM0-3`, `SIZEP0-3/SIZEM`, `GRACTL`,
plus P/M DMA state. When in doubt whether a register can affect
pixels, include it -- false dirt costs one redundant render, false
clean costs a wrong frame.

**29c -- consult at frame end.** In the post-frame path (before
`%PUSH-VIDEO-FRAME`): compute the frame's watched-page set from ANTIC
state -- the display-list pages the walk covered, the LMS screen
regions, `CHBASE` character-set pages, and `PMBASE` pages when P/M
DMA is on (ANTIC walks the display list every frame already; record
pages during the walk or recompute from latched state, whichever is
cheaper to keep exact). The frame is CLEAN iff no watched page is
dirty, `regs-dirty` is clear, and the previous frame was actually
rendered. CLEAN -> the `scanline-fn` gate from Phase 28a skips
rendering next frame and `%FRAME-UNCHANGED-P` returns T without
comparing. Any doubt (display-list walk anomaly, GTIA mode change
mid-frame) -> render; the displayed frame's correctness must never
depend on the map being precise, only the skip does. Clear the map
and flags after the decision.

**29d -- tests + acceptance.** `renderer-suite` (or `machine-suite`
where the full machine is needed): (1) poke one screen-memory byte
through the bus -> next frame re-renders and differs; (2) poke an
unrelated RAM page -> skip engages (assert via a render-call counter
hook) and the framebuffer is byte-identical; (3) write a color
register -> re-render. Suites green both implementations. bench-ab:
`idle` improves CLEAN on both implementations; `nop` and `irq` MUST
stay within noise on both -- if the dirty-map store separates cleanly
as a regression on either, the phase is reverted per the tranche
rule; `display` within noise or better.

Commits: `bus: per-page RAM write dirty map`,
`renderer: skip rendering clean frames`.

---

## Phase 30 -- Deferred POKEY advance  [hot path -> benchmark]

> **Done (2026-08-23)**, three commits plus this close-out: `14dae58`
> (machine lockstep equivalence harness, no behavior change), `4875544`
> (30a, sync-on-access plumbing: `pokey-lag` / `pokey-defer-disabled-p`
> / `pokey-defer-engagements` / `pokey-defer-break-p` on
> `ATARI-MACHINE`, `%MACHINE-SYNC-POKEY`, wrapped `$D2xx` bus closures),
> `f123fcb` (30b, the scheduler gate: per-line `POKEY-DEFERRABLE-P` plus
> split defer/non-defer instruction loops in `%RUN-CLOCKS`). Measured
> with `scripts/bench-ab.sh` (5+ interleaved pairs, both
> implementations) per the tranche rules: 30a stayed in noise
> everywhere as required (pure plumbing, unreachable until 30b); 30b's
> `f123fcb` vs `4875544` delta separated CLEAN on `nop` on BOTH
> implementations (sbcl +35.0%, lispworks +35.2% -- the rare phase
> where SBCL was expected to move too, per this phase's own opening:
> "32% self time is the prize"), with `display`/`idle` also CLEAN or
> strongly positive on both, `irq`/`audio` flat as predicted (the gate
> excludes both by construction), and `serve` flat (AESP-push-dominated,
> not POKEY-dominated). The reason the lockstep harness (`14dae58`)
> exists: `MACHINE-LOCKSTEP-DEFER-ON-VS-OFF`
> (`tests/test-machine.lisp`) ran 64 frames of two otherwise-identical
> machines -- one at deferral's default, one with
> `POKEY-DEFER-DISABLED-P` forced -- through identical mid-run POKEY
> pokes crossing both the defer-engaged and defer-broken (timer-IRQ-
> enabled) regimes, and found byte-identical POKEY/CPU/RAM state on
> every single frame, exactly as the batching-is-EXACT argument
> predicts; separate assertions confirmed the deferring machine actually
> engaged the gate (`POKEY-DEFER-ENGAGEMENTS` > 0) and the disabled one
> never did, so the pass is not vacuous. Re-profiling LispWorks `nop`
> and `display` with the Phase 18/26 `hcl` methodology confirmed the
> predicted collapse: `POKEY-ADVANCE` fell from the #1 self-time entry
> at the Phase 26 close-out (28% self / 51% incl on `nop`, 11% / 19% on
> `display`) to 7% / 13% on `nop` (tied for 5th/6th place with array
> internals) and 3% / 5% on `display` (11th place) -- the CPU core's own
> `%RUN-CLOCKS`/`STEP-CPU`/`BUS-READ` now occupy most of `nop`'s top 5.
> Full suites green on both implementations (sbcl 2700/2686/0,
> lispworks 2703/2689/0 -- checks/pass/fail); the CPU core itself is
> untouched by this phase, so per item 30c/4 no Harte re-run beyond the
> standard suite was required. See `PERFORMANCE_LOG.md`'s "ROADMAP
> Phase 30" section for the full A/B tables and re-profile tables.
> Phases 29 and 31 remain conditional -- both are gated on a fresh
> `idle` re-profile this close-out did not run (30d only re-profiled
> `nop` and `display` per spec); whether `idle` still shows the
> renderer or the CPU spin itself dominating after this phase's gains
> is an open question for whichever of 29/31 gets picked up next.

The Phase 26 close-out profile still puts `POKEY-ADVANCE` first on
LispWorks `nop` (28% self) and SBCL `nop` (32% self). The cost is no
longer array dispatch: `POKEY-ADVANCE` already event-skips WITHIN a
call (it jumps between sub-counter expiries; see its docstring). What
remains is the call pattern -- `%RUN-CLOCKS` invokes it after EVERY
instruction in 2-7 cycle chunks, so the function-call overhead and
chunk bookkeeping run ~15-50x per scanline. When nothing observable
can happen, those calls are pure overhead, and batching them is
EXACT: `POKEY-ADVANCE` by A then by B is bit-identical to one advance
by A+B (each is equivalent to that many `POKEY-TICK`s -- the property
`pokey-tick-vs-advance-equivalence` already pins), so the ONLY ways
deferral could be observed are (a) the CPU touching a POKEY register
mid-line, or (b) POKEY raising an IRQ mid-line. (a) gets a sync; (b)
is excluded by the gate. This mirrors the chip's existing lazy-RNG
design: `POKEY-RNG-LAG` + `%SYNC-RNG` already defer LFSR stepping to
the next `RANDOM` read -- this phase applies the same idea one level
up.

**30a -- sync-on-access plumbing.**

1. The machine (or the scheduler's line loop) keeps a `pokey-lag`
   fixnum: cycles POKEY is behind the CPU within the current line.
   `%MACHINE-SYNC-POKEY`: when the lag is positive, `POKEY-ADVANCE`
   by it and zero it.
2. In `MAKE-ATARI-MACHINE`'s bus wiring, wrap the POKEY read AND
   write closures registered for `$D200-$D2FF` so every access syncs
   first -- `RANDOM`, `IRQST`, `STIMER`, `IRQEN`, `AUDF*`, `AUDC*`,
   `AUDCTL`, `SKCTL` and friends then always see exact state.
3. Audit every path that reads or mutates POKEY state WITHOUT going
   through the bus: `ATTACH-POKEY-INPUT`, `MACHINE-ATTACH-AUDIO`,
   AESP's `%SYNC-AUDIO-ATTACHMENT`, REPL instrumentation, tests.
   Each either provably runs between frames -- where the lag is zero
   because of the line-end sync in 30b -- or must call
   `%MACHINE-SYNC-POKEY` itself. List each audited path and its
   disposition in the commit message.

**30b -- the scheduler gate.** In `%RUN-CLOCKS`:

1. Once PER LINE compute
   `defer-p = (and (null audio-attachment) (zerop pending)
   (zerop (logand (pokey-irqen pokey)
                  (logior +irq-timer1+ +irq-timer2+ +irq-timer4+))))`.
   With `defer-p`: skip the per-instruction `POKEY-ADVANCE` call and
   accumulate the instruction's cycles into the lag instead; the
   existing "top POKEY up to exactly this line's cycle count" step at
   line end becomes the sync point (its `pokey-remaining` arithmetic
   already advances whatever the per-instruction path did not).
   Without `defer-p`: byte-for-byte today's behavior.
2. A mid-line `$D2xx` WRITE can invalidate the gate (enable a timer
   IRQ, set `PENDING`, start audio): the write wrapper from 30a, in
   addition to syncing, clears `defer-p` for the remainder of the
   line -- the simple, obviously-correct rule; do not try to
   recompute eligibility mid-line.
3. Heed the Phase 22 lesson quoted in `POKEY-ADVANCE`'s own
   docstring: an extra test in this inner loop once cost ~7% on
   `nop`. The defer test must be hoisted out of the per-instruction
   loop -- split the instruction loop into defer and no-defer
   variants (the same shape `advance-loop` uses to split on audio)
   so the deferring loop contains NO new per-instruction test at all.

**30c -- proof and tests.**

1. Because `defer-p` requires all timer IRQ enables clear, no IRQ can
   be delayed by deferral -- state this invariant where the gate is
   computed.
2. Machine-level equivalence test: a debug flag (test-only slot or
   special) forces deferral off; run a synthetic-ROM machine N frames
   both ways -- including mid-run `AUDF`/`AUDCTL`/`STIMER`/`IRQEN`
   pokes through the bus -- and compare the complete POKEY struct
   state, CPU state, and IRQ delivery counts each frame. Byte-identical
   or the phase is wrong.
3. A test asserting deferral never engages while a timer IRQ enable
   bit is set (expose an engagement counter under the debug flag).
4. Full suites both implementations; the CPU core is untouched so no
   Harte re-run beyond the standard suite is required.

**30d -- measurement.** bench-ab vs the previous commit, 5+ pairs,
both implementations. Expectations: `nop` and `idle` improve on BOTH
implementations -- this is the rare phase where SBCL is supposed to
move too (32% self time is the prize); `irq` within noise (the gate
disengages under timer IRQs; only the once-per-line test is added);
`audio` within noise (audio attached -> defer off); `display`/`serve`
inherit the spin-side gain. `PERFORMANCE_LOG.md` rows; re-profile
LispWorks `nop` and record the new top-5 -- `POKEY-ADVANCE`'s share
should collapse toward the CPU core's.

Commits: `machine: sync-on-access plumbing for deferred POKEY`,
`machine: defer per-instruction POKEY advance when unobservable`.

---

## Phase 31 -- Spin-loop fast-forward  [hot path -> benchmark]  (conditional, opt-in)

Gate: run this phase ONLY if, after Phases 28 and 30, the `idle`
workload remains materially below `nop` on either implementation AND
a profile blames the CPU spin itself. Otherwise close with a
not-needed note. This is the one phase in the tranche that can bend
timing, so it ships OFF by default and stays deliberately minimal.

Design -- detect exactly `JMP *`, nothing more:

1. `ATARI-MACHINE` gains an `idle-skip-p` flag, default NIL. Exposed
   as a keyword on the `a800` facade constructor only; no AESP
   control message, no env var -- keep the surface minimal.
2. In `%RUN-CLOCKS`' instruction loop, when the flag is on: remember
   the PC before `STEP-CPU`; afterwards, if the PC is unchanged AND
   the opcode byte at that PC is `#x4C` (read it via `CPU-BUS-READ`
   ONLY when the PC lies outside `$D000-$D7FF`; a PC inside I/O
   space aborts the check rather than risk a side-effecting read),
   the CPU is in a zero-side-effect absolute-jump-to-self loop: set
   `cpu-budget` to 0. The line's remaining budget is burned without
   stepping -- no instruction is simulated or skipped, the loop
   simply stops iterating this line. Do NOT match branch-to-self or
   anything else: an instruction that leaves PC unchanged but has
   side effects (contrived `RTS`-to-self stack tricks) must keep
   executing, and the `#x4C` opcode check is what excludes them.
3. What stays exact: all per-line ANTIC/POKEY/renderer processing
   (scanline granularity is untouched); the machine's architectural
   state, because `JMP *` iterations have no effects. What bends:
   a pending IRQ/NMI is serviced by `STEP-CPU` at the next line's
   first step instead of mid-line, so interrupt latency can grow by
   up to ~113 cycles -- ONLY while the flag is on and ONLY inside a
   `JMP *` loop. State this in the flag's docstring and in
   README.md's known-limitations list.

Tests (`machine-suite`): (1) a `JMP *` ROM run N frames with the flag
on vs off yields identical architectural state -- CPU registers,
memory, chip registers, framebuffer (compare state, not internal
budget/cycle bookkeeping); (2) an IRQ raised during the spin is
serviced within one scanline under both settings; (3) the flag
defaults to NIL and the whole suite runs with it off -- the suite
itself is the no-behavior-change proof.

Measurement: report `idle` with the flag on as a separate BENCH line
(an `idle-skip` variant in `scripts/bench.lisp`) so the default
`idle` row stays honest; `nop`/`irq`/`display`/`audio` with the flag
off must sit within noise on both implementations (the flag test in
the instruction loop is the only added cost -- if it separates as a
regression, hoist it the way 30b hoists `defer-p`, or revert).

Commit: `machine: opt-in JMP-self spin-loop fast-forward`.

---

## Roadmap definition of done

- Suite green on SBCL and LispWorks after every phase (rule 2).
- `./scripts/record.sh asm/edvent02_rasterbars.asm -frames 300` yields
  an mp4 with visible animated raster bars and (once a demo uses
  POKEY) audible tone.
- `PERFORMANCE_LOG.md` has rows for phases 3, 5, 6, 9.
- The plan status headers reflect reality. As of 2026-08-07:
  `SCANLINE_ACCURACY_PLAN.md` Phases 0-3 done, stretch 4-5 open (Phase
  17 below is their prerequisite); `MISC_IMPROVEMENTS_PLAN.md` items
  1-8 done, 9 and 10 open, 11 obsolete (superseded by item 4);
  `PERFORMANCE_PLAN.md` Phases 0-3 done (2 rejected on measurement),
  Phase 4 open as Phase 18 below.
- Acid800's CPU + ANTIC subsets under the real OS ROM: gated as of
  Phase 24 (previously aspirational) -- 7/20 tests required-passing
  (4 CPU + 3 ANTIC), the other 13 documented, permanent skips in
  `+ACID800-KNOWN-ISSUES+` (`tests/test-machine.lisp`); see that
  phase's status entry and `CHANGES.md` for the full per-test triage.

For the 13-24 tranche, done means: the machine can be typed at (13) and
booted from a disk image (16), the Harte data is one command away (14)
and checks bus traces rather than cycle counts alone (17), the docs
match the code (15, 20), a suite pass on this machine proves the
real-ROM paths instead of skipping them (21), the POKEY hot path
carries one pending-work test instead of four (22), no bare CONFIRM
flag remains anywhere (23), and Acid800's CPU subset passes under the
real OS (24) -- delivered; the ANTIC subset's remaining 10 documented
gaps are follow-up work for Phase 17/SCANLINE_ACCURACY_PLAN and beyond,
not blockers for this tranche.
