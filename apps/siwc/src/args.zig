const std = @import("std");
const siwc = @import("siwc");

pub const arguments_max = 256;
pub const argument_bytes_max = 64 * 1024;

pub const Command = enum { login, accounts, status, models, logout, credential, exec };

pub const Options = struct {
    command: Command,
    app: []const u8 = "",
    account: ?[]const u8 = null,
    new_account: ?[]const u8 = null,
    auth_dir: ?[]const u8 = null,
    enable_plan: bool = false,
    no_browser: bool = false,
    json: bool = false,
    child_argv: []const []const u8 = &.{},
};

pub fn parse(argv: []const []const u8) !Options {
    try validateArguments(argv);
    if (argv.len < 2) return error.CommandRequired;
    var options: Options = .{
        .command = std.meta.stringToEnum(Command, argv[1]) orelse return error.UnknownCommand,
    };
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--")) {
            if (options.command != .exec) return error.UnexpectedSeparator;
            options.child_argv = argv[index + 1 ..];
            break;
        }
        try readOption(&options, argv, &index);
    }
    try validateOptions(options);
    return options;
}

pub fn validateArguments(argv: []const []const u8) !void {
    if (argv.len > arguments_max) return error.TooManyArguments;
    var bytes: usize = 0;
    for (argv) |argument| {
        if (argument.len >= argument_bytes_max - bytes) return error.ArgumentsTooLarge;
        bytes += argument.len + 1;
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArgument;
    }
}

fn readOption(options: *Options, argv: []const []const u8, index: *usize) !void {
    const argument = argv[index.*];
    if (std.mem.eql(u8, argument, "--app")) {
        if (options.app.len != 0) return error.DuplicateOption;
        options.app = try takeValue(argv, index);
    } else if (std.mem.eql(u8, argument, "--account")) {
        if (options.account != null) return error.DuplicateOption;
        options.account = try takeValue(argv, index);
    } else if (std.mem.eql(u8, argument, "--new-account")) {
        if (options.new_account != null) return error.DuplicateOption;
        options.new_account = try takeValue(argv, index);
    } else if (std.mem.eql(u8, argument, "--auth-dir")) {
        if (options.auth_dir != null) return error.DuplicateOption;
        options.auth_dir = try takeValue(argv, index);
    } else if (std.mem.eql(u8, argument, "--enable-plan")) {
        if (options.enable_plan) return error.DuplicateOption;
        options.enable_plan = true;
    } else if (std.mem.eql(u8, argument, "--no-browser")) {
        if (options.no_browser) return error.DuplicateOption;
        options.no_browser = true;
    } else if (std.mem.eql(u8, argument, "--json")) {
        if (options.json) return error.DuplicateOption;
        options.json = true;
    } else {
        return error.UnknownOption;
    }
}

fn takeValue(argv: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* == argv.len) return error.OptionValueRequired;
    const value = argv[index.*];
    if (value.len == 0 or std.mem.startsWith(u8, value, "--")) return error.OptionValueRequired;
    return value;
}

fn validateOptions(options: Options) !void {
    if (options.app.len == 0) return error.AppRequired;
    try siwc.store.validateLabel(options.app);
    if (options.account) |account| try siwc.store.validateLabel(account);
    if (options.new_account) |account| try siwc.store.validateLabel(account);
    if (options.command != .login and (options.enable_plan or options.no_browser))
        return error.LoginOptionNotAllowed;
    if (options.json and (options.command == .login or options.command == .exec))
        return error.JsonOptionNotAllowed;
    switch (options.command) {
        .login => {
            if (options.account == null and options.new_account == null)
                return error.AccountRequired;
            if (options.account != null and options.new_account != null)
                return error.ConflictingAccountSelection;
        },
        .accounts => {
            if (options.account != null or options.new_account != null)
                return error.UnexpectedAccountSelection;
        },
        else => {
            if (options.new_account != null) return error.NewAccountNotAllowed;
            if (options.account == null) return error.AccountRequired;
        },
    }
    if (options.command == .credential and !options.json) return error.JsonRequired;
    if (options.command == .exec and
        (options.child_argv.len == 0 or options.child_argv[0].len == 0))
        return error.ChildCommandRequired;
}

test "login selects an explicit app and exactly one account mode" {
    const fresh = try parse(&.{
        "siwc",     "login",         "--app",        "protean",    "--new-account",
        "personal", "--enable-plan", "--no-browser", "--auth-dir", "/tmp/private",
    });
    try std.testing.expectEqual(Command.login, fresh.command);
    try std.testing.expectEqualStrings("protean", fresh.app);
    try std.testing.expectEqualStrings("personal", fresh.new_account.?);
    try std.testing.expectEqualStrings("/tmp/private", fresh.auth_dir.?);
    try std.testing.expect(fresh.account == null and fresh.enable_plan and fresh.no_browser);
    const existing = try parse(&.{ "siwc", "login", "--app", "app", "--account", "work" });
    try std.testing.expectEqualStrings("work", existing.account.?);
    try std.testing.expect(existing.new_account == null);
}

