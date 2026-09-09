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

const Parser = struct {
    allocator: std.mem.Allocator,
    paths: std.ArrayList([]const u8) = .empty,
    includes: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    use_stdin: bool = false,
    git_seen: bool = false,
    git_repo: ?[]const u8 = null,
    diff_ref: ?[]const u8 = null,
    diff_repo: ?[]const u8 = null,
    out: ?[]const u8 = null,
    facts: bool = false,
    json: bool = false,
    positional_only: bool = false,

    fn deinit(self: *Parser) void {
        self.paths.deinit(self.allocator);
        self.includes.deinit(self.allocator);
        self.excludes.deinit(self.allocator);
    }

    fn output(self: *Parser, value: []const u8) !void {
        if (self.out != null) return error.DuplicateOutput;
        if (value.len == 0) return error.MissingOptionValue;
        self.out = value;
    }

    fn argument(self: *Parser, args: []const []const u8, i: *usize) !?ParseResult {
        const arg = args[i.*];
        if (self.positional_only) {
            try self.paths.append(self.allocator, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            self.positional_only = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--facts")) {
            self.facts = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            self.json = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            self.use_stdin = true;
        } else if (std.mem.eql(u8, arg, "--git")) {
            self.git_seen = true;
            if (optionalRepo(args, i)) |repo| self.git_repo = repo;
        } else if (std.mem.eql(u8, arg, "--diff")) {
            self.diff_ref = try nextValue(args, i);
            const ref = self.diff_ref.?;
            if (ref.len == 0 or std.mem.startsWith(u8, ref, "-")) return error.UnsafeDiffRef;
            if (optionalRepo(args, i)) |repo| self.diff_repo = repo;
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (self.out != null) return error.DuplicateOutput;
            try self.output(try nextValue(args, i));
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            try self.output(arg["--out=".len..]);
        } else if (std.mem.eql(u8, arg, "--include") or std.mem.eql(u8, arg, "--exclude")) {
            try self.filter(std.mem.eql(u8, arg, "--include"), try nextValue(args, i));
        } else if (std.mem.startsWith(u8, arg, "--include=")) {
            try self.filter(true, arg["--include=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try self.filter(false, arg["--exclude=".len..]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            try self.paths.append(self.allocator, arg);
        }
        return null;
    }

    fn filter(self: *Parser, include: bool, value: []const u8) !void {
        if (value.len == 0) return error.MissingOptionValue;
        const list = if (include) &self.includes else &self.excludes;
        try list.append(self.allocator, value);
    }

    fn finish(self: *Parser) !ParseResult {
        const source_count = @as(usize, @intFromBool(self.paths.items.len > 0)) +
            @as(usize, @intFromBool(self.use_stdin)) + @as(usize, @intFromBool(self.git_seen)) +
            @as(usize, @intFromBool(self.diff_ref != null));
        if (source_count == 0) return error.SourceRequired;
        if (source_count != 1) return error.ConflictingSources;
        if (self.out == null) return error.OutputRequired;
        if ((self.includes.items.len > 0 or self.excludes.items.len > 0) and
            self.paths.items.len == 0) return error.FiltersRequirePaths;
        const includes = try self.includes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(includes);
        const excludes = try self.excludes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(excludes);
        const source: Source = if (self.paths.items.len > 0)
            .{ .paths = try self.paths.toOwnedSlice(self.allocator) }
        else if (self.use_stdin)
            .stdin
        else if (self.git_seen)
            .{ .git = self.git_repo }
        else
            .{ .diff = .{ .ref = self.diff_ref.?, .repo = self.diff_repo } };
        return .{ .options = .{
            .source = source,
            .out = self.out.?,
            .include = includes,
            .exclude = excludes,
            .facts = self.facts,
            .json = self.json,
        } };
    }
};

fn nextValue(args: []const []const u8, i: *usize) ![]const u8 {
    if (i.* + 1 >= args.len) return error.MissingOptionValue;
    i.* += 1;
    return args[i.*];
}

fn optionalRepo(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len or std.mem.startsWith(u8, args[i.* + 1], "-")) return null;
    i.* += 1;
    return args[i.*];
}

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !ParseResult {
    var parser = Parser{ .allocator = allocator };
    defer parser.deinit();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (try parser.argument(args, &i)) |result| return result;
    }
    return parser.finish();
}

test "parse requires an explicit source and output" {
    try std.testing.expectError(error.SourceRequired, parse(std.testing.allocator, &.{}));
    try std.testing.expectError(
        error.OutputRequired,
        parse(std.testing.allocator, &.{"README.md"}),
    );
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
    try std.testing.expectError(
        error.ConflictingSources,
        parse(std.testing.allocator, &.{ "--out", "o", "--stdin", "a.md" }),
    );
    try std.testing.expectError(
        error.FiltersRequirePaths,
        parse(std.testing.allocator, &.{ "--out", "o", "--stdin", "--include", "*.md" }),
    );
}
