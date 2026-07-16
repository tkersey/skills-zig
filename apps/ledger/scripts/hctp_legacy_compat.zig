const durable_store = @import("durable_store");
const paths = @import("hctp_legacy_paths");
const std = @import("std");

const MaxBytes = 16 * 1024 * 1024;
const campaign_bytes = paths.campaign_bytes;
const scenario_bytes = paths.scenario_bytes;
const event_bytes = paths.event_bytes;
const expected_progress_bytes = paths.expected_progress_bytes;
const corpus_bytes = paths.corpus_bytes;

const Corpus = struct {
    schema: []const u8,
    producer: Producer,
    artifacts: []const Artifact,
    event_count: usize,
    campaign_count: usize,
    chain_head: []const u8,
    legacy_projection: Projection,
};

const Producer = struct {
    command: []const u8,
    version: []const u8,
    source_contract_revision: []const u8,
};

const Artifact = struct {
    path: []const u8,
    sha256: []const u8,
    size_bytes: usize,
};

const Projection = struct {
    scenario_count: usize,
    attempt_count: usize,
    historical_baseline_attempt_count: usize,
    grade_count: usize,
    eligible_grade_count: usize,
    practice_scenarios: usize,
    practice_eligible_grades: usize,
    practice_passes: usize,
    frontier_count: usize,
    improvement_edge_count: usize,
    trial_profile_fields_absent: bool,
};

fn parseValue(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.ObjectRequired,
    };
}

fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |items| items,
        else => error.ArrayRequired,
    };
}

fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.RequiredFieldMissing;
}

fn requiredObject(map: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return object(try required(map, key));
}

fn requiredArray(map: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return array(try required(map, key));
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try required(map, key)) {
        .string => |text| text,
        else => error.StringRequired,
    };
}

fn requiredUnsigned(map: std.json.ObjectMap, key: []const u8) !usize {
    return switch (try required(map, key)) {
        .integer => |value| std.math.cast(usize, value) orelse error.UnsignedRequired,
        else => error.UnsignedRequired,
    };
}

fn artifactByPath(corpus: Corpus, path: []const u8) !Artifact {
    for (corpus.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.path, path)) return artifact;
    }
    return error.ArtifactMissing;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn expectPinnedArtifact(corpus: Corpus, path: []const u8, bytes: []const u8) !void {
    const artifact = try artifactByPath(corpus, path);
    const digest = sha256Hex(bytes);
    try std.testing.expectEqualStrings(artifact.sha256, &digest);
    try std.testing.expectEqual(artifact.size_bytes, bytes.len);
}

fn processExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 255,
    };
}

fn runAlloc(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(MaxBytes),
        .stderr_limit = .limited(MaxBytes),
    });
    defer allocator.free(result.stderr);
    if (processExitCode(result.term) != 0) {
        std.debug.print("legacy compatibility command failed:\n{s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.LegacyCompatibilityCommandFailed;
    }
    return result.stdout;
}

fn assertSnapshotPayloads(snapshot: durable_store.EventSnapshot) !void {
    var lines = std.mem.splitScalar(u8, event_bytes, '\n');
    for (snapshot.records) |record| {
        const line = lines.next() orelse return error.LegacyEventLineMissing;
        try std.testing.expectEqualStrings(line, record.payload);
    }
    try std.testing.expectEqualStrings("", lines.next() orelse return error.LegacyEventTerminatorMissing);
    try std.testing.expect(lines.next() == null);
}

