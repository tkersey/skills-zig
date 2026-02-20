# Zig/Python Parity Contract

This repository treats the Python implementation at
`/Users/tk/.dotfiles/codex/skills/seq/scripts/seq.py` as the compatibility oracle.

## Scope

- Commands: `skills-rank`, `skill-trend`, `skill-report`, `role-breakdown`,
  `occurrence-export`, `find-session`, `session-prompts`, `report-bundle`,
  `section-audit`, `token-usage`, `datasets`, `dataset-schema`, `query`.
- Behavior class parity:
  - command success/failure exit class,
  - output row semantics,
  - dataset schema fields,
  - required argument handling,
  - accepted format values per command.

## Required Compatibility Invariants

1. `tool_calls` rows must expose `timestamp`, `day`, `week`, and `month` exactly
   as oracle-compatible nullable fields.
2. `seq <command> --help` must return help output with zero exit status.
3. `--max` and `--top` must be recognized as limit aliases where supported.
4. Query output must remain deterministic under fixed sort clauses.
5. Any parity benchmark claim is invalid unless differential parity checks pass first.

## Differential Cases

Primary command-level parity checks are defined in `scripts/parity/matrix.json`.
Query-level deterministic fixtures are stored in `testdata/parity/specs/*.json`.

## Performance Gate Prerequisite

Head-to-head benchmark gating (`>=20%` p50 Zig speedup) is only valid after all
required differential cases pass.
