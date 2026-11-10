const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const max_files = 16;
pub const max_file_bytes = 256 * 1024;
pub const max_total_bytes = 1024 * 1024;
pub const max_json_bytes = 8 * 1024 * 1024;
pub const request_timeout_ms = 30_000;

pub const help =
    \\seq gist create --input <request.json> [--format json]
    \\seq gist read --gist <id|url> [--revision <40-hex-sha>] [--format json]
    \\
    \\Create accepts {"description":"...","files":{"handoff.md":{"content":"..."}}}.
    \\Only those fields are accepted. Creation always sets public=false and
    \\verifies every file at the returned revision before reporting success.
    \\Secret gists are unlisted: anyone with the URL can read their contents.
    \\
    \\Read returns complete text at one immutable revision. Without --revision,
    \\the current revision is resolved once, then fetched by SHA.
    \\Limits: 16 files, 256 KiB per file, 1 MiB total text, 8 MiB JSON.
    \\Truncated or unsupported contents fail; remote URLs are never followed.
    \\
    \\Authentication: SEQ_GITHUB_TOKEN, then GH_TOKEN, then GITHUB_TOKEN.
    \\Creation requires a token with permission to create gists. Reading can
    \\be anonymous. Requests use the GitHub API directly.
    \\A failed create can have published a gist. Never retry an uncertain
    \\creation automatically; inspect the reported ID or your GitHub account.
    \\
;

pub const Diagnostics = struct {
    attempted_create: bool = false,
    id: [64]u8 = undefined,
    id_len: u8 = 0,
    revision: ?[40]u8 = null,

    pub fn gistId(self: *const Diagnostics) ?[]const u8 {
        return if (self.id_len == 0) null else self.id[0..self.id_len];
    }

    fn remember(self: *Diagnostics, id: []const u8, revision: ?[]const u8) void {
        if (!validId(id)) return;
        @memcpy(self.id[0..id.len], id);
        self.id_len = @intCast(id.len);
        if (revision) |sha| if (validRevision(sha)) {
            self.revision = sha[0..40].*;
        };
    }
};

pub const Ref = struct {
    id: []const u8,
    revision: ?[]const u8 = null,
};

pub const Options = union(enum) {
    help,
    create: []const u8,
    read: Ref,
};

pub fn parseArgs(args: []const []const u8) !Options {
    if (args.len == 0 or (args.len == 1 and isHelp(args[0]))) return .help;
    if (args.len == 2 and isHelp(args[1])) return .help;
    const is_create = std.mem.eql(u8, args[0], "create");
    if (!is_create and !std.mem.eql(u8, args[0], "read")) return error.UnknownGistCommand;
    var input: ?[]const u8 = null;
    var gist: ?[]const u8 = null;
    var revision: ?[]const u8 = null;
    var format_seen = false;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingGistArgument;
        const flag = args[index];
        const value = args[index + 1];
        if (value.len == 0) return error.MissingGistArgument;
        if (std.mem.eql(u8, flag, "--input") and is_create) {
            if (input != null) return error.DuplicateGistArgument;
            input = value;
        } else if (std.mem.eql(u8, flag, "--gist") and !is_create) {
            if (gist != null) return error.DuplicateGistArgument;
            gist = value;
        } else if (std.mem.eql(u8, flag, "--revision") and !is_create) {
            if (revision != null) return error.DuplicateGistArgument;
            revision = value;
        } else if (std.mem.eql(u8, flag, "--format")) {
            if (format_seen) return error.DuplicateGistArgument;
            if (!std.mem.eql(u8, value, "json")) return error.UnsupportedGistFormat;
            format_seen = true;
        } else return error.UnknownGistArgument;
    }
    if (is_create) return .{ .create = input orelse return error.MissingGistInput };
    var ref = try parseGistRef(gist orelse return error.MissingGistId);
    if (revision) |sha| {
        if (!validRevision(sha)) return error.InvalidGistRevision;
        if (ref.revision) |embedded| {
            if (!std.mem.eql(u8, sha, embedded)) return error.ConflictingGistRevision;
        }
        ref.revision = sha;
    }
    return .{ .read = ref };
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

pub fn parseGistRef(value: []const u8) !Ref {
    if (validId(value)) return .{ .id = value };
    if (value.len > 512 or std.mem.indexOfAny(u8, value, "\\?# \t\r\n") != null)
        return error.InvalidGistUrl;
    const gist_prefix = "https://gist.github.com/";
    const api_prefix = "https://api.github.com/gists/";
    const api = std.mem.startsWith(u8, value, api_prefix);
    const path = if (api)
        value[api_prefix.len..]
    else if (std.mem.startsWith(u8, value, gist_prefix))
        value[gist_prefix.len..]
    else
        return error.InvalidGistUrl;
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var split = std.mem.splitScalar(u8, path, '/');
    while (split.next()) |part| {
        if (part.len == 0 or count == parts.len) return error.InvalidGistUrl;
        parts[count] = part;
        count += 1;
    }
    const ref: Ref = if (count == 1)
        .{ .id = parts[0] }
    else if (count == 2 and (api or (validId(parts[0]) and validRevision(parts[1]))))
        .{ .id = parts[0], .revision = parts[1] }
    else if (!api and count == 2 and validOwner(parts[0]))
        .{ .id = parts[1] }
    else if (!api and count == 3 and validOwner(parts[0]))
        .{ .id = parts[1], .revision = parts[2] }
    else
        return error.InvalidGistUrl;
    if (!validId(ref.id)) return error.InvalidGistId;
    if (ref.revision) |sha| if (!validRevision(sha)) return error.InvalidGistRevision;
    return ref;
}

