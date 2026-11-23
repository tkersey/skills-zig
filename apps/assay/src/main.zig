const std = @import("std");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");
const assay = @import("assay");

const limits = assay.limits;
const cli = assay.cli;
const render = assay.render;
const Diagnostic = assay.diag.Diagnostic;
const Writer = std.Io.Writer;

const help: core_cli.HelpSurface = .{
    .executable_name = "assay",
    .help_text =
    \\assay — bounded assessment of obligations against supplied evidence
    \\
    \\Usage:
    \\  assay capabilities
    \\  assay assess --contract CONTRACT.json --subject SUBJECT.json \
    \\               --evidence EVIDENCE.json [--subject-root DIRECTORY] [--format json|text]
    \\  assay compare --baseline BASELINE.json --candidate CANDIDATE.json [--format json|text]
    \\  assay explain --assessment ASSESSMENT.json [--format json|text]
    \\  assay --help | --version
    \\
    \\assess exits 0 when every required obligation is supported, 1 when one is
    \\refuted, and 3 when none is refuted but one is unresolved. compare and explain
    \\exit 0 once processing completes, whatever the judgments. Exit 2 is a command,
    \\document, integrity, resource, or I/O error, and no result is produced.
    \\
    \\Assay reads only the named local documents and, with --subject-root, the files
    \\the subject manifest lists. It runs no evaluator, uses no network, grants no
    \\authority, and writes results and JSON errors to stdout; text-mode errors and
    \\output-failure notices go to stderr. See apps/assay/README.md.
    ,
};

const producer: render.Producer = .{ .version = core_cli.normalizeVersion(app_meta.version) };

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    std.process.exit(run(init.io, init.gpa, argv));
}

fn run(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) u8 {
    var budget = assay.budget.Budget.init(gpa, limits.allocation_bytes_max);
    var arena_state = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output: Writer.Allocating = .init(arena);
    var d: Diagnostic = .{};
    const format: cli.Format = if (argv.len > 1) cli.requestedFormat(argv[1..]) else .json;
    const status = execute(io, arena, &output.writer, argv, &d) catch |err| {
        switch (err) {
            error.Rejected => {},
            error.OutOfMemory, error.WriteFailed => d.set(
                .resource_limit,
                null,
                "allocation budget of {d} bytes exhausted",
                .{limits.allocation_bytes_max},
            ),
        }
        return emitError(io, &d, format);
    };
    const admitted = admitOutput(&d, output.written()) catch return emitError(io, &d, format);
    std.Io.File.stdout().writeStreamingAll(io, admitted) catch {
        const message = "assay: io_error: stdout write failed\n";
        std.Io.File.stderr().writeStreamingAll(io, message) catch return 2;
        return 2;
    };
    return status;
}

fn admitOutput(d: *Diagnostic, bytes: []const u8) error{Rejected}![]const u8 {
    if (bytes.len > limits.receipt_bytes_max) {
        const bound = limits.receipt_bytes_max;
        return d.fail(.resource_limit, null, "output exceeds {d} bytes", .{bound});
    }
    return bytes;
}

fn emitError(io: std.Io, d: *const Diagnostic, format: cli.Format) u8 {
    const escaped_bytes_max = 6 * (limits.error_message_bytes_max + assay.diag.location_bytes_max);
    var buffer: [escaped_bytes_max + 1024]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    const rendered = switch (format) {
        .json => render.commandError(&writer, d),
        .text => render.commandErrorText(&writer, d),
    };
    rendered catch return 2;
    const file = if (format == .json) std.Io.File.stdout() else std.Io.File.stderr();
    file.writeStreamingAll(io, writer.buffered()) catch {
        const notice = "assay: io_error: error output write failed\n";
        std.Io.File.stderr().writeStreamingAll(io, notice) catch return 2;
    };
    return 2;
}

const ExecuteError = error{ Rejected, OutOfMemory, WriteFailed };

fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    w: *Writer,
    argv: []const []const u8,
    d: *Diagnostic,
) ExecuteError!u8 {
    if (try core_cli.handleDefaultHelpAndVersionSurface(w, argv, help, app_meta.version)) return 0;
    const options = try cli.parse(argv[1..], d);
    switch (options.command) {
        .capabilities => {
            try render.capabilities(w, producer);
            return 0;
        },
        .assess => return assessCommand(io, arena, w, options, d),
        .compare => return compareCommand(io, arena, w, options, d),
        .explain => return explainCommand(io, arena, w, options, d),
    }
}

