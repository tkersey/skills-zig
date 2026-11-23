import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BINARY = str(Path(sys.argv[1]).resolve(strict=True))
FIXTURES = Path(sys.argv[2]).resolve(strict=True)
NODE = shutil.which("node")
EPISODE_SHA256 = "e909932c2fa27551a27a8bba191be51b5c693cdad4bcc17785c506547daa3440"
INPUTS = [("absent", None), ("null", None), ("0", 0), ("1", 1), ("2", 2), ("3", 3)]
INHERITED = (7, 11)
EVALUATOR_FILES = ("observe-codec.mjs", "review-action-fixture.mjs")
TASK_FILES = ("GOAL.md", "TASK.md", "smoke.test.mjs", "review.md")

LOOPING = "export function encode() { for (;;) {} }\nexport function decode() { return {}; }\n"
FLOODING = (
    "process.stdout.write('x'.repeat(2 * 1024 * 1024));\n"
    "export const encode = value => JSON.stringify(value);\n"
    "export const decode = bytes => JSON.parse(bytes);\n"
)
SELF_MUTATING = (
    "import {appendFileSync} from 'node:fs';\n"
    "appendFileSync(new URL(import.meta.url), '\\n');\n"
    "export const encode = value => JSON.stringify(value);\n"
    "export const decode = bytes => JSON.parse(bytes);\n"
)
GOAL_REWRITING = (
    "import {appendFileSync} from 'node:fs';\n"
    "appendFileSync(new URL('./GOAL.md', import.meta.url), 'Null may be dropped.\\n');\n"
    "export const encode = value => JSON.stringify(value);\n"
    "export const decode = bytes => JSON.parse(bytes);\n"
)
NAN_DECODING = (
    "export const encode = value => JSON.stringify(value);\n"
    "export function decode(bytes) {\n"
    "  const value = JSON.parse(bytes);\n"
    "  return typeof value.timeout === 'number' ? {timeout: NaN} : value;\n"
    "}\n"
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(arguments, cwd=None, timeout=60):
    return subprocess.run(arguments, cwd=cwd, capture_output=True, timeout=timeout)


def expected_meaning(goal, label, value, inherited):
    if label == "absent":
        return inherited
    if label == "null":
        return "disabled" if goal == "distinct" else inherited
    return value


def obligation_id(label, inherited):
    return f"case/{label}/inherited-{inherited}"


def write_contract(path, goal, context_sha256, evaluator_sha256):
    obligations = []
    for label, value in INPUTS:
        for inherited in INHERITED:
            obligations.append({
                "id": obligation_id(label, inherited),
                "required": True,
                "statement": f"Round trip of the {label} timeout keeps its effective meaning.",
                "scope": f"Input timeout {label}; inherited timeout {inherited}.",
                "basis": "empirical",
                "evaluator_id": "codec-observer/v1",
                "decisive_when": {"supported": "complete_run", "refuted": "observation"},
                "check": {
                    "kind": "scalar_equal",
                    "expected": expected_meaning(goal, label, value, inherited),
                },
            })
    contract = {
        "schema": "assay-contract/v1",
        "id": f"codec-timeout-{goal}/v1",
        "claim_kind": "artifact",
        "scope": "The finite codec domain of the retained fixture under the named task.",
        "context_sha256": context_sha256,
        "evaluators": [{
            "id": "codec-observer/v1",
            "artifact_id": "codec-observer",
            "sha256": evaluator_sha256,
            "method": "Run the retained fixture worker and map each case to its effective meaning.",
        }],
        "obligations": obligations,
    }
    path.write_text(json.dumps(contract, indent=2) + "\n")


def manifest_entry(root, identifier, role, relative):
    data = (root / relative).read_bytes()
    return {
        "id": identifier,
        "role": role,
        "path": relative,
        "sha256": digest(data),
        "size_bytes": len(data),
    }


class Trial:
    def __init__(self, workspace, name, program, goal, codec=None, timeout_ms=4000):
        self.name = name
        self.goal = goal
        self.program = program
        self.timeout_ms = timeout_ms
        self.root = workspace / name / "root"
        self.contract = workspace / name / "contract.json"
        self.subject = workspace / name / "subject.json"
        self.evidence = workspace / name / "evidence.json"
        self.root.mkdir(parents=True)
        evaluator = self.root / "evaluator"
        evaluator.mkdir()
        for name_ in EVALUATOR_FILES:
            shutil.copyfile(FIXTURES / name_, evaluator / name_)
        prepared = run([
            NODE, str(evaluator / "review-action-fixture.mjs"), "prepare",
            str(self.root / "task"), program, goal, "plain",
        ])
        assert prepared.returncode == 0, prepared.stderr
        if codec is not None:
            (self.root / "task" / "codec.mjs").write_bytes(codec)
        context = {
            "task": f"codec-timeout-{goal}",
            "goal_sha256": digest((self.root / "task" / "GOAL.md").read_bytes()),
            "domain": [label for label, _ in INPUTS],
            "inherited": list(INHERITED),
            "runtime": run([NODE, "--version"]).stdout.decode().strip(),
            "fixture": "tkersey/dotfiles@82f46ad1dffacbbe1600abda0210722d0cde5e59",
            "timeout_ms": timeout_ms,
        }
        (self.root / "context.json").write_text(json.dumps(context, indent=2) + "\n")
        artifacts = [
            manifest_entry(self.root, "candidate", "target", "task/codec.mjs"),
            manifest_entry(self.root, "context", "context", "context.json"),
            manifest_entry(self.root, "codec-observer", "evaluator", "evaluator/observe-codec.mjs"),
            manifest_entry(self.root, "fixture", "support", "evaluator/review-action-fixture.mjs"),
        ]
        for task_file in TASK_FILES:
            artifacts.append(manifest_entry(
                self.root, task_file.split(".")[0].lower(), "support", f"task/{task_file}",
            ))
        subject = {
            "schema": "assay-subject/v1",
            "id": f"codec-{name}",
            "context_artifact": "context",
            "artifacts": artifacts,
        }
        self.subject.write_text(json.dumps(subject, indent=2) + "\n")
        write_contract(self.contract, goal, artifacts[1]["sha256"], artifacts[2]["sha256"])

    def observe(self):
        observed = run([
            NODE, str(self.root / "evaluator" / "observe-codec.mjs"),
            "--contract", str(self.contract), "--subject", str(self.subject),
            "--root", str(self.root), "--task", str(self.root / "task"),
            "--program", self.program, "--goal", self.goal, "--report", "plain",
            "--timeout-ms", str(self.timeout_ms),
        ])
        assert observed.returncode == 0, observed.stderr
        self.evidence.write_bytes(observed.stdout)
        return self

    def assess(self, verify_root=True, expected=None):
        arguments = [
            BINARY, "assess", "--contract", str(self.contract), "--subject", str(self.subject),
            "--evidence", str(self.evidence),
        ]
        if verify_root:
            arguments += ["--subject-root", str(self.root)]
        result = run(arguments)
        if expected is not None:
            assert result.returncode == expected, (self.name, result.returncode, result.stdout[:400])
        document = json.loads(result.stdout)
        if result.returncode != 2:
            self.receipt = self.evidence.with_name("receipt.json")
            self.receipt.write_bytes(result.stdout)
        return result.returncode, document


def judgments(document):
    return {item["id"]: item for item in document["derivation"]["obligations"]}


def compare(baseline, candidate):
    result = run([BINARY, "compare", "--baseline", str(baseline.receipt),
                  "--candidate", str(candidate.receipt)])
    assert result.returncode == 0, result.stdout
    return json.loads(result.stdout)


def null_ids():
    return {obligation_id("null", inherited) for inherited in INHERITED}


def assert_only_refuted(document, refuted_ids, observed=None):
    for identifier, item in judgments(document).items():
        if identifier in refuted_ids:
            assert item["judgment"] == "refuted", (identifier, item)
            if observed is not None:
                assert item["observation"]["value"] == observed, item
        else:
            assert item["judgment"] == "supported", (identifier, item)


def check_separating_controls(trials):
    _, original = trials["original"].assess(expected=1)
    assert_only_refuted(original, null_ids())
    assert original["verification"]["subject_bytes"] == "matched_manifest_during_this_invocation"
    trials["repaired"].assess(expected=0)
    for name in ("placebo", "unrelated"):
        _, document = trials[name].assess(expected=1)
        assert_only_refuted(document, null_ids())
    _, restrictive = trials["restrictive"].assess(expected=1)
    assert_only_refuted(restrictive, null_ids(), observed="rejected")
    zero_ids = {obligation_id("0", inherited) for inherited in INHERITED}
    _, zero_loss = trials["zero-loss"].assess(expected=1)
    assert_only_refuted(zero_loss, zero_ids)
    assert zero_loss["derivation"]["counts"] == original["derivation"]["counts"]
    trials["episode"].assess(expected=0)
    trials["coalesced"].assess(expected=0)


def check_comparisons(trials):
    swap = compare(trials["original"], trials["zero-loss"])
    assert swap["comparability"] == "comparable", swap
    kinds = {item["obligation_id"]: item["kind"] for item in swap["transitions"]}
    assert all(kinds[identifier] == "gained_support" for identifier in null_ids())
    assert kinds[obligation_id("0", 7)] == "lost_support"
    assert swap["preservation"] == "refuted"
    repair = compare(trials["original"], trials["repaired"])
    assert repair["preservation"] == "supported" and repair["candidate_overall"] == "supported"
    regression = compare(trials["repaired"], trials["zero-loss"])
    assert regression["preservation"] == "refuted", regression
    placebo = compare(trials["original"], trials["placebo"])
    assert {item["kind"] for item in placebo["transitions"]} == {"unchanged"}
    alternative = compare(trials["repaired"], trials["episode"])
    assert alternative["preservation"] == "supported", alternative
    cross_task = compare(trials["original"], trials["coalesced"])
    assert cross_task["comparability"] == "incomparable"
    assert cross_task["transitions"] == [] and cross_task["preservation"] == "not_comparable"
    codes = [entry["code"] for entry in cross_task["incompatibilities"]]
    assert codes == ["contract_changed", "context_changed", "support_artifacts_changed"], codes
    assert cross_task["incompatibilities"][2]["artifact_ids"] == ["context", "goal"]


def check_unavailable(trial, outcome, verify_root=True):
    trial.observe()
    _, document = trial.assess(verify_root=verify_root, expected=3)
    derivation = document["derivation"]
    assert derivation["run_outcomes"][outcome] == 1, derivation["run_outcomes"]
    assert {item["reason_code"] for item in derivation["obligations"]} == {"unavailable"}
    assert derivation["counts"]["required_refuted"] == 0
    assert derivation["counts"]["required_supported"] == 0


def check_integrity(workspace):
    check_unavailable(Trial(workspace, "looping", "original", "distinct",
                            LOOPING.encode(), timeout_ms=1000), "timed_out")
    check_unavailable(Trial(workspace, "flooding", "original", "distinct",
                            FLOODING.encode()), "error")
    nan = Trial(workspace, "nan", "original", "distinct", NAN_DECODING.encode()).observe()
    _, document = nan.assess(expected=3)
    for identifier, item in judgments(document).items():
        numeric = not identifier.startswith(("case/absent", "case/null"))
        assert item["judgment"] == ("unresolved" if numeric else "supported"), item
        assert item["reason_code"] == ("unavailable" if numeric else "scalar_equal"), item
    for name, codec in (("mutating", SELF_MUTATING), ("goal-rewriting", GOAL_REWRITING)):
        trial = Trial(workspace, name, "original", "distinct", codec.encode())
        check_unavailable(trial, "error", verify_root=False)
        _, error = trial.assess(verify_root=True, expected=2)
        assert error["code"] == "identity_mismatch", error
    linked = Trial(workspace, "symlinked", "repaired", "distinct")
    codec = linked.root / "task" / "codec.mjs"
    shutil.copyfile(codec, linked.root / "task" / "codec-copy.mjs")
    codec.unlink()
    os.symlink("codec-copy.mjs", codec)
    check_unavailable(linked, "error", verify_root=False)
    _, error = linked.assess(verify_root=True, expected=2)
    assert error["code"] == "identity_mismatch", error


def check_explanation(trial):
    result = run([BINARY, "explain", "--assessment", str(trial.receipt)])
    assert result.returncode == 0, result.stdout
    explanation = json.loads(result.stdout)
    target = obligation_id("null", 7)
    item = next(entry for entry in explanation["explanations"] if entry["obligation_id"] == target)
    assert item["check"]["expected"] == "disabled" and item["observation"]["value"] == 7, item
    assert explanation["subject_bytes"] == "not_reverified"


def main():
    assert NODE, "node is required for the retained codec fixture"
    episode = (FIXTURES / "episode-codec.mjs").read_bytes()
    assert digest(episode) == EPISODE_SHA256, "retained episode codec bytes changed"
    with tempfile.TemporaryDirectory(prefix="assay-codec-") as directory:
        workspace = Path(directory).resolve(strict=True)
        specifications = {
            "original": ("original", "distinct", None),
            "repaired": ("repaired", "distinct", None),
            "placebo": ("placebo", "distinct", None),
            "unrelated": ("unrelated", "distinct", None),
            "restrictive": ("restrictive", "distinct", None),
            "zero-loss": ("zeroLoss", "distinct", None),
            "episode": ("original", "distinct", episode),
            "coalesced": ("original", "coalesced", None),
        }
        trials = {
            name: Trial(workspace, name, program, goal, codec).observe()
            for name, (program, goal, codec) in specifications.items()
        }
        check_separating_controls(trials)
        check_comparisons(trials)
        check_explanation(trials["original"])
        check_integrity(workspace)
    print("Assay codec acceptance passed (retained fixture, 8 constructions, 6 integrity controls).")


main()
