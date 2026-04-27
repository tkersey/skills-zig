const std = @import("std");
const collector = @import("parse_arch_collector");

pub const default_suite = "apps/parse-arch/references/eval/suite.yaml";

pub const EvalOptions = struct {
    suite_path: []const u8,
};

const FocusExpectation = struct {
    expected_top_signal: ?[]const u8 = null,
    note_regex: ?[]const u8 = null,
    path: []const u8,
};

const Case = struct {
    expected_docs_claim_regex: ?[]const u8 = null,
    expected_repo_kind: ?[]const u8 = null,
    expected_read_depth_verdict: ?[]const u8 = null,
    expected_suggested_focus_paths: []const []const u8 = &.{},
    expected_thin_signal_classes: []const []const u8 = &.{},
    expected_top_signal: ?[]const u8 = null,
    focus_expectations: []const FocusExpectation = &.{},
    focus_paths: []const []const u8 = &.{},
    forbidden_suggested_focus_paths: []const []const u8 = &.{},
    forbidden_top_signals: []const []const u8 = &.{},
    id: []const u8,
    min_dependency_hint_count: ?usize = null,
    min_entrypoint_hint_count: ?usize = null,
    min_runtime_hint_count: ?usize = null,
    repo: []const u8,
};

const Suite = struct {
    cases: []const Case,
    version: usize,
};

pub fn runEval(allocator: std.mem.Allocator, writer: anytype, options: EvalOptions) !u8 {
    const suite = try loadSuite(allocator, options.suite_path);
    _ = suite.version;
    const suite_dir = std.fs.path.dirname(options.suite_path) orelse ".";
    var failures_found = false;
    for (suite.cases) |case| {
        const repo_path = try std.fs.path.join(allocator, &.{ suite_dir, case.repo });
        const payload = try collector.collect(allocator, repo_path, .{ .focus_paths = case.focus_paths });
        const failures = try validateCase(allocator, case, payload);
        const actual_top_signal = if (payload.architecture_signals.len > 0) payload.architecture_signals[0].name else "<none>";
        const actual_repo_kinds = try joinRepoKinds(allocator, payload.repo_kind_hints);
        if (failures.len > 0) {
            failures_found = true;
            try writer.print("FAIL {s}: top={s} repo_kinds={s}\n", .{ case.id, actual_top_signal, actual_repo_kinds });
            for (failures) |failure| {
                try writer.print("  - {s}\n", .{failure});
            }
        } else {
            try writer.print("PASS {s}: top={s} repo_kinds={s}\n", .{ case.id, actual_top_signal, actual_repo_kinds });
        }
    }
    return if (failures_found) 1 else 0;
}

pub fn loadSuite(allocator: std.mem.Allocator, suite_path: []const u8) !Suite {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), suite_path, allocator, .limited(1024 * 1024));
    return try parseSuiteYaml(allocator, bytes);
}

