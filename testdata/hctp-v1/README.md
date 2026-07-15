# HCTP-v1 executable contract corpus

These fixtures are the shared wire-contract spine for Ledger, CAS, Seq,
Retrace, and offline proof verification. Valid fixtures must be accepted
without semantic reinterpretation. Invalid fixtures bind one named fail-closed
boundary and must never be repaired by a consumer.

`canonical-json-v1.json` publishes the executable
`hylo-canonical-json/v1` identity vectors. It includes every RFC 8785 Appendix
B binary64 input, recording the RFC spelling and this profile's spelling in
separate fields, plus profile-specific UTF-8 key ordering, escape, exact-i64,
negative-zero, float-bearing identity-surface, and SHA-256 cases. The profile
intentionally preserves exact signed 64-bit integers, orders keys by raw UTF-8
bytes, and renders an integer-shaped binary64 outside the parser's i64 domain
in scientific notation. That last rule deliberately differs from three RFC
Appendix B spellings so parse -> canonical is byte-closed while arbitrary
`number_string` values remain rejected. Published vectors and the deterministic
binary64 corpus exercise the actual `std.json.Value` parse -> canonical path.

DCP-v2 is not migrated to this profile. Its released packet IDs continue to use
the private legacy DCP-v2 writer and are protected by exact packet-ID, float,
and string-escape compatibility locks.

## Section 36 conformance index

`conformance-v1.json` maps each normative Section 36 case, exactly once, to
the source file and exact Zig test name that executes it. The
`test-hctp-conformance-manifest` build step rejects missing, duplicate,
out-of-range, mislabeled, or unresolvable mappings. The aggregate
`test-hctp-conformance` step runs both that index check and every mapped test
module.

The index is evidence routing, not an alternate test runner: a mapping is
valid only when its named `test` declaration exists exactly once in the
declared source.

## Frozen producer and sealing contracts

- `valid-trial.json` and `valid-null-trial.json` embed
  `grading.producer_authorities` for the absolute and pair graders. Grade
  receipts must match those frozen identities, versions, binaries, keys, and
  roles.
- Promotion conformance fixtures embed a fingerprinted
  `hylo-source-selection-receipt/v1`. Its cases must cover the registered units
  exactly and preserve scenario, split, independence-cluster, visible-input,
  and hidden-reference commitments while reporting zero exact cross-split
  duplicates.
- Case-blind conformance fixtures embed a fingerprinted
  `hylo-case-materializer-contract/v1`. The controller and materializer bind
  distinct role and signing-key identities, and both the capability and visible
  input must be delivered by file descriptor.
- Sealed reveal fixtures carry one signed
  `hylo-materialization-receipt/v1` per lane. Each receipt binds the one-lane
  capability scope, opaque arm, visible input, frozen materializer producer,
  and controller/materializer trust domain without disclosing the hidden
  reference or semantic arm identity.
- Sealed grading fixtures admit only distinct anonymous FIFO endpoints with
  zero link count, the declared access direction, exact key length, clean EOF,
  and the expected descriptor allowlist. They bind each receiver by role and
  key ID. Their execution evidence truthfully records
  `separate_process: true` and `os_confinement: false`: the cryptographic and
  capability boundary is verified, but hostile native-code confinement is not
  claimed.

## macOS sealed-role proof driver

The Section 36 case 67 promotion proof uses one persistent, unprivileged macOS
`hctp-sealed-role-driver serve` process. The driver creates and retains distinct
source-seal, materializer, runner, absolute-grader, and pair-grader key material
in memory for the session. Absolute- and pair-grader keys are never persisted.
The source-seal, materializer, and runner keys have one bounded exception: while
a lane start is pending, they are retained only inside the encrypted recovery
checkpoint so that the exact admitted lane can resume. They are removed from
the checkpoint when that pending lane becomes a terminal-receipt record. The
public source-owner metadata scopes this distinction explicitly:
`source_fixture_role_secrets_persisted: false` describes the source fixture,
`driver_pending_lane_resume_secrets: encrypted_bounded_exception` describes
the driver checkpoint, and `grader_seeds_persisted: false` remains absolute.

The controller retains a separate 32-byte custody key and sends it to each
initial or recovery driver process through a fresh anonymous, one-shot file
descriptor. Other secret or semantic inputs use the same anonymous-descriptor
delivery rule. The custody key, source manifest, seal key, role signing seeds,
materialized visible input, and source profile therefore do not travel in
command-line arguments, environment variables, or plaintext named files.

Before `lane_started`, the driver generates and securely owns one canonical
lease, writes an XChaCha20-Poly1305-encrypted mode-`0600` pending checkpoint,
and only then calls Ledger's idempotent `commit-lane-start` with the lease on an
anonymous descriptor. An exact retry reuses the original start event; changed
trial, lane, runner, or lease identity fails without mutation. Output-style
`start-lane` is rejected for `assurance.required_level: sealed` trials.

Before appending a public lane finish, grade commitment, or reveal, the driver
likewise checkpoints the exact terminal receipt and lease, private grade
opening, ordered grade request identity, presentation receipt, canonical reveal
request, public receipts, and append intents. Pair custody is scoped by both
trial and pair. A restarted driver is recovery-only: it may resume the exact
pending lane, finish or reconcile admitted lane work, reconcile an exact
committed grade, return existing opaque ACKs, and complete the exact admitted
reveal. It rejects changed retries and new work. If CAS already has a verified
terminal receipt, recovery adopts the exact receipt without executing again;
a verified claim without a terminal receipt fails closed rather than violating
the zero-retry policy. Successful shutdown refuses any pending start, proves
that every persisted lane and grade belongs to a publicly revealed trial, then
removes the checkpoint and securely clears its owned mutable secret buffers.
The shutdown field `owned_secret_buffers_zeroed` is limited to those buffers;
it does not claim removal of compiler temporaries, register copies, allocator
remnants, or arbitrary process memory.

The controller-facing protocol returns only inline public metadata and opaque
ACKs. Before reveal, those ACKs bind accepted commitments and terminal
fingerprints without returning hidden references, semantic arm identities,
plaintext grade outcomes, or private openings.

The source owner signs three exact source-selection receipts at origin: the
six-case campaign receipt, the one-case practice receipt used only by the
bootstrap repair trial, and the five-case holdout receipt used only by the
promotion trial. This keeps the promotion cohort split-pure without deriving a
new source claim downstream of source ownership.

This test architecture records `os_confinement: false` and uses no
platform-specific isolation adapter. The driver and fixtures exercise the
supported macOS path through Zig and macOS POSIX process primitives.

The remaining same-user boundary is explicit. The encrypted checkpoint is
defense-in-depth for crash recovery, while CAS output and trace artifacts remain
path-backed test fixtures. A hostile process running as the same user may be
able to inspect process memory or read or alter accessible artifacts. The proof
establishes cryptographic commitment/opening integrity, role separation,
one-shot delivery, and public non-disclosure; it does not claim OS isolation or
hostile same-user isolation. Production use with that threat model would
require a separately authorized artifact store or another stronger custody
boundary.
