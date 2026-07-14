const std = @import("std");

pub const Source = union(enum) {
    paths: []const []const u8,
    stdin,
    git: ?[]const u8,
    diff: Diff,

    pub const Diff = struct {
        ref: []const u8,
        repo: ?[]const u8,
    };
};

pub const Options = struct {
    source: Source,
    out: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    facts: bool,
    json: bool,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        switch (self.source) {
            .paths => |paths| allocator.free(paths),
            else => {},
        }
        allocator.free(self.include);
        allocator.free(self.exclude);
        self.* = undefined;
    }
};

pub const ParseResult = union(enum) {
    options: Options,
    help,
    version,
};

pub const UsageError = error{
    UnknownOption,
    MissingOptionValue,
    DuplicateOutput,
    OutputRequired,
    SourceRequired,
    ConflictingSources,
    FiltersRequirePaths,
    UnsafeDiffRef,
};

pub fn isUsageError(err: anyerror) bool {
    return switch (err) {
        error.UnknownOption,
        error.MissingOptionValue,
        error.DuplicateOutput,
        error.OutputRequired,
        error.SourceRequired,
        error.ConflictingSources,
        error.FiltersRequirePaths,
        error.UnsafeDiffRef,
        => true,
        else => false,
    };
}

pub fn usageErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownOption => "unknown option",
        error.MissingOptionValue => "option requires a value",
        error.DuplicateOutput => "--out may be supplied only once",
        error.OutputRequired => "--out DIR is required",
        error.SourceRequired => "choose PATH..., --stdin, --git [REPO], or --diff REF [REPO]",
        error.ConflictingSources => "input modes are mutually exclusive",
        error.FiltersRequirePaths => "--include and --exclude are valid only with PATH input",
        error.UnsafeDiffRef => "--diff REF must be non-empty and may not begin with '-'",
        else => "invalid command line",
    };
}

pub const help_text =
    \\Usage: img [OPTIONS] PATH...
    \\       img [OPTIONS] --stdin
    \\       img [OPTIONS] --git [REPO]
    \\       img [OPTIONS] --diff REF [REPO]
    \\
    \\Render UTF-8 source and document text to dense PNG pages.
    \\
    \\Input (choose exactly one):
    \\  PATH...              files and directories; use -- before dash-prefixed paths
    \\  --stdin              read one UTF-8 document from standard input
    \\  --git [REPO]         git diff HEAD plus untracked, nonignored text files (trusted repo)
    \\  --diff REF [REPO]    tracked git diff against REF (trusted repo)
    \\
    \\Output:
    \\  --out DIR            required; DIR must be absent or empty
    \\  --facts              also write factsheet.txt with precision-critical tokens
    \\  --json               print an img.render.v1 summary to standard output
    \\
    \\Path selection:
    \\  --include GLOB       include matching files (repeatable; PATH input only)
    \\  --exclude GLOB       exclude matching files (repeatable; PATH input only)
    \\
    \\Other:
    \\  -h, --help           show this help
    \\  --version            print the version
    \\
    \\Globs support *, **, and ?. A pattern without '/' matches basenames.
;

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !ParseResult {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(allocator);
    var excludes: std.ArrayList([]const u8) = .empty;
    defer excludes.deinit(allocator);

    var use_stdin = false;
    var git_seen = false;
    var git_repo: ?[]const u8 = null;
    var diff_ref: ?[]const u8 = null;
    var diff_repo: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var facts = false;
    var json = false;
    var positional_only = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (positional_only) {
            try paths.append(allocator, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            positional_only = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--facts")) {
            facts = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (std.mem.eql(u8, arg, "--git")) {
            git_seen = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                git_repo = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--diff")) {
            if (i + 1 >= args.len) return error.MissingOptionValue;
            i += 1;
            diff_ref = args[i];
            if (diff_ref.?.len == 0 or std.mem.startsWith(u8, diff_ref.?, "-")) return error.UnsafeDiffRef;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                diff_repo = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (out != null) return error.DuplicateOutput;
            if (i + 1 >= args.len) return error.MissingOptionValue;
            i += 1;
            if (args[i].len == 0) return error.MissingOptionValue;
            out = args[i];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            if (out != null) return error.DuplicateOutput;
            const value = arg["--out=".len..];
            if (value.len == 0) return error.MissingOptionValue;
            out = value;
        } else if (std.mem.eql(u8, arg, "--include") or std.mem.eql(u8, arg, "--exclude")) {
            const include = std.mem.eql(u8, arg, "--include");
            if (i + 1 >= args.len) return error.MissingOptionValue;
            i += 1;
            if (args[i].len == 0) return error.MissingOptionValue;
            if (include) try includes.append(allocator, args[i]) else try excludes.append(allocator, args[i]);
        } else if (std.mem.startsWith(u8, arg, "--include=")) {
            const value = arg["--include=".len..];
            if (value.len == 0) return error.MissingOptionValue;
            try includes.append(allocator, value);
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            const value = arg["--exclude=".len..];
            if (value.len == 0) return error.MissingOptionValue;
            try excludes.append(allocator, value);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            try paths.append(allocator, arg);
        }
    }

    const source_count: usize = @as(usize, @intFromBool(paths.items.len > 0)) +
        @as(usize, @intFromBool(use_stdin)) + @as(usize, @intFromBool(git_seen)) +
        @as(usize, @intFromBool(diff_ref != null));
    if (source_count == 0) return error.SourceRequired;
    if (source_count != 1) return error.ConflictingSources;
    if (out == null) return error.OutputRequired;
    if ((includes.items.len > 0 or excludes.items.len > 0) and paths.items.len == 0) {
        return error.FiltersRequirePaths;
    }

    const include_owned = try includes.toOwnedSlice(allocator);
    errdefer allocator.free(include_owned);
    const exclude_owned = try excludes.toOwnedSlice(allocator);
    errdefer allocator.free(exclude_owned);

    const source: Source = if (paths.items.len > 0) blk: {
        const owned = try paths.toOwnedSlice(allocator);
        break :blk .{ .paths = owned };
    } else if (use_stdin)
        .stdin
    else if (git_seen)
        .{ .git = git_repo }
    else
        .{ .diff = .{ .ref = diff_ref.?, .repo = diff_repo } };

    return .{ .options = .{
        .source = source,
        .out = out.?,
        .include = include_owned,
        .exclude = exclude_owned,
        .facts = facts,
        .json = json,
    } };
}

test "parse requires an explicit source and output" {
    try std.testing.expectError(error.SourceRequired, parse(std.testing.allocator, &.{}));
    try std.testing.expectError(error.OutputRequired, parse(std.testing.allocator, &.{"README.md"}));
}

test "parse accepts paths after option terminator" {
    var result = try parse(std.testing.allocator, &.{ "--out", "images", "--", "-notes.md" });
    defer switch (result) {
        .options => |*options| options.deinit(std.testing.allocator),
        else => {},
    };
    try std.testing.expectEqualStrings("-notes.md", result.options.source.paths[0]);
}

test "parse locks source modes and path-only filters" {
    try std.testing.expectError(error.ConflictingSources, parse(std.testing.allocator, &.{ "--out", "o", "--stdin", "a.md" }));
    try std.testing.expectError(error.FiltersRequirePaths, parse(std.testing.allocator, &.{ "--out", "o", "--stdin", "--include", "*.md" }));
}
