const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

pub const max_file_bytes: usize = 1_000_000;
pub const max_total_bytes: usize = 32 * 1024 * 1024;
const binary_sniff_bytes: usize = 512;
const max_git_stderr: usize = 64 * 1024;

pub const Kind = enum {
    paths,
    stdin,
    git,
    diff,

    pub fn jsonName(self: Kind) []const u8 {
        return switch (self) {
            .paths => "paths",
            .stdin => "stdin",
            .git => "git",
            .diff => "diff",
        };
    }
};

pub const WarningKind = enum {
    inaccessible,
    oversized,
    binary,
    invalid_utf8,
    symlink,
    unsupported,

    pub fn jsonName(self: WarningKind) []const u8 {
        return switch (self) {
            .inaccessible => "inaccessible",
            .oversized => "oversized",
            .binary => "binary",
            .invalid_utf8 => "invalid_utf8",
            .symlink => "symlink",
            .unsupported => "unsupported",
        };
    }
};

pub const Warning = struct {
    kind: WarningKind,
    path: []u8,
};

pub const Corpus = struct {
    kind: Kind,
    text: []u8,
    files: []const []u8,
    warnings: []Warning,
    source_bytes: usize,

    pub fn deinit(self: *Corpus, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.files) |path| allocator.free(path);
        allocator.free(self.files);
        for (self.warnings) |warning| allocator.free(warning.path);
        allocator.free(self.warnings);
        self.* = undefined;
    }
};

pub const InputError = error{
    EmptyInput,
    InputTooLarge,
    TargetUnavailable,
    ExplicitSymlink,
    ExplicitUnsupported,
    ExplicitOversized,
    ExplicitBinary,
    ExplicitInvalidUtf8,
    InvalidUtf8,
    GitFailed,
    InvalidGitPath,
};

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyInput => "input is empty",
        error.InputTooLarge => "input exceeds the 32 MiB aggregate limit",
        error.TargetUnavailable => "an explicit input target is unavailable",
        error.ExplicitSymlink => "an explicit input target is a symlink",
        error.ExplicitUnsupported => "an explicit input target is not a regular file or directory",
        error.ExplicitOversized => "an explicit file exceeds 1,000,000 bytes",
        error.ExplicitBinary => "an explicit file appears to be binary",
        error.ExplicitInvalidUtf8 => "an explicit file is not valid UTF-8",
        error.InvalidUtf8 => "input is not valid UTF-8",
        error.GitFailed => "git command failed",
        error.InvalidGitPath => "git returned an unsafe or invalid path",
        else => "failed to collect input",
    };
}

pub fn collect(
    allocator: std.mem.Allocator,
    process_io: std.Io,
    source: cli.Source,
    include: []const []const u8,
    exclude: []const []const u8,
) !Corpus {
    var empty_environment = std.process.Environ.Map.init(allocator);
    defer empty_environment.deinit();
    return collectWithEnvironment(allocator, process_io, &empty_environment, source, include, exclude);
}

pub fn collectWithEnvironment(
    allocator: std.mem.Allocator,
    process_io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    source: cli.Source,
    include: []const []const u8,
    exclude: []const []const u8,
) !Corpus {
    return switch (source) {
        .paths => |paths| collectPaths(allocator, paths, include, exclude),
        .stdin => collectStdin(allocator),
        .git => |repo| collectGit(allocator, process_io, parent_environment, repo, null),
        .diff => |diff| collectGit(allocator, process_io, parent_environment, diff.repo, diff.ref),
    };
}

