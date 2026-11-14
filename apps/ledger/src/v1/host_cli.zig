const std = @import("std");
const context = @import("host_context.zig");
const owner = @import("host_owner.zig");
const adoption = @import("host_adoption.zig");
const migration = @import("host_migration.zig");

const Help =
    \\usage:
    \\  ledger context --catalog-root <absolute-path>
    \\    [--workspace <absolute-path>] [--store-id <id>]
    \\    [--ensure | --initialize | --attach-workspace | --list-stores]
    \\    [--register-root <absolute-path> | --import-registration <absolute-path>]
    \\    [--legacy-path <relative-path>]... [--format json]
    \\  ledger context --catalog-root <absolute-path> [--workspace <absolute-path>]
    \\    [--store-id <id>] --ensure-owner|--reconcile-owner|--read-only|--repair-archive
    \\    --definition <absolute-path> --owner-manifest <absolute-path>
    \\    [--param <name>=<value>]... [--confirm-no-legacy-writers]
    \\  ledger context --catalog-root <absolute-path> --workspace <absolute-path>
    \\    --initialize --adopt-from <absolute-path> --definition <absolute-path>...
    \\    --confirm-no-writers
    \\  ledger context --catalog-root <absolute-path> --workspace <absolute-path>
    \\    --migrate --owner-manifest <absolute-path>...
    \\    [--apply --confirm-no-writers] [--framing-controls <absolute-path>]
    \\    [--owner-import-receipt <absolute-path>]...
    \\
    \\Context lookup is read-only by default. The caller supplies storage location.
    \\Ensure may adopt an existing registration; initialization is explicit.
    \\Registration retains the existing root, identity, history, and directory layout.
    \\Owner ensure admits healthy managed history or prepares a missing owner.
    \\Owner reconciliation additionally checks discovered source-family coverage.
    \\Historical migration inspects by default; retired conversion stays with its owner.
    \\
;

const Mode = enum {
    resolve,
    ensure,
    initialize,
    attach,
    list,
    register,
    import_registration,
    owner_read,
    owner_ensure,
    owner_reconcile,
    archive_repair,
    migrate,
};

const Args = struct {
    options: context.Options,
    mode: Mode = .resolve,
    path: ?[]const u8 = null,
    legacy_paths: []const []const u8 = &.{},
    definition: ?[]const u8 = null,
    definitions: []const []const u8 = &.{},
    adopt_from: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
    manifests: []const []const u8 = &.{},
    import_receipts: []const []const u8 = &.{},
    parameters: []const []const u8 = &.{},
    framing_controls: ?[]const u8 = null,
    apply: bool = false,
    confirm_no_writers: bool = false,

    fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        allocator.free(self.legacy_paths);
        allocator.free(self.definitions);
        allocator.free(self.manifests);
        allocator.free(self.import_receipts);
        allocator.free(self.parameters);
        self.* = undefined;
    }

    fn mutating(self: *const Args) bool {
        if (self.mode == .migrate) return self.apply;
        return self.mode != .resolve and self.mode != .list and self.mode != .owner_read;
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    if (argv.len == 1 and (std.mem.eql(u8, argv[0], "--help") or
        std.mem.eql(u8, argv[0], "-h")))
    {
        try emit(io, Help);
        return 0;
    }
    var args = parse(allocator, argv) catch |err| {
        try emitError(io, err, false);
        return 3;
    };
    defer args.deinit(allocator);
    if (args.mode == .migrate) {
        var result = try migration.execute(allocator, io, environment, .{
            .context = args.options,
            .manifests = args.manifests,
            .apply = args.apply,
            .confirm_no_writers = args.confirm_no_writers,
            .framing_controls = args.framing_controls,
            .import_receipts = args.import_receipts,
        });
        defer result.deinit();
        try emitJson(io, result.value);
        return result.exit_code;
    }
    if (args.adopt_from) |source| {
        var result = adoption.execute(
            allocator,
            io,
            environment,
            args.options,
            source,
            args.definitions,
            args.confirm_no_writers,
        ) catch |err| {
            try emitError(io, err, null);
            return 3;
        };
        defer result.deinit();
        try emitJson(io, result.value);
        return 0;
    }
    if (args.definition) |definition| {
        var result = try owner.execute(allocator, io, environment, .{
            .context = args.options,
            .definition = definition,
            .manifest = args.manifest.?,
            .parameters = args.parameters,
            .ensure = args.mode != .owner_read,
            .reconcile = args.mode == .owner_reconcile,
            .repair_archive = args.mode == .archive_repair,
            .confirm_no_writers = args.confirm_no_writers,
        });
        defer result.deinit();
        try emitJson(io, result.value);
        return result.exit_code;
    }
    selected(allocator, io, environment, args) catch |err| {
        try emitError(io, err, if (args.mutating()) null else false);
        return 3;
    };
    return 0;
}

