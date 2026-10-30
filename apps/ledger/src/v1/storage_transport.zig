const std = @import("std");
const sources = @import("storage_sources.zig");
const storage_root = @import("storage_root");
const bundle = @import("storage_bundle.zig");
const admission = @import("storage_admission.zig");
const definition_core = @import("definition_core");

pub const MergeOptions = struct {
    target: bundle.Target,
    limits: bundle.Limits,
    max_input_bytes: u64,
    established_input: ?usize = null,
    binding_operation: ?[]const u8 = null,
};

pub fn merge(
    allocator: std.mem.Allocator,
    inputs: []const *const bundle.Captured,
    parameters: *const definition_core.parameters.Bindings,
    options: MergeOptions,
) !bundle.Captured {
    if (inputs.len == 0) return error.NoPreparationSources;
    if (inputs.len > options.limits.sources) return error.TooManySources;
    if (options.established_input) |index| {
        if (index >= inputs.len) return error.InvalidPreparationTarget;
    }
    const inspected = try allocator.alloc(Inspected, inputs.len);
    defer allocator.free(inspected);
    var loaded: usize = 0;
    defer for (inspected[0..loaded]) |*input| input.deinit();
    var remaining = options.max_input_bytes;
    for (inputs, inspected) |input, *target| {
        try chargeInput(input, &remaining);
        target.* = try Inspected.init(allocator, input, parameters, options);
        loaded += 1;
    }
    const selected = try selectOriginal(inspected, options.established_input);
    const views = try allocator.alloc(bundle.MergeView, inputs.len);
    defer allocator.free(views);
    for (inspected, inputs, views) |input, captured, *view| {
        view.* = .{ .description = input.manifest.description, .files = captured.files };
    }
    return bundle.assembleSources(allocator, views, selected, options.target, options.limits);
}

const Inspected = struct {
    manifest: bundle.Manifest,
    history: admission.Inspection,

    fn init(
        allocator: std.mem.Allocator,
        captured: *const bundle.Captured,
        parameters: *const definition_core.parameters.Bindings,
        options: MergeOptions,
    ) !Inspected {
        var manifest = try bundle.parse(allocator, captured.manifest, options.limits);
        errdefer manifest.deinit();
        return .{
            .manifest = manifest,
            .history = try admission.inspectCaptured(allocator, captured, parameters, .{
                .limits = options.limits,
                .binding_operation = options.binding_operation,
            }),
        };
    }

    fn deinit(self: *Inspected) void {
        self.history.deinit();
        self.manifest.deinit();
    }
};

fn chargeInput(input: *const bundle.Captured, remaining: *u64) !void {
    if (input.manifest.len > remaining.*) return error.TransportInputLimitExceeded;
    remaining.* -= input.manifest.len;
    for (input.files) |file| {
        if (file.content.len > remaining.*) return error.TransportInputLimitExceeded;
        remaining.* -= file.content.len;
    }
}

fn selectOriginal(inputs: []const Inspected, established: ?usize) !bundle.SourceSelection {
    var selected: bundle.SourceSelection = .{ .input = 0, .source = 0 };
    for (inputs, 0..) |input, input_index| {
        for (input.history.sources, 0..) |_, source_index| {
            const candidate: bundle.SourceSelection = .{
                .input = input_index,
                .source = source_index,
            };
            if (try covers(inputs, candidate, selected)) {
                if (!try covers(inputs, selected, candidate) or bundle.compareSources(
                    input.manifest.description.sources[source_index],
                    inputs[selected.input].manifest.description.sources[selected.source],
                ) == .lt) selected = candidate;
            }
        }
    }
    const chosen = &inputs[selected.input].history;
    const history = chosen.sources[selected.source].history;
    for (inputs, 0..) |*input, input_index| {
        for (input.history.sources, 0..) |_, source_index| {
            if (!try covers(inputs, selected, .{ .input = input_index, .source = source_index })) {
                return error.PreparationReconciliationRequired;
            }
        }
        if (!try chosen.covers(history, &input.history, input.history.primary_history)) {
            return error.PreparationReconciliationRequired;
        }
    }
    if (established) |index| {
        const target = &inputs[index].history;
        if (!try target.covers(target.primary_history, chosen, history)) {
            return error.PreparationReconciliationRequired;
        }
    }
    return selected;
}