test "HCTP legacy 0.7.2 corpus remains byte-locked under the current parser and fold" {
    var parsed_corpus = try std.json.parseFromSlice(Corpus, std.testing.allocator, corpus_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed_corpus.deinit();
    const corpus = parsed_corpus.value;
    try std.testing.expectEqualStrings("hylo-legacy-corpus/v1", corpus.schema);
    try std.testing.expectEqualStrings("ledger --source hylo", corpus.producer.command);
    try std.testing.expectEqualStrings("0.7.2", corpus.producer.version);
    try std.testing.expectEqualStrings(
        "8a1a96da5bb79a541924c97209bf3c1268036e87",
        corpus.producer.source_contract_revision,
    );
    try std.testing.expectEqual(@as(usize, 4), corpus.event_count);
    try std.testing.expectEqual(@as(usize, 1), corpus.campaign_count);
    try expectPinnedArtifact(corpus, "campaign-v1.json", campaign_bytes);
    try expectPinnedArtifact(corpus, "scenarios.jsonl", scenario_bytes);
    try expectPinnedArtifact(corpus, "events-v1.jsonl", event_bytes);
    try expectPinnedArtifact(corpus, "expected-progress-v1.json", expected_progress_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repo);
    const gitignore_path = try std.fs.path.join(std.testing.allocator, &.{ repo, ".gitignore" });
    defer std.testing.allocator.free(gitignore_path);
    try durable_store.writeTextAtomic(std.testing.allocator, gitignore_path, ".ledger/\n");
    const git_init = try runAlloc(std.testing.allocator, &.{ "git", "-C", repo, "init", "-q" });
    defer std.testing.allocator.free(git_init);

    const campaign_path = try std.fs.path.join(std.testing.allocator, &.{ repo, "campaign-v1.json" });
    defer std.testing.allocator.free(campaign_path);
    const scenarios_path = try std.fs.path.join(std.testing.allocator, &.{ repo, "scenarios.jsonl" });
    defer std.testing.allocator.free(scenarios_path);
    try durable_store.writeTextAtomic(std.testing.allocator, campaign_path, campaign_bytes);
    try durable_store.writeTextAtomic(std.testing.allocator, scenarios_path, scenario_bytes);

    const validation_output = try runAlloc(std.testing.allocator, &.{
        paths.ledger_path,
        "--source",
        "hylo",
        "validate-campaign",
        "--campaign",
        campaign_path,
    });
    defer std.testing.allocator.free(validation_output);
    var validation = try parseValue(std.testing.allocator, validation_output);
    defer validation.deinit();
    const validation_root = try object(validation.value);
    try std.testing.expectEqualStrings(
        "hylo-campaign-validation/v1",
        try requiredString(validation_root, "schema"),
    );
    try std.testing.expectEqualStrings("valid", try requiredString(validation_root, "status"));
    try std.testing.expectEqualStrings("cmp-test", try requiredString(validation_root, "campaign_id"));
    try std.testing.expectEqualStrings(
        "sha256:a3c70abfe24d189953c694c88f4843077df6a01d4dba7561b9d85972100cebed",
        try requiredString(validation_root, "campaign_fingerprint"),
    );
    try std.testing.expectEqual(@as(usize, 1), try requiredUnsigned(validation_root, "scenario_count"));
    const split_counts = try requiredObject(validation_root, "split_counts");
    try std.testing.expectEqual(@as(usize, 1), try requiredUnsigned(split_counts, "practice"));
    try std.testing.expectEqual(@as(usize, 0), try requiredUnsigned(split_counts, "holdout"));
    try std.testing.expectEqual(@as(usize, 0), try requiredUnsigned(split_counts, "challenge"));

    const unchanged_campaign = try durable_store.readFileAlloc(std.testing.allocator, campaign_path, MaxBytes);
    defer std.testing.allocator.free(unchanged_campaign);
    const unchanged_scenarios = try durable_store.readFileAlloc(std.testing.allocator, scenarios_path, MaxBytes);
    defer std.testing.allocator.free(unchanged_scenarios);
    try std.testing.expectEqualStrings(campaign_bytes, unchanged_campaign);
    try std.testing.expectEqualStrings(scenario_bytes, unchanged_scenarios);

    const store_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ repo, ".ledger", "hylo", "events.jsonl" },
    );
    defer std.testing.allocator.free(store_path);
    try durable_store.writeTextAtomic(std.testing.allocator, store_path, event_bytes);

    var persistence = durable_store.PersistentEventStore.init(store_path);
    var snapshot = try persistence.eventStore().snapshot(std.testing.allocator, MaxBytes);
    defer snapshot.deinit(std.testing.allocator);
    const event_artifact = try artifactByPath(corpus, "events-v1.jsonl");
    const expected_revision = try std.fmt.allocPrint(std.testing.allocator, "sha256:{s}", .{event_artifact.sha256});
    defer std.testing.allocator.free(expected_revision);
    try std.testing.expectEqualStrings(expected_revision, snapshot.revision);
    try std.testing.expectEqualStrings(expected_revision, snapshot.content_digest);
    try std.testing.expectEqual(event_bytes.len, snapshot.extent_bytes);
    try std.testing.expectEqual(@as(usize, 0), snapshot.blank_entries);
    try std.testing.expectEqual(@as(usize, 0), snapshot.append_separator_bytes);
    try std.testing.expectEqual(corpus.event_count, snapshot.records.len);
    try assertSnapshotPayloads(snapshot);

    const doctor_output = try runAlloc(std.testing.allocator, &.{
        paths.ledger_path,
        "--source",
        "hylo",
        "--repo",
        repo,
        "doctor",
    });
    defer std.testing.allocator.free(doctor_output);
    var doctor = try parseValue(std.testing.allocator, doctor_output);
    defer doctor.deinit();
    const doctor_root = try object(doctor.value);
    try std.testing.expectEqualStrings("valid", try requiredString(doctor_root, "status"));
    try std.testing.expectEqual(corpus.event_count, try requiredUnsigned(doctor_root, "records"));
    try std.testing.expectEqual(corpus.campaign_count, try requiredUnsigned(doctor_root, "campaigns"));
    try std.testing.expectEqualStrings(corpus.chain_head, try requiredString(doctor_root, "chain_head"));

    const progress_output = try runAlloc(std.testing.allocator, &.{
        paths.ledger_path,
        "--source",
        "hylo",
        "--repo",
        repo,
        "progress",
        "--campaign-id",
        "cmp-test",
        "--format",
        "json",
    });
    defer std.testing.allocator.free(progress_output);
    try std.testing.expectEqualStrings(expected_progress_bytes, progress_output);

    var progress = try parseValue(std.testing.allocator, progress_output);
    defer progress.deinit();
    const progress_root = try object(progress.value);
    const projection = corpus.legacy_projection;
    try std.testing.expectEqual(corpus.event_count, try requiredUnsigned(progress_root, "event_count"));
    try std.testing.expectEqual(projection.scenario_count, try requiredUnsigned(progress_root, "scenario_count"));
    try std.testing.expectEqual(projection.attempt_count, try requiredUnsigned(progress_root, "attempt_count"));
    try std.testing.expectEqual(
        projection.historical_baseline_attempt_count,
        try requiredUnsigned(progress_root, "historical_baseline_attempt_count"),
    );
    try std.testing.expectEqual(projection.grade_count, try requiredUnsigned(progress_root, "grade_count"));
    try std.testing.expectEqual(
        projection.eligible_grade_count,
        try requiredUnsigned(progress_root, "eligible_grade_count"),
    );
    const practice = try requiredObject(try requiredObject(progress_root, "split_results"), "practice");
    try std.testing.expectEqual(projection.practice_scenarios, try requiredUnsigned(practice, "scenarios"));
    try std.testing.expectEqual(
        projection.practice_eligible_grades,
        try requiredUnsigned(practice, "eligible_grades"),
    );
    try std.testing.expectEqual(projection.practice_passes, try requiredUnsigned(practice, "passes"));
    try std.testing.expectEqual(projection.frontier_count, (try requiredArray(progress_root, "frontier")).items.len);
    try std.testing.expectEqual(
        projection.improvement_edge_count,
        (try requiredArray(progress_root, "improvement_edges")).items.len,
    );
    if (projection.trial_profile_fields_absent) {
        try std.testing.expect(progress_root.get("protocol_profiles") == null);
        try std.testing.expect(progress_root.get("trial_counts") == null);
        try std.testing.expect(progress_root.get("claim_summary") == null);
    }
    try std.testing.expect(progress_root.get("causal_frontier") == null);
    try std.testing.expect(progress_root.get("next_step_decisions") == null);

    const after = try durable_store.readFileAlloc(std.testing.allocator, store_path, MaxBytes);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(event_bytes, after);
}
