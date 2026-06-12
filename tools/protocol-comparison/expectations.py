"""Case-definition validation and per-implementation expectation matching.

A case (loaded by runner.py) names a request, an expectation on the
response, and a `required` map saying which implementations must satisfy
the expectation. Matching is *semantic* by default — payloads only
have to satisfy the spec, not be bit-identical.
"""

from __future__ import annotations

from typing import Any


# ---------------------------------------------------------------------------
# Schema validation (light — we don't want PyYAML/jsonschema as deps).

REQUIRED_TOP_LEVEL = {"id", "protocol", "expectation"}
VALID_PROTOCOLS = {"aesp", "cli"}
VALID_AESP_CHANNELS = {"control", "video", "audio"}


def validate_case(case: dict) -> list[str]:
    """Return a list of human-readable validation errors (empty = ok)."""
    errors: list[str] = []
    for key in REQUIRED_TOP_LEVEL:
        if key not in case:
            errors.append(f"missing top-level key: {key}")
    if "protocol" in case and case["protocol"] not in VALID_PROTOCOLS:
        errors.append(f"protocol must be one of {VALID_PROTOCOLS}, got {case['protocol']!r}")
    if case.get("protocol") == "aesp":
        ch = case.get("channel", "control")
        if ch not in VALID_AESP_CHANNELS:
            errors.append(f"aesp channel must be one of {VALID_AESP_CHANNELS}, got {ch!r}")
    if ("request" not in case and "steps" not in case
            and "expectation" in case):
        errors.append("missing 'request' or 'steps' block")
    if "steps" in case and not isinstance(case["steps"], list):
        errors.append("'steps' must be a list")
    return errors


# ---------------------------------------------------------------------------
# Expectation matching.

def match_aesp(normalized: dict, expectation: dict) -> tuple[bool, str]:
    """Match a normalized AESP record against an expectation.

    Supported expectation shapes:
      response:
        type: PONG                 # single expected type name
        one_of:                    # any-of alternatives
          - {type: ERROR}
          - {connection_closed: true}
          - {no_response: true}    # TIMEOUT counts as match (spec-silent)
        payload:                   # optional payload constraints
          class: empty_or_ignored | empty | non_empty | json | text
          min_length: N
          max_length: N
          equals_hex: "AE5001..."  # exact byte match
        semantic:                  # field-level expectations (subset match)
          state: running
        accept_no_response: true   # convenience: ACK and TIMEOUT both pass

    Returns (passed, reason). REASON is a short human string.
    """
    spec = expectation.get("response", {})

    # Convenience flag: equivalent to one_of: [{<current spec>}, {no_response: true}].
    if spec.get("accept_no_response") and normalized["type"] == "TIMEOUT":
        return True, "no response (accepted by accept_no_response)"

    if "one_of" in spec:
        reasons: list[str] = []
        for alt in spec["one_of"]:
            ok, reason = match_aesp(normalized, {"response": alt})
            if ok:
                return True, "matched one_of alternative"
            reasons.append(reason)
        return False, "no one_of alternative matched: " + " | ".join(reasons)

    if spec.get("no_response"):
        if normalized["type"] == "TIMEOUT":
            return True, "no response as expected"
        return False, f"expected no response, got {normalized['type']}"

    if spec.get("connection_closed"):
        if normalized["type"] == "DISCONNECT":
            return True, "connection closed as expected"
        return False, f"expected disconnect, got {normalized['type']}"

    expected_type = spec.get("type")
    if expected_type and normalized["type"] != expected_type:
        return False, f"expected {expected_type}, got {normalized['type']}"

    payload_spec = spec.get("payload", {})
    plen = normalized["payload_length"]
    pclass = payload_spec.get("class")
    if pclass and pclass != "empty_or_ignored":
        if pclass == "empty" and plen != 0:
            return False, f"expected empty payload, got {plen} bytes"
        if pclass == "non_empty" and plen == 0:
            return False, "expected non-empty payload, got 0 bytes"
        if pclass == "json" and normalized["payload_class"] != "json":
            return False, f"expected JSON payload, got {normalized['payload_class']}"
        if pclass == "text" and normalized["payload_class"] not in ("text", "json"):
            return False, f"expected text payload, got {normalized['payload_class']}"

    if "min_length" in payload_spec and plen < payload_spec["min_length"]:
        return False, f"payload too short ({plen} < {payload_spec['min_length']})"
    if "max_length" in payload_spec and plen > payload_spec["max_length"]:
        return False, f"payload too long ({plen} > {payload_spec['max_length']})"

    if "equals_hex" in payload_spec:
        if normalized["raw_payload_hex"].lower() != payload_spec["equals_hex"].lower():
            return False, "payload bytes mismatch (exact compare)"

    for field, expected in spec.get("semantic", {}).items():
        actual = normalized["semantic_fields"].get(field)
        if not _semantic_field_match(actual, expected):
            return False, f"semantic field {field}: expected {expected!r}, got {actual!r}"

    return True, "ok"