fn collectStdin(allocator: std.mem.Allocator) !Corpus {
    var reader = std.Io.File.stdin().reader(defaultIo(), &.{});
    const text = reader.interface.allocRemaining(allocator, .limited(max_total_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InputTooLarge,
        else => return err,
    };
    errdefer allocator.free(text);
    if (text.len > max_total_bytes) return error.InputTooLarge;
    if (text.len == 0) return error.EmptyInput;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return .{
        .kind = .stdin,
        .text = text,
        .files = try allocator.alloc([]u8, 0),
        .warnings = try allocator.alloc(Warning, 0),
        .source_bytes = text.len,
    };
}

const Candidate = struct {
    abs_path: []u8,
    label: []u8,
    recursive: bool,
};

const PathCollector = struct {
    allocator: std.mem.Allocator,
    cwd_abs: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    candidates: std.ArrayList(Candidate) = .empty,
    by_absolute: std.StringHashMap(usize),
    warnings: std.ArrayList(Warning) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        cwd_abs: []const u8,
        include: []const []const u8,
        exclude: []const []const u8,
    ) PathCollector {
        return .{
            .allocator = allocator,
            .cwd_abs = cwd_abs,
            .include = include,
            .exclude = exclude,
            .by_absolute = std.StringHashMap(usize).init(allocator),
        };
    }

    fn deinit(self: *PathCollector) void {
        self.by_absolute.deinit();
        for (self.candidates.items) |candidate| {
            self.allocator.free(candidate.abs_path);
            self.allocator.free(candidate.label);
        }
        self.candidates.deinit(self.allocator);
        for (self.warnings.items) |warning| self.allocator.free(warning.path);
        self.warnings.deinit(self.allocator);
    }

    fn warn(self: *PathCollector, kind: WarningKind, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.warnings.append(self.allocator, .{ .kind = kind, .path = owned });
    }

    fn labelFor(self: *PathCollector, abs_path: []const u8) ![]u8 {
        const rel = try std.fs.path.relative(self.allocator, self.cwd_abs, null, self.cwd_abs, abs_path);
        defer self.allocator.free(rel);
        const normalized = try normalizeSlashesAlloc(self.allocator, rel);
        if (!std.unicode.utf8ValidateSlice(normalized)) {
            self.allocator.free(normalized);
            return error.InvalidGitPath;
        }
        return normalized;
    }

    fn addFile(self: *PathCollector, abs_path: []const u8, recursive: bool) !void {
        const label = try self.labelFor(abs_path);
        errdefer self.allocator.free(label);
        if (!shouldInclude(label, self.include, self.exclude)) {
            self.allocator.free(label);
            return;
        }
        if (self.by_absolute.get(abs_path)) |index| {
            if (!recursive) self.candidates.items[index].recursive = false;
            self.allocator.free(label);
            return;
        }
        const owned_abs = try self.allocator.dupe(u8, abs_path);
        errdefer self.allocator.free(owned_abs);
        const index = self.candidates.items.len;
        try self.candidates.append(self.allocator, .{
            .abs_path = owned_abs,
            .label = label,
            .recursive = recursive,
        });
        errdefer _ = self.candidates.pop();
        try self.by_absolute.put(owned_abs, index);
    }
};

fn collectPaths(
    allocator: std.mem.Allocator,
    targets: []const []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
) !Corpus {
    const cwd_abs = try std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), ".", allocator);
    defer allocator.free(cwd_abs);
    var collector = PathCollector.init(allocator, cwd_abs, include, exclude);
    defer collector.deinit();

    for (targets) |target| try collectExplicitTarget(&collector, target);
    std.mem.sort(Candidate, collector.candidates.items, {}, candidateLessThan);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    var source_bytes: usize = 0;
    for (collector.candidates.items) |candidate| {
        const content = readCandidate(allocator, &collector, candidate) catch |err| switch (err) {
            error.RecursiveSkip => continue,
            else => return err,
        };
        defer allocator.free(content);
        if (source_bytes + content.len > max_total_bytes) return error.InputTooLarge;
        source_bytes += content.len;
        if (files.items.len > 0) try text.appendSlice(allocator, "\n\n");
        try appendHeader(&text, allocator, candidate.label);
        try text.appendSlice(allocator, content);
        if (text.items.len > max_total_bytes) return error.InputTooLarge;
        try files.append(allocator, try allocator.dupe(u8, candidate.label));
    }
    if (files.items.len == 0) return error.EmptyInput;

    std.mem.sort(Warning, collector.warnings.items, {}, warningLessThan);
    const warnings = try collector.warnings.toOwnedSlice(allocator);
    errdefer {
        for (warnings) |warning| allocator.free(warning.path);
        allocator.free(warnings);
    }
    return .{
        .kind = .paths,
        .text = try text.toOwnedSlice(allocator),
        .files = try files.toOwnedSlice(allocator),
        .warnings = warnings,
        .source_bytes = source_bytes,
    };
}

