#!/usr/bin/env bash
set -euo pipefail
umask 077

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
bin_path=${1:-"$root_dir/zig-out/bin/siwc"}
version_path=${2:-"$root_dir/apps/siwc/VERSION"}

if [[ ! -x "$bin_path" ]]; then
  echo "binary not found or executable: $bin_path" >&2
  exit 1
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/siwc-process.XXXXXXXX")
trap 'rm -rf -- "$test_root"' EXIT

python3 - "$bin_path" "$version_path" "$test_root" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

BINARY = str(Path(sys.argv[1]).resolve(strict=True))
VERSION = Path(sys.argv[2]).read_text().strip()
ROOT = Path(sys.argv[3]).resolve(strict=True)
AUTH = ROOT / "auth"
APP = "process-gate"
ACCOUNT = "personal"
API_BASE = "https://api.openai.com/v1"
ACCESS = "synthetic-process-access-token"
REFRESH = "synthetic-process-refresh-token"
IDENTITY = "synthetic-process-id-token"
SELECTORS = ("OPENAI_ORGANIZATION", "OPENAI_ORG_ID", "OPENAI_PROJECT", "OPENAI_PROJECT_ID")
BASE_ENV = {key: value for key, value in os.environ.items() if not key.startswith("OPENAI_")}
BASE_ENV["SIWC_PROCESS_SETTING"] = "preserved setting"


