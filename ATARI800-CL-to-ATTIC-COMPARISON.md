# atari800-cl to Attic Protocol Comparison Framework Plan

## Goal

Build a protocol comparison framework that verifies that `atari800-cl` and Attic's `AtticServer` both conform to the frozen AESP and CLI protocol specifications, without requiring the two implementations to be bit-exact where the specification allows implementation-specific behavior.

The framework should:

- Treat Attic `docs/PROTOCOL.md` as the normative protocol specification.
- Exercise both implementations through their public protocol surfaces, not private internals.
- Distinguish wire-format conformance from emulator-state equivalence.
- Report differences as one of:
  - `pass`: both implementations conform to the spec for the case.
  - `accepted_difference`: both conform, but differ in permitted values, ordering, timing, formatting, or unsupported optional features.
  - `atari800_cl_failure`: Attic conforms, atari800-cl does not.
  - `attic_failure`: atari800-cl conforms, Attic does not.
  - `both_failure`: neither implementation conforms.
  - `unsupported`: a protocol feature is not implemented by one or both implementations and the current expectation marks it as not yet required.
  - `inconclusive`: the test environment prevented a reliable comparison.

## Known local project paths and launch commands

- `atari800-cl` path: `/Users/nikolai/common-lisp/atari800-cl`
- Attic path: `/Users/nikolai/Source/Repos/GitHub/huegli/attic`
- Attic server launch command: `swift run AtticServer`
- atari800-cl test runners already available:
  - `./scripts/test-sbcl.sh`
  - `./scripts/test-lispworks.sh`

Existing atari800-cl protocol files to inspect before implementation:

- `README.md`, section `Protocol servers (AESP + CLI)`
- `AI-Docs/AESP-CLI-Protocol-Plan.md`
- `src/aesp.lisp`
- `src/cli-socket.lisp`
- `src/transport.lisp`
- `src/compat.lisp`
- `tests/test-aesp.lisp`
- `tests/test-cli-socket.lisp`
- `tests/test-compat.lisp`
- `tests/test-helpers.lisp`

Existing Attic protocol files to inspect before implementation:

- `docs/PROTOCOL.md`
- `Sources/AtticServer/AtticServer.swift`
- `Sources/AtticProtocol/AESPMessage.swift`
- `Sources/AtticProtocol/AESPMessageType.swift`
- `Sources/AtticProtocol/AESPServer.swift`
- `Sources/AtticCore/CLIProtocol.swift`
- `Sources/AtticCore/CLISocketServer.swift`
- `Tests/AtticProtocolTests/*`
- `Tests/AtticCoreTests/CLIProtocolTests.swift`
- `Tests/AtticCoreTests/CLISocketTests.swift`

## Important constraints

### Conformance is not bit-exactness

Do not fail a comparison merely because payload strings, informational metadata, timing, frame contents, or error text differ unless the protocol specification requires exact values. Normalize responses before comparing.

Examples of likely non-bit-exact but acceptable differences:

- `INFO` payload content may differ by implementation name, emulator state, version, supported features, or formatting.
- `STATUS` payload content may differ in counters, frame numbers, timing fields, or machine-specific state as long as the payload is valid according to the spec.
- `ERROR` payload strings may differ as long as an invalid request yields an error response of the correct type/category.
- `ACK` payloads may be empty or contain implementation-defined details if the spec permits this.
- CLI `version` output may name a different implementation.
- CLI errors may differ in wording while still satisfying the expected error class.

### Live sockets may not be available in all environments

The atari800-cl test suite already contains skip probes for environments where TCP listener binds or Unix-domain socket listener binds are denied. Preserve and reuse that approach.

The comparison framework must support these modes:

1. `live`: start both servers and connect over TCP and Unix-domain sockets.
2. `adapter-only`: test codecs, parsers, serializers, and response normalizers without binding sockets.
3. `atari800-cl-only`: run atari800-cl conformance cases when Attic is unavailable.
4. `attic-only`: run Attic conformance cases when atari800-cl is unavailable.

A tool-calling LLM implementing this should first determine whether the local environment permits:

- TCP binds on loopback.
- TCP connects to loopback.
- Unix-domain socket binds.
- Unix-domain socket connects.
- Launching `swift run AtticServer` from the Attic repository.
- Launching an atari800-cl protocol server under SBCL.
- Launching an atari800-cl protocol server under LispWorks, if LispWorks is configured.

If any required capability is missing, emit `inconclusive` or skip with a precise reason instead of forcing a failure.

## Target architecture

Create a new comparison harness under `tools/protocol-comparison/` in `atari800-cl`.

Suggested layout:

