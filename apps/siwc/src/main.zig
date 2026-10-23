const std = @import("std");
const core_cli = @import("core_cli");
const app_meta = @import("app_meta");
const siwc = @import("siwc");
const args = @import("args.zig");
const execution = @import("exec.zig");
const browser = @import("browser.zig");

const help: core_cli.HelpSurface = .{
    .executable_name = "siwc",
    .help_text =
    \\siwc — Sign in with ChatGPT for local apps
    \\
    \\Usage:
    \\  siwc login --app APP --new-account LABEL [--enable-plan] [--no-browser]
    \\  siwc login --app APP --account LABEL [--enable-plan] [--no-browser]
    \\  siwc accounts --app APP [--json]
    \\  siwc status --app APP --account LABEL [--json]
    \\  siwc models --app APP --account LABEL [--json]
    \\  siwc logout --app APP --account LABEL [--json]
    \\  siwc credential --app APP --account LABEL --json
    \\  siwc exec --app APP --account LABEL -- COMMAND ARGUMENTS...
    \\
    \\All commands accept --auth-dir ABSOLUTE_PATH (default: $HOME/.config/siwc).
    \\APP and LABEL: 1–64 lowercase ASCII letters, digits, underscores, or hyphens;
    \\the first character must be a letter or digit. Select an account explicitly.
    \\
    \\credential writes a short-lived access token to stdout. Treat its output as secret.
    \\exec supplies OPENAI_API_KEY and OPENAI_BASE_URL to a trusted child process.
    \\The child must support the ChatGPT Responses request contract. Its environment
    \\cannot refresh itself; long-running apps should request fresh credentials.
    \\See apps/siwc/README.md for integration, storage, and recovery details.
    ,
};

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_file = std.Io.File.stdout().writer(init.io, &.{});
    var stderr_file = std.Io.File.stderr().writer(init.io, &.{});
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;
    if (try core_cli.handleDefaultHelpAndVersionSurface(stdout, argv, help, app_meta.version))
        return;
    const options = args.parse(argv) catch |err| {
        try core_cli.printUsageFailureWithHelp(
            stderr,
            help,
            app_meta.version,
            @errorName(err),
            null,
        );
        std.process.exit(2);
    };
    const code = run(init, options, stdout, stderr) catch |err| {
        try report(stderr, err, null);
        std.process.exit(1);
    };
    if (code != 0) std.process.exit(code);
}

fn run(
    init: std.process.Init,
    options: args.Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (options.command == .exec) try execution.validateDestination(init.environ_map);
    const allocator = init.gpa;
    const path = try authPath(allocator, init.environ_map, options.auth_dir);
    defer allocator.free(path);
    const read_only = options.command == .status or options.command == .accounts;
    var store = try siwc.Store.open(
        init.io,
        allocator,
        path,
        options.app,
        if (read_only) .read_only else .create,
    );
    defer store.deinit();
    var http = try siwc.transport.Http.init(allocator, init.io);
    defer http.deinit();
    var manager: siwc.Manager = .{
        .allocator = allocator,
        .io = init.io,
        .store = &store,
        .transport = http.transport(),
    };
    return dispatch(init, &manager, options, stdout, stderr) catch |err| {
        try report(stderr, err, manager.last_http_status);
        return 1;
    };
}

fn authPath(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    override: ?[]const u8,
) ![]u8 {
    if (override) |path| return allocator.dupe(u8, path);
    const home = environment.get("HOME") orelse return error.HomeDirectoryUnavailable;
    if (!std.fs.path.isAbsolute(home) or home.len > 4000) return error.InvalidHomeDirectory;
    return std.fs.path.join(allocator, &.{ home, ".config", "siwc" });
}

fn dispatch(
    init: std.process.Init,
    manager: *siwc.Manager,
    options: args.Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    switch (options.command) {
        .login => try login(manager, options, stdout, stderr),
        .accounts => try accounts(manager, stdout, options.json),
        .status => try accountStatus(manager, options.account.?, stdout, options.json),
        .models => {
            var catalogue = try manager.models(options.account.?);
            defer catalogue.deinit();
            if (options.json) {
                try writeJson(stdout, catalogue.visible);
            } else for (catalogue.visible) |model| {
                try stdout.print("{s}\t{s}\n", .{ model.slug, model.display_name });
            }
        },
        .logout => return logout(manager, options, stdout),
        .credential => {
            var lease = try manager.credential(options.account.?);
            defer lease.deinit();
            try writeJson(stdout, lease.value);
        },
        .exec => {
            var lease = try manager.credential(options.account.?);
            defer lease.deinit();
            var environment = try execution.makeEnvironment(
                init.gpa,
                init.environ_map,
                lease.value.access_token,
            );
            defer environment.deinit();
            try execution.execute(init.io, options.child_argv, &environment);
        },
    }
    return 0;
}