def match_cli(normalized: dict, expectation: dict) -> tuple[bool, str]:
    """Match a normalized CLI record against an expectation.

    Supported expectation shapes:
      response:
        status: OK | ERR | disconnect | timeout
        data_class: empty | pong | version | status | registers | memory_dump | text | ...
        contains: "running"          # substring of `data`
        startswith: "stepped"
        semantic:
          state: running
        one_of:                      # any-of alternatives
          - {status: OK}
          - {status: ERR}
    """
    spec = expectation.get("response", {})
    if "one_of" in spec:
        reasons: list[str] = []
        for alt in spec["one_of"]:
            ok, reason = match_cli(normalized, {"response": alt})
            if ok:
                return True, "matched one_of alternative"
            reasons.append(reason)
        return False, "no one_of alternative matched: " + " | ".join(reasons)

    expected_status = spec.get("status")
    if expected_status and normalized["status"] != expected_status:
        return False, f"expected status {expected_status}, got {normalized['status']}"

    expected_class = spec.get("data_class")
    if expected_class and normalized["data_class"] != expected_class:
        return False, f"expected data_class {expected_class}, got {normalized['data_class']}"

    if "contains" in spec and spec["contains"] not in normalized["data"]:
        return False, f"data does not contain {spec['contains']!r}: {normalized['data']!r}"
    if "startswith" in spec:
        # Compare against data (already stripped of prefix); some impls embed an
        # extra family word like "data ...". Allow either form by checking both.
        if not (normalized["data"].startswith(spec["startswith"])
                or normalized["data"].lstrip("data ").startswith(spec["startswith"])):
            return False, f"data does not start with {spec['startswith']!r}: {normalized['data']!r}"

    for field, expected in spec.get("semantic", {}).items():
        actual = normalized["semantic_fields"].get(field)
        if not _semantic_field_match(actual, expected):
            return False, f"semantic field {field}: expected {expected!r}, got {actual!r}"

    return True, "ok"


def _semantic_field_match(actual, expected) -> bool:
    """Subset-aware comparison for `semantic` expectations.

    - dict expected: every (k, v) must be present in actual (recursive).
    - everything else: ordinary equality.
    """
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return False
        return all(_semantic_field_match(actual.get(k), v) for k, v in expected.items())
    return actual == expected


# ---------------------------------------------------------------------------
# Cross-implementation classification.

def classify(case: dict, per_impl: dict[str, dict]) -> str:
    """Produce one of the spec'd classifications.

    PER_IMPL is a mapping implementation -> {pass: bool, reason: str,
    normalized: dict, supported: bool, unsupported: bool}.

    Outcomes:
      pass                  every impl met its expectation; semantic views agree.
      accepted_difference   every impl met its expectation; semantic views differ.
      unsupported           required impls passed; an optional impl signaled
                            a not-implemented gap as expected by policy.
      <impl>_failure        exactly one required impl failed.
      both_failure          two or more required impls failed.
    """
    required = case.get("expectation", {}).get("required", {})
    unsupported_policy = case.get("expectation", {}).get("unsupported_policy", {})

    # Only implementations that were actually run.
    run = {k: v for k, v in per_impl.items() if v is not None}

    failing_required: list[str] = []
    gap_signals: list[str] = []
    for impl, result in run.items():
        impl_required = required.get(impl, True)
        unsupported = bool(result.get("unsupported"))
        policy = unsupported_policy.get(impl)
        if impl_required and not result["pass"]:
            # Required impl failed. If it explicitly signaled unsupported
            # AND policy permits it, that's not a failure — but it's also
            # unusual to require an impl AND accept unsupported. Treat the
            # policy as permission to downgrade.
            if policy == "accepted" and unsupported:
                gap_signals.append(impl)
                continue
            failing_required.append(impl)
        elif not impl_required and unsupported:
            # Optional impl reported a gap as expected.
            gap_signals.append(impl)

    if failing_required:
        if len(failing_required) == 1:
            impl = failing_required[0]
            slug = impl.replace("-", "_")
            return f"{slug}_failure"
        return "both_failure"

    if gap_signals:
        return "unsupported"

    normalized_views = {k: v["normalized"] for k, v in run.items()}
    if _semantic_match(normalized_views, case):
        return "pass"
    return "accepted_difference"


def _semantic_match(per_impl_norm: dict[str, dict], case: dict) -> bool:
    """Compare normalized records across implementations for full agreement.

    The default policy says we don't care about implementation-specific
    payload bytes, just that the canonical fields agree. Cases can request
    an exact-payload comparison.
    """
    if len(per_impl_norm) < 2:
        return True

    compare_mode = case.get("expectation", {}).get("compare", {}).get("mode", "semantic")
    impls = list(per_impl_norm.keys())
    a_name, b_name = impls[0], impls[1]
    a, b = per_impl_norm[a_name], per_impl_norm[b_name]

    if case.get("protocol") == "aesp":
        # Same response type is the load-bearing comparison.
        if a.get("type") != b.get("type"):
            return False
        if compare_mode == "exact":
            return a.get("raw_payload_hex") == b.get("raw_payload_hex")
        # Semantic mode: payload-length-match is too strict; compare a few
        # decoded fields when both impls produced them.
        a_sem, b_sem = a.get("semantic_fields", {}), b.get("semantic_fields", {})
        for k in set(a_sem) & set(b_sem):
            # State/config fields should match exactly when both expose them.
            if k in {"state", "width", "height", "bytes_per_pixel", "fps",
                     "sample_rate", "bits", "channels"} and a_sem[k] != b_sem[k]:
                return False
        return True

    if case.get("protocol") == "cli":
        if a.get("status") != b.get("status"):
            return False
        if a.get("data_class") != b.get("data_class"):
            return False
        if compare_mode == "exact":
            return a.get("data") == b.get("data")
        return True

    return True
