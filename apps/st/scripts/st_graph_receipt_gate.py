#!/usr/bin/env python3
"""Validate ST GCR-v2 graph-intelligence receipts.

This is the first implementation slice for ST-OPERATIONAL-GRAPH-GATES-v1.
It is intentionally a standalone gate so receipt shape and denial semantics can
stabilize before the monolithic `st` command surface starts enforcing them.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

PROOF_CUT_KINDS = {"exact", "approximation", "unavailable"}
VALID_EXECUTION = {True, False, "yes", "no", "pass", "fail"}


def load_json(path: str) -> dict[str, Any]:
    text = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    value = json.loads(text)
    if not isinstance(value, dict):
        raise ValueError("receipt must be a JSON object")
    body = value.get("graph_control_receipt", value)
    if not isinstance(body, dict):
        raise ValueError("graph_control_receipt must be a JSON object")
    return body


def is_yes(value: Any) -> bool:
    return value is True or value in {"yes", "pass"}


def is_no(value: Any) -> bool:
    return value is False or value in {"no", "fail"}


def require_obj(parent: dict[str, Any], key: str, errors: list[str], prefix: str = "") -> dict[str, Any]:
    value = parent.get(key)
    if not isinstance(value, dict):
        errors.append(f"{prefix}{key}:must_be_object")
        return {}
    return value


def require_list(parent: dict[str, Any], key: str, errors: list[str], prefix: str = "") -> list[Any]:
    value = parent.get(key)
    if not isinstance(value, list):
        errors.append(f"{prefix}{key}:must_be_list")
        return []
    return value


def require_scalar(parent: dict[str, Any], key: str, errors: list[str], prefix: str = "") -> Any:
    value = parent.get(key)
    if value is None or value == "":
        errors.append(f"{prefix}{key}:missing")
    return value


def list_strings(value: list[Any], name: str, errors: list[str]) -> list[str]:
    out: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item:
            errors.append(f"{name}[{index}]:must_be_nonempty_string")
            continue
        out.append(item)
    return out


def require_reason_rows(rows: list[Any], field: str, expected: set[str], errors: list[str], prefix: str) -> None:
    seen: set[str] = set()
    for index, row in enumerate(rows):
        label = f"{prefix}[{index}]"
        if not isinstance(row, dict):
            errors.append(f"{label}:must_be_object")
            continue
        node = row.get(field)
        if not isinstance(node, str) or not node:
            errors.append(f"{label}.{field}:missing")
        else:
            seen.add(node)
        reason = row.get("reason")
        if not isinstance(reason, str) or not reason:
            errors.append(f"{label}.reason:missing")
    missing = sorted(expected - seen)
    if missing:
        errors.append(f"{prefix}:missing_reason_for:{','.join(missing)}")


def validate_gcr(receipt: dict[str, Any]) -> tuple[list[str], list[str], dict[str, Any]]:
    errors: list[str] = []
    warnings: list[str] = []

    if receipt.get("receipt_version") != "GCR-v2":
        errors.append("receipt_version:must_be_GCR-v2")
    require_scalar(receipt, "gcr_id", errors)

    workspace = require_obj(receipt, "workspace", errors)
    for key in ("workspace_id", "workspace_sequence", "target_branch", "branch_epoch", "head", "working_tree_fingerprint"):
        require_scalar(workspace, key, errors, "workspace.")

    plan = require_obj(receipt, "plan", errors)
    for key in ("plan_id", "plan_sequence"):
        require_scalar(plan, key, errors, "plan.")
    fingerprints = require_obj(plan, "graph_fingerprints", errors, "plan.")
    for key in ("structure", "contract", "coverage", "execution"):
        require_scalar(fingerprints, key, errors, "plan.graph_fingerprints.")

    coordination = require_obj(receipt, "coordination", errors)
    for key in ("claim_id", "fencing_token", "session_id", "executor"):
        require_scalar(coordination, key, errors, "coordination.")
    resources = require_list(coordination, "resources", errors, "coordination.")
    conflicts = require_list(coordination, "conflicting_claims", errors, "coordination.")
    if coordination.get("lease_current") is not True:
        errors.append("coordination.lease_current:must_be_true")
    if coordination.get("fencing_current") is not True:
        errors.append("coordination.fencing_current:must_be_true")

    graph = require_obj(receipt, "graph", errors)
    nodes = require_list(graph, "nodes", errors, "graph.")
    edges = require_list(graph, "edges", errors, "graph.")
    ready = set(list_strings(require_list(graph, "ready_frontier", errors, "graph."), "graph.ready_frontier", errors))
    blocked = set(list_strings(require_list(graph, "blocked_frontier", errors, "graph."), "graph.blocked_frontier", errors))
    selected = set(list_strings(require_list(graph, "selected_frontier", errors, "graph."), "graph.selected_frontier", errors))
    unselected = set(list_strings(require_list(graph, "unselected_ready", errors, "graph."), "graph.unselected_ready", errors))
    critical_path = list_strings(require_list(graph, "critical_path", errors, "graph."), "graph.critical_path", errors)
    require_list(graph, "roots", errors, "graph.")
    require_list(graph, "leaves", errors, "graph.")
    require_list(graph, "components", errors, "graph.")
    require_list(graph, "downstream_unlocks", errors, "graph.")
    require_list(graph, "antichain_candidates", errors, "graph.")
    require_list(graph, "high_fanout_nodes", errors, "graph.")
    require_list(graph, "articulation_nodes", errors, "graph.")
    graph_debt = require_list(graph, "graph_debt", errors, "graph.")
    require_scalar(graph, "parallel_width", errors, "graph.")
    if graph.get("gate_passed") is not True:
        errors.append("graph.gate_passed:must_be_true")

    proof = require_obj(receipt, "proof", errors)
    proof_obligations = require_list(proof, "obligations", errors, "proof.")
    missing_proof = require_list(proof, "missing", errors, "proof.")
    proof_cut = require_list(proof, "minimum_proof_cut", errors, "proof.")
    cut_kind = proof.get("proof_cut_kind")
    if cut_kind not in PROOF_CUT_KINDS:
        errors.append("proof.proof_cut_kind:invalid")
    if cut_kind == "approximation" and not proof.get("approximation_reason"):
        errors.append("proof.approximation_reason:required_for_approximation")

    decision = require_obj(receipt, "aperture_decision", errors)
    selected_nodes = set(list_strings(require_list(decision, "selected_nodes", errors, "aperture_decision."), "aperture_decision.selected_nodes", errors))
    why_selected = require_list(decision, "why_selected", errors, "aperture_decision.")
    why_unselected = require_list(decision, "why_unselected_ready_waits", errors, "aperture_decision.")
    require_list(decision, "why_not_parallelized", errors, "aperture_decision.")
    require_scalar(decision, "scheduler_version", errors, "aperture_decision.")

    projection = require_obj(receipt, "session_projection", errors)
    projection_selected = set(list_strings(require_list(projection, "selected_task_ids", errors, "session_projection."), "session_projection.selected_task_ids", errors))
    for key in ("view_id", "session_id", "projection_digest"):
        require_scalar(projection, key, errors, "session_projection.")

    execution = receipt.get("execution_allowed")
    if execution not in VALID_EXECUTION:
        errors.append("execution_allowed:invalid")
    denial_reasons = require_list(receipt, "denial_reasons", errors)
    ledger_only = receipt.get("ledger_only", False)

    if not selected:
        errors.append("graph.selected_frontier:empty")
    if not selected.issubset(ready):
        errors.append("graph.selected_frontier:not_subset_of_ready_frontier")
    if selected & unselected:
        errors.append("graph.selected_frontier:overlaps_unselected_ready")
    if ready != selected | unselected:
        errors.append("graph.ready_frontier:must_equal_selected_plus_unselected_ready")
    if selected_nodes != selected:
        errors.append("aperture_decision.selected_nodes:mismatch_selected_frontier")
    if projection_selected != selected:
        errors.append("session_projection.selected_task_ids:mismatch_selected_frontier")
    if not critical_path:
        errors.append("graph.critical_path:empty")
    if cut_kind == "unavailable":
        errors.append("proof.proof_cut_kind:unavailable")
    elif not proof_cut:
        errors.append("proof.minimum_proof_cut:empty")
    if missing_proof:
        errors.append("proof.missing:not_empty")
    if graph_debt:
        errors.append("graph.graph_debt:not_empty")
    if conflicts:
        errors.append("coordination.conflicting_claims:not_empty")

    require_reason_rows(why_selected, "node_id", selected, errors, "aperture_decision.why_selected")
    require_reason_rows(why_unselected, "node_id", unselected, errors, "aperture_decision.why_unselected_ready_waits")

    complete = not errors and not ledger_only
    if is_yes(execution):
        if not complete:
            errors.append("execution_allowed:requires_complete_graph_intelligence")
        if denial_reasons:
            errors.append("denial_reasons:must_be_empty_when_execution_allowed")
    elif is_no(execution):
        if not denial_reasons:
            errors.append("denial_reasons:required_when_execution_denied")
    if ledger_only and is_yes(execution):
        errors.append("ledger_only:cannot_authorize_execution")

    summary = {
        "gcr_id": receipt.get("gcr_id"),
        "workspace_id": workspace.get("workspace_id"),
        "plan_id": plan.get("plan_id"),
        "selected_frontier": sorted(selected),
        "unselected_ready": sorted(unselected),
        "blocked_frontier": sorted(blocked),
        "proof_cut_kind": cut_kind,
        "ledger_only": bool(ledger_only),
        "execution_allowed": execution,
        "node_count": len(nodes),
        "edge_count": len(edges),
        "resource_count": len(resources),
        "proof_obligation_count": len(proof_obligations),
    }
    return errors, warnings, summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate GCR-v2 graph-intelligence receipt JSON")
    parser.add_argument("file", help="receipt JSON path or '-' for stdin")
    args = parser.parse_args()

    try:
        receipt = load_json(args.file)
        errors, warnings, summary = validate_gcr(receipt)
    except Exception as exc:  # deliberately fail-closed for malformed JSON/input
        errors, warnings, summary = [str(exc)], [], {}

    result = {
        "st_graph_receipt_gate": {
            "verdict": "pass" if not errors else "fail",
            **summary,
            "errors": errors,
            "warnings": warnings,
        }
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