```text
tools/protocol-comparison/
  README.md
  compare-protocols.py
  protocol_spec.py
  aesp_codec.py
  cli_codec.py
  process_manager.py
  adapters.py
  normalizers.py
  expectations.py
  reporters.py
  cases/
    aesp_control.yaml
    aesp_input.yaml
    aesp_video.yaml
    aesp_audio.yaml
    cli_core.yaml
    cli_memory.yaml
    cli_registers.yaml
    cli_debugger.yaml
    cli_disk_basic_dos.yaml
  fixtures/
    invalid_aesp_frames.yaml
    cli_command_matrix.yaml
  reports/
    .gitkeep
```

Use Python for the cross-project comparison harness because it can easily:

- Spawn Swift and Lisp processes.
- Connect to TCP sockets.
- Connect to Unix-domain sockets.
- Encode/decode binary protocol frames.
- Produce structured JSON and Markdown reports.
- Run from a developer shell without requiring either implementation to import code from the other.

Keep Common Lisp tests as implementation-local tests. The comparison harness should sit above both implementations.

## Server adapter model

Define an adapter interface with these operations:

```python
class ProtocolImplementation:
    name: str
    capabilities: set[str]

    def start(self) -> None: ...
    def stop(self) -> None: ...
    def connect_aesp_control(self) -> BinaryConnection: ...
    def connect_aesp_video(self) -> BinaryConnection: ...
    def connect_aesp_audio(self) -> BinaryConnection: ...
    def connect_cli(self) -> TextConnection: ...
```

Implement two concrete adapters:

### Attic adapter

Responsibilities:

- Run `swift run AtticServer` in `/Users/nikolai/Source/Repos/GitHub/huegli/attic`.
- Prefer command-line flags that force deterministic ports and socket paths if available.
- If Attic supports choosing port base and CLI socket path, use a temporary isolated allocation instead of the default ports.
- Detect readiness by parsing stdout/stderr and/or actively probing ports.
- Stop the process gracefully, then forcibly kill on timeout.

Implementation notes:

- Inspect `Sources/AtticServer/AtticServer.swift` to identify supported flags.
- Confirm whether `--no-aesp`, web mode, custom port, and custom socket path flags exist.
- Never assume the server is ready immediately after process spawn.
- Capture logs into the report directory for failed cases.

### atari800-cl adapter

Responsibilities:

- Start an SBCL subprocess that loads `:atari800-cl`, creates a machine, starts the machine runner, starts AESP, starts CLI, prints a readiness record, and waits until terminated.
- Optionally support a LispWorks variant after the SBCL path works.
- Use temporary isolated ports and socket path if the atari800-cl API supports that.
- Stop AESP, stop CLI, and stop the machine in an unwind-protect/finalizer path.

Create a helper script, for example:

```text
tools/protocol-comparison/start-atari800-cl-server.lisp
```

The script should:

- Avoid relying on user init files.
- Use the same ASDF source/output registry discipline as `scripts/test-sbcl.sh`.
- Accept environment variables or command-line arguments for:
  - control port
  - video port
  - audio port
  - CLI socket path
  - readiness file path
- Print a single machine-readable JSON readiness line such as:

```json
{"implementation":"atari800-cl","aesp_control":49100,"aesp_video":49101,"aesp_audio":49102,"cli_socket":"/tmp/atari800-cl-compare-...sock"}
```

If the existing atari800-cl server API does not expose custom ports or custom socket paths, add that as a small prerequisite change before implementing the full harness.

## Port and socket allocation

Avoid default ports during automated comparison because Attic defaults to `47800` to `47802`, and parallel runs or stale servers could collide.

Implement a resource allocator that:

- Finds a free contiguous TCP port triple for AESP.
- Reserves unique Unix socket paths under a temporary directory.
- Passes the chosen values into each adapter if possible.
- Validates that the server actually listens on the assigned endpoints.
- Deletes stale Unix socket paths before startup.
- Cleans up Unix socket files after shutdown.

If one implementation cannot bind custom ports, mark the adapter as requiring defaults and serialize those cases.

## Protocol model

Encode the protocol specification explicitly in the harness rather than scraping it dynamically.

### AESP core constants

From Attic `docs/PROTOCOL.md`:

- Header length: 8 bytes.
- Magic: `0xAE50`.
- Version: `0x01`.
- Type: 1 unsigned byte.
- Payload length: 4-byte unsigned big-endian.
- Maximum payload size: 16 MiB.
- Multi-byte AESP integers: big-endian unless the spec explicitly says otherwise.
- Ports/channels:
  - control: default `47800`
  - video: default `47801`
  - audio: default `47802`
  - websocket bridge: default `47803`, out of scope for the first comparison pass.