fn validId(value: []const u8) bool {
    return value.len >= 5 and value.len <= 64 and lowerHex(value);
}

fn validRevision(value: []const u8) bool {
    return value.len == 40 and lowerHex(value);
}

fn lowerHex(value: []const u8) bool {
    for (value) |byte| if (!(byte >= '0' and byte <= '9') and
        !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn validOwner(value: []const u8) bool {
    if (value.len == 0 or value.len > 39) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    return true;
}

fn validateFilename(name: []const u8) !void {
    if (name.len == 0 or name.len > 128 or !std.ascii.isAlphanumeric(name[0]))
        return error.InvalidGistFilename;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '.' and byte != '-' and byte != '_') return error.InvalidGistFilename;
}

fn validateText(value: []const u8, max_bytes: usize) !void {
    if (value.len > max_bytes) return error.GistTextLimitExceeded;
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
        return error.InvalidGistText;
}

const File = struct { content: []const u8 };
const Create = struct {
    description: []const u8 = "",
    files: std.json.ArrayHashMap(File),
};

pub fn parseCreate(allocator: Allocator, bytes: []const u8) !std.json.Parsed(Create) {
    if (bytes.len > max_json_bytes) return error.GistJsonLimitExceeded;
    const parsed = try std.json.parseFromSlice(Create, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    try validateText(parsed.value.description, 2048);
    if (parsed.value.files.map.count() == 0 or parsed.value.files.map.count() > max_files)
        return error.GistFileLimitExceeded;
    var total: usize = 0;
    var files = parsed.value.files.map.iterator();
    while (files.next()) |entry| {
        try validateFilename(entry.key_ptr.*);
        try validateText(entry.value_ptr.content, max_file_bytes);
        total += entry.value_ptr.content.len;
        if (total > max_total_bytes) return error.GistTextLimitExceeded;
    }
    return parsed;
}

fn tokenFromEnvironment(environment: *const std.process.Environ.Map) !?[]const u8 {
    const token = environment.get("SEQ_GITHUB_TOKEN") orelse
        environment.get("GH_TOKEN") orelse environment.get("GITHUB_TOKEN") orelse return null;
    try validateToken(token);
    return token;
}

fn validateToken(token: []const u8) !void {
    if (token.len == 0 or token.len > 4096) return error.InvalidGistToken;
    for (token) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidGistToken;
}

pub fn run(
    io: Io,
    dir: Io.Dir,
    allocator: Allocator,
    environment: *const std.process.Environ.Map,
    args: []const []const u8,
    output: *Writer,
    diagnostics: *Diagnostics,
) !void {
    const options = try parseArgs(args);
    if (options == .help) return output.writeAll(help);
    const token = try tokenFromEnvironment(environment);
    var http: Http = .{};
    var document = switch (options) {
        .help => unreachable,
        .read => |ref| try read(allocator, io, http.transport(), ref, token),
        .create => |path| created: {
            if (token == null) return error.GistTokenRequired;
            const bytes = try dir.readFileAlloc(io, path, allocator, .limited(max_json_bytes));
            defer allocator.free(bytes);
            var input = try parseCreate(allocator, bytes);
            defer input.deinit();
            break :created try create(
                allocator,
                io,
                http.transport(),
                input.value,
                token.?,
                diagnostics,
            );
        },
    };
    defer document.deinit();
    try document.write(allocator, output);
}

const ApiRequest = struct {
    operation: union(enum) { create: []const u8, read: Ref },
    token: ?[]const u8,

    fn validate(self: ApiRequest) !void {
        if (self.token) |token| try validateToken(token);
        switch (self.operation) {
            .create => |bytes| {
                if (self.token == null) return error.GistTokenRequired;
                if (bytes.len > max_json_bytes) return error.GistJsonLimitExceeded;
            },
            .read => |ref| {
                if (!validId(ref.id)) return error.InvalidGistId;
                if (ref.revision) |sha| if (!validRevision(sha))
                    return error.InvalidGistRevision;
            },
        }
    }
};

const Response = struct {
    allocator: Allocator,
    status: u16,
    body: []u8,

    fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

const Transport = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, Allocator, Io, ApiRequest) anyerror!Response,

    fn request(self: Transport, allocator: Allocator, io: Io, value: ApiRequest) !Response {
        try value.validate();
        return self.request_fn(self.context, allocator, io, value);
    }
};

const Metadata = struct {
    id: []const u8,
    public: bool,
    history: []const struct { version: []const u8 } = &.{},
};

const RemoteFile = struct {
    filename: []const u8,
    size: usize,
    truncated: bool,
    content: []const u8,
    encoding: []const u8 = "utf-8",
};

const Remote = struct {
    id: []const u8,
    public: bool,
    description: ?[]const u8 = null,
    truncated: bool,
    files: std.json.ArrayHashMap(RemoteFile),
};

const Document = struct {
    parsed: std.json.Parsed(Remote),
    revision: [40]u8,

    fn parse(allocator: Allocator, bytes: []const u8, ref: Ref) !Document {
        if (bytes.len > max_json_bytes) return error.GistJsonLimitExceeded;
        const parsed = try std.json.parseFromSlice(Remote, allocator, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        });
        errdefer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.id, ref.id)) return error.GistIdentityMismatch;
        const revision = ref.revision orelse return error.InvalidGistRevision;
        if (!validRevision(revision)) return error.InvalidGistRevision;
        if (value.truncated) return error.GistContentTruncated;
        if (value.files.map.count() == 0 or value.files.map.count() > max_files)
            return error.GistFileLimitExceeded;
        try validateText(value.description orelse "", 2048);
        var total: usize = 0;
        var files = value.files.map.iterator();
        while (files.next()) |entry| {
            try validateFilename(entry.key_ptr.*);
            const file = entry.value_ptr.*;
            if (!std.mem.eql(u8, file.filename, entry.key_ptr.*))
                return error.GistFilenameMismatch;
            if (file.truncated) return error.GistContentTruncated;
            if (!std.mem.eql(u8, file.encoding, "utf-8")) return error.InvalidGistText;
            try validateText(file.content, max_file_bytes);
            if (file.size != file.content.len) return error.GistContentSizeMismatch;
            total += file.content.len;
            if (total > max_total_bytes) return error.GistTextLimitExceeded;
        }
        return .{ .parsed = parsed, .revision = revision[0..40].* };
    }

    fn deinit(self: *Document) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    fn matches(self: *const Document, expected: Create) !void {
        const actual = self.parsed.value;
        if (actual.public) return error.GistUnexpectedPublic;
        if (!std.mem.eql(u8, actual.description orelse "", expected.description))
            return error.GistContentMismatch;
        if (actual.files.map.count() != expected.files.map.count())
            return error.GistContentMismatch;
        var files = expected.files.map.iterator();
        while (files.next()) |entry| {
            const file = actual.files.map.get(entry.key_ptr.*) orelse
                return error.GistContentMismatch;
            if (!std.mem.eql(u8, file.content, entry.value_ptr.content))
                return error.GistContentMismatch;
        }
    }

    fn write(self: *const Document, allocator: Allocator, output: *Writer) !void {
        const value = self.parsed.value;
        const url = try std.fmt.allocPrint(allocator, "https://gist.github.com/{s}", .{value.id});
        defer allocator.free(url);
        const revision_url = try apiUrl(allocator, .{
            .operation = .{ .read = .{ .id = value.id, .revision = &self.revision } },
            .token = null,
        });
        defer allocator.free(revision_url);
        try std.json.Stringify.value(.{
            .schema = "seq-gist/v1",
            .gist_id = value.id,
            .revision = &self.revision,
            .url = url,
            .revision_url = revision_url,
            .public = value.public,
            .description = value.description orelse "",
            .files = OutputFiles{ .files = value.files },
        }, .{}, output);
        try output.writeByte('\n');
    }
};