fn parseSuiteYaml(allocator: std.mem.Allocator, bytes: []const u8) !Suite {
    var version: ?usize = null;
    var cases = std.ArrayList(Case).empty;
    var current: ?Case = null;
    var active_list: enum { none, focus_paths, forbidden, focus_expectations, expected_thin_classes, expected_suggestions, forbidden_suggestions } = .none;
    var pending_focus: ?FocusExpectation = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, stripYamlComment(line_raw), " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "cases:")) continue;
        if (std.mem.startsWith(u8, line, "version:")) {
            version = try std.fmt.parseUnsigned(usize, std.mem.trim(u8, line["version:".len..], " \t\r"), 10);
            continue;
        }
        if (std.mem.startsWith(u8, line, "- id:")) {
            if (pending_focus) |focus| {
                var tmp = current.?;
                var list = std.ArrayList(FocusExpectation).empty;
                try list.appendSlice(allocator, tmp.focus_expectations);
                try list.append(allocator, focus);
                tmp.focus_expectations = try list.toOwnedSlice(allocator);
                current = tmp;
                pending_focus = null;
            }
            if (current) |case_prev| try cases.append(allocator, case_prev);
            current = .{
                .id = try allocator.dupe(u8, parseScalar(line["- id:".len..])),
                .repo = "",
            };
            active_list = .none;
            continue;
        }
        if (current == null) continue;
        if (std.mem.startsWith(u8, line, "- path:")) {
            pending_focus = .{ .path = try allocator.dupe(u8, parseScalar(line["- path:".len..])) };
            active_list = .focus_expectations;
            continue;
        }
        if (std.mem.startsWith(u8, line, "- ")) {
            const item = try allocator.dupe(u8, parseScalar(line[2..]));
            switch (active_list) {
                .focus_paths => {
                    var list = std.ArrayList([]const u8).empty;
                    try list.appendSlice(allocator, current.?.focus_paths);
                    try list.append(allocator, item);
                    current.?.focus_paths = try list.toOwnedSlice(allocator);
                },
                .forbidden => {
                    var list = std.ArrayList([]const u8).empty;
                    try list.appendSlice(allocator, current.?.forbidden_top_signals);
                    try list.append(allocator, item);
                    current.?.forbidden_top_signals = try list.toOwnedSlice(allocator);
                },
                .expected_thin_classes => {
                    var list = std.ArrayList([]const u8).empty;
                    try list.appendSlice(allocator, current.?.expected_thin_signal_classes);
                    try list.append(allocator, item);
                    current.?.expected_thin_signal_classes = try list.toOwnedSlice(allocator);
                },
                .expected_suggestions => {
                    var list = std.ArrayList([]const u8).empty;
                    try list.appendSlice(allocator, current.?.expected_suggested_focus_paths);
                    try list.append(allocator, item);
                    current.?.expected_suggested_focus_paths = try list.toOwnedSlice(allocator);
                },
                .forbidden_suggestions => {
                    var list = std.ArrayList([]const u8).empty;
                    try list.appendSlice(allocator, current.?.forbidden_suggested_focus_paths);
                    try list.append(allocator, item);
                    current.?.forbidden_suggested_focus_paths = try list.toOwnedSlice(allocator);
                },
                else => {},
            }
            continue;
        }

        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon_idx], " \t\r");
        const raw_value = line[colon_idx + 1 ..];
        if (pending_focus != null and !std.mem.eql(u8, key, "focus_expectations")) {
            if (std.mem.eql(u8, key, "expected_top_signal")) {
                pending_focus.?.expected_top_signal = try allocator.dupe(u8, parseScalar(raw_value));
                continue;
            }
            if (std.mem.eql(u8, key, "note_regex")) {
                pending_focus.?.note_regex = try allocator.dupe(u8, parseScalar(raw_value));
                continue;
            }
        }

        if (std.mem.eql(u8, key, "repo")) {
            current.?.repo = try allocator.dupe(u8, parseScalar(raw_value));
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "expected_repo_kind")) {
            current.?.expected_repo_kind = try allocator.dupe(u8, parseScalar(raw_value));
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "expected_top_signal")) {
            current.?.expected_top_signal = try allocator.dupe(u8, parseScalar(raw_value));
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "expected_read_depth_verdict")) {
            current.?.expected_read_depth_verdict = try allocator.dupe(u8, parseScalar(raw_value));
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "expected_docs_claim_regex")) {
            current.?.expected_docs_claim_regex = try allocator.dupe(u8, parseScalar(raw_value));
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "min_runtime_hint_count")) {
            current.?.min_runtime_hint_count = try std.fmt.parseUnsigned(usize, parseScalar(raw_value), 10);
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "min_dependency_hint_count")) {
            current.?.min_dependency_hint_count = try std.fmt.parseUnsigned(usize, parseScalar(raw_value), 10);
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "min_entrypoint_hint_count")) {
            current.?.min_entrypoint_hint_count = try std.fmt.parseUnsigned(usize, parseScalar(raw_value), 10);
            active_list = .none;
            continue;
        }
        if (std.mem.eql(u8, key, "focus_paths")) {
            active_list = .focus_paths;
            continue;
        }
        if (std.mem.eql(u8, key, "forbidden_top_signals")) {
            active_list = .forbidden;
            continue;
        }
        if (std.mem.eql(u8, key, "expected_thin_signal_classes")) {
            active_list = .expected_thin_classes;
            continue;
        }
        if (std.mem.eql(u8, key, "expected_suggested_focus_paths")) {
            active_list = .expected_suggestions;
            continue;
        }
        if (std.mem.eql(u8, key, "forbidden_suggested_focus_paths")) {
            active_list = .forbidden_suggestions;
            continue;
        }
        if (std.mem.eql(u8, key, "focus_expectations")) {
            active_list = .focus_expectations;
            continue;
        }
    }

    if (pending_focus) |focus| {
        var tmp = current.?;
        var list = std.ArrayList(FocusExpectation).empty;
        try list.appendSlice(allocator, tmp.focus_expectations);
        try list.append(allocator, focus);
        tmp.focus_expectations = try list.toOwnedSlice(allocator);
        current = tmp;
    }
    if (current) |case_last| try cases.append(allocator, case_last);
    if (version != 1) return error.InvalidSuiteVersion;
    if (cases.items.len == 0) return error.InvalidSuite;
    return .{ .cases = try cases.toOwnedSlice(allocator), .version = version.? };
}