### AESP message inventory

Represent at least these message types:

```python
AESP_MESSAGES = {
    0x00: "PING",
    0x01: "PONG",
    0x02: "PAUSE",
    0x03: "RESUME",
    0x04: "RESET",
    0x05: "STATUS",
    0x06: "INFO",
    0x07: "BOOT_FILE",
    0x0F: "ACK",
    0x3F: "ERROR",
    0x40: "KEY_DOWN",
    0x41: "KEY_UP",
    0x42: "JOYSTICK",
    0x43: "CONSOLE_KEYS",
    0x44: "PADDLE",
    0x60: "FRAME_RAW",
    0x61: "FRAME_DELTA",
    0x62: "FRAME_CONFIG",
    0x63: "VIDEO_SUBSCRIBE",
    0x64: "VIDEO_UNSUBSCRIBE",
    0x80: "AUDIO_PCM",
    0x81: "AUDIO_CONFIG",
    0x82: "AUDIO_SYNC",
    0x83: "AUDIO_SUBSCRIBE",
    0x84: "AUDIO_UNSUBSCRIBE",
}
```

### CLI command inventory

Represent at least these CLI command families from Attic `docs/PROTOCOL.md`:

Core and control:

- `ping`
- `pause`
- `resume`
- `step`
- `stepover`
- `until`
- `boot`
- `version`
- `reset`
- `status`
- `quit`
- `shutdown`

Memory and CPU:

- `read`
- `write`
- `fill`
- `screen`
- `registers`
- `disassemble`
- `assemble`

Debugging:

- `breakpoint set`
- `breakpoint clear`
- `breakpoint clearall`
- `breakpoint list`

Disk/state/media:

- `mount`
- `unmount`
- `drives`
- `state save`
- `state load`
- `screenshot`

Input/BASIC/DOS:

- `inject basic`
- `inject keys`
- `basic ...`
- `dos ...`

For the first implementation pass, include all commands in the matrix but mark commands outside atari800-cl's current MVP support as `unsupported_expected_for_atari800_cl` unless the user wants to make protocol completeness a hard requirement.

## Normalization rules

Create one normalizer per protocol response type. The normalizer should convert raw responses into semantic records.

### AESP normalization

Normalize AESP responses to:

```json
{
  "type": "PONG|ACK|ERROR|STATUS|INFO|FRAME_CONFIG|AUDIO_CONFIG|FRAME_RAW|AUDIO_PCM|...",
  "valid_header": true,
  "magic": "0xAE50",
  "version": 1,
  "payload_length_matches": true,
  "payload_class": "empty|text|json|binary|config|frame|audio|error",
  "semantic_fields": {},
  "raw_payload_sha256": "..."
}
```

Do not compare raw payload bytes unless the case expectation says `exact_payload: true`.

Useful semantic checks:

- `PING` response must be `PONG` with a valid AESP header.
- `PAUSE`, `RESUME`, input events, `VIDEO_UNSUBSCRIBE`, and `AUDIO_UNSUBSCRIBE` should usually respond with `ACK` or a spec-permitted response.
- `STATUS` response must be parseable according to the spec. If the spec permits text or JSON, classify accordingly.
- `INFO` response must be parseable according to the spec and should identify the implementation in some form if required.
- `VIDEO_SUBSCRIBE` should yield `FRAME_CONFIG` and may then yield frame messages if implemented.
- `AUDIO_SUBSCRIBE` should yield `AUDIO_CONFIG` and may then yield PCM/sync messages if implemented.
- Unknown or malformed message types should yield `ERROR` or disconnect in a spec-permitted way.

### CLI normalization

Normalize CLI replies to:

```json
{
  "status": "OK|ERR|disconnect|timeout",
  "verb": "ping|status|read|...",
  "data_class": "empty|pong|version|status|memory_dump|registers|list|error_text|implementation_text",
  "semantic_fields": {},
  "raw_line": "..."
}
```

General CLI rules:

- Requests are newline terminated.
- Requests use `CMD:<verb> [args]` for the wire-level text protocol where applicable.
- Successful replies start with `OK:`.
- Failed replies start with `ERR:`.
- Ignore exact capitalization in implementation-specific free text unless the spec requires it.
- Strip trailing whitespace before comparison.
- Preserve raw lines in reports.

## Test-case format

Use YAML or JSON test case files so a tool-calling LLM can add coverage without editing harness code.

Example AESP case:

```yaml
- id: aesp.control.ping
  protocol: aesp
  channel: control
  request:
    type: PING
    payload_hex: ""
  expectation:
    response:
      type: PONG
      payload:
        class: empty_or_ignored
    compare:
      mode: semantic
    required:
      atari800_cl: true
      attic: true
```