fn covers(
    inputs: []const Inspected,
    cover: bundle.SourceSelection,
    source: bundle.SourceSelection,
) !bool {
    const left = &inputs[cover.input].history;
    const right = &inputs[source.input].history;
    return left.covers(
        left.sources[cover.source].history,
        right,
        right.sources[source.source].history,
    );
}

pub const Loaded = struct {
    source: sources.Plan,
    root: storage_root.SourceRoot,
    captured: bundle.Captured,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        descriptor: sources.Source,
        limits: bundle.Limits,
    ) !Loaded {
        const source_limits: sources.Limits = .{
            .sources = limits.sources,
            .observations = limits.observations,
            .manifest_bytes = limits.manifest_bytes,
        };
        const encoded = try sources.encode(allocator, &.{descriptor}, source_limits);
        defer allocator.free(encoded);
        var plan = try sources.parseWithLimits(allocator, encoded, source_limits);
        errdefer plan.deinit();
        const source = plan.sources[0];
        if (source.kind != .@"preservation-bundle") return error.UnsupportedTransportSource;
        var root = try storage_root.SourceRoot.open(allocator, io, source.locator, null);
        errdefer root.deinit();
        var captured = try bundle.loadPublished(allocator, &root, source.manifest_digest.?, limits);
        errdefer captured.deinit();
        var manifest = try bundle.parse(allocator, captured.manifest, limits);
        defer manifest.deinit();
        if (manifest.description.sources.len == 0) return error.UnsupportedBundleLineage;
        try requireObservations(source.observations, manifest.description.observations);
        return .{ .source = plan, .root = root, .captured = captured };
    }

    pub fn deinit(self: *Loaded) void {
        self.captured.deinit();
        self.root.deinit();
        self.source.deinit();
        self.* = undefined;
    }

    pub fn revalidate(self: *const Loaded) !void {
        try self.root.revalidateControl();
    }
};

fn requireObservations(
    supplied: []const sources.Observation,
    retained: []const sources.Observation,
) !void {
    for (supplied) |expected| {
        var low: usize = 0;
        var high = retained.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, retained[middle].observation_id, expected.observation_id)) {
                .eq => {
                    if (!sameObservation(retained[middle], expected)) {
                        return error.BundleObservationMismatch;
                    }
                    break;
                },
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        if (low == high) return error.BundleObservationMismatch;
    }
}

fn sameObservation(left: sources.Observation, right: sources.Observation) bool {
    return std.mem.eql(u8, left.evidence_locator, right.evidence_locator) and
        std.mem.eql(u8, left.evidence_digest, right.evidence_digest) and
        std.mem.eql(u8, left.evidence_pointer, right.evidence_pointer) and
        left.binding.eql(right.binding);
}

test "transport assertions preserve every retained original observation" {
    const original: sources.Observation = .{
        .observation_id = "b",
        .evidence_locator = "/explicit/origin.json",
        .evidence_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .evidence_pointer = "/original",
        .binding = .{ .root_pointer = "/root" },
    };
    var first = original;
    first.observation_id = "a";
    var last = original;
    last.observation_id = "c";
    const retained = [_]sources.Observation{ first, original, last };
    try requireObservations(&.{}, &retained);
    for (retained) |item| try requireObservations(&.{item}, &retained);
    try requireObservations(&.{ last, first }, &retained);
    var changed = original;
    changed.observation_id = "absent";
    try std.testing.expectError(error.BundleObservationMismatch, requireObservations(
        &.{changed},
        &retained,
    ));
    changed = original;
    changed.binding.root_pointer = "/different-root";
    try std.testing.expectError(error.BundleObservationMismatch, requireObservations(
        &.{changed},
        &retained,
    ));
    changed = original;
    changed.evidence_locator = "/transport/relabelled.json";
    try std.testing.expectError(error.BundleObservationMismatch, requireObservations(
        &.{changed},
        &retained,
    ));
    try std.testing.expectError(
        error.BundleObservationMismatch,
        requireObservations(&.{original}, &.{}),
    );
}