fn collectExplicitTarget(collector: *PathCollector, target: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(defaultIo(), target, .{ .follow_symlinks = false }) catch return error.TargetUnavailable;
    switch (stat.kind) {
        .file => {
            const abs = std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), target, collector.allocator) catch return error.TargetUnavailable;
            defer collector.allocator.free(abs);
            try collector.addFile(abs, false);
        },
        .directory => {
            const abs = std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), target, collector.allocator) catch return error.TargetUnavailable;
            defer collector.allocator.free(abs);
            try walkDirectory(collector, abs);
        },
        .sym_link => return error.ExplicitSymlink,
        else => return error.ExplicitUnsupported,
    }
}

fn walkDirectory(collector: *PathCollector, dir_abs: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(defaultIo(), dir_abs, .{ .iterate = true, .follow_symlinks = false }) catch {
        const label = collector.labelFor(dir_abs) catch dir_abs;
        defer if (label.ptr != dir_abs.ptr) collector.allocator.free(label);
        try collector.warn(.inaccessible, label);
        return;
    };
    defer dir.close(defaultIo());
    var it = dir.iterate();
    while (it.next(defaultIo()) catch {
        const label = collector.labelFor(dir_abs) catch dir_abs;
        defer if (label.ptr != dir_abs.ptr) collector.allocator.free(label);
        try collector.warn(.inaccessible, label);
        return;
    }) |entry| {
        if (entry.kind == .directory and shouldSkipDirectory(entry.name)) continue;
        const child = try std.fs.path.join(collector.allocator, &.{ dir_abs, entry.name });
        defer collector.allocator.free(child);
        const kind = if (entry.kind == .unknown)
            (dir.statFile(defaultIo(), entry.name, .{ .follow_symlinks = false }) catch {
                const label = collector.labelFor(child) catch entry.name;
                defer if (label.ptr != entry.name.ptr) collector.allocator.free(label);
                try collector.warn(.inaccessible, label);
                continue;
            }).kind
        else
            entry.kind;
        switch (kind) {
            .file => try collector.addFile(child, true),
            .directory => try walkDirectory(collector, child),
            .sym_link => {
                const label = collector.labelFor(child) catch entry.name;
                defer if (label.ptr != entry.name.ptr) collector.allocator.free(label);
                try collector.warn(.symlink, label);
            },
            else => {
                const label = collector.labelFor(child) catch entry.name;
                defer if (label.ptr != entry.name.ptr) collector.allocator.free(label);
                try collector.warn(.unsupported, label);
            },
        }
    }
}

const RecursiveSkip = error{RecursiveSkip};