fn readInput(
    io: std.Io,
    arena: std.mem.Allocator,
    d: *Diagnostic,
    path: []const u8,
    label: []const u8,
    bytes_max: u64,
) error{ Rejected, OutOfMemory }![]const u8 {
    const limit: std.Io.Limit = .limited(@intCast(bytes_max + 1));
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound, error.NotDir, error.IsDir => d.fail(
            .missing_input,
            null,
            "{s} document not found as a file",
            .{label},
        ),
        error.StreamTooLong => d.fail(.resource_limit, null, "{s} document exceeds {d} bytes", .{
            label, bytes_max,
        }),
        else => d.fail(.io_error, null, "{s} document could not be read: {s}", .{
            label, @errorName(err),
        }),
    };
}

fn assessCommand(
    io: std.Io,
    arena: std.mem.Allocator,
    w: *Writer,
    options: cli.Options,
    d: *Diagnostic,
) ExecuteError!u8 {
    const bound = limits.source_document_bytes_max;
    const sources: assay.assess.Sources = .{
        .contract = try readInput(io, arena, d, options.required(.contract), "contract", bound),
        .subject = try readInput(io, arena, d, options.required(.subject), "subject", bound),
        .evidence = try readInput(io, arena, d, options.required(.evidence), "evidence", bound),
    };
    const loaded = try assay.assess.load(arena, d, sources);
    var checked: assay.verify.Verification = .{};
    if (options.get(.@"subject-root")) |root| {
        const buffer = try arena.create([limits.hash_buffer_bytes]u8);
        checked = try assay.verify.verify(io, d, root, loaded.subject, buffer);
    }
    const derivation = try assay.assess.derive(arena, &loaded);
    switch (options.format) {
        .json => try render.assessment(w, producer, &loaded, derivation, checked),
        .text => try render.assessmentText(w, &loaded, derivation, checked),
    }
    return switch (derivation.overall) {
        .supported => 0,
        .refuted => 1,
        .unresolved => 3,
    };
}

fn readReceipt(
    io: std.Io,
    arena: std.mem.Allocator,
    d: *Diagnostic,
    path: []const u8,
    role: []const u8,
) error{ Rejected, OutOfMemory }!assay.receipt.Verified {
    const bytes = try readInput(io, arena, d, path, role, limits.receipt_bytes_max);
    return assay.receipt.check(arena, d, bytes, role);
}

fn compareCommand(
    io: std.Io,
    arena: std.mem.Allocator,
    w: *Writer,
    options: cli.Options,
    d: *Diagnostic,
) ExecuteError!u8 {
    const baseline = try readReceipt(io, arena, d, options.required(.baseline), "baseline");
    const candidate = try readReceipt(io, arena, d, options.required(.candidate), "candidate");
    const result = try assay.compare.compare(arena, &baseline, &candidate);
    switch (options.format) {
        .json => try render.comparison(w, result),
        .text => try render.comparisonText(w, result),
    }
    return 0;
}

fn explainCommand(
    io: std.Io,
    arena: std.mem.Allocator,
    w: *Writer,
    options: cli.Options,
    d: *Diagnostic,
) ExecuteError!u8 {
    const verified = try readReceipt(io, arena, d, options.required(.assessment), "assessment");
    switch (options.format) {
        .json => try render.explanation(w, &verified),
        .text => try render.explanationText(w, &verified),
    }
    return 0;
}

test "output beyond the receipt bound is a clean resource error" {
    const allocator = std.testing.allocator;
    const at_limit = try allocator.alloc(u8, limits.receipt_bytes_max);
    defer allocator.free(at_limit);
    var d: Diagnostic = .{};
    try std.testing.expectEqual(at_limit.len, (try admitOutput(&d, at_limit)).len);
    const above = try allocator.alloc(u8, limits.receipt_bytes_max + 1);
    defer allocator.free(above);
    try std.testing.expectError(error.Rejected, admitOutput(&d, above));
    try std.testing.expectEqual(assay.diag.Code.resource_limit, d.code);
    try std.testing.expectEqualStrings("output exceeds 67108864 bytes", d.message());
}

test "help names every command and the authority boundary" {
    for (render.commands) |command| {
        try std.testing.expect(std.mem.indexOf(u8, help.help_text, command) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, help.help_text, "grants no") != null);
}