test "account commands accept scoped JSON and exec preserves literal arguments" {
    const accounts = try parse(&.{ "siwc", "accounts", "--app", "app", "--json" });
    try std.testing.expectEqual(Command.accounts, accounts.command);
    try std.testing.expect(accounts.account == null and accounts.json);
    for ([_][]const u8{ "status", "models", "logout", "credential" }) |command| {
        const options = try parse(&.{
            "siwc", command, "--app", "app", "--account", "work", "--json",
        });
        try std.testing.expectEqualStrings("work", options.account.?);
        try std.testing.expect(options.json);
    }
    const literal = [_][]const u8{ "./my app", "--json", "", "$(printf hidden)", "--" };
    const prefix = [_][]const u8{
        "siwc", "exec", "--app", "app", "--account", "work", "--",
    };
    const argv = prefix ++ literal;
    const options = try parse(&argv);
    try std.testing.expectEqual(Command.exec, options.command);
    try std.testing.expectEqualDeep(&literal, options.child_argv);
}

test "parser rejects missing values unknown flags duplicates and unscoped commands" {
    try std.testing.expectError(error.CommandRequired, parse(&.{"siwc"}));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "siwc", "unknown" }));
    try std.testing.expectError(error.AppRequired, parse(&.{ "siwc", "accounts" }));
    try std.testing.expectError(error.OptionValueRequired, parse(&.{ "siwc", "login", "--app" }));
    try std.testing.expectError(error.OptionValueRequired, parse(&.{
        "siwc", "login", "--app", "--account", "work",
    }));
    try std.testing.expectError(error.UnknownOption, parse(&.{
        "siwc", "accounts", "--app=app",
    }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{
        "siwc", "accounts", "--app", "app", "--app", "other",
    }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{
        "siwc", "accounts", "--app", "app", "--json", "--json",
    }));
    try std.testing.expectError(error.InvalidLabel, parse(&.{
        "siwc", "accounts", "--app", "../app",
    }));
    try std.testing.expectError(error.InvalidArgument, parse(&.{ "siwc", "accounts\x00" }));
}

test "parser rejects invalid command option and account combinations" {
    try std.testing.expectError(error.AccountRequired, parse(&.{
        "siwc", "login", "--app", "app",
    }));
    try std.testing.expectError(error.ConflictingAccountSelection, parse(&.{
        "siwc", "login", "--app", "app", "--account", "a", "--new-account", "b",
    }));
    try std.testing.expectError(error.UnexpectedAccountSelection, parse(&.{
        "siwc", "accounts", "--app", "app", "--account", "a",
    }));
    try std.testing.expectError(error.NewAccountNotAllowed, parse(&.{
        "siwc", "status", "--app", "app", "--new-account", "a",
    }));
    for ([_][]const u8{ "--enable-plan", "--no-browser" }) |flag| {
        try std.testing.expectError(error.LoginOptionNotAllowed, parse(&.{
            "siwc", "status", "--app", "app", "--account", "a", flag,
        }));
    }
    try std.testing.expectError(error.JsonRequired, parse(&.{
        "siwc", "credential", "--app", "app", "--account", "a",
    }));
    try std.testing.expectError(error.JsonOptionNotAllowed, parse(&.{
        "siwc", "login", "--app", "app", "--account", "a", "--json",
    }));
    try std.testing.expectError(error.UnexpectedSeparator, parse(&.{
        "siwc", "accounts", "--app", "app", "--", "program",
    }));
    try std.testing.expectError(error.ChildCommandRequired, parse(&.{
        "siwc", "exec", "--app", "app", "--account", "a", "--",
    }));
    try std.testing.expectError(error.ChildCommandRequired, parse(&.{
        "siwc", "exec", "--app", "app", "--account", "a", "--", "",
    }));
}

test "argument counts and bytes accept their exact bounds and reject overflow" {
    var argv: [arguments_max + 1][]const u8 = undefined;
    @memset(&argv, "x");
    const prefix = [_][]const u8{
        "siwc", "exec", "--app", "app", "--account", "work", "--", "program",
    };
    @memcpy(argv[0..prefix.len], &prefix);
    _ = try parse(argv[0 .. arguments_max - 1]);
    _ = try parse(argv[0..arguments_max]);
    try std.testing.expectError(error.TooManyArguments, parse(&argv));
    var padding: [argument_bytes_max]u8 = undefined;
    @memset(&padding, 'x');
    var byte_argv = prefix ++ [_][]const u8{""};
    const prefix_bytes = 5 + 5 + 6 + 4 + 10 + 5 + 3 + 8 + 1;
    byte_argv[8] = padding[0 .. argument_bytes_max - prefix_bytes - 1];
    _ = try parse(&byte_argv);
    byte_argv[8] = padding[0 .. argument_bytes_max - prefix_bytes];
    _ = try parse(&byte_argv);
    byte_argv[8] = padding[0 .. argument_bytes_max - prefix_bytes + 1];
    try std.testing.expectError(error.ArgumentsTooLarge, parse(&byte_argv));
}