fn validateCase(allocator: std.mem.Allocator, case: Case, payload: collector.Payload) ![]const []const u8 {
    var failures = std.ArrayList([]const u8).empty;
    if (case.expected_repo_kind) |expected| {
        if (!hasRepoKind(payload.repo_kind_hints, expected)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected repo kind '{s}', got '{s}'", .{ expected, try joinRepoKinds(allocator, payload.repo_kind_hints) }));
        }
    }
    if (case.expected_top_signal) |expected| {
        const actual = if (payload.architecture_signals.len > 0) payload.architecture_signals[0].name else "<none>";
        if (!std.mem.eql(u8, actual, expected)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected top signal '{s}', got '{s}'", .{ expected, actual }));
        }
    }
    const actual_top = if (payload.architecture_signals.len > 0) payload.architecture_signals[0].name else "<none>";
    for (case.forbidden_top_signals) |forbidden| {
        if (std.mem.eql(u8, actual_top, forbidden)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "forbidden top signal '{s}' became dominant", .{forbidden}));
        }
    }
    if (case.expected_docs_claim_regex) |pattern| {
        if (!docsClaimsContain(payload.docs_claims, pattern)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "docs claim regex did not match: '{s}'", .{pattern}));
        }
    }
    if (case.expected_read_depth_verdict) |expected| {
        if (!std.mem.eql(u8, payload.read_depth_verdict, expected)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected read_depth_verdict '{s}', got '{s}'", .{ expected, payload.read_depth_verdict }));
        }
    }
    for (case.expected_thin_signal_classes) |expected| {
        if (!stringSliceContains(payload.thin_signal_classes, expected)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected thin_signal_classes to contain '{s}'", .{expected}));
        }
    }
    for (case.expected_suggested_focus_paths) |expected| {
        if (!stringSliceContains(payload.suggested_focus_paths, expected)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected suggested_focus_paths to contain '{s}'", .{expected}));
        }
    }
    for (case.forbidden_suggested_focus_paths) |forbidden| {
        if (stringSliceContains(payload.suggested_focus_paths, forbidden)) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "forbidden suggested_focus_path '{s}' was emitted", .{forbidden}));
        }
    }
    if (case.min_runtime_hint_count) |minimum| {
        if (payload.runtime_boundary_hints.len < minimum) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected runtime_boundary_hints >= {d}, got {d}", .{ minimum, payload.runtime_boundary_hints.len }));
        }
    }
    if (case.min_dependency_hint_count) |minimum| {
        if (payload.dependency_direction_hints.len < minimum) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected dependency_direction_hints >= {d}, got {d}", .{ minimum, payload.dependency_direction_hints.len }));
        }
    }
    if (case.min_entrypoint_hint_count) |minimum| {
        if (payload.entrypoint_hints.len < minimum) {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "expected entrypoint_hints >= {d}, got {d}", .{ minimum, payload.entrypoint_hints.len }));
        }
    }
    for (case.focus_expectations) |focus_expectation| {
        const observation = findObservation(payload.focus_path_observations, focus_expectation.path) orelse {
            try failures.append(allocator, try std.fmt.allocPrint(allocator, "missing focus observation for '{s}'", .{focus_expectation.path}));
            continue;
        };
        if (focus_expectation.expected_top_signal) |expected| {
            const actual = if (observation.top_signals) |signals| if (signals.len > 0) signals[0].name else null else null;
            if (actual == null or !std.mem.eql(u8, actual.?, expected)) {
                try failures.append(allocator, try std.fmt.allocPrint(allocator, "focus path '{s}' expected top signal '{s}', got '{s}'", .{ focus_expectation.path, expected, actual orelse "<none>" }));
            }
        }
        if (focus_expectation.note_regex) |expected| {
            if (observation.note == null or !matchesRegexish(observation.note.?, expected)) {
                try failures.append(allocator, try std.fmt.allocPrint(allocator, "focus path '{s}' note did not match regex '{s}'", .{ focus_expectation.path, expected }));
            }
        }
    }
    return try failures.toOwnedSlice(allocator);
}

fn docsClaimsContain(claims: []const collector.DocsClaim, pattern: []const u8) bool {
    for (claims) |claim| {
        if (containsIgnoreCase(claim.claim, pattern)) return true;
    }
    return false;
}

fn hasRepoKind(hints: []const collector.RepoKindHint, expected: []const u8) bool {
    for (hints) |hint| {
        if (std.mem.eql(u8, hint.repo_kind, expected)) return true;
    }
    return false;
}

fn findObservation(observations: []const collector.FocusObservation, path: []const u8) ?collector.FocusObservation {
    for (observations) |observation| {
        if (std.mem.eql(u8, observation.path, path)) return observation;
    }
    return null;
}

fn stringSliceContains(items: []const []const u8, expected: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, expected)) return true;
    }
    return false;
}

fn joinRepoKinds(allocator: std.mem.Allocator, hints: []const collector.RepoKindHint) ![]const u8 {
    if (hints.len == 0) return "<none>";
    var items = std.ArrayList([]const u8).empty;
    for (hints) |hint| try items.append(allocator, hint.repo_kind);
    return try std.mem.join(allocator, ", ", items.items);
}

fn stripYamlComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |ch, idx| {
        if (ch == '\'' and !in_double) in_single = !in_single;
        if (ch == '"' and !in_single) in_double = !in_double;
        if (ch == '#' and !in_single and !in_double) return line[0..idx];
    }
    return line;
}

fn parseScalar(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn matchesRegexish(haystack: []const u8, pattern: []const u8) bool {
    var parts = std.mem.splitScalar(u8, pattern, '|');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len == 0) continue;
        if (containsIgnoreCase(haystack, trimmed)) return true;
    }
    return false;
}