fn readCandidate(allocator: std.mem.Allocator, collector: *PathCollector, candidate: Candidate) ![]u8 {
    const stat = std.Io.Dir.cwd().statFile(defaultIo(), candidate.abs_path, .{ .follow_symlinks = false }) catch {
        if (candidate.recursive) {
            try collector.warn(.inaccessible, candidate.label);
            return RecursiveSkip.RecursiveSkip;
        }
        return error.TargetUnavailable;
    };
    if (stat.kind != .file) {
        if (candidate.recursive) {
            try collector.warn(if (stat.kind == .sym_link) .symlink else .unsupported, candidate.label);
            return RecursiveSkip.RecursiveSkip;
        }
        return if (stat.kind == .sym_link) error.ExplicitSymlink else error.ExplicitUnsupported;
    }
    if (stat.size > max_file_bytes) {
        if (candidate.recursive) {
            try collector.warn(.oversized, candidate.label);
            return RecursiveSkip.RecursiveSkip;
        }
        return error.ExplicitOversized;
    }
    const content = std.Io.Dir.cwd().readFileAlloc(defaultIo(), candidate.abs_path, allocator, .limited(max_file_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => {
            if (candidate.recursive) {
                try collector.warn(.oversized, candidate.label);
                return RecursiveSkip.RecursiveSkip;
            }
            return error.ExplicitOversized;
        },
        else => {
            if (candidate.recursive) {
                try collector.warn(.inaccessible, candidate.label);
                return RecursiveSkip.RecursiveSkip;
            }
            return error.TargetUnavailable;
        },
    };
    errdefer allocator.free(content);
    if (content.len > max_file_bytes) {
        if (candidate.recursive) {
            try collector.warn(.oversized, candidate.label);
            return RecursiveSkip.RecursiveSkip;
        }
        return error.ExplicitOversized;
    }
    if (std.mem.indexOfScalar(u8, content[0..@min(content.len, binary_sniff_bytes)], 0) != null) {
        if (candidate.recursive) {
            try collector.warn(.binary, candidate.label);
            return RecursiveSkip.RecursiveSkip;
        }
        return error.ExplicitBinary;
    }
    if (!std.unicode.utf8ValidateSlice(content)) {
        if (candidate.recursive) {
            try collector.warn(.invalid_utf8, candidate.label);
            return RecursiveSkip.RecursiveSkip;
        }
        return error.ExplicitInvalidUtf8;
    }
    return content;
}

fn collectGit(
    allocator: std.mem.Allocator,
    process_io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    repo_arg: ?[]const u8,
    diff_ref: ?[]const u8,
) !Corpus {
    var git_environment = try sanitizedGitEnvironment(allocator, parent_environment);
    defer git_environment.deinit();
    const repo_input = repo_arg orelse ".";
    const repo_abs = std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), repo_input, allocator) catch return error.TargetUnavailable;
    defer allocator.free(repo_abs);
    var repo_dir = std.Io.Dir.openDirAbsolute(defaultIo(), repo_abs, .{ .follow_symlinks = false }) catch return error.TargetUnavailable;
    defer repo_dir.close(defaultIo());
    const cwd_abs = try std.Io.Dir.cwd().realPathFileAlloc(defaultIo(), ".", allocator);
    defer allocator.free(cwd_abs);

    const diff = if (diff_ref) |ref|
        try runGit(allocator, process_io, &git_environment, repo_abs, &.{
            "git",                    "-c",                     "core.quotePath=true",   "diff",
            "--no-ext-diff",          "--no-textconv",          "--no-color",            "--no-renames",
            "--full-index",           "--diff-algorithm=myers", "--no-indent-heuristic", "--unified=3",
            "--inter-hunk-context=0", "--src-prefix=a/",        "--dst-prefix=b/",       ref,
            "--",
        }, max_total_bytes + 1)
    else
        try runGit(allocator, process_io, &git_environment, repo_abs, &.{
            "git",                    "-c",                     "core.quotePath=true",   "diff",
            "--no-ext-diff",          "--no-textconv",          "--no-color",            "--no-renames",
            "--full-index",           "--diff-algorithm=myers", "--no-indent-heuristic", "--unified=3",
            "--inter-hunk-context=0", "--src-prefix=a/",        "--dst-prefix=b/",       "HEAD",
            "--",
        }, max_total_bytes + 1);
    defer allocator.free(diff);
    if (diff.len > max_total_bytes) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(diff)) return error.InvalidUtf8;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, diff);
    var source_bytes = text.items.len;
    var files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    var warnings: std.ArrayList(Warning) = .empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning.path);
        warnings.deinit(allocator);
    }

    if (diff_ref == null) {
        const raw_names = try runGit(allocator, process_io, &git_environment, repo_abs, &.{ "git", "ls-files", "-z", "--others", "--exclude-standard" }, max_total_bytes + 1);
        defer allocator.free(raw_names);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        var pos: usize = 0;
        while (pos < raw_names.len) {
            const nul = std.mem.indexOfScalarPos(u8, raw_names, pos, 0) orelse return error.InvalidGitPath;
            const name = raw_names[pos..nul];
            pos = nul + 1;
            if (name.len == 0 or std.fs.path.isAbsolute(name) or !std.unicode.utf8ValidateSlice(name)) return error.InvalidGitPath;
            try names.append(allocator, name);
        }
        std.mem.sort([]const u8, names.items, {}, stringLessThan);
        var previous: ?[]const u8 = null;
        for (names.items) |name| {
            if (previous) |value| if (std.mem.eql(u8, value, name)) continue;
            previous = name;
            if (hasUnsafeComponent(name) or try pathContainsSymlink(repo_dir, name)) {
                const label = try gitLabelAlloc(allocator, cwd_abs, repo_abs, name);
                try warnings.append(allocator, .{ .kind = .symlink, .path = label });
                continue;
            }
            const stat = repo_dir.statFile(defaultIo(), name, .{ .follow_symlinks = false }) catch {
                const label = try gitLabelAlloc(allocator, cwd_abs, repo_abs, name);
                try warnings.append(allocator, .{ .kind = .inaccessible, .path = label });
                continue;
            };
            const label = try gitLabelAlloc(allocator, cwd_abs, repo_abs, name);
            if (stat.kind != .file) {
                try warnings.append(allocator, .{ .kind = if (stat.kind == .sym_link) .symlink else .unsupported, .path = label });
                continue;
            }
            if (stat.size > max_file_bytes) {
                try warnings.append(allocator, .{ .kind = .oversized, .path = label });
                continue;
            }
            const content = repo_dir.readFileAlloc(defaultIo(), name, allocator, .limited(max_file_bytes + 1)) catch {
                try warnings.append(allocator, .{ .kind = .inaccessible, .path = label });
                continue;
            };
            defer allocator.free(content);
            if (content.len > max_file_bytes) {
                try warnings.append(allocator, .{ .kind = .oversized, .path = label });
                continue;
            }
            if (std.mem.indexOfScalar(u8, content[0..@min(content.len, binary_sniff_bytes)], 0) != null) {
                try warnings.append(allocator, .{ .kind = .binary, .path = label });
                continue;
            }
            if (!std.unicode.utf8ValidateSlice(content)) {
                try warnings.append(allocator, .{ .kind = .invalid_utf8, .path = label });
                continue;
            }
            if (source_bytes + content.len > max_total_bytes) return error.InputTooLarge;
            source_bytes += content.len;
            try text.append(allocator, '\n');
            try appendHeader(&text, allocator, label);
            try text.appendSlice(allocator, content);
            if (text.items.len > max_total_bytes) return error.InputTooLarge;
            try files.append(allocator, label);
        }
    }
    if (text.items.len == 0) return error.EmptyInput;
    std.mem.sort(Warning, warnings.items, {}, warningLessThan);
    return .{
        .kind = if (diff_ref == null) .git else .diff,
        .text = try text.toOwnedSlice(allocator),
        .files = try files.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
        .source_bytes = source_bytes,
    };
}

