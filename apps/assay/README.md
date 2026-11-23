# Assay

Assay answers one bounded question: given this exact subject, this accepted
contract, and this supplied evidence, which obligations are supported, refuted,
or unresolved? It makes that derivation inspectable and compares two assessments
made under the same contract and controls.

Assay is passive. It reads local documents and, on request, the files a subject
manifest names. It does not run candidate code or evaluators, use the network,
acquire credentials, mutate repositories, or grant permission to adopt, publish,
repair, or close out work. Every result carries `authority_granted: false` and
`storage_mutated: false`.

The implemented contract is the Assay CLI v1 specification
([gist](https://gist.github.com/tkersey/ce1d7d3c15b3b27d467c2e3a20bb4407),
revision `631d061bfb6a0dc260548c4c386be1848c85675c`).

## Commands

```text
assay capabilities
assay assess --contract CONTRACT.json --subject SUBJECT.json \
             --evidence EVIDENCE.json [--subject-root DIRECTORY] [--format json|text]
assay compare --baseline BASELINE.json --candidate CANDIDATE.json [--format json|text]
assay explain --assessment ASSESSMENT.json [--format json|text]
assay --help | -h
assay --version | -V | version
```

JSON is the default format. `capabilities` always emits JSON. Output is rendered
completely, bounded, and then written to stdout in one write; redirect stdout to
keep a receipt. A failed stdout write is an `io_error` with exit 2, reported on
stderr. Flags take separate values (`--flag VALUE`); repeated, unknown, or
misplaced flags and positional arguments are `invalid_usage`. `--help` after a
command prints help.

| Exit | `assess` | `compare` / `explain` |
|---:|---|---|
| 0 | every required obligation supported | receipts valid; processing complete |
| 1 | a required obligation refuted | unused |
| 2 | command, document, integrity, resource, or I/O error; no result | same |
| 3 | none refuted, at least one unresolved | unused |

In JSON mode an error is one `assay-command-error/v1` object on stdout with a
stable `code`, a bounded `message`, and a JSON Pointer `location` (or null). In
text mode the same code and message go to stderr and stdout stays empty.
Messages name the document and never echo input bodies or environment values.
A location stops at the nearest enclosing value when a key on its path exceeds
128 bytes, so oversized keys are never echoed.

## Documents

Inputs are strict UTF-8 JSON without a byte order mark. Unpaired surrogate
escapes, duplicate keys at any depth (compared after decoding escapes), unknown
fields, duplicate identifiers, and unknown references are rejected. The `schema`
string is checked before any other field, so a newer schema is
`unsupported_schema` rather than an unknown-field error. Identifiers match
`[A-Za-z0-9][A-Za-z0-9._:/-]*` (1–128 bytes, fixed by the protocol); digests are
64 lowercase hex digits of SHA-256. Counts and byte sizes accept any JSON number
spelling that denotes an exact non-negative integer (`224`, `224.0`, `2.24e2`);
fractions and negatives are invalid, and values beyond `u64` or a published limit
are `resource_limit`.

- `assay-contract/v1`: `schema`, `id`, `claim_kind` (`artifact`, `repair`,
  `procedure`), `scope`, `context_sha256`, `evaluators`, `obligations`. Each
  obligation has `id`, `required`, `statement`, `scope`, `basis`,
  `evaluator_id`, `decisive_when` (`supported` and `refuted`, each
  `observation` or `complete_run`), and one `check`: `scalar_equal` with
  `expected`, or `domain_judgment` with `qualification`. At least one obligation
  must be required.
- `assay-subject/v1`: `schema`, `id`, `context_artifact`, `artifacts`. Each
  artifact has `id`, `role` (`target`, `context`, `evaluator`, `support`),
  relative POSIX `path`, `sha256`, and `size_bytes`. At least one target and
  exactly one context are required; IDs and paths are unique.
- `assay-evidence/v1`: `schema`, the raw `contract_sha256`, `subject_sha256`,
  and `context_sha256` bindings, `runs`, `records`, and `artifacts`. A run
  reports `complete`, `interrupted`, `timed_out`, or `error` with a reason
  (nonempty unless complete). Each obligation has at most one record: observed
  (a scalar or a judgment with a reason) or `skipped`/`unavailable` with a
  reason.

Document identity is SHA-256 of the exact file bytes. Formatting changes create
new identities. `assessment_id` is SHA-256 of
`assay-kernel/v1\ncontract=<hex>\nsubject=<hex>\nevidence=<hex>\n`.

The contract's context digest must equal the subject's context artifact, and each
contract evaluator must name a subject artifact with role `evaluator` and the
same digest. Evidence must bind the raw contract and subject bytes and that
context, each run must name a contract evaluator with its digest, and each
record's run must use the obligation's evaluator. Mismatches are
`identity_mismatch` errors, not unresolved obligations.

## Derivation

Obligations are derived in contract order:

- no record: `unresolved`, `missing_observation`;
- skipped or unavailable: `unresolved`, `skipped` or `unavailable`;
- an `unresolved` domain judgment: `unresolved`, `evaluator_unresolved`;
- a scalar proposes `supported` when typed-equal to `expected` and `refuted`
  otherwise; a domain judgment proposes its own judgment. The applicable gate
  (`decisive_when.supported` or `.refuted`) downgrades the proposal to
  `unresolved` with `run_incomplete` when it requires `complete_run` and the
  run did not complete.

Scalar equality is typed: null equals only null, false differs from zero, and
strings compare decoded Unicode scalars without normalization. Numbers compare
as exact decimals from their original tokens (`1`, `1.0`, and `1e0` are equal;
negative zero equals zero) using the shared exact-number module.

The overall judgment covers required obligations only: any refuted is `refuted`,
otherwise any unresolved is `unresolved`, otherwise `supported`. There is no
score. Evidence artifact availability is always `not_checked`.

## Receipts, explain, and compare

An `assay-assessment/v1` receipt carries the three input documents verbatim as
JSON strings, the derivation, producer metadata, and the invocation-local
verification report. `explain` and `compare` recover the inputs, rerun every
validation and derivation rule, and compare each stored derivation field with
the recomputed one; object key order and equivalent number spellings in the
envelope do not matter. A mismatch is `receipt_mismatch`. Recorded verification
is returned only as an `unauthenticated_receipt_claim`; `explain` reports
`subject_bytes: "not_reverified"`. Receipts are integrity-checked, not
authenticated: a consistently rewritten receipt has a different identity, and
telling it from the intended one needs an external trusted digest.

Two assessments are comparable only when their kernel and raw contract digest
match, their context digests match, and every non-target subject artifact matches
by ID, role, path, digest, and size. Otherwise `compare` reports
`contract_changed`, `context_changed`, and `support_artifacts_changed` (with the
sorted affected IDs) and aligns no obligations. Comparable pairs report each
obligation's transition and the preservation of required obligations the
baseline supported. Neither exit 0 nor any field is an adoption recommendation.

## Subject verification

Without `--subject-root` the manifest is an assertion (`not_checked`). With it,
Assay opens the root one component at a time from `/` or the working directory
without following links, so a symbolic link anywhere in the root path is an
`identity_mismatch` (pass a physical path, for example from `realpath`) and a
`..` component is `invalid_usage`. It opens each artifact path component without
following links, then opens the file once with `O_NOFOLLOW | O_NONBLOCK`, so a
substituted FIFO or device cannot block it. It decides file kind and size from
that open descriptor (a regular file of the manifest size), streams SHA-256
through a 64 KiB buffer until end of file whatever the read sizes, and rejects
visible changes in inode, size, or timestamps during the read. Any failure is exit 2; a
requested verification is never downgraded. Success proves which bytes Assay read
during this invocation, not that they were executed or that the manifest omits
nothing.

## Limits

`assay capabilities` publishes every configurable limit (the 128-byte identifier
length is fixed by the protocol): 2 MiB per source document, 6 MiB
combined, 64 MiB per receipt input or result, JSON depth 32, 4,096 obligations,
runs, records, subject artifacts, and evidence artifacts, 256 evaluators, 16 KiB
per text field or scalar string, 1,024-byte number tokens, 4,096-byte paths and
locators, 4 GiB per verified artifact, 16 GiB in total, 4 KiB error messages, and
a 512 MiB allocation budget enforced by a bounded allocator. Number tokens must
also fit the exact-number exponent range; larger ones are `resource_limit`. JSON
`explain` output repeats each obligation's run reason, as its schema requires, so
a maximal receipt can produce an explanation above 64 MiB; that is a clean
`resource_limit` error. Text output lists each run's reason once.

## Tests

```bash
zig build test-assay              # routine: core, entry point, and process smoke
zig build test-assay-core         # kernel unit and behavior matrix
zig build test-assay-cli-smoke    # executable process contract (python3)
zig build test-assay-acceptance   # retained codec controls (python3, node)
zig build test-full               # routine lanes plus the acceptance controls
```

The acceptance controls include timeout and output-exhaustion probes, so they run
in `test-full`, PR CI, and release qualification rather than routine `test`.

The acceptance lane vendors the retained codec fixture from
`tkersey/dotfiles@82f46ad1dffacbbe1600abda0210722d0cde5e59`
(`agents/skills/actuating/tests/review-action-fixture.mjs`, SHA-256
`f09102531a5ae7b8ed8d37a1eb39746f3a35965d52b1ae93426d1a51c9caa560`, and
`fixtures/episode-codec.mjs`, SHA-256
`e909932c2fa27551a27a8bba191be51b5c693cdad4bcc17785c506547daa3440`) unchanged.
`fixtures/codec/observe-codec.mjs` is the evaluator adapter. It keeps the
fixture's semantic oracle and maps each finite case to its effective meaning. A
thrown encode or decode error on a required-valid input is observed as
`"rejected"` (a refutation). An out-of-domain value that the fixture's worker
catches is `unavailable`. Unavailable execution, a changed candidate, or changed
protected inputs make every record `unavailable` with the run's reason. The
suite checks the defect, a real repair, placebo and unrelated changes, an invalid
restriction, zero-loss against null-loss with equal counts, a later regression,
the compact episode codec as a valid alternative, the coalesced-null task as an
incomparable contract, and timeout, output exhaustion, invalid runtime values,
source mutation, protected-input changes, and symlink substitution. These are
adequacy probes, not proof that no blind spot remains.