const OutputFiles = struct {
    files: std.json.ArrayHashMap(RemoteFile),

    pub fn jsonStringify(self: OutputFiles, json: anytype) !void {
        try json.beginObject();
        var files = self.files.map.iterator();
        while (files.next()) |entry| {
            try json.objectField(entry.key_ptr.*);
            try json.write(File{ .content = entry.value_ptr.content });
        }
        try json.endObject();
    }
};

fn read(
    allocator: Allocator,
    io: Io,
    transport: Transport,
    ref: Ref,
    token: ?[]const u8,
) !Document {
    var selected = ref;
    var revision: [40]u8 = undefined;
    if (selected.revision == null) {
        var latest = try get(allocator, io, transport, ref, token);
        defer latest.deinit();
        var metadata = try parseMetadata(allocator, latest.body);
        defer metadata.deinit();
        if (!std.mem.eql(u8, metadata.value.id, ref.id)) return error.GistIdentityMismatch;
        const sha = try currentRevision(metadata.value);
        revision = sha[0..40].*;
        selected.revision = &revision;
    }
    var response = try get(allocator, io, transport, selected, token);
    defer response.deinit();
    return Document.parse(allocator, response.body, selected);
}

fn get(allocator: Allocator, io: Io, transport: Transport, ref: Ref, token: ?[]const u8) !Response {
    var response = try transport.request(allocator, io, .{
        .operation = .{ .read = ref },
        .token = token,
    });
    errdefer response.deinit();
    if (response.status != 200) return statusError(response.status);
    return response;
}

