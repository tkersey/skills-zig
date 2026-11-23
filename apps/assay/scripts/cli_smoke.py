import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BINARY = str(Path(sys.argv[1]).resolve(strict=True))
VERSION = Path(sys.argv[2]).read_text().strip()
COMMANDS = ("capabilities", "assess", "compare", "explain")
LIMIT_KEYS = (
    "source_document_bytes_max", "source_documents_bytes_max", "receipt_bytes_max",
    "json_depth_max", "obligations_max", "evaluators_max", "runs_max",
    "subject_artifacts_max", "evidence_artifacts_max", "records_max", "text_bytes_max",
    "number_bytes_max", "path_bytes_max", "artifact_bytes_max", "artifacts_bytes_max",
    "hash_buffer_bytes", "error_message_bytes_max", "allocation_bytes_max",
)


def execute(arguments, expected, cwd=None, stdout=subprocess.PIPE):
    result = subprocess.run(
        [BINARY, *arguments], stdout=stdout, stderr=subprocess.PIPE, cwd=cwd, timeout=30,
    )
    assert result.returncode == expected, (arguments, result.returncode, result.stdout, result.stderr)
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def assert_no_authority(value):
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, dict):
            for key, child in item.items():
                if key in ("authority_granted", "storage_mutated"):
                    assert child is False, (key, child)
                pending.append(child)
        elif isinstance(item, list):
            pending.extend(item)


def command_error(arguments, code, cwd=None):
    result = execute(arguments, 2, cwd=cwd)
    assert result.stderr == b"", result.stderr
    assert result.stdout.count(b"\n") == 1, result.stdout
    value = json.loads(result.stdout)
    assert value["schema"] == "assay-command-error/v1" and value["code"] == code, value
    assert set(value) == {
        "schema", "code", "message", "location", "authority_granted", "storage_mutated",
    }
    assert_no_authority(value)
    return value


def test_help_version_capabilities():
    for arguments in ([], ["--help"], ["-h"], ["assess", "--help"], ["compare", "-h"]):
        result = execute(arguments, 0)
        assert result.stderr == b""
        text = result.stdout.decode()
        for command in COMMANDS:
            assert f"assay {command}" in text, (arguments, command)
    for flag in ("--version", "-V", "version"):
        assert execute([flag], 0).stdout.decode().strip() == VERSION
    capabilities = json.loads(execute(["capabilities"], 0).stdout)
    assert list(capabilities) == [
        "schema", "product", "version", "kernel", "commands", "input_schemas", "output_schemas",
        "check_kinds", "formats", "default_format", "exit_codes", "limits", "boundary",
    ]
    assert capabilities["product"] == "assay" and capabilities["version"] == VERSION
    assert capabilities["kernel"] == "assay-kernel/v1"
    assert capabilities["commands"] == list(COMMANDS)
    assert capabilities["check_kinds"] == ["scalar_equal", "domain_judgment"]
    assert capabilities["exit_codes"] == {
        "supported": 0, "refuted": 1, "command_error": 2, "unresolved": 3,
        "processing_complete": 0,
    }
    assert tuple(capabilities["limits"]) == LIMIT_KEYS
    assert all(isinstance(value, int) for value in capabilities["limits"].values())
    assert capabilities["boundary"] == {
        "executes_evaluators": False, "network_access": False,
        "subject_verification": "optional_local_manifest_files",
        "receipt_authentication": "none", "authority_granted": False, "storage_mutated": False,
    }


def test_usage_errors(workspace):
    for arguments in (
        ["unknown"], ["assess"], ["capabilities", "--format", "json"],
        ["assess", "--contract", "a", "--contract", "a"],
        ["explain", "--assessment", "a", "positional"],
        ["explain", "--assessment", "a", "--format", "yaml"],
        ["compare", "--baseline", "a"], ["explain", "--bogus", "x"],
    ):
        command_error(arguments, "invalid_usage")
    text = execute(["explain", "--format", "text"], 2)
    assert text.stdout == b"" and b"invalid_usage" in text.stderr
    missing = command_error(["explain", "--assessment", str(workspace / "absent.json")], "missing_input")
    assert "absent" not in missing["message"]