Example CLI case:

```yaml
- id: cli.core.ping
  protocol: cli
  request:
    line: "CMD:ping\n"
  expectation:
    response:
      status: OK
      data_class: pong
    compare:
      mode: semantic
    required:
      atari800_cl: true
      attic: true
```

Example optional feature case:

```yaml
- id: cli.debugger.breakpoint_list
  protocol: cli
  request:
    line: "CMD:breakpoint list\n"
  expectation:
    response:
      status: OK
      data_class: list
    compare:
      mode: semantic
    required:
      attic: true
      atari800_cl: false
    unsupported_policy:
      atari800_cl: accepted
```

Example invalid AESP case:

```yaml
- id: aesp.invalid.bad_magic
  protocol: aesp
  channel: control
  request:
    raw_hex: "0000010000000000"
  expectation:
    response:
      one_of:
        - type: ERROR
        - connection_closed: true
    compare:
      mode: semantic
    required:
      atari800_cl: true
      attic: true
```

## Comparison algorithm

For each case:

1. Load case definition.
2. Validate the case definition against a schema before running.
3. For each selected implementation:
   1. Ensure the implementation is started.
   2. Ensure the required protocol endpoint is reachable.
   3. Send the request.
   4. Read one or more responses according to case timeout and response count policy.
   5. Decode the raw response.
   6. Normalize the response.
   7. Evaluate against the protocol expectation.
4. Compare semantic results across implementations.
5. Assign a classification:
   - both pass and semantic normalized result compatible: `pass`
   - both pass but normalized implementation-specific fields differ: `accepted_difference`
   - one fails expectation: implementation-specific failure
   - both fail expectation: `both_failure`
   - optional feature missing as expected: `unsupported`
6. Record raw request/response bytes or lines, normalized results, logs, and timing.
7. Continue to the next case unless startup failed globally.

## Initial case suite

### Phase 1: smoke and wire-format conformance

Implement these first because they quickly validate the harness:

AESP:

- `aesp.control.ping`: PING -> PONG.
- `aesp.control.pause`: PAUSE -> ACK or spec-valid response.
- `aesp.control.resume`: RESUME -> ACK or spec-valid response.
- `aesp.control.reset`: RESET cold/warm/default payload variants as specified.
- `aesp.control.status`: STATUS -> spec-valid status payload.
- `aesp.control.info`: INFO -> spec-valid info payload.
- `aesp.invalid.bad_magic`: bad magic -> ERROR or close, according to spec.
- `aesp.invalid.bad_version`: unsupported version -> ERROR or close, according to spec.
- `aesp.invalid.length_too_large`: oversized payload length -> ERROR or close.
- `aesp.invalid.truncated_payload`: declared length greater than transmitted payload -> ERROR, timeout, or close according to spec.

CLI:

- `cli.core.ping`: `CMD:ping` -> `OK:pong` equivalent.
- `cli.core.version`: `CMD:version` -> `OK:<implementation version text>`.
- `cli.core.status`: `CMD:status` -> `OK:<status>` parseable enough to classify.
- `cli.core.pause`: `CMD:pause` -> `OK`.
- `cli.core.resume`: `CMD:resume` -> `OK`.
- `cli.core.step_default`: `CMD:step` -> `OK`.
- `cli.core.step_n`: `CMD:step 3` -> `OK`.
- `cli.core.reset_default`: `CMD:reset` -> `OK`.
- `cli.core.unknown`: unknown command -> `ERR`.
- `cli.core.malformed_prefix`: non-`CMD:` line -> `ERR` or close according to spec.

### Phase 2: deterministic state-changing CLI operations

These require both emulators to start from a comparable initial machine state.

- `cli.memory.read_zero_page`: read a small range from zero page.
- `cli.memory.write_then_read`: write bytes then read them back from the same implementation.
- `cli.memory.fill_then_read`: fill a range then read it back.
- `cli.cpu.registers_read`: read registers and parse required fields.
- `cli.cpu.registers_write_then_read`: set a subset of registers and verify round-trip.

For these, compare each implementation against its own round-trip expectation first. Only compare cross-implementation values when the initial state is explicitly controlled.

### Phase 3: AESP input and subscription behavior

