#!/usr/bin/env -S uv run python
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def canonical_bytes(path: Path) -> bytes:
    value = json.loads(path.read_text(encoding="utf-8"))
    text = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return text.encode("utf-8")


def digest(path: Path) -> str:
    return "sha256:" + hashlib.sha256(canonical_bytes(path)).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", required=True)
    args = parser.parse_args()

    root = Path(args.fixtures)
    key_a = root / "key_order_a.json"
    key_b = root / "key_order_b.json"
    array_changed = root / "array_order_changed.json"

    digest_a = digest(key_a)
    digest_b = digest(key_b)
    digest_array = digest(array_changed)

    if digest_a != digest_b:
        raise SystemExit("key-order invariant failed")
    if digest_a == digest_array:
        raise SystemExit("array-order sensitivity failed")

    print(json.dumps({
        "digest_parity": "pass",
        "key_order_digest": digest_a,
        "array_order_digest": digest_array,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