fn selected(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    args: Args,
) !void {
    if (args.mode == .list) {
        var result = try context.list(allocator, io, args.options.catalog_root);
        defer result.deinit();
        return emitJson(io, result.value);
    }
    var result = switch (args.mode) {
        .resolve => try context.resolve(allocator, io, environment, args.options),
        .ensure => try context.ensure(allocator, io, environment, args.options),
        .initialize => try context.initialize(allocator, io, environment, args.options),
        .attach => try context.attach(allocator, io, environment, args.options),
        .register => try context.registerRoot(
            allocator,
            io,
            environment,
            args.options,
            args.path.?,
            args.options.store_id.?,
        ),
        .import_registration => try context.importRegistration(
            allocator,
            io,
            environment,
            args.options,
            args.path.?,
        ),
        .list,
        .owner_read,
        .owner_ensure,
        .owner_reconcile,
        .archive_repair,
        .migrate,
        => unreachable,
    };
    defer result.deinit();
    try emitJson(io, result.value);
}

const Parsing = struct {
    args: Args = .{ .options = .{ .catalog_root = "" } },
    selected_mode: bool = false,
    legacy_paths: std.ArrayList([]const u8) = .empty,
    definitions: std.ArrayList([]const u8) = .empty,
    manifests: std.ArrayList([]const u8) = .empty,
    import_receipts: std.ArrayList([]const u8) = .empty,
    parameters: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Parsing, allocator: std.mem.Allocator) void {
        self.legacy_paths.deinit(allocator);
        self.definitions.deinit(allocator);
        self.manifests.deinit(allocator);
        self.import_receipts.deinit(allocator);
        self.parameters.deinit(allocator);
    }

    fn flag(self: *Parsing, name: []const u8) !bool {
        if (std.mem.eql(u8, name, "--confirm-no-legacy-writers") or
            std.mem.eql(u8, name, "--confirm-no-writers"))
        {
            self.args.confirm_no_writers = true;
            return true;
        }
        if (std.mem.eql(u8, name, "--apply")) {
            self.args.apply = true;
            return true;
        }
        const mode = modes.get(name) orelse return false;
        if (self.selected_mode) return error.ConflictingContextModes;
        self.selected_mode = true;
        self.args.mode = mode;
        return mode != .register and mode != .import_registration;
    }

    fn option(
        self: *Parsing,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
    ) !void {
        if (std.mem.eql(u8, name, "--catalog-root")) {
            self.args.options.catalog_root = value;
        } else if (std.mem.eql(u8, name, "--definition")) {
            self.args.definition = value;
            try append(allocator, &self.definitions, value);
        } else if (std.mem.eql(u8, name, "--adopt-from")) {
            self.args.adopt_from = value;
        } else if (std.mem.eql(u8, name, "--owner-manifest")) {
            self.args.manifest = value;
            try append(allocator, &self.manifests, value);
        } else if (std.mem.eql(u8, name, "--owner-import-receipt")) {
            try append(allocator, &self.import_receipts, value);
        } else if (std.mem.eql(u8, name, "--framing-controls")) {
            self.args.framing_controls = value;
        } else if (std.mem.eql(u8, name, "--param")) {
            try append(allocator, &self.parameters, value);
        } else if (std.mem.eql(u8, name, "--workspace")) {
            self.args.options.workspace = value;
        } else if (std.mem.eql(u8, name, "--store-id")) {
            self.args.options.store_id = value;
        } else if (std.mem.eql(u8, name, "--legacy-path")) {
            try append(allocator, &self.legacy_paths, value);
        } else if (modes.has(name)) {
            self.args.path = value;
        } else if (std.mem.eql(u8, name, "--format")) {
            if (!std.mem.eql(u8, value, "json")) return error.UnsupportedFormat;
        } else return error.UnknownOption;
    }

    fn validate(self: *const Parsing) !void {
        const args = self.args;
        const mode = args.mode;
        if (args.options.catalog_root.len == 0) return error.MissingCatalogRoot;
        if (!std.fs.path.isAbsolute(args.options.catalog_root)) return error.CatalogRootNotAbsolute;
        if (mode == .list and (args.options.workspace != null or args.options.store_id != null))
            return error.ListDoesNotAcceptSelectors;
        if (mode == .register and args.options.store_id == null) return error.MissingStoreIdentity;
        if (mode == .import_registration and args.options.store_id != null)
            return error.ImportRegistrationProvidesStoreIdentity;
        if (mode == .owner_reconcile and args.options.workspace == null)
            return error.ReconciliationRequiresWorkspace;
        if (self.legacy_paths.items.len != 0 and mode != .initialize)
            return error.LegacyPathsRequireInitialization;
        const owner_mode = mode == .owner_read or mode == .owner_ensure or
            mode == .owner_reconcile or mode == .archive_repair;
        if (mode != .migrate and
            (args.apply or args.framing_controls != null or self.import_receipts.items.len != 0))
            return error.MigrationOptionsRequireMigration;
        if (mode == .migrate) {
            if (self.manifests.items.len == 0 or args.definition != null or
                args.adopt_from != null or self.parameters.items.len != 0)
                return error.InvalidMigrationSelection;
            if (args.confirm_no_writers and !args.apply) return error.QuiescenceRequiresPreparation;
        } else if (args.adopt_from != null) {
            if (mode != .initialize or args.options.workspace == null or
                self.definitions.items.len == 0 or !args.confirm_no_writers or
                args.manifest != null or self.parameters.items.len != 0)
                return error.InvalidColdAdoptionSelection;
        } else {
            if (owner_mode != (args.definition != null) or owner_mode != (args.manifest != null))
                return error.OwnerSelectionRequiresDefinitionAndManifest;
            if (self.manifests.items.len > 1) return error.OwnerSelectionRequiresOneManifest;
            if (!owner_mode and self.parameters.items.len != 0) return error.ParametersRequireOwner;
            if (self.definitions.items.len > 1) return error.OwnerSelectionRequiresOneDefinition;
            if (args.confirm_no_writers and mode != .owner_ensure and
                mode != .owner_reconcile and mode != .archive_repair)
                return error.QuiescenceRequiresPreparation;
        }
    }

    fn finish(self: *Parsing, allocator: std.mem.Allocator) !Args {
        try self.validate();
        var result = self.args;
        errdefer result.deinit(allocator);
        result.legacy_paths = try self.legacy_paths.toOwnedSlice(allocator);
        result.options.legacy_paths = result.legacy_paths;
        result.definitions = try self.definitions.toOwnedSlice(allocator);
        result.manifests = try self.manifests.toOwnedSlice(allocator);
        result.import_receipts = try self.import_receipts.toOwnedSlice(allocator);
        result.parameters = try self.parameters.toOwnedSlice(allocator);
        return result;
    }
};