- `aesp.input.key_down`: KEY_DOWN valid payload -> ACK.
- `aesp.input.key_up`: KEY_UP valid payload -> ACK.
- `aesp.input.joystick`: JOYSTICK valid payload -> ACK.
- `aesp.input.console_keys`: CONSOLE_KEYS valid payload -> ACK.
- `aesp.input.paddle`: PADDLE valid payload -> ACK.
- `aesp.video.subscribe_config`: VIDEO_SUBSCRIBE -> FRAME_CONFIG.
- `aesp.video.unsubscribe`: VIDEO_UNSUBSCRIBE -> ACK or no further frames according to spec.
- `aesp.audio.subscribe_config`: AUDIO_SUBSCRIBE -> AUDIO_CONFIG.
- `aesp.audio.unsubscribe`: AUDIO_UNSUBSCRIBE -> ACK or no further audio according to spec.

Treat actual `FRAME_RAW`, `FRAME_DELTA`, `AUDIO_PCM`, and `AUDIO_SYNC` streaming as optional initially for atari800-cl because its README says video frame payloads and audio PCM are not yet implemented.

### Phase 4: Attic-complete command families

Add Attic's more complete CLI command families as coverage, but configure current expectations carefully:

- Debugger commands: likely required for Attic, optional/unsupported for atari800-cl unless implemented.
- Disk commands: likely required for Attic, optional/unsupported for atari800-cl unless implemented.
- BASIC commands: likely required for Attic, optional/unsupported for atari800-cl unless implemented.
- DOS commands: likely required for Attic, optional/unsupported for atari800-cl unless implemented.
- Screenshot/state commands: likely required for Attic, optional/unsupported for atari800-cl unless implemented.

This phase produces a protocol feature gap report, not just pass/fail status.

## Reporting

Generate both machine-readable and human-readable outputs.

Suggested files per run:

```text
tools/protocol-comparison/reports/YYYYMMDD-HHMMSS/
  summary.json
  summary.md
  cases.jsonl
  failures.md
  feature-matrix.md
  raw/
    <case-id>.<implementation>.request.bin
    <case-id>.<implementation>.response.bin
    <case-id>.<implementation>.request.txt
    <case-id>.<implementation>.response.txt
  logs/
    attic.stdout.log
    attic.stderr.log
    atari800-cl.stdout.log
    atari800-cl.stderr.log
```

`summary.md` should include:

- Environment information:
  - OS
  - Python version
  - Swift version
  - SBCL version
  - LispWorks version, if used
  - Attic git commit
  - atari800-cl git commit
- Server launch commands.
- Socket capability probe results.
- Total cases by classification.
- Required cases failing by implementation.
- Accepted differences.
- Unsupported optional features.
- Links/paths to raw logs.

`feature-matrix.md` should list each protocol feature with columns:

- Feature
- Spec reference
- Attic expected support
- Attic observed result
- atari800-cl expected support
- atari800-cl observed result
- Notes

## Integration with atari800-cl tests

Do not immediately fold live cross-project comparison into the default `asdf:test-system :atari800-cl` path, because it depends on a second local repository and on live socket availability.

Instead:

1. Add a standalone script:

```text
scripts/compare-attic-protocols.sh
```

2. The script should:
   - Verify Attic exists at the configured path.
   - Verify `swift` exists.
   - Verify SBCL exists.
   - Run socket capability probes.
   - Run `python3 tools/protocol-comparison/compare-protocols.py`.

3. Add documentation in `tools/protocol-comparison/README.md`.

4. Optionally add a lightweight FiveAM test that checks only that the comparison harness files are present and its static specs validate. Do not start Attic from normal unit tests.

## Suggested command-line interface

`compare-protocols.py` should support:

```sh
python3 tools/protocol-comparison/compare-protocols.py \
  --attic-dir /Users/nikolai/Source/Repos/GitHub/huegli/attic \
  --atari800-cl-dir /Users/nikolai/common-lisp/atari800-cl \
  --implementations attic,atari800-cl \
  --protocols aesp,cli \
  --cases all \
  --mode live \
  --report-dir tools/protocol-comparison/reports
```

Useful additional flags:

- `--mode live|adapter-only|dry-run`
- `--implementation attic|atari800-cl|both`
- `--atari-lisp sbcl|lispworks|both`
- `--case <case-id>` repeatable
- `--case-file <path>` repeatable
- `--require-all-supported`
- `--allow-unsupported`
- `--timeout <seconds>`
- `--keep-servers-on-failure`
- `--verbose`
- `--json`

Exit code policy:

- `0`: all required cases pass or are accepted differences.
- `1`: at least one required case fails.
- `2`: harness/configuration error.
- `3`: environment cannot run required live tests.

## Implementation sequence for a tool-calling LLM

### Step 1: Inventory and confirm launch options