fn runGit(
    allocator: std.mem.Allocator,
    process_io: std.Io,
    environment: *const std.process.Environ.Map,
    repo: []const u8,
    argv: []const []const u8,
    max_stdout: usize,
) ![]u8 {
    const result = std.process.run(allocator, process_io, .{
        .argv = argv,
        .cwd = .{ .path = repo },
        .environ_map = environment,
        .stdout_limit = .limited(max_stdout),
        .stderr_limit = .limited(max_git_stderr),
    }) catch |err| switch (err) {
        error.StreamTooLong => return error.InputTooLarge,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.GitFailed;
    return allocator.dupe(u8, result.stdout);
}

fn sanitizedGitEnvironment(
    allocator: std.mem.Allocator,
    parent: *const std.process.Environ.Map,
) !std.process.Environ.Map {
    var child = try parent.clone(allocator);
    var index: usize = 0;
    while (index < child.keys().len) {
        const key = child.keys()[index];
        if (std.ascii.startsWithIgnoreCase(key, "GIT_")) {
            _ = child.swapRemove(key);
        } else {
            index += 1;
        }
    }
    return child;
}

fn pathContainsSymlink(root: std.Io.Dir, path: []const u8) !bool {
    var component_end: usize = 0;
    while (component_end < path.len) {
        component_end = std.mem.indexOfScalarPos(u8, path, component_end, '/') orelse path.len;
        if (component_end > 0) {
            const stat = root.statFile(defaultIo(), path[0..component_end], .{ .follow_symlinks = false }) catch return true;
            if (stat.kind == .sym_link) return true;
        }
        if (component_end == path.len) break;
        component_end += 1;
    }
    return false;
}

fn hasUnsafeComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

fn gitLabelAlloc(allocator: std.mem.Allocator, cwd_abs: []const u8, repo_abs: []const u8, rel: []const u8) ![]u8 {
    const abs = try std.fs.path.join(allocator, &.{ repo_abs, rel });
    defer allocator.free(abs);
    const cwd_rel = try std.fs.path.relative(allocator, cwd_abs, null, cwd_abs, abs);
    defer allocator.free(cwd_rel);
    return normalizeSlashesAlloc(allocator, cwd_rel);
}

fn appendHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8) !void {
    try out.appendSlice(allocator, "===== ");
    for (label) |c| switch (c) {
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => if (c < 0x20 or c == 0x7f) {
            var buf: [4]u8 = undefined;
            const escaped = try std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c});
            try out.appendSlice(allocator, escaped);
        } else try out.append(allocator, c),
    };
    try out.appendSlice(allocator, " =====\n");
}

