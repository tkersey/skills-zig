# Durable Negative Ledger Storage And Release Campaign

Source: current thread `$grill-me` + `$plan` handoff on 2026-06-17.

Objective: build and ship a `ledger` CLI in `skills-zig` that stores repo-local durable negative evidence at `.ledger/negative-ledger.jsonl`, shares durable-store mechanics with `st` and `learnings`, cuts `.dotfiles` `$negative-ledger`/`$resolve` gates over to operational ledger evidence, and completes release/tap proof.

Locked decisions:

- Store: `.ledger/negative-ledger.jsonl`, tracked/shared, append-only JSONL events, separate from `.step`.
- CLI: `ledger`, `apps/ledger/VERSION = 0.1.0`, JSON-first automation input.
- Durable IDs: monotonic `NEG-000001` style.
- Active exclusions: require inspectable witness evidence; user-context-only entries become `unknown` or `need-evidence`.
- Matching: exact/applicability matches can block; deterministic lexical fuzzy matches suggest only.
- Consumer refactor: `st` and `learnings` share durable-store machinery only; existing schemas, paths, outputs, and projections stay stable.
- Skill cutover: update `.dotfiles` `$negative-ledger`/`$resolve` instructions and gates to require operational `ledger` evidence for repeated-route mutation.
- Migrations: code/storage refactor only; no `.learnings.jsonl` import/backfill and no existing store rewrite.
- Release: full release chain is authorized, including public tag/release/tap work after proof.

Execution waves:

1. Prepare `libs/durable_store` shared mechanics and tests.
2. Refactor `st` and `learnings` onto those mechanics without behavior drift.
3. Implement `ledger` CLI commands and route-gate output.
4. Add route-gate fixture proof suite.
5. Wire build, docs, CI, release metadata, and `apps/ledger/VERSION`.
6. Cut over `.dotfiles` skill docs/gates.
7. Run full repo and targeted validation.
8. Publish release and Homebrew tap proof.

Done state: future same-cluster `$resolve` mutation cannot proceed on prose-only negative-ledger claims and can reproduce active route exclusions from durable `NEG-*` evidence.