- Inspect Attic `Sources/AtticServer/AtticServer.swift` and docs to identify command-line flags for ports, socket paths, and disabling AESP/web modes.
- Inspect atari800-cl `src/aesp.lisp` and `src/cli-socket.lisp` to identify whether custom ports and custom CLI socket paths are supported.
- Inspect atari800-cl `tests/test-aesp.lisp` and `tests/test-cli-socket.lisp` to reuse helper patterns and skip probes.
- Inspect Attic tests for canonical expected behavior and test fixtures.

Deliverable: short notes in `tools/protocol-comparison/README.md` describing launch options and any prerequisites.

### Step 2: Implement codecs and static spec validation

- Implement `aesp_codec.py`:
  - encode header
  - decode header
  - validate magic/version/length
  - enforce max payload length
  - read complete frames from a socket
- Implement `cli_codec.py`:
  - encode newline-terminated CLI requests
  - parse `OK:` and `ERR:` replies
- Implement `protocol_spec.py` with message and command inventories.
- Add unit tests for codecs if a Python test framework is available, otherwise add a `--self-test` mode.

Deliverable: `python3 tools/protocol-comparison/compare-protocols.py --self-test` passes without starting servers.

### Step 3: Implement process and socket capability probes

- Add TCP bind/connect probe.
- Add Unix-domain socket bind/connect probe.
- Add Swift availability probe.
- Add SBCL availability probe.
- Add Attic path probe.
- Add atari800-cl ASDF load probe if cheap enough.

Deliverable: `compare-protocols.py --probe` prints JSON and exits successfully when probes complete, even if some capabilities are unavailable.

### Step 4: Implement Attic adapter

- Start `swift run AtticServer` with deterministic endpoints.
- Wait for readiness.
- Connect to AESP control/video/audio and CLI endpoints.
- Shut down cleanly.
- Capture logs.

Deliverable: one live Attic-only PING test passes.

### Step 5: Implement atari800-cl adapter

- Add or generate `start-atari800-cl-server.lisp`.
- Start SBCL with no user init.
- Load the local ASDF system using the same registry pattern as existing scripts.
- Start machine, AESP, and CLI services.
- Emit readiness JSON.
- Shut down cleanly.

Deliverable: one live atari800-cl-only PING test passes.

### Step 6: Implement semantic expectations and result classification

- Implement normalizers.
- Implement expectation matching.
- Implement cross-implementation classification.
- Make exact payload comparison opt-in.
- Emit raw and normalized evidence for every case.

Deliverable: the Phase 1 case suite runs against both implementations and produces `summary.md` and `summary.json`.

### Step 7: Expand CLI and AESP coverage

- Add Phase 2 deterministic CLI memory/register cases.
- Add Phase 3 input/subscription cases.
- Add Phase 4 feature matrix cases.
- Mark known atari800-cl MVP gaps as accepted unsupported unless the user chooses to make them required.

Deliverable: `feature-matrix.md` clearly shows overlapping support and gaps.

### Step 8: Integrate developer workflow

- Add `scripts/compare-attic-protocols.sh`.
- Document usage in `tools/protocol-comparison/README.md`.
- Add troubleshooting notes for socket bind failures and port collisions.
- Optionally add CI-safe static harness tests that do not start live servers.

Deliverable: a developer can run one command from the atari800-cl repo and get a comparison report.

## Prerequisite changes likely needed in atari800-cl

A tool-calling LLM should check these before starting implementation:

1. `start-aesp-server` should allow custom control/video/audio ports.
2. `start-cli-socket` should allow a custom socket path.
3. Server start functions should return enough endpoint information for harness readiness output.
4. Server stop functions should be idempotent enough for failure cleanup.
5. A machine/server startup script should be runnable under `sbcl --no-userinit` without Quicklisp local-project side effects.
6. Existing socket capability probes in tests should be factored so the comparison script can reuse the logic or mirror it accurately.

If any of these are missing, implement them as separate, small commits before implementing the full comparison harness.

## Prerequisite changes possibly needed in Attic

A tool-calling LLM should check these before assuming the Attic adapter can be deterministic:

1. `AtticServer` should allow custom AESP control/video/audio ports.
2. `AtticServer` should allow a custom CLI Unix socket path.
3. `AtticServer` should print or expose readiness information.
4. `AtticServer` should have a clean shutdown path from SIGTERM/SIGINT.
5. If defaults are hard-coded, the harness must serialize Attic runs and detect stale processes before launch.

Do not modify Attic from the atari800-cl repository unless the user explicitly asks for cross-repository edits. If Attic changes are required, document them in the comparison README or create a separate Attic issue/patch plan.

## Acceptance criteria

The framework is ready when:

- `scripts/compare-attic-protocols.sh --probe` reports environment capabilities.
- `scripts/compare-attic-protocols.sh --cases smoke` can run both implementations when sockets are available.
- Phase 1 AESP and CLI cases produce a report with no harness crashes.
- Unsupported optional features are reported as feature gaps, not raw failures.
- Raw request/response evidence is saved for every failed or accepted-difference case.
- Reports include both git commits and launch commands.
- The framework can run Attic-only and atari800-cl-only modes for debugging.
- The default atari800-cl unit test suite remains independent of Attic.

## Open decisions for the user

Before making unsupported features hard failures, decide:

1. Should atari800-cl be expected to eventually implement the full Attic CLI protocol, including debugger, disk, BASIC, DOS, state, and screenshot commands?
2. Should video/audio streaming payload tests be required now, or should only subscribe/config behavior be required until atari800-cl implements frame/PCM payloads?
3. Should the comparison harness live permanently in `atari800-cl`, or should it become a third repository/tool that treats both projects as peers?
4. Should LispWorks live-server comparison be part of the initial harness, or should SBCL be the first supported atari800-cl runtime?
5. Should the framework ever auto-start default-port servers, or should it require custom endpoints to avoid collisions?

## First concrete implementation prompt

Use the following prompt for a coding agent after this plan is approved:

```text
Implement Phase 1 of the protocol comparison framework described in ATARI800-CL-to-ATTIC-COMPARISON.md.

Work in /Users/nikolai/common-lisp/atari800-cl. Do not modify the Attic repository unless explicitly necessary and separately approved. First inspect Attic launch options and atari800-cl server start APIs. If custom ports/socket paths are not supported by atari800-cl, add minimal support for them with tests. Then create tools/protocol-comparison with Python codecs, probes, adapters, Phase 1 cases, JSON/Markdown reporting, and scripts/compare-attic-protocols.sh. Keep normal atari800-cl ASDF tests independent from Attic. Run ./scripts/test-sbcl.sh and the new comparison probe/smoke commands. Report any live-socket limitations as skips/inconclusive rather than failures.
```

## Execution results -- Phases 1-4 (initial run)

### Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-06-11 |
| Wall-clock duration | ~62 s for 48 cases (~ 1 m 02 s, excluding the initial `swift build`) |
| Report directory | `tools/protocol-comparison/reports/20260611-134655/` |
| atari800-cl commit | `1b86226` (branch `main`) |
| Attic commit | `dc7dfce` (branch `main`) |

### Host

| Field | Value |
| --- | --- |
| Machine | Apple Mac mini, M2 (arm64) |
| RAM | 8 GB |
| OS | macOS 26.5.1 (Darwin 25.5.0) |
| Python | 3.14.5 |
| Swift | Apple Swift 6.3.2 (swiftlang 6.3.2.1.108, clang 2100.1.1.101) |
| SBCL | 2.6.5-85913ede1 |
| LispWorks | 8.1.0 (console image; available but not exercised in this run) |

### Orchestrator

| Field | Value |
| --- | --- |
| Tool | Claude Code (Anthropic CLI for Claude) |
| Model | Claude Opus 4.7 with 1M-token context (`claude-opus-4-7[1m]`) |
| Mode | Fast mode, `auto` effort, foreground tool calls only |

The orchestrator inspected both codebases, decided no atari800-cl prerequisite
changes were needed (custom ports and CLI socket path are already supported),
generated the entire `tools/protocol-comparison/` harness plus
`scripts/compare-attic-protocols.sh` and the SBCL launcher
`start-atari800-cl-server.lisp`, wrote 13 Phase 1-4 case files (48 cases), and
ran the suite end-to-end against both live servers without further human
interaction. Two real bugs were caught by self-tests and re-runs during
development: `_recv_exactly` was swallowing socket timeouts as EOF
(misclassifying Attic no-response as `DISCONNECT`), and the memory-dump
normalizer was mis-reading the leading word `data` in Attic's reply as the
hex byte `0xDA`. Both fixes ship in this run's harness.

### Classification counts

| Classification | Count | % of 48 |
| --- | --- | --- |
| `pass` | 18 | 38 % |
| `accepted_difference` | 11 | 23 % |
| `unsupported` (expected gap, atari800-cl side) | 15 | 31 % |
| `attic_failure` | 4 | 8 % |
| `atari800_cl_failure` | 0 | 0 % |
| `both_failure` | 0 | 0 % |
| `inconclusive` / `harness_error` | 0 | 0 % |

Process exit code: `1` (one or more required cases failed -- all four are
Attic side).

### Confirmed Attic spec gaps (4)