fn create(
    allocator: Allocator,
    io: Io,
    transport: Transport,
    input: Create,
    token: []const u8,
    diagnostics: *Diagnostics,
) !Document {
    try validateToken(token);
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .description = input.description,
        .files = input.files,
        .public = false,
    }, .{});
    defer allocator.free(payload);
    if (payload.len > max_json_bytes) return error.GistJsonLimitExceeded;
    diagnostics.attempted_create = true;
    var response = transport.request(allocator, io, .{
        .operation = .{ .create = payload },
        .token = token,
    }) catch |err| return if (err == error.GistCreatedButUnverified)
        err
    else
        error.GistCreateOutcomeUnknown;
    defer response.deinit();
    if (response.status != 201) {
        if (response.status >= 400 and response.status < 500) return statusError(response.status);
        return error.GistCreateOutcomeUnknown;
    }
    rememberCreatedId(allocator, response.body, diagnostics);
    var metadata = parseMetadata(allocator, response.body) catch
        return error.GistCreatedButUnverified;
    defer metadata.deinit();
    diagnostics.remember(metadata.value.id, null);
    const revision = currentRevision(metadata.value) catch return error.GistCreatedButUnverified;
    diagnostics.remember(metadata.value.id, revision);
    if (metadata.value.public) return error.GistCreatedButUnverified;
    const ref: Ref = .{ .id = metadata.value.id, .revision = revision };
    var initial = Document.parse(allocator, response.body, ref) catch
        return error.GistCreatedButUnverified;
    defer initial.deinit();
    initial.matches(input) catch return error.GistCreatedButUnverified;
    var confirmed = read(allocator, io, transport, ref, token) catch
        return error.GistCreatedButUnverified;
    errdefer confirmed.deinit();
    confirmed.matches(input) catch return error.GistCreatedButUnverified;
    return confirmed;
}

fn rememberCreatedId(allocator: Allocator, bytes: []const u8, diagnostics: *Diagnostics) void {
    if (bytes.len > max_json_bytes) return;
    const parsed = std.json.parseFromSlice(struct { id: []const u8 }, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch return;
    defer parsed.deinit();
    diagnostics.remember(parsed.value.id, null);
}

fn parseMetadata(allocator: Allocator, bytes: []const u8) !std.json.Parsed(Metadata) {
    if (bytes.len > max_json_bytes) return error.GistJsonLimitExceeded;
    const parsed = try std.json.parseFromSlice(Metadata, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    });
    errdefer parsed.deinit();
    if (!validId(parsed.value.id)) return error.InvalidGistId;
    return parsed;
}

fn currentRevision(metadata: Metadata) ![]const u8 {
    if (metadata.history.len == 0 or !validRevision(metadata.history[0].version))
        return error.InvalidGistRevision;
    return metadata.history[0].version;
}

fn statusError(status: u16) anyerror {
    return switch (status) {
        401 => error.GistAuthenticationFailed,
        403 => error.GistAccessDenied,
        404 => error.GistNotFound,
        422 => error.GistRequestRejected,
        429 => error.GistRateLimited,
        else => error.GistHttpError,
    };
}

fn apiUrl(allocator: Allocator, request: ApiRequest) ![]u8 {
    try request.validate();
    return switch (request.operation) {
        .create => allocator.dupe(u8, "https://api.github.com/gists"),
        .read => |ref| if (ref.revision) |revision|
            std.fmt.allocPrint(
                allocator,
                "https://api.github.com/gists/{s}/{s}",
                .{ ref.id, revision },
            )
        else
            std.fmt.allocPrint(allocator, "https://api.github.com/gists/{s}", .{ref.id}),
    };
}

const Http = struct {
    fn transport(self: *Http) Transport {
        return .{ .context = self, .request_fn = request };
    }

    fn request(_: *anyopaque, allocator: Allocator, io: Io, value: ApiRequest) !Response {
        const url = try apiUrl(allocator, value);
        defer allocator.free(url);
        return exchangeAt(allocator, io, value, try std.Uri.parse(url), request_timeout_ms);
    }

    fn exchangeAt(
        allocator: Allocator,
        io: Io,
        value: ApiRequest,
        uri: std.Uri,
        timeout_ms: u32,
    ) !Response {
        var job: Job = .{ .allocator = allocator, .io = io, .request = value, .uri = uri };
        defer if (job.response) |*response| response.deinit();
        var results: [2]Outcome = undefined;
        var select = Io.Select(Outcome).init(io, &results);
        defer select.cancelDiscard();
        try select.concurrent(.request, Job.run, .{&job});
        try select.concurrent(.timeout, waitTimeout, .{ io, timeout_ms });
        const outcome = select.await() catch |err| {
            select.cancelDiscard();
            return if (job.creation_acknowledged) error.GistCreatedButUnverified else err;
        };
        select.cancelDiscard();
        switch (outcome) {
            .request => |result| result catch |err| {
                return if (job.creation_acknowledged) error.GistCreatedButUnverified else err;
            },
            .timeout => |result| {
                try result;
                if (job.creation_acknowledged) return error.GistCreatedButUnverified;
                return error.GistRequestTimedOut;
            },
        }
        const response = job.response orelse return error.GistResponseMissing;
        job.response = null;
        return response;
    }
};

const Outcome = union(enum) { request: anyerror!void, timeout: Io.Cancelable!void };

fn waitTimeout(io: Io, timeout_ms: u32) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(timeout_ms), .awake);
}

