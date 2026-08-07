# Protocol comparison harness

Cross-checks `atari800-cl` and Attic's `AtticServer` against the frozen
AESP and CLI protocol specifications described in
[`docs/PROTOCOL.md`](https://github.com/huegli/attic/blob/main/docs/PROTOCOL.md)
within the Attic repo.

The harness sits **above** both projects: it speaks AESP and the CLI
text protocol directly, treating each emulator as a black box behind
its protocol sockets. It does not link to either codebase -- comparison
runs the real servers on a temporary port triple and Unix socket, fires
requests, and classifies the responses.

The primary entry point is
`tools/protocol-comparison/compare-protocols.py`; everyday use goes
through `scripts/compare-attic-protocols.sh`.

## Quick start

```sh
# Capability probes -- does this environment allow live socket tests?
scripts/compare-attic-protocols.sh --probe

# Pure codec/spec self-tests (no servers).
scripts/compare-attic-protocols.sh --self-test

# Run all Phase 1 cases against both implementations.
scripts/compare-attic-protocols.sh

# Run against only one implementation.
scripts/compare-attic-protocols.sh --implementations atari800-cl
scripts/compare-attic-protocols.sh --implementations attic

# Run a subset of cases.
scripts/compare-attic-protocols.sh --cases aesp.control.ping,cli.core.ping
```

Reports land in `tools/protocol-comparison/reports/<timestamp>/`
(`summary.md`, `summary.json`, `cases.jsonl`, `failures.md`,
`feature-matrix.md`, plus `raw/` and `logs/`).

## Architecture

```
compare-protocols.py
  |-- probes.py        environment capability probes
  |-- adapters.py      Attic / atari800-cl process adapters
  |     `-- start-atari800-cl-server.lisp  (SBCL/LispWorks launcher)
  |-- aesp_codec.py    AESP wire format
  |-- cli_codec.py     CLI text protocol
  |-- protocol_spec.py message/command inventories
  |-- normalizers.py   raw bytes/lines -> semantic records
  |-- expectations.py  case-level matching + cross-impl classification
  |-- runner.py        per-case execution
  `-- reporters.py     summary/feature-matrix/failures output
```

### Implementation conformance

A case classifies into one of:

| Class                 | Meaning                                                                |
| --------------------- | ---------------------------------------------------------------------- |
| `pass`                | Both implementations conform to the spec for this case.                |
| `accepted_difference` | Both conform, but produce implementation-specific values/formatting.   |
| `attic_failure`       | atari800-cl conforms, Attic does not.                                  |
| `atari800_cl_failure` | Attic conforms, atari800-cl does not.                                  |
| `both_failure`        | Neither implementation conforms.                                       |
| `unsupported`         | Optional feature missing as expected by current case policy.           |
| `harness_error`       | Case definition invalid or the harness itself faulted.                 |

### Implementation status

Both implementations support custom AESP ports and CLI socket paths,
so the harness picks free ports/temp socket paths up front and passes
them to each server. atari800-cl additionally accepts port `0` to mean
"ephemeral"; Attic does not (the harness handles this transparently).

| Feature                                      | atari800-cl    | Attic  |
| -------------------------------------------- | -------------- | ------ |
| Custom AESP ports                            | yes (or 0)     | yes    |
| Custom CLI Unix socket path                  | yes            | yes    |
| `--no-aesp` / `--no-cli-socket`              | n/a            | yes    |
| Auto-ROM resolution                          | yes (built-in) | yes    |

### atari800-cl launcher

`start-atari800-cl-server.lisp` reads endpoint configuration from
environment variables (`A800_CONTROL_PORT`, `A800_VIDEO_PORT`,
`A800_AUDIO_PORT`, `A800_CLI_SOCKET`, `A800_HOST`) and prints a single
`ATARI800-CL-READY <json>` line on stdout once the AESP and CLI
servers are bound. The Python adapter waits for that line, parses the
JSON, then PINGs the control port to confirm.

The launcher follows the same ASDF source-registry / output-translation
discipline as `scripts/test-sbcl.sh` so it works under
`sbcl --no-userinit` without touching `~/quicklisp/local-projects/`.

### Attic adapter

`AtticAdapter` runs `swift build --product AtticServer` once, then
`swift run --skip-build AtticServer --control-port N --video-port N+1
--audio-port N+2 --socket-path /tmp/attic-XXXX/cli.sock --silent`. It
detects readiness by repeatedly attempting a PING on the control port
(the most reliable signal across Attic versions).

## Cases

Cases live in `cases/*.json` (the harness will load `*.yaml` too if
`PyYAML` happens to be installed). Each file is a JSON list of case
objects:

```json
{
  "id": "aesp.control.ping",
  "protocol": "aesp",
  "channel": "control",
  "request": { "type": "PING", "payload_hex": "" },
  "expectation": {
    "response": { "type": "PONG", "payload": { "class": "empty_or_ignored" } },
    "compare": { "mode": "semantic" },
    "required": { "atari800-cl": true, "attic": true }
  }
}
```

Phase 1 covers AESP control-plane round-trips, invalid-frame handling,
and the CLI core commands. Phases 2-4 (deterministic memory/register
flows, AESP input/subscription, Attic-complete CLI families) are listed
in `ATARI800-CL-to-ATTIC-COMPARISON.md` and can be added by dropping
new JSON files into `cases/`.

## Skip policy

When `--probe` shows TCP loopback or Unix sockets are unavailable, the
harness exits with code `3` rather than producing spurious failures.
The pure-codec `--self-test` mode always runs and is the right thing to
run in CI sandboxes.

## Open decisions

The plan in `ATARI800-CL-to-ATTIC-COMPARISON.md` enumerates several
policy decisions (e.g. whether the full Attic CLI surface is a hard
requirement for atari800-cl, whether frame/PCM streaming is required).
The default case suite uses the conservative reading: AESP control plus
CLI core are required of both implementations; everything else is
optional until you opt in.