fn login(
    manager: *siwc.Manager,
    options: args.Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const label = options.new_account orelse options.account.?;
    var listener = try siwc.callback.Listener.open(manager.io, manager.allocator);
    defer listener.deinit();
    var session = try manager.beginLogin(.{
        .label = label,
        .new_account = options.new_account != null,
        .redirect_uri = listener.redirect_uri,
        .enable_plan = options.enable_plan,
    });
    defer session.deinit();
    if (options.no_browser) {
        try stderr.print("Open this URL on this computer to sign in:\n{s}\n", .{
            session.authorization_url,
        });
    } else {
        browser.open(manager.io, session.authorization_url) catch |err| {
            try stderr.print("Browser launch: {s}. Open this URL on this computer:\n{s}\n", .{
                @errorName(err),
                session.authorization_url,
            });
        };
    }
    try stderr.writeAll("Waiting up to 10 minutes for browser sign-in...\n");
    var callback = try listener.wait(&session.secrets.state, session.record.value.client_id);
    defer callback.deinit();
    try session.complete(callback);
    try accountStatus(manager, label, stdout, false);
    var record = try manager.store.load(label);
    defer record.deinit();
    if (!siwc.oauth.hasPlanScope(record.value.tokens.?.scope)) {
        try stderr.print("Plan usage was not enabled. Run: siwc login --app {s} " ++
            "--account {s} --enable-plan\n", .{ options.app, label });
    }
}

fn accounts(manager: *siwc.Manager, stdout: *std.Io.Writer, json: bool) !void {
    const labels = try manager.store.list();
    defer manager.store.freeList(labels);
    var records: std.ArrayList(std.json.Parsed(siwc.store.Record)) = .empty;
    defer {
        for (records.items) |*record| record.deinit();
        records.deinit(manager.allocator);
    }
    try records.ensureTotalCapacity(manager.allocator, labels.len);
    var values: [siwc.store.accounts_max]siwc.Status = undefined;
    const now = try manager.clock.now(manager.io);
    for (labels, 0..) |label, index| {
        records.appendAssumeCapacity(try manager.store.load(label));
        values[index] = siwc.manager.status(records.items[index].value, now);
    }
    if (json) return writeJson(stdout, values[0..labels.len]);
    for (values[0..labels.len]) |value| try printStatus(stdout, value);
}

fn accountStatus(
    manager: *siwc.Manager,
    label: []const u8,
    stdout: *std.Io.Writer,
    json: bool,
) !void {
    var record = try manager.store.load(label);
    defer record.deinit();
    const value = siwc.manager.status(record.value, try manager.clock.now(manager.io));
    if (json) return writeJson(stdout, value);
    try printStatus(stdout, value);
}

fn printStatus(stdout: *std.Io.Writer, value: siwc.Status) !void {
    try stdout.print("{s}/{s}\t{s}\t{s}\n", .{
        value.app,
        value.account,
        @tagName(value.phase),
        value.email orelse "-",
    });
}

fn logout(manager: *siwc.Manager, options: args.Options, stdout: *std.Io.Writer) !u8 {
    const result = try manager.logout(options.account.?);
    if (options.json) {
        try writeJson(stdout, result);
    } else {
        try stdout.print("{s}/{s}: local session cleared; registration retained.\n", .{
            options.app,
            options.account.?,
        });
        if (result.revocation_error) |reason| {
            try stdout.print("Remote revocation was not confirmed: {s}.\n", .{reason});
        } else if (result.revoked) try stdout.writeAll("Remote revocation confirmed.\n");
    }
    return if (result.revocation_error == null) 0 else 1;
}

fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

fn report(stderr: *std.Io.Writer, err: anyerror, http_status: ?u16) !void {
    try stderr.print("siwc: {s}", .{@errorName(err)});
    if (http_status) |code| try stderr.print(" (HTTP {d})", .{code});
    try stderr.writeByte('\n');
    const identity_hint = "Identity mismatch. Use a different new account label.";
    const permissions_hint = "Use owner-only permissions: directories 0700 and files 0600.";
    const hint: ?[]const u8 = switch (err) {
        error.FileNotFound, error.NotSignedIn => "Sign in with --app and --account.",
        error.AccountAlreadyExists => "The label is reserved. Continue with --account LABEL.",
        error.AccountBusy => "Another operation owns this account. Retry after it finishes.",
        error.ReauthenticationRequired => "Sign in again with --account LABEL.",
        error.PlanUsageNotEnabled => "Sign in again with --account LABEL --enable-plan.",
        error.IdentityMismatch, error.ClientMismatch, error.RegistrationMismatch => identity_hint,
        error.InsecurePrivateDirectory, error.InsecurePrivateFile => permissions_hint,
        else => null,
    };
    if (hint) |value| try stderr.print("{s}\n", .{value});
}

test {
    _ = args;
    _ = execution;
}

test "status and help outputs exclude token-bearing record fields" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try printStatus(&output.writer, .{
        .app = "example",
        .account = "personal",
        .client_id = "oaiapp_test",
        .subject = "subject",
        .email = "test@example.invalid",
        .phase = .ready,
        .expires_at = 42,
    });
    try std.testing.expectEqualStrings(
        "example/personal\tready\ttest@example.invalid\n",
        output.written(),
    );
    try std.testing.expect(std.mem.indexOf(u8, help.help_text, "--new-account") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.help_text, "long-running") != null);
}