| Case | Spec section | Attic observed | atari800-cl observed |
| --- | --- | --- | --- |
| `aesp.control.info` | AESP section INFO (0x06) -- *UTF-8 JSON response required* | `TIMEOUT` (no `.info` case in the TCP `ServerDelegate` switch; only the WebSocket bridge handles INFO) | `INFO` payload: `{"emulator":"atari800-cl","frame":N,"scanline":N,"running":true}` |
| `aesp.invalid.bad_magic` | AESP section Error Handling -- *Invalid magic should yield `ERROR(0x3F)` or close* | `TIMEOUT` (frame silently dropped) | `DISCONNECT` (spec-permitted close) |
| `aesp.invalid.bad_version` | AESP section Error Handling -- *Unsupported version* | `TIMEOUT` | `DISCONNECT` |
| `aesp.invalid.unknown_type` | AESP section Error Handling -- *Unknown message type* | `TIMEOUT` | `ERROR(0x3F)` with code `NotImplemented` |

### Accepted differences (11)

| Case | Difference |
| --- | --- |
| `aesp.input.key_down/key_up/joystick/console_keys/paddle` (5) | atari800-cl sends `ACK`; Attic stays silent (spec table lists request only). |
| `aesp.video.subscribe_config` / `aesp.video.unsubscribe` (2) | atari800-cl returns `FRAME_CONFIG` / `ACK`; Attic stays silent. |
| `aesp.audio.subscribe_config` / `aesp.audio.unsubscribe` (2) | atari800-cl returns `AUDIO_CONFIG` / `ACK`; Attic stays silent. |
| `cli.core.step_default` / `cli.core.step_n` (2) | atari800-cl: `OK:stepped N pc=$XXXX`. Attic: `OK:stepped A=$xx X=$xx Y=$xx S=$xx P=$xx PC=$xxxx`. Both satisfy "status=OK". |

### atari800-cl feature gaps reported as `unsupported` (15)

All marked `required: { attic: true, atari800-cl: false }` with
`unsupported_policy: { atari800-cl: accepted }`. The framework classifies the
case as `unsupported` rather than `atari800_cl_failure`:

- Debugger (5): `breakpoint set/clear/clearall/list`, `stepover`, `until`.
- Disk (2): `drives`, `unmount`.
- DOS (1): `dos dir`.
- BASIC (3): `basic list`, `basic info`, `basic vars`.
- CPU-extended (3): `disassemble` (default + address-anchored), `assemble`.
- Media (1): `screen`.

### Round-trip verification (Phase 2 multi-step)

| Case | Outcome |
| --- | --- |
| `cli.memory.read_zero_page` | `pass` -- both return 4 bytes from `$0000`. |
| `cli.memory.write_then_read` | `pass` -- `write $1000 DE,AD,BE,EF` + `read $1000 4` yields `[0xDE,0xAD,0xBE,0xEF]` on both. |
| `cli.memory.fill_then_read` | `pass` -- `fill $2000 $2003 $AA` + read yields `[0xAA x 4]` on both. |
| `cli.cpu.registers_read` | `pass` -- both implementations report `A/X/Y/(S\|SP)/P/PC`. |
| `cli.cpu.registers_write_then_read` | `pass` after a leading `CMD:pause` step -- without pausing, Attic's running CPU clobbered `A` between write and re-read. |

### Evidence captured

- Per-case raw request and response bytes (binary or text):
  `reports/20260611-134655/raw/<case-id>.<implementation>.{request,response}.{bin,txt}`
  -- 192 files total.
- Per-server stdout and stderr logs: `reports/20260611-134655/logs/`.
- Normalized records + per-step results: `cases.jsonl`.
- Human reports: `summary.md`, `summary.json`, `failures.md`,
  `feature-matrix.md`.

### Acceptance criteria -- final status

| Criterion | Status |
| --- | --- |
| `scripts/compare-attic-protocols.sh --probe` reports environment capabilities | [x] |
| `scripts/compare-attic-protocols.sh --cases smoke` runs both impls when sockets available | [x] (any `--cases <id,...>` subset works) |
| Phase 1 AESP and CLI cases produce a report with no harness crashes | [x] |
| Unsupported optional features reported as feature gaps, not raw failures | [x] (15 `unsupported`) |
| Raw request/response evidence saved for every failed/accepted-difference case | [x] (saved for **every** case, not just failures) |
| Reports include both git commits and launch commands | [x] |
| Framework supports Attic-only and atari800-cl-only modes | [x] (`--implementations attic` / `--implementations atari800-cl`) |
| Default atari800-cl unit test suite remains independent of Attic | [x] (`asdf:test-system :atari800-cl` and `./scripts/test-sbcl.sh` unchanged) |