const Job = struct {
    allocator: Allocator,
    io: Io,
    request: ApiRequest,
    uri: std.Uri,
    response: ?Response = null,
    creation_acknowledged: bool = false,

    fn run(self: *Job) !void {
        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const bearer = if (self.request.token) |token|
            try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token})
        else
            null;
        defer if (bearer) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        };
        const payload: ?[]const u8 = switch (self.request.operation) {
            .create => |bytes| bytes,
            .read => null,
        };
        var request = try client.request(if (payload == null) .GET else .POST, self.uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .authorization = if (bearer) |value| .{ .override = value } else .omit,
                .user_agent = .{ .override = "seq" },
                .content_type = if (payload == null) .omit else .{ .override = "application/json" },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/vnd.github+json" },
                .{ .name = "X-GitHub-Api-Version", .value = "2026-03-10" },
            },
        });
        defer {
            if (request.connection) |connection| connection.closing = true;
            request.deinit();
        }
        if (payload) |bytes| {
            request.transfer_encoding = .{ .content_length = bytes.len };
            var body = try request.sendBodyUnflushed(&.{});
            try body.writer.writeAll(bytes);
            try body.end();
            try request.connection.?.flush();
        } else try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        self.creation_acknowledged = self.request.operation == .create and
            response.head.status == .created;
        if (response.head.status.class() == .redirect) return error.GistRedirectNotAllowed;
        const status: u16 = @backingInt(response.head.status);
        if (status != 200 and status != 201) {
            self.response = .{
                .allocator = self.allocator,
                .status = status,
                .body = try self.allocator.dupe(u8, ""),
            };
            return;
        }
        if (response.head.content_encoding != .identity) return error.InvalidGistEncoding;
        var transfer: [4096]u8 = undefined;
        const bytes = try response.reader(&transfer).allocRemaining(
            self.allocator,
            .limited(max_json_bytes),
        );
        self.response = .{ .allocator = self.allocator, .status = status, .body = bytes };
    }
};

const test_id = "0123456789abcdef0123456789abcdef";
const test_revision = "0123456789abcdef0123456789abcdef01234567";
const test_input =
    \\{"description":"handoff","files":{"handoff.md":{"content":"Goal\nEvidence\n"}}}
;

fn testResponse(allocator: Allocator, content: []const u8, public: bool, truncated: bool) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .id = test_id,
        .public = public,
        .description = "handoff",
        .truncated = truncated,
        .history = .{.{ .version = test_revision }},
        .files = .{ .@"handoff.md" = .{
            .filename = "handoff.md",
            .size = content.len,
            .truncated = truncated,
            .content = content,
            .raw_url = "https://untrusted.invalid/do-not-fetch",
        } },
    }, .{});
}

test "gist request admission excludes public controls paths duplicate fields and invalid text" {
    var accepted = try parseCreate(std.testing.allocator, test_input);
    defer accepted.deinit();
    try std.testing.expectEqualStrings(
        "Goal\nEvidence\n",
        accepted.value.files.map.get("handoff.md").?.content,
    );
    for ([_][]const u8{
        \\{"public":true,"files":{"handoff.md":{"content":"data"}}}
        ,
        \\{"public":false,"files":{"handoff.md":{"content":"data"}}}
        ,
        \\{"files":{"handoff.md":{"content":"data","filename":"other.md"}}}
        ,
        \\{"files":{"handoff.md":{"content":"first"},"handoff.md":{"content":"second"}}}
        ,
        \\{"files":{"../handoff.md":{"content":"data"}}}
        ,
        \\{"files":{"C:\\handoff.md":{"content":"data"}}}
        ,
        \\{"files":{".env":{"content":"data"}}}
        ,
        \\{"files":{"handoff.md":{"content":"\u0000"}}}
        ,
        \\{"files":{}}
        ,
    }) |input| {
        if (parseCreate(std.testing.allocator, input)) |unexpected| {
            unexpected.deinit();
            return error.InvalidGistInputAccepted;
        } else |err| try std.testing.expect(err != error.OutOfMemory);
    }
    try std.testing.expectError(error.InvalidGistText, validateText("\xff", 10));
    const oversized = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.GistTextLimitExceeded,
        validateText(oversized, max_file_bytes),
    );
}

test "gist references retain explicit revision and reject alternate authorities" {
    for ([_][]const u8{
        "https://gist.github.com/person/" ++ test_id ++ "/" ++ test_revision,
        "https://gist.github.com/" ++ test_id ++ "/" ++ test_revision,
        "https://api.github.com/gists/" ++ test_id ++ "/" ++ test_revision,
    }) |url| {
        const ref = try parseGistRef(url);
        try std.testing.expectEqualStrings(test_id, ref.id);
        try std.testing.expectEqualStrings(test_revision, ref.revision.?);
    }
    for ([_][]const u8{
        "https://gist.github.com.evil/" ++ test_id,
        "https://gist.github.com@evil/" ++ test_id,
        "http://gist.github.com/person/" ++ test_id,
        "https://gist.github.com/person/" ++ test_id ++ "?x=1",
        "https://api.github.com/repos/" ++ test_id,
        "https://gist.github.com/person/" ++ test_id ++ "/abcd",
        "https://gist.github.com/person/../" ++ test_id,
    }) |url| {
        if (parseGistRef(url)) |_| return error.InvalidGistUrlAccepted else |_| {}
    }
    const pinned = "https://gist.github.com/person/" ++ test_id ++ "/" ++ test_revision;
    try std.testing.expectError(error.ConflictingGistRevision, parseArgs(&.{
        "read", "--gist", pinned, "--revision", "ffffffffffffffffffffffffffffffffffffffff",
    }));
    try std.testing.expectError(error.UnknownGistArgument, parseArgs(&.{
        "create", "--input", "request.json", "--public", "true",
    }));
}