fn shouldSkipDirectory(name: []const u8) bool {
    for ([_][]const u8{
        "node_modules", ".git",  ".svn",  ".hg",    "dist",       "build",   "__pycache__",
        ".cache",       ".next", ".nuxt", ".turbo", ".zig-cache", "zig-out",
    }) |skipped| if (std.mem.eql(u8, name, skipped)) return true;
    return false;
}

pub fn shouldInclude(path: []const u8, include: []const []const u8, exclude: []const []const u8) bool {
    for (exclude) |pattern| if (matchGlob(pattern, path)) return false;
    if (include.len == 0) return true;
    for (include) |pattern| if (matchGlob(pattern, path)) return true;
    return false;
}

pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    const normalized_path = stripOneNormalizedDotSlash(path);
    const target = if (!containsNormalizedSeparator(pattern))
        normalizedBasename(normalized_path)
    else
        normalized_path;
    var budget: usize = 1_000_000;
    return globMatch(pattern, .{}, target, .{}, &budget);
}

const GlobCursor = struct {
    byte_index: usize = 0,
    low_surrogate: bool = false,
};

const GlobStep = struct {
    unit: u16,
    next: GlobCursor,
};

fn globMatch(pattern: []const u8, pi: GlobCursor, value: []const u8, vi: GlobCursor, budget: *usize) bool {
    if (budget.* == 0) return false;
    budget.* -= 1;
    const pattern_step = utf16Step(pattern, pi) orelse return utf16Step(value, vi) == null;
    const pc = normalizedGlobUnit(pattern_step.unit);
    if (pc == '*') {
        const second = utf16Step(pattern, pattern_step.next);
        if (second != null and normalizedGlobUnit(second.?.unit) == '*') {
            var next = second.?.next;
            if (utf16Step(pattern, next)) |slash| {
                if (normalizedGlobUnit(slash.unit) == '/') {
                    next = slash.next;
                    if (globMatch(pattern, next, value, vi, budget)) return true;
                    var cursor = vi;
                    while (utf16Step(value, cursor)) |step| {
                        cursor = step.next;
                        if (normalizedGlobUnit(step.unit) == '/' and globMatch(pattern, next, value, cursor, budget)) return true;
                    }
                    return false;
                }
            }
            if (globMatch(pattern, next, value, vi, budget)) return true;
            var cursor = vi;
            while (utf16Step(value, cursor)) |step| {
                cursor = step.next;
                if (globMatch(pattern, next, value, cursor, budget)) return true;
            }
            return false;
        }
        if (globMatch(pattern, pattern_step.next, value, vi, budget)) return true;
        var cursor = vi;
        while (utf16Step(value, cursor)) |step| {
            if (normalizedGlobUnit(step.unit) == '/') break;
            cursor = step.next;
            if (globMatch(pattern, pattern_step.next, value, cursor, budget)) return true;
        }
        return false;
    }
    if (pc == '?') {
        const value_step = utf16Step(value, vi) orelse return false;
        return normalizedGlobUnit(value_step.unit) != '/' and globMatch(pattern, pattern_step.next, value, value_step.next, budget);
    }
    const value_step = utf16Step(value, vi) orelse return false;
    return pc == normalizedGlobUnit(value_step.unit) and globMatch(pattern, pattern_step.next, value, value_step.next, budget);
}

fn normalizedSeparator(c: u8) u8 {
    return if (c == '\\') '/' else c;
}

fn normalizedGlobUnit(unit: u16) u16 {
    return if (unit == '\\') '/' else unit;
}

fn containsNormalizedSeparator(value: []const u8) bool {
    for (value) |byte| if (normalizedSeparator(byte) == '/') return true;
    return false;
}

fn stripOneNormalizedDotSlash(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '.' and normalizedSeparator(value[1]) == '/') return value[2..];
    return value;
}

fn normalizedBasename(value: []const u8) []const u8 {
    var basename_start: usize = 0;
    for (value, 0..) |byte, index| {
        if (normalizedSeparator(byte) == '/') basename_start = index + 1;
    }
    return value[basename_start..];
}