class Documents:
    def __init__(self, root, outcome="interrupted", value="7", gates=("complete_run", "observation")):
        self.root = root
        files = root / "files"
        files.mkdir(parents=True)
        (files / "candidate.mjs").write_text("export const candidate = 1;\n")
        (files / "context.json").write_text('{"task":"timeout-null"}\n')
        (files / "observe.mjs").write_text("export const observe = true;\n")
        artifacts = []
        for identifier, role, name in (
            ("candidate", "target", "candidate.mjs"),
            ("context", "context", "context.json"),
            ("observer", "evaluator", "observe.mjs"),
        ):
            data = (files / name).read_bytes()
            artifacts.append({"id": identifier, "role": role, "path": name,
                              "sha256": digest(data), "size_bytes": len(data)})
        self.subject = self.write("subject.json", {
            "schema": "assay-subject/v1", "id": "codec-candidate",
            "context_artifact": "context", "artifacts": artifacts,
        })
        self.contract = self.write("contract.json", {
            "schema": "assay-contract/v1", "id": "codec-null-case/v1", "claim_kind": "artifact",
            "scope": "Explicit null remains disabled for this declared finite case.",
            "context_sha256": artifacts[1]["sha256"],
            "evaluators": [{"id": "codec-observer/v1", "artifact_id": "observer",
                            "sha256": artifacts[2]["sha256"], "method": "Round trip."}],
            "obligations": [{
                "id": "explicit-null-disables", "required": True,
                "statement": "A round trip preserves explicit null rather than inheriting 7.",
                "scope": "Input timeout=null; inherited timeout=7.", "basis": "empirical",
                "evaluator_id": "codec-observer/v1",
                "decisive_when": {"supported": gates[0], "refuted": gates[1]},
                "check": {"kind": "scalar_equal", "expected": None},
            }],
        })
        self.evidence = self.write_raw("evidence.json", (
            '{"schema":"assay-evidence/v1","contract_sha256":"%s","subject_sha256":"%s",'
            '"context_sha256":"%s","runs":[{"id":"codec-run-1","evaluator_id":"codec-observer/v1",'
            '"evaluator_sha256":"%s","outcome":"%s","reason":"%s"}],"records":[{'
            '"obligation_id":"explicit-null-disables","run_id":"codec-run-1","status":"observed",'
            '"observation":{"kind":"scalar","value":%s},"artifact_ids":[]}],"artifacts":[]}\n'
        ) % (
            digest(self.contract.read_bytes()), digest(self.subject.read_bytes()),
            artifacts[1]["sha256"], artifacts[2]["sha256"], outcome,
            "" if outcome == "complete" else "Runner was interrupted after recording this case.",
            value,
        ))

    def write(self, name, value):
        return self.write_raw(name, json.dumps(value, indent=2) + "\n")

    def write_raw(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path

    def arguments(self, *extra):
        return ["assess", "--contract", str(self.contract), "--subject", str(self.subject),
                "--evidence", str(self.evidence), *extra]


def test_assessment_exits_and_agreement(workspace):
    cases = (
        ("refuted", Documents(workspace / "refuted"), 1),
        ("unresolved", Documents(workspace / "unresolved", value="null"), 3),
        ("supported", Documents(workspace / "supported", outcome="complete", value="null"), 0),
    )
    receipts = {}
    for name, documents, exit_code in cases:
        result = execute(documents.arguments(), exit_code)
        assert result.stderr == b""
        receipt = json.loads(result.stdout)
        assert receipt["derivation"]["overall"] == name
        assert receipt["inputs"]["evidence_utf8"].encode() == documents.evidence.read_bytes()
        assert receipt["verification"] == {"subject_bytes": "not_checked", "files_checked": 0, "bytes_read": 0}
        assert_no_authority(receipt)
        text = execute(documents.arguments("--format", "text"), exit_code).stdout.decode()
        assert f"overall: {name}" in text and receipt["assessment_id"] in text
        assert f"explicit-null-disables [required] {name}" in text
        path = workspace / f"{name}.receipt.json"
        path.write_bytes(result.stdout)
        receipts[name] = path
    refuted = json.loads(receipts["refuted"].read_bytes())["derivation"]["obligations"][0]
    assert refuted["reason_code"] == "scalar_unequal" and refuted["run_outcome"] == "interrupted"
    unresolved = json.loads(receipts["unresolved"].read_bytes())["derivation"]["obligations"][0]
    assert unresolved["reason_code"] == "run_incomplete" and unresolved["completion_gate"] == "complete_run"
    return receipts


def test_explain_and_compare(receipts):
    explained = execute(["explain", "--assessment", str(receipts["refuted"])], 0)
    explanation = json.loads(explained.stdout)
    item = explanation["explanations"][0]
    assert item["check"] == {"kind": "scalar_equal", "expected": None}
    assert item["observation"] == {"kind": "scalar", "value": 7}
    assert item["run_reason"] == "Runner was interrupted after recording this case."
    assert explanation["receipt_consistency"] == "verified"
    assert_no_authority(explanation)
    text = execute(["explain", "--assessment", str(receipts["refuted"]), "--format", "text"], 0)
    assert b"receipt consistency: verified" in text.stdout
    for fragment in (b'scope: "Input timeout=null; inherited timeout=7."', b"basis: empirical",
                     b"evaluator: codec-observer/v1", b"check: scalar_equal, expected null"):
        assert fragment in text.stdout, fragment
    compared = json.loads(execute([
        "compare", "--baseline", str(receipts["supported"]), "--candidate", str(receipts["refuted"]),
    ], 0).stdout)
    assert compared["comparability"] == "comparable"
    assert compared["transitions"][0]["kind"] == "lost_support"
    assert compared["preservation"] == "refuted"
    assert_no_authority(compared)
    tampered = receipts["refuted"].with_name("tampered.json")
    original = receipts["refuted"].read_text()
    tampered.write_text(original.replace('"overall":"refuted"', '"overall":"supported"', 1))
    error = command_error(["explain", "--assessment", str(tampered)], "receipt_mismatch")
    assert error["location"] == "/derivation/overall"
    command_error(["compare", "--baseline", str(tampered), "--candidate", str(receipts["refuted"])],
                  "receipt_mismatch")


def test_subject_root(workspace):
    documents = Documents(workspace / "verified", outcome="complete", value="null")
    files = documents.root / "files"
    receipt = json.loads(execute(documents.arguments("--subject-root", str(files)), 0).stdout)
    total = sum(path.stat().st_size for path in files.iterdir())
    assert receipt["verification"] == {
        "subject_bytes": "matched_manifest_during_this_invocation", "files_checked": 3,
        "bytes_read": total,
    }
    explained = json.loads(execute(["explain", "--assessment", str(
        documents.write_raw("receipt.json", json.dumps(receipt)))], 0).stdout)
    assert explained["subject_bytes"] == "not_reverified"
    assert explained["recorded_verification"]["trust"] == "unauthenticated_receipt_claim"
    os.symlink(files, documents.root / "linked")
    for spelling in ("linked", "linked/", "linked/."):
        command_error(documents.arguments("--subject-root", str(documents.root / "linked") +
                                          spelling[len("linked"):]), "identity_mismatch")
    command_error(documents.arguments("--subject-root", str(files / ".." / "files")),
                  "invalid_usage")
    command_error(documents.arguments("--subject-root", str(documents.root / "absent")),
                  "missing_input")
    original = (files / "candidate.mjs").read_bytes()
    (files / "candidate.mjs").write_bytes(original.upper())
    command_error(documents.arguments("--subject-root", str(files)), "identity_mismatch")
    (files / "candidate.mjs").unlink()
    command_error(documents.arguments("--subject-root", str(files)), "missing_input")
    os.mkfifo(files / "candidate.mjs")
    error = command_error(documents.arguments("--subject-root", str(files)), "identity_mismatch")
    assert error["location"] == "/artifacts/0/path"


def test_bounds_and_output(workspace):
    documents = Documents(workspace / "bounds")
    oversized = documents.write_raw("oversized.json", " " * (2 * 1024 * 1024) + "{}")
    command_error(["assess", "--contract", str(oversized), "--subject", str(documents.subject),
                   "--evidence", str(documents.evidence)], "resource_limit")
    deep = documents.write_raw("deep.json", "[" * 33 + "]" * 33)
    command_error(["assess", "--contract", str(deep), "--subject", str(documents.subject),
                   "--evidence", str(documents.evidence)], "resource_limit")
    truncated = documents.write_raw("truncated.json", documents.contract.read_text()[:40])
    command_error(["assess", "--contract", str(truncated), "--subject", str(documents.subject),
                   "--evidence", str(documents.evidence)], "invalid_json")
    stale = documents.write_raw("stale.json", documents.contract.read_text() + "\n")
    error = command_error(["assess", "--contract", str(stale), "--subject", str(documents.subject),
                           "--evidence", str(documents.evidence)], "identity_mismatch")
    assert error["location"] == "/contract_sha256"
    if Path("/dev/full").exists():
        with open("/dev/full", "wb") as full:
            result = subprocess.run([BINARY, *documents.arguments()], stdout=full,
                                    stderr=subprocess.PIPE, timeout=30)
        assert result.returncode == 2 and b"io_error" in result.stderr, result
    read_end, write_end = os.pipe()
    os.close(read_end)
    result = subprocess.run([BINARY, *documents.arguments()], stdout=write_end,
                            stderr=subprocess.PIPE, timeout=30)
    os.close(write_end)
    assert result.returncode != 0 and result.returncode != 1, result


def main():
    test_help_version_capabilities()
    with tempfile.TemporaryDirectory(prefix="assay-cli-") as directory:
        workspace = Path(directory).resolve(strict=True)
        test_usage_errors(workspace)
        receipts = test_assessment_exits_and_agreement(workspace)
        test_explain_and_compare(receipts)
        test_subject_root(workspace)
        test_bounds_and_output(workspace)
    print("Assay CLI smoke passed (local documents only; no evaluator execution).")


main()