test "gist credentials retain explicit precedence and cannot inject headers" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectEqual(null, try tokenFromEnvironment(&environment));
    try environment.put("GITHUB_TOKEN", "synthetic-third");
    try environment.put("GH_TOKEN", "synthetic-second");
    try environment.put("SEQ_GITHUB_TOKEN", "synthetic-first");
    try std.testing.expectEqualStrings(
        "synthetic-first",
        (try tokenFromEnvironment(&environment)).?,
    );
    try environment.put("SEQ_GITHUB_TOKEN", "bad\r\nX-Leak: injected");
    try std.testing.expectError(error.InvalidGistToken, tokenFromEnvironment(&environment));
}

const MockReply = struct {
    operation: enum { create, latest, revision },
    status: u16 = 200,
    body: []const u8 = "",
    fail: bool = false,
};

const Mock = struct {
    replies: []const MockReply,
    calls: usize = 0,

    fn transport(self: *Mock) Transport {
        return .{ .context = self, .request_fn = request };
    }

    fn request(context: *anyopaque, allocator: Allocator, _: Io, value: ApiRequest) !Response {
        const self: *Mock = @ptrCast(@alignCast(context));
        if (self.calls >= self.replies.len) return error.UnexpectedRequest;
        const reply = self.replies[self.calls];
        self.calls += 1;
        switch (reply.operation) {
            .create => {
                try std.testing.expect(value.operation == .create);
                var parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    value.operation.create,
                    .{},
                );
                defer parsed.deinit();
                try std.testing.expectEqual(false, parsed.value.object.get("public").?.bool);
            },
            .latest, .revision => {
                try std.testing.expect(value.operation == .read);
                try std.testing.expectEqualStrings(test_id, value.operation.read.id);
                if (reply.operation == .revision)
                    try std.testing.expectEqualStrings(
                        test_revision,
                        value.operation.read.revision.?,
                    )
                else
                    try std.testing.expect(value.operation.read.revision == null);
            },
        }
        if (reply.fail) return error.ConnectionLost;
        return .{
            .allocator = allocator,
            .status = reply.status,
            .body = try allocator.dupe(u8, reply.body),
        };
    }
};

test "gist create verifies secret content with an immutable read before success" {
    const allocator = std.testing.allocator;
    const body = try testResponse(allocator, "Goal\nEvidence\n", false, false);
    defer allocator.free(body);
    var input = try parseCreate(allocator, test_input);
    defer input.deinit();
    var mock: Mock = .{ .replies = &.{
        .{ .operation = .create, .status = 201, .body = body },
        .{ .operation = .revision, .body = body },
    } };
    var diagnostics: Diagnostics = .{};
    var document = try create(
        allocator,
        std.testing.io,
        mock.transport(),
        input.value,
        "synthetic-token",
        &diagnostics,
    );
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
    try std.testing.expectEqualStrings(test_id, diagnostics.gistId().?);
    try std.testing.expectEqualStrings(test_revision, &diagnostics.revision.?);
    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    try document.write(allocator, &output.writer);
    var decoded = try std.json.parseFromSlice(std.json.Value, allocator, output.written(), .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings(
        test_revision,
        decoded.value.object.get("revision").?.string,
    );
    try std.testing.expectEqualStrings(
        "https://api.github.com/gists/" ++ test_id ++ "/" ++ test_revision,
        decoded.value.object.get("revision_url").?.string,
    );
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "raw_url") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "synthetic-token") == null);
}

test "gist read resolves latest once then ignores untrusted raw URLs" {
    const allocator = std.testing.allocator;
    const body = try testResponse(allocator, "Goal\nEvidence\n", false, false);
    defer allocator.free(body);
    var mock: Mock = .{ .replies = &.{
        .{ .operation = .latest, .body = body },
        .{ .operation = .revision, .body = body },
    } };
    var document = try read(allocator, std.testing.io, mock.transport(), .{ .id = test_id }, null);
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
    try std.testing.expectEqualStrings(test_revision, &document.revision);
}

