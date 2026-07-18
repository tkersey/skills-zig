# Hylo operator-recipe fixture

This fixture binds the documented CRF/HCTP operator order to native test
surfaces. It is not a second protocol definition and grants no campaign,
trial, execution, reveal, proof, or target-mutation authority.

`source-manifest.json` is a native source-selection request with one controlled
direct CRF episode and one transcript-only episode admitted through an
authoritative historical profile. The packaged-Seq lane compiles that request
through the selected product binary and exact-validates the receipt against a
minimal source-binding projection. That projection exercises only the
assurance, campaign, and sealing join; it is not a complete registered trial.
The macOS runtime separately invokes Ledger `validate-campaign` on
`campaign-template.json`.

The repository-dependent campaign head, target snapshots, applied change, and
receipt fingerprint in `trial-build-request.json` are rebound from one admitted
test repository by the Ledger owner test named `operator recipe executable`.
That test admits the campaign, both scenarios, target bundle, and bounded
change; delivers `hylo-trial-custody/v1` over anonymous directional pipes; and,
on macOS, invokes the selected Ledger, Seq, CAS trial, and fixture-executor
binaries for trial compilation, native validation, exact source-receipt
validation, and custody-backed registration. It then exercises lane preflight,
Seq source and profile materialization, start recovery, custody- and lease-bound
Ledger target materialization, CAS execution, finish recovery, and blind
grading for the direct and historical routes. This ordering establishes the
visible and private source prerequisites before the lease claim while
preserving Ledger materialization's required start and lease lineage. After all
lanes are terminal and absolutely graded, it records one blind pair grade for
every frozen pair, performs the custody-backed reveal, derives the result,
closes the trial, builds and exports the proof artifact set, and verifies the
exported proof. The historical route delivers the source profile through a
protected FD and runs the DCP/RIP/FIR replay inside `cas_trial run`; it does not
invoke a separate `compile-replay` phase.

The exact 36-step expectation enumerates the evaluated-trial route and its
explicit `owner_applied_candidate_precondition`. A
fixture-only motivating-practice precondition is folded after campaign
admission and before candidate creation; it is not a substitute for any listed
product command. Only after that evidence is terminal does the owner fixture
stage the candidate. Candidate target-bundle admission and the applied-change
event then cross the released `ledger --source hylo append` surface, and the
test proves the resulting bundle, snapshot, diff, change status, and current
target. A final product `doctor` then inspects that complete pre-trial admission
state before the evaluation trial is compiled. This state proves an
owner-applied candidate; Hylo grants no mutation authority.

The compiled trial retains both source routes, two balanced pairs per unit,
four pairs total, and eight one-claim lanes. The aggregate operator suite
separately proves that incomplete campaign, scenario-manifest, target, or
compiler-authority state fails without public output, private output, or event
append. The JSON request contains the complete native policy shape; its
content-addressed identity fields are illustrative until that owner-bound
rebinding occurs. The verifier, CAS runner, fixture executor, Ledger authority,
runner-contract, and trust-policy fingerprints are rebound to the selected
executables and the embedded CAS version before entropy. The runner contract
binds `cas-trial`, `cas-trial-executor`, and `hylo-ledger` as separate declared
authorities. Request sealing contains only caller-owned reveal and materializer
policy; Ledger derives visibility and visible/hidden commitment sets from the
validated source receipt.

The portable lane statically checks the campaign, scenario, compiler-request,
ordering, and route shapes, then invokes the platform-neutral Ledger trial
validator. The macOS runtime probes the released Seq/Ledger/CAS capabilities
and executes the exact compiled public `hylo-trial/v2` through both frozen
routes and the post-execution grade, custody reveal, result, close, proof export,
and proof verification phases. The broader HCTP integration suite remains
complementary coverage, not a substitute for this fixture's execution.

`hctp-sealed-role-driver` remains conformance-only. Production sealed execution
must fail before secret generation or mutation unless an admitted broker exists.