fn utf16Step(value: []const u8, cursor: GlobCursor) ?GlobStep {
    if (cursor.byte_index >= value.len) return null;
    const decoded = decodeGlobScalar(value, cursor.byte_index);
    if (decoded.codepoint <= 0xffff) {
        return .{
            .unit = @intCast(decoded.codepoint),
            .next = .{ .byte_index = cursor.byte_index + decoded.byte_len },
        };
    }

    const supplementary: u32 = @as(u32, decoded.codepoint) - 0x10000;
    if (!cursor.low_surrogate) {
        return .{
            .unit = @intCast(0xd800 + (supplementary >> 10)),
            .next = .{ .byte_index = cursor.byte_index, .low_surrogate = true },
        };
    }
    return .{
        .unit = @intCast(0xdc00 + (supplementary & 0x3ff)),
        .next = .{ .byte_index = cursor.byte_index + decoded.byte_len },
    };
}

const GlobScalar = struct {
    codepoint: u21,
    byte_len: usize,
};

fn decodeGlobScalar(value: []const u8, byte_index: usize) GlobScalar {
    const byte_len: usize = std.unicode.utf8ByteSequenceLength(value[byte_index]) catch 1;
    if (byte_index + byte_len > value.len) return .{ .codepoint = value[byte_index], .byte_len = 1 };
    const codepoint = std.unicode.utf8Decode(value[byte_index..][0..byte_len]) catch
        return .{ .codepoint = value[byte_index], .byte_len = 1 };
    return .{ .codepoint = codepoint, .byte_len = byte_len };
}

fn normalizeSlashesAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    if (builtin.os.tag == .windows) {
        for (out) |*c| {
            if (c.* == '\\') c.* = '/';
        }
    }
    return out;
}

fn candidateLessThan(_: void, left: Candidate, right: Candidate) bool {
    const order = std.mem.order(u8, left.label, right.label);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, left.abs_path, right.abs_path) == .lt;
}