test "gist creation uncertainty and failed verification preserve recovery without replay" {
    const allocator = std.testing.allocator;
    var input = try parseCreate(allocator, test_input);
    defer input.deinit();
    var lost: Mock = .{ .replies = &.{.{ .operation = .create, .fail = true }} };
    var unknown: Diagnostics = .{};
    try std.testing.expectError(error.GistCreateOutcomeUnknown, create(
        allocator,
        std.testing.io,
        lost.transport(),
        input.value,
        "synthetic-token",
        &unknown,
    ));
    try std.testing.expectEqual(@as(usize, 1), lost.calls);
    try std.testing.expect(unknown.attempted_create);
    try std.testing.expect(unknown.gistId() == null);
    const initial = try testResponse(allocator, "Goal\nEvidence\n", false, false);
    defer allocator.free(initial);
    const changed = try testResponse(allocator, "changed", false, false);
    defer allocator.free(changed);
    const public = try testResponse(allocator, "Goal\nEvidence\n", true, false);
    defer allocator.free(public);
    const truncated = try testResponse(allocator, "Goal\nEvidence\n", false, true);
    defer allocator.free(truncated);
    for ([_][]const u8{ changed, public, truncated }) |body| {
        var mock: Mock = .{ .replies = &.{
            .{ .operation = .create, .status = 201, .body = initial },
            .{ .operation = .revision, .body = body },
        } };
        var diagnostics: Diagnostics = .{};
        try std.testing.expectError(error.GistCreatedButUnverified, create(
            allocator,
            std.testing.io,
            mock.transport(),
            input.value,
            "synthetic-token",
            &diagnostics,
        ));
        try std.testing.expectEqual(@as(usize, 2), mock.calls);
        try std.testing.expectEqualStrings(test_id, diagnostics.gistId().?);
        try std.testing.expectEqualStrings(test_revision, &diagnostics.revision.?);
    }
}

test "gist read rejects truncation instead of presenting an incomplete document" {
    const allocator = std.testing.allocator;
    const body = try testResponse(allocator, "Goal\nEvidence\n", false, true);
    defer allocator.free(body);
    var mock: Mock = .{ .replies = &.{.{ .operation = .revision, .body = body }} };
    try std.testing.expectError(error.GistContentTruncated, read(
        allocator,
        std.testing.io,
        mock.transport(),
        .{ .id = test_id, .revision = test_revision },
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

const HttpFixture = struct {
    server: Io.net.Server,
    replies: []const MockReply,
    calls: std.atomic.Value(usize) = .init(0),
    wire: ?[]const u8 = null,
    stall: bool = false,
    authorization: ?[]const u8 = "Bearer synthetic-token",

    fn open(replies: []const MockReply) !HttpFixture {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{
            .server = try address.listen(std.testing.io, .{ .mode = .stream, .protocol = .tcp }),
            .replies = replies,
        };
    }

    fn transport(self: *HttpFixture) Transport {
        return .{ .context = self, .request_fn = request };
    }

    fn request(context: *anyopaque, allocator: Allocator, io: Io, value: ApiRequest) !Response {
        const self: *HttpFixture = @ptrCast(@alignCast(context));
        const canonical = try apiUrl(allocator, value);
        defer allocator.free(canonical);
        var buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}{s}", .{
            self.server.socket.address.getPort(), canonical["https://api.github.com".len..],
        });
        return Http.exchangeAt(allocator, io, value, try std.Uri.parse(url), 1_000);
    }

    fn serve(self: *HttpFixture) !void {
        for (self.replies) |reply| {
            const stream = try self.server.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var input: [4096]u8 = undefined;
            var output: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &input);
            var writer = stream.writer(std.testing.io, &output);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var incoming = try server.receiveHead();
            _ = self.calls.fetchAdd(1, .monotonic);
            try std.testing.expectEqual(
                if (reply.operation == .create) std.http.Method.POST else .GET,
                incoming.head.method,
            );
            const target = switch (reply.operation) {
                .create => "/gists",
                .latest => "/gists/" ++ test_id,
                .revision => "/gists/" ++ test_id ++ "/" ++ test_revision,
            };
            try std.testing.expectEqualStrings(target, incoming.head.target);
            var headers = incoming.iterateHeaders();
            var authorization_count: usize = 0;
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                    authorization_count += 1;
                    const expected = self.authorization orelse return error.UnexpectedAuthorization;
                    try std.testing.expectEqualStrings(expected, header.value);
                }
            }
            try std.testing.expectEqual(
                @as(usize, if (self.authorization == null) 0 else 1),
                authorization_count,
            );
            const body_reader = incoming.server.reader.bodyReader(
                &.{},
                incoming.head.transfer_encoding,
                incoming.head.content_length orelse 0,
            );
            const payload = try body_reader.allocRemaining(
                std.testing.allocator,
                .limited(max_json_bytes),
            );
            defer std.testing.allocator.free(payload);
            if (reply.operation == .create) {
                var parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    std.testing.allocator,
                    payload,
                    .{},
                );
                defer parsed.deinit();
                try std.testing.expectEqual(false, parsed.value.object.get("public").?.bool);
                const file = parsed.value.object.get("files").?.object.get("handoff.md").?;
                const sent = file.object.get("content").?.string;
                try std.testing.expectEqualStrings("Goal\nEvidence\n", sent);
            }
            if (reply.fail) return;
            if (self.wire) |wire| {
                try writer.interface.writeAll(wire);
                try writer.interface.flush();
            } else try incoming.respond(reply.body, .{
                .status = @fromBackingInt(@intCast(reply.status)),
            });
            if (self.stall) try std.testing.io.sleep(.fromSeconds(10), .awake);
        }
    }
};

