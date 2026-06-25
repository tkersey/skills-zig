#!/usr/bin/env -S uv run python
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


EXPECTED_CASES = {
    "valid_complex_epg",
    "valid_linear_epg",
    "duplicate_ids",
    "unknown_atom",
    "custom_atom_undeclared",
    "action_dependency_cycle",
    "unreachable_action",
    "dangling_action_outcome",
    "critical_unknown_without_observation",
    "critical_unknown_without_resolver",
    "obligation_without_closer",
    "risky_action_without_shield",
    "readiness_contradiction",
    "canonical_digest_stability",
    "key_order_invariance",
    "array_order_sensitivity",
    "state_digest_exclusion",
    "shielded_candidate",
    "utility_ranking",
    "priority_before_utility",
    "stable_tie_break",
    "terminal_selection",
    "policy_dead_end",
    "repeatable_action",
    "completed_nonrepeatable_excluded",
    "required_prior_action",
    "valid_etr",
    "identity_mismatch",
    "prediction_mismatch",
    "unknown_outcome",
    "missing_proof",
    "model_failure_return_to_policy",
    "intent_failure_return_to_spec",
    "state_atom_application",
    "potential_comparison",
    "parser_lifetime",
    "size_depth_limits",
    "malformed_json",
    "unknown_extension_policy",
    "cross_app_fixture_parity",
}


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", required=True)
    args = parser.parse_args()

    fixtures = Path(args.fixtures)
    manifest_path = fixtures / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    cases = set(manifest.get("required_cases", []))
    missing_cases = sorted(EXPECTED_CASES - cases)
    if missing_cases:
        raise SystemExit(f"manifest missing cases: {', '.join(missing_cases)}")

    for name in manifest["implemented_by"]["fixtures"]:
        path = fixtures / name
        json.loads(path.read_text(encoding="utf-8"))

    run(["uv", "run", "python", "tools/execution_policy_digest_parity.py", "--fixtures", str(fixtures)])
    run(["zig", "build", "test-execution-policy-core", "--summary", "all"])

    print(json.dumps({
        "conformance": "pass",
        "case_count": len(cases),
        "fixture_count": len(manifest["implemented_by"]["fixtures"]),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