fn warningLessThan(_: void, left: Warning, right: Warning) bool {
    const order = std.mem.order(u8, left.path, right.path);
    if (order != .eq) return order == .lt;
    return @intFromEnum(left.kind) < @intFromEnum(right.kind);
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "glob matching preserves pxpipe wildcard semantics" {
    try std.testing.expect(matchGlob("*.ts", "src/core/foo.ts"));
    try std.testing.expect(!matchGlob("*.ts", "src/core/foo.js"));
    try std.testing.expect(matchGlob("**/*.ts", "foo.ts"));
    try std.testing.expect(matchGlob("**/*.ts", "src/core/foo.ts"));
    try std.testing.expect(matchGlob("src/**", "src/core/foo.ts"));
    try std.testing.expect(matchGlob("foo?.ts", "foo1.ts"));
    try std.testing.expect(!matchGlob("foo?.ts", "foo12.ts"));
}

test "glob normalization precedes basename selection and strips one dot slash" {
    try std.testing.expect(matchGlob("*.ts", "src\\core\\foo.ts"));
    try std.testing.expect(matchGlob("src\\**\\*.ts", ".\\src\\core\\foo.ts"));
    try std.testing.expect(matchGlob("./src/foo.ts", "././src/foo.ts"));
    try std.testing.expect(!matchGlob("src/foo.ts", "././src/foo.ts"));
}

test "glob question mark consumes one UTF-16 code unit" {
    try std.testing.expect(matchGlob("?.txt", "é.txt"));
    try std.testing.expect(!matchGlob("?.txt", "😀.txt"));
    try std.testing.expect(matchGlob("??.txt", "😀.txt"));
    try std.testing.expect(!matchGlob("??.txt", "é.txt"));
}

test "git child environment removes every Git-prefixed variable" {
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("PATH", "/example/bin");
    try parent.put("HOME", "/example/home");
    try parent.put("GIT_DIR", "/decoy/.git");
    try parent.put("git_work_tree", "/decoy");
    try parent.put("GIT_COMMON_DIR", "/decoy/.git");
    try parent.put("GIT_INDEX_FILE", "/decoy/.git/index");
    try parent.put("GIT_OBJECT_DIRECTORY", "/decoy/.git/objects");
    try parent.put("GIT_CONFIG_COUNT", "1");
    try parent.put("GIT_CONFIG_KEY_0", "core.worktree");
    try parent.put("GIT_CONFIG_VALUE_0", "/decoy");
    try parent.put("GIT_DIFF_OPTS", "--unified=0");

    var child = try sanitizedGitEnvironment(std.testing.allocator, &parent);
    defer child.deinit();
    try std.testing.expectEqualStrings("/example/bin", child.get("PATH").?);
    try std.testing.expectEqualStrings("/example/home", child.get("HOME").?);
    for (child.keys()) |key| try std.testing.expect(!std.ascii.startsWithIgnoreCase(key, "GIT_"));
    try std.testing.expect(parent.contains("GIT_DIR"));
}

test "git collection keeps the requested repository authoritative" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(defaultIo(), "requested", .default_dir);
    try tmp.dir.createDir(defaultIo(), "decoy", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(defaultIo(), ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const requested = try std.fs.path.join(std.testing.allocator, &.{ root, "requested" });
    defer std.testing.allocator.free(requested);
    const decoy = try std.fs.path.join(std.testing.allocator, &.{ root, "decoy" });
    defer std.testing.allocator.free(decoy);

    try initTestRepository(requested, "requested-before\n");
    try initTestRepository(decoy, "decoy-before\n");
    try writeTestFile(requested, "tracked.txt", "requested-after\n");
    try writeTestFile(requested, "untracked.txt", "requested-untracked\n");
    try writeTestFile(decoy, "tracked.txt", "decoy-after\n");
    try writeTestFile(decoy, "untracked.txt", "decoy-untracked\n");

    const decoy_git = try std.fs.path.join(std.testing.allocator, &.{ decoy, ".git" });
    defer std.testing.allocator.free(decoy_git);
    const decoy_index = try std.fs.path.join(std.testing.allocator, &.{ decoy_git, "index" });
    defer std.testing.allocator.free(decoy_index);
    const decoy_objects = try std.fs.path.join(std.testing.allocator, &.{ decoy_git, "objects" });
    defer std.testing.allocator.free(decoy_objects);
    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    try parent.put("GIT_DIR", decoy_git);
    try parent.put("GIT_WORK_TREE", decoy);
    try parent.put("GIT_COMMON_DIR", decoy_git);
    try parent.put("GIT_INDEX_FILE", decoy_index);
    try parent.put("GIT_OBJECT_DIRECTORY", decoy_objects);
    try parent.put("GIT_CONFIG_COUNT", "1");
    try parent.put("GIT_CONFIG_KEY_0", "core.worktree");
    try parent.put("GIT_CONFIG_VALUE_0", decoy);
    try parent.put("GIT_DIFF_OPTS", "--unified=0");

    var corpus = try collectWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        &parent,
        .{ .git = requested },
        &.{},
        &.{},
    );
    defer corpus.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, corpus.text, "requested-after") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus.text, "requested-untracked") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus.text, "decoy-after") == null);
    try std.testing.expect(std.mem.indexOf(u8, corpus.text, "decoy-untracked") == null);
}

fn initTestRepository(repo: []const u8, initial: []const u8) !void {
    try runTestGit(repo, &.{ "init", "-q" });
    try runTestGit(repo, &.{ "config", "user.email", "img@example.invalid" });
    try runTestGit(repo, &.{ "config", "user.name", "img test" });
    try writeTestFile(repo, "tracked.txt", initial);
    try runTestGit(repo, &.{ "add", "tracked.txt" });
    try runTestGit(repo, &.{ "commit", "-q", "-m", "base" });
}

fn runTestGit(repo: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try argv.append(std.testing.allocator, "git");
    try argv.appendSlice(std.testing.allocator, args);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const stdout = try runGit(
        std.testing.allocator,
        std.testing.io,
        &environment,
        repo,
        argv.items,
        64 * 1024,
    );
    std.testing.allocator.free(stdout);
}

fn writeTestFile(repo: []const u8, name: []const u8, content: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(defaultIo(), repo, .{});
    defer dir.close(defaultIo());
    var file = try dir.createFile(defaultIo(), name, .{ .truncate = true });
    defer file.close(defaultIo());
    try file.writeStreamingAll(defaultIo(), content);
}