test "native HTTP creates secret payload and reads exact revision without external commands" {
    const allocator = std.testing.allocator;
    const body = try testResponse(allocator, "Goal\nEvidence\n", false, false);
    defer allocator.free(body);
    var fixture = try HttpFixture.open(&.{
        .{ .operation = .create, .status = 201, .body = body },
        .{ .operation = .revision, .body = body },
    });
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpFixture.serve, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var input = try parseCreate(allocator, test_input);
    defer input.deinit();
    var diagnostics: Diagnostics = .{};
    var document = try create(
        allocator,
        std.testing.io,
        fixture.transport(),
        input.value,
        "synthetic-token",
        &diagnostics,
    );
    defer document.deinit();
    try worker.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls.load(.monotonic));
    try std.testing.expectEqualStrings(test_revision, &document.revision);
}

test "native HTTP rejects redirects without following locations or waiting for response body" {
    var fixture = try HttpFixture.open(&.{.{ .operation = .revision }});
    defer fixture.server.deinit(std.testing.io);
    fixture.wire = "HTTP/1.1 302 Found\r\n" ++
        "Location: https://untrusted.invalid/steal\r\nContent-Length: 1000\r\n\r\n";
    fixture.stall = true;
    var worker = try std.testing.io.concurrent(HttpFixture.serve, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    try std.testing.expectError(error.GistRedirectNotAllowed, read(
        std.testing.allocator,
        std.testing.io,
        fixture.transport(),
        .{ .id = test_id, .revision = test_revision },
        "synthetic-token",
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.monotonic));
}

test "native HTTP never replays a create after lost response" {
    var fixture = try HttpFixture.open(&.{.{ .operation = .create, .fail = true }});
    defer fixture.server.deinit(std.testing.io);
    var worker = try std.testing.io.concurrent(HttpFixture.serve, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var input = try parseCreate(std.testing.allocator, test_input);
    defer input.deinit();
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.GistCreateOutcomeUnknown, create(
        std.testing.allocator,
        std.testing.io,
        fixture.transport(),
        input.value,
        "synthetic-token",
        &diagnostics,
    ));
    try worker.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.monotonic));
}

test "native HTTP preserves acknowledged creation when its response body is lost" {
    for ([_]bool{ false, true }) |stall| {
        var fixture = try HttpFixture.open(&.{.{ .operation = .create }});
        defer fixture.server.deinit(std.testing.io);
        fixture.wire = "HTTP/1.1 201 Created\r\nContent-Length: 1000\r\n\r\n{";
        fixture.stall = stall;
        var worker = try std.testing.io.concurrent(HttpFixture.serve, .{&fixture});
        defer _ = worker.cancel(std.testing.io) catch null;
        var input = try parseCreate(std.testing.allocator, test_input);
        defer input.deinit();
        var diagnostics: Diagnostics = .{};
        try std.testing.expectError(error.GistCreatedButUnverified, create(
            std.testing.allocator,
            std.testing.io,
            fixture.transport(),
            input.value,
            "synthetic-token",
            &diagnostics,
        ));
        if (!stall) try worker.await(std.testing.io);
        try std.testing.expect(diagnostics.attempted_create);
        try std.testing.expect(diagnostics.gistId() == null);
        try std.testing.expect(diagnostics.revision == null);
        try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.monotonic));
    }
}

test "gist command stages no output or network publication for rejected input" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "request.json",
        .data =
        \\{"public":true,"files":{"handoff.md":{"content":"must not publish"}}}
        ,
    });
    var environment: std.process.Environ.Map = .init(allocator);
    defer environment.deinit();
    try environment.put("SEQ_GITHUB_TOKEN", "synthetic-token");
    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.UnknownField, run(
        std.testing.io,
        tmp.dir,
        allocator,
        &environment,
        &.{ "create", "--input", "request.json" },
        &output.writer,
        &diagnostics,
    ));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try std.testing.expect(!diagnostics.attempted_create);
}

test "native HTTP anonymous read omits credentials and still pins a revision" {
    const allocator = std.testing.allocator;
    const body = try testResponse(allocator, "Goal\nEvidence\n", false, false);
    defer allocator.free(body);
    var fixture = try HttpFixture.open(&.{.{ .operation = .revision, .body = body }});
    defer fixture.server.deinit(std.testing.io);
    fixture.authorization = null;
    var worker = try std.testing.io.concurrent(HttpFixture.serve, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    var document = try read(allocator, std.testing.io, fixture.transport(), .{
        .id = test_id,
        .revision = test_revision,
    }, null);
    defer document.deinit();
    try worker.await(std.testing.io);
    try std.testing.expectEqualStrings(test_revision, &document.revision);
}

test "native HTTP incomplete response ends at deadline without reporting content" {
    var fixture = try HttpFixture.open(&.{.{ .operation = .revision }});
    defer fixture.server.deinit(std.testing.io);
    fixture.wire = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n{";
    fixture.stall = true;
    var worker = try std.testing.io.concurrent(HttpFixture.serve, .{&fixture});
    defer _ = worker.cancel(std.testing.io) catch null;
    try std.testing.expectError(error.GistRequestTimedOut, read(
        std.testing.allocator,
        std.testing.io,
        fixture.transport(),
        .{ .id = test_id, .revision = test_revision },
        "synthetic-token",
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.monotonic));
}