const modes = std.StaticStringMap(Mode).initComptime(.{
    .{ "--migrate", .migrate },
    .{ "--ensure-owner", .owner_ensure },
    .{ "--reconcile-owner", .owner_reconcile },
    .{ "--read-only", .owner_read },
    .{ "--repair-archive", .archive_repair },
    .{ "--ensure", .ensure },
    .{ "--initialize", .initialize },
    .{ "--attach-workspace", .attach },
    .{ "--list-stores", .list },
    .{ "--register-root", .register },
    .{ "--import-registration", .import_registration },
});

fn append(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    if (list.items.len == 128) return error.TooManyOptionValues;
    try list.append(allocator, value);
}

fn repeatable(name: []const u8) bool {
    return std.mem.eql(u8, name, "--legacy-path") or std.mem.eql(u8, name, "--definition") or
        std.mem.eql(u8, name, "--owner-manifest") or
        std.mem.eql(u8, name, "--owner-import-receipt") or
        std.mem.eql(u8, name, "--param");
}

fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var state: Parsing = .{};
    defer state.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const name = argv[index];
        if (!repeatable(name)) {
            if (seen.contains(name)) return error.DuplicateOption;
            try seen.put(allocator, name, {});
        }
        if (try state.flag(name)) continue;
        index += 1;
        if (index == argv.len) return error.MissingOptionValue;
        try state.option(allocator, name, argv[index]);
    }
    return state.finish(allocator);
}

pub fn emitJson(io: std.Io, value: anytype) !void {
    var writer = std.Io.File.stdout().writer(io, &.{});
    try std.json.Stringify.value(value, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn emit(io: std.Io, bytes: []const u8) !void {
    var writer = std.Io.File.stdout().writer(io, &.{});
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn emitError(io: std.Io, err: anyerror, mutated: ?bool) !void {
    try emitJson(io, .{
        .schema = "ledger-workspace-context-error/v1",
        .status = "blocked",
        .error_code = @errorName(err),
        .storage_mutated = mutated,
        .authority_granted = false,
    });
}

test "context CLI requires explicit location and effect selection" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingCatalogRoot, parse(allocator, &.{}));
    try std.testing.expectError(error.CatalogRootNotAbsolute, parse(allocator, &.{
        "--catalog-root", "relative",
    }));
    try std.testing.expectError(error.ConflictingContextModes, parse(allocator, &.{
        "--catalog-root", "/explicit", "--initialize", "--ensure",
    }));
    var args = try parse(allocator, &.{ "--catalog-root", "/explicit", "--workspace", "/work" });
    defer args.deinit(allocator);
    try std.testing.expectEqual(Mode.resolve, args.mode);
    try std.testing.expect(!args.mutating());
}

test "owner reconciliation requires an explicit source workspace" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ReconciliationRequiresWorkspace, parse(allocator, &.{
        "--catalog-root",         "/explicit",
        "--store-id",             "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--reconcile-owner",      "--definition",
        "/owner/definition.json", "--owner-manifest",
        "/owner/migration.json",
    }));
    var args = try parse(allocator, &.{
        "--catalog-root",         "/explicit",
        "--workspace",            "/work",
        "--store-id",             "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "--reconcile-owner",      "--definition",
        "/owner/definition.json", "--owner-manifest",
        "/owner/migration.json",
    });
    defer args.deinit(allocator);
    try std.testing.expectEqual(Mode.owner_reconcile, args.mode);
    try std.testing.expect(args.mutating());
}

test {
    _ = context;
    _ = owner;
    _ = adoption;
    _ = migration;
    _ = @import("host_pending.zig");
    _ = @import("host_sources.zig");
    _ = @import("host_legacy.zig");
}