def execute(arguments, expected=0, environment=None, input_text="", cwd=ROOT):
    process = subprocess.Popen(
        [BINARY, *arguments],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=cwd,
        env=BASE_ENV if environment is None else environment,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(input_text, timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=2)
        raise AssertionError("SIWC process exceeded its 10-second deadline") from None
    assert process.returncode == expected, (
        f"unexpected process exit: {process.returncode}; expected {expected}; stderr: {stderr}"
    )
    return stdout, stderr, process.pid


def scoped(command, *extra, auth=AUTH, account=True):
    arguments = [command, "--app", APP, "--auth-dir", str(auth)]
    if account:
        arguments += ["--account", ACCOUNT]
    return arguments + list(extra)


def assert_redacted(output):
    assert all(token not in output for token in (ACCESS, REFRESH, IDENTITY))
    assert all(key not in output for key in ("access_token", "refresh_token", "id_token"))


def snapshot():
    result = {}
    for path in [AUTH, *sorted(AUTH.rglob("*"))]:
        metadata = path.lstat()
        result[str(path.relative_to(AUTH))] = (
            metadata.st_mode,
            metadata.st_ino,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            path.read_bytes() if path.is_file() else None,
        )
    return result


def prepare_store():
    AUTH.mkdir(mode=0o700)
    app_dir = AUTH / APP
    app_dir.mkdir(mode=0o700)
    record = {
        "version": 1,
        "app": APP,
        "label": ACCOUNT,
        "client_id": "oaiapp_process_gate",
        "subject": "synthetic-subject",
        "email": "synthetic@example.invalid",
        "refresh_pending": False,
        "tokens": {
            "access_token": ACCESS,
            "refresh_token": REFRESH,
            "id_token": IDENTITY,
            "scope": "openid profile email offline_access "
            "resource.invoke chatgpt.tokens.use.direct",
            "expires_at": int(time.time()) + 3600,
            "earliest_refresh_at": None,
        },
    }
    path = app_dir / f"account-{ACCOUNT}.json"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(record, output)
    assert AUTH.stat().st_mode & 0o777 == 0o700
    assert app_dir.stat().st_mode & 0o777 == 0o700
    assert path.stat().st_mode & 0o777 == 0o600


def test_command_admission():
    for arguments in ([], ["--help"], ["-h"]):
        stdout, stderr, _ = execute(arguments)
        assert stderr == ""
        for command in ("login", "accounts", "status", "models", "logout", "credential", "exec"):
            assert f"siwc {command} " in stdout
    for flag in ("--version", "-V", "version"):
        stdout, stderr, _ = execute([flag])
        assert stdout.strip() == VERSION and stderr == ""
    invalid = (
        ["unknown"],
        ["accounts"],
        ["accounts", "--app"],
        ["accounts", "--app", "../outside"],
        ["accounts", "--app", APP, "--unknown"],
        ["accounts", "--app", APP, "--app", APP],
        scoped("status", "--new-account", "other"),
        scoped("status", "--enable-plan"),
        scoped("login", "--new-account", "other"),
        scoped("credential"),
        scoped("exec", "--"),
        scoped("exec", "--", ""),
    )
    for arguments in invalid:
        stdout, stderr, _ = execute(arguments, expected=2)
        assert stdout == "" and stderr != ""
    assert not AUTH.exists()


def test_read_only_reports():
    before = snapshot()
    for command in ("status", "accounts"):
        for json_mode in (False, True):
            tail = ("--json",) if json_mode else ()
            stdout, stderr, _ = execute(scoped(command, *tail, account=command == "status"))
            assert stderr == ""
            assert_redacted(stdout)
            if json_mode:
                value = json.loads(stdout)
                if command == "accounts":
                    assert len(value) == 1
                    value = value[0]
                assert value["app"] == APP and value["account"] == ACCOUNT
                assert value["phase"] == "ready"
                assert value["subject"] == "synthetic-subject"
            else:
                assert f"{APP}/{ACCOUNT}\tready\t" in stdout
        missing = ROOT / f"missing-{command}"
        execute(scoped(command, auth=missing, account=command == "status"), expected=1)
        assert not missing.exists()
    execute(["accounts", "--app", "absent", "--auth-dir", str(AUTH)], expected=1)
    assert snapshot() == before, "read-only reports changed the credential store"


def test_credential_output():
    stdout, stderr, _ = execute(scoped("credential", "--json"))
    assert stderr == ""
    value = json.loads(stdout)
    assert value["version"] == 1 and value["provider"] == "chatgpt"
    assert value["app"] == APP and value["account"] == ACCOUNT
    assert value["access_token"] == ACCESS and value["token_type"] == "Bearer"
    assert value["resource"] == API_BASE and value["issuer"] == "https://auth.openai.com"
    assert value["expires_at"] > time.time() + 60
    assert "refresh_token" not in value and "id_token" not in value and "tokens" not in value
    assert REFRESH not in stdout and IDENTITY not in stdout


def test_exec_process_contract():
    environment = dict(BASE_ENV, OPENAI_API_KEY="synthetic-old-key", OPENAI_API_BASE=API_BASE + "/")
    environment.update({key: "synthetic-billing-selector" for key in SELECTORS})
    child = (
        "import json,os,sys; "
        "print(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd(),'stdin':sys.stdin.read(),"
        "'pid':os.getpid(),'environment':{k:v for k,v in os.environ.items() "
        "if k.startswith('OPENAI_') or k=='SIWC_PROCESS_SETTING'}}))"
    )
    literal = ["argument with spaces", "$(printf should-not-run)", "", "--", "a'b\"c;$PATH"]
    work = ROOT / "child working directory"
    work.mkdir(mode=0o700)
    stdin = "inherited input\nsecond line\x00tail"
    stdout, stderr, pid = execute(
        scoped("exec", "--", sys.executable, "-c", child, *literal),
        environment=environment,
        input_text=stdin,
        cwd=work,
    )
    value = json.loads(stdout)
    assert stderr == "" and value["argv"] == literal
    assert value["cwd"] == str(work) and value["stdin"] == stdin
    assert value["pid"] == pid, "exec must replace the CLI process"
    actual = value["environment"]
    assert actual["OPENAI_API_KEY"] == ACCESS and actual["OPENAI_BASE_URL"] == API_BASE
    assert actual["SIWC_PROCESS_SETTING"] == "preserved setting"
    assert all(key not in actual for key in SELECTORS)
    assert REFRESH not in stdout and IDENTITY not in stdout
    stdout, stderr, _ = execute(
        scoped("exec", "--", sys.executable, "-c", "raise SystemExit(37)"), expected=37
    )
    assert stdout == "" and stderr == ""
    terminate = "import os,signal; os.kill(os.getpid(), signal.SIGTERM)"
    stdout, stderr, _ = execute(
        scoped("exec", "--", sys.executable, "-c", terminate), expected=-signal.SIGTERM
    )
    assert stdout == "" and stderr == ""


def test_foreign_destinations():
    for key in ("OPENAI_BASE_URL", "OPENAI_API_BASE"):
        rejected = ROOT / f"rejected-{key.lower()}"
        environment = dict(BASE_ENV)
        environment[key] = "https://foreign.invalid/v1"
        stdout, stderr, _ = execute(
            scoped("exec", "--", sys.executable, "-c", "raise SystemExit(99)", auth=rejected),
            expected=1,
            environment=environment,
        )
        assert stdout == "" and "UntrustedApiDestination" in stderr
        assert not rejected.exists(), "destination validation must precede store creation"


test_command_admission()
prepare_store()
test_read_only_reports()
test_credential_output()
test_exec_process_contract()
test_foreign_destinations()
print("SIWC process gate passed (synthetic credentials; no network requests).")
PY
