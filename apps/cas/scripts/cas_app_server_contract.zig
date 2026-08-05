const std = @import("std");

pub const baseline_json = @import("cas_app_server_contract_data").json;

const max_methods = 256;
const max_shapes = 64;
const max_documents = 64;
const max_document_bytes = 8 * 1024 * 1024;

pub const Profile = enum { core, review, session_inquiry, full };
pub const Status = enum { compatible, incompatible };

pub const Document = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const SchemaBundle = struct {
    documents: []const Document,
};

pub const InspectionReport = struct {
    status: Status = .compatible,
    missing_required: std.ArrayList([]u8) = .empty,
    additive_client_methods: std.ArrayList([]u8) = .empty,
    additive_server_requests: std.ArrayList([]u8) = .empty,
    unclassified_server_requests: std.ArrayList([]u8) = .empty,
    additive_notifications: std.ArrayList([]u8) = .empty,
    shape_failures: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *InspectionReport, allocator: std.mem.Allocator) void {
        deinitStrings(&self.missing_required, allocator);
        deinitStrings(&self.additive_client_methods, allocator);
        deinitStrings(&self.additive_server_requests, allocator);
        deinitStrings(&self.unclassified_server_requests, allocator);
        deinitStrings(&self.additive_notifications, allocator);
        deinitStrings(&self.shape_failures, allocator);
    }
};

pub fn parseBaseline(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, baseline_json, .{});
    errdefer parsed.deinit();
    try validateBaseline(parsed.value);
    return parsed;
}

pub fn inspect(
    allocator: std.mem.Allocator,
    baseline: *const std.json.Value,
    stable: SchemaBundle,
    experimental: SchemaBundle,
    profile: Profile,
) !InspectionReport {
    var report: InspectionReport = .{};
    errdefer report.deinit(allocator);

    const stable_contract = try objectField(baseline.*, "stable");
    const experimental_contract = try objectField(baseline.*, "experimental");

    var stable_clients = try collectMethods(allocator, try documentBytes(stable, "ClientRequest.json"));
    defer stable_clients.deinit(allocator);
    var stable_servers = try collectMethods(allocator, try documentBytes(stable, "ServerRequest.json"));
    defer stable_servers.deinit(allocator);
    var stable_notifications = try collectMethods(allocator, try documentBytes(stable, "ServerNotification.json"));
    defer stable_notifications.deinit(allocator);
    var experimental_clients = try collectMethods(allocator, try documentBytes(experimental, "ClientRequest.json"));
    defer experimental_clients.deinit(allocator);
    var experimental_servers = try collectMethods(allocator, try documentBytes(experimental, "ServerRequest.json"));
    defer experimental_servers.deinit(allocator);
    var experimental_notifications = try collectMethods(allocator, try documentBytes(experimental, "ServerNotification.json"));
    defer experimental_notifications.deinit(allocator);

    const required_stable_clients = try arrayField(stable_contract, "requiredClientMethods");
    const required_stable_servers = try arrayField(stable_contract, "requiredServerRequests");
    const required_notifications = try arrayField(stable_contract, "requiredNotifications");
    const required_experimental_clients = try arrayField(experimental_contract, "requiredClientMethods");

    try compareRequired(allocator, required_stable_clients, stable_clients.items.items, &report.missing_required);
    try compareRequired(allocator, required_stable_servers, stable_servers.items.items, &report.missing_required);
    try compareRequired(allocator, required_notifications, stable_notifications.items.items, &report.missing_required);
    try compareRequired(allocator, required_notifications, experimental_notifications.items.items, &report.missing_required);
    try compareRequired(allocator, required_experimental_clients, experimental_clients.items.items, &report.missing_required);
    try collectAdditive(allocator, stable_clients.items.items, required_stable_clients, &report.additive_client_methods);
    try collectAdditive(allocator, experimental_clients.items.items, required_experimental_clients, &report.additive_client_methods);
    try collectAdditive(allocator, stable_notifications.items.items, required_notifications, &report.additive_notifications);
    try collectAdditive(allocator, experimental_notifications.items.items, required_notifications, &report.additive_notifications);

    const policies = try objectField(baseline.*, "serverRequestPolicies");
    try comparePolicyRequired(allocator, policies, experimental_servers.items.items, &report.missing_required);
    try classifyServerAdditions(allocator, stable_servers.items.items, required_stable_servers, policies, &report);
    try classifyExperimentalServerAdditions(allocator, experimental_servers.items.items, policies, &report);

    try inspectShapes(allocator, stable, try arrayField(stable_contract, "requiredShapes"), &report.shape_failures);
    try inspectShapes(allocator, experimental, try arrayField(experimental_contract, "requiredShapes"), &report.shape_failures);

    if (report.missing_required.items.len != 0 or report.shape_failures.items.len != 0 or
        (profile == .full and report.unclassified_server_requests.items.len != 0))
    {
        report.status = .incompatible;
    }
    return report;
}

fn validateBaseline(root: std.json.Value) !void {
    const object = switch (root) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    const keys = [_][]const u8{ "schema", "contractId", "minimumCodexVersion", "stable", "experimental", "serverRequestPolicies", "behavioralProbes" };
    if (object.count() != keys.len) return error.InvalidContract;
    for (keys) |key| if (!object.contains(key)) return error.InvalidContract;
    if (!std.mem.eql(u8, try stringField(root, "schema"), "cas-app-server-contract/v1")) return error.InvalidContract;
    if (!std.mem.eql(u8, try stringField(root, "contractId"), "codex-app-server-0.146.0")) return error.InvalidContract;
    if (!std.mem.eql(u8, try stringField(root, "minimumCodexVersion"), "0.146.0")) return error.InvalidContract;

    const stable = try objectField(root, "stable");
    const experimental = try objectField(root, "experimental");
    if ((try arrayField(stable, "requiredClientMethods")).items.len != 90) return error.InvalidContract;
    if ((try arrayField(stable, "requiredServerRequests")).items.len != 10) return error.InvalidContract;
    if ((try arrayField(stable, "requiredNotifications")).items.len != 70) return error.InvalidContract;
    if ((try arrayField(experimental, "requiredClientMethods")).items.len != 127) return error.InvalidContract;
    if ((try arrayField(stable, "requiredShapes")).items.len > max_shapes) return error.ContractTooLarge;
    if ((try arrayField(experimental, "requiredShapes")).items.len > max_shapes) return error.ContractTooLarge;
    try validateStringArray(try arrayField(stable, "requiredClientMethods"));
    try validateStringArray(try arrayField(stable, "requiredServerRequests"));
    try validateStringArray(try arrayField(stable, "requiredNotifications"));
    try validateStringArray(try arrayField(experimental, "requiredClientMethods"));

    const policies = try objectField(root, "serverRequestPolicies");
    for ((try arrayField(stable, "requiredServerRequests")).items) |item| {
        const method = switch (item) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        if (switch (policies) {
            .object => |value| !value.contains(method),
            else => true,
        }) return error.InvalidContract;
    }
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    if (policy_object.count() != 11) return error.InvalidContract;
    var policy_iterator = policy_object.iterator();
    while (policy_iterator.next()) |entry| {
        const policy = switch (entry.value_ptr.*) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        if (std.mem.trim(u8, policy, " \t\r\n").len == 0) return error.InvalidContract;
    }
    if (!policy_object.contains("currentTime/read")) return error.InvalidContract;
    const probes = try arrayField(root, "behavioralProbes");
    try validateStringArray(probes);
    if (probes.items.len != 15) return error.InvalidContract;
}

const MethodSet = struct {
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *MethodSet, allocator: std.mem.Allocator) void {
        deinitStrings(&self.items, allocator);
    }
};

fn collectMethods(allocator: std.mem.Allocator, raw: []const u8) !MethodSet {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const variants = try arrayField(parsed.value, "oneOf");
    if (variants.items.len > max_methods) return error.SchemaTooLarge;
    var methods: MethodSet = .{};
    errdefer methods.deinit(allocator);
    for (variants.items) |variant| {
        const properties = try objectField(variant, "properties");
        const method_schema = try objectField(properties, "method");
        const values = try arrayField(method_schema, "enum");
        if (values.items.len != 1) return error.InvalidMethodDiscriminator;
        const method = switch (values.items[0]) {
            .string => |value| value,
            else => return error.InvalidMethodDiscriminator,
        };
        if (contains(methods.items.items, method)) return error.DuplicateMethod;
        try methods.items.append(allocator, try allocator.dupe(u8, method));
    }
    return methods;
}

fn compareRequired(allocator: std.mem.Allocator, required: std.json.Array, actual: []const []u8, failures: *std.ArrayList([]u8)) !void {
    for (required.items) |item| {
        const method = switch (item) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        if (!contains(actual, method)) try appendUnique(allocator, failures, method);
    }
}

fn collectAdditive(allocator: std.mem.Allocator, actual: []const []u8, required: std.json.Array, output: *std.ArrayList([]u8)) !void {
    for (actual) |method| if (!jsonArrayContains(required, method)) try appendUnique(allocator, output, method);
}

fn classifyServerAdditions(
    allocator: std.mem.Allocator,
    actual: []const []u8,
    required: std.json.Array,
    policies: std.json.Value,
    report: *InspectionReport,
) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    for (actual) |method| {
        if (jsonArrayContains(required, method)) continue;
        try appendUnique(allocator, &report.additive_server_requests, method);
        if (!policy_object.contains(method)) try appendUnique(allocator, &report.unclassified_server_requests, method);
    }
}

fn classifyExperimentalServerAdditions(
    allocator: std.mem.Allocator,
    actual: []const []u8,
    policies: std.json.Value,
    report: *InspectionReport,
) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    for (actual) |method| {
        if (policy_object.contains(method)) continue;
        try appendUnique(allocator, &report.additive_server_requests, method);
        try appendUnique(allocator, &report.unclassified_server_requests, method);
    }
}

fn comparePolicyRequired(allocator: std.mem.Allocator, policies: std.json.Value, actual: []const []u8, failures: *std.ArrayList([]u8)) !void {
    const policy_object = switch (policies) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    var iterator = policy_object.iterator();
    while (iterator.next()) |entry| {
        if (!contains(actual, entry.key_ptr.*)) try appendUnique(allocator, failures, entry.key_ptr.*);
    }
}

fn inspectShapes(allocator: std.mem.Allocator, bundle: SchemaBundle, shapes: std.json.Array, failures: *std.ArrayList([]u8)) !void {
    if (bundle.documents.len > max_documents or shapes.items.len > max_shapes) return error.SchemaTooLarge;
    for (shapes.items) |shape| {
        const id = try stringField(shape, "id");
        const document = try stringField(shape, "document");
        const pointer = try stringField(shape, "pointer");
        const expected_kind = try stringField(shape, "kind");
        const expected_nullable = try boolField(shape, "nullable");
        const raw = documentBytes(bundle, document) catch {
            try appendUnique(allocator, failures, id);
            continue;
        };
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
            try appendUnique(allocator, failures, id);
            continue;
        };
        defer parsed.deinit();
        const node = resolveShapeNode(&parsed.value, shape, pointer) catch {
            try appendUnique(allocator, failures, id);
            continue;
        };
        if (!schemaHasKind(node.*, expected_kind) or schemaIsNullable(node.*) != expected_nullable or
            !requiredNamesPresent(shape, node.*) or !enumValuesPresent(shape, node.*))
        {
            try appendUnique(allocator, failures, id);
        }
    }
}

fn resolveShapeNode(root: *const std.json.Value, selector: std.json.Value, pointer: []const u8) !*const std.json.Value {
    const selector_object = switch (selector) {
        .object => |value| value,
        else => return error.InvalidContract,
    };
    const variant_pointer_value = selector_object.get("variantPointer") orelse return resolvePointer(root, pointer);
    const variant_pointer = switch (variant_pointer_value) {
        .string => |value| value,
        else => return error.InvalidContract,
    };
    const discriminator = try stringField(selector, "discriminator");
    const discriminator_value = try stringField(selector, "discriminatorValue");
    const variants_node = try resolvePointer(root, variant_pointer);
    const variants = switch (variants_node.*) {
        .array => |value| value,
        else => return error.InvalidContract,
    };
    for (variants.items) |*variant| {
        const variant_object = switch (variant.*) {
            .object => |value| value,
            else => continue,
        };
        const properties_value = variant_object.get("properties") orelse continue;
        const properties = switch (properties_value) {
            .object => |value| value,
            else => continue,
        };
        const discriminator_schema_value = properties.get(discriminator) orelse continue;
        const discriminator_schema = switch (discriminator_schema_value) {
            .object => |value| value,
            else => continue,
        };
        const enum_value = discriminator_schema.get("enum") orelse continue;
        const enum_values = switch (enum_value) {
            .array => |value| value,
            else => continue,
        };
        if (jsonArrayContains(enum_values, discriminator_value)) return resolvePointer(variant, pointer);
    }
    return error.MissingDiscriminatorVariant;
}

fn resolvePointer(root: *const std.json.Value, pointer: []const u8) !*const std.json.Value {
    if (pointer.len == 0) return root;
    if (pointer[0] != '/') return error.InvalidPointer;
    var current = root;
    var segments = std.mem.splitScalar(u8, pointer[1..], '/');
    while (segments.next()) |segment| {
        if (std.mem.indexOfScalar(u8, segment, '~') != null) return error.InvalidPointer;
        current = switch (current.*) {
            .object => |object| object.getPtr(segment) orelse return error.MissingShape,
            .array => |array| blk: {
                const index = try std.fmt.parseUnsigned(usize, segment, 10);
                if (index >= array.items.len) return error.MissingShape;
                break :blk &array.items[index];
            },
            else => return error.MissingShape,
        };
    }
    return current;
}

fn schemaHasKind(value: std.json.Value, expected: []const u8) bool {
    const object = switch (value) {
        .object => |item| item,
        else => return false,
    };
    if (std.mem.eql(u8, expected, "ref")) {
        if (object.get("$ref") != null) return true;
        return unionHasRef(object.get("anyOf")) or unionHasRef(object.get("oneOf"));
    }
    if (object.get("type")) |type_value| switch (type_value) {
        .string => |kind| if (std.mem.eql(u8, kind, expected)) return true,
        .array => |kinds| for (kinds.items) |kind_value| switch (kind_value) {
            .string => |kind| if (std.mem.eql(u8, kind, expected)) return true,
            else => {},
        },
        else => {},
    };
    return unionHasKind(object.get("anyOf"), expected) or unionHasKind(object.get("oneOf"), expected);
}

fn unionHasRef(value: ?std.json.Value) bool {
    const variants = switch (value orelse return false) {
        .array => |items| items,
        else => return false,
    };
    for (variants.items) |variant| {
        const object = switch (variant) {
            .object => |item| item,
            else => continue,
        };
        if (object.get("$ref") != null) return true;
    }
    return false;
}

fn schemaIsNullable(value: std.json.Value) bool {
    return schemaHasKind(value, "null");
}

fn unionHasKind(value: ?std.json.Value, expected: []const u8) bool {
    const variants = switch (value orelse return false) {
        .array => |items| items,
        else => return false,
    };
    for (variants.items) |variant| {
        const object = switch (variant) {
            .object => |item| item,
            else => continue,
        };
        const type_value = object.get("type") orelse continue;
        if (switch (type_value) {
            .string => |kind| std.mem.eql(u8, kind, expected),
            else => false,
        }) return true;
    }
    return false;
}

fn requiredNamesPresent(selector: std.json.Value, schema: std.json.Value) bool {
    const selector_object = switch (selector) {
        .object => |value| value,
        else => return false,
    };
    const expected = selector_object.get("required") orelse return true;
    const expected_array = switch (expected) {
        .array => |value| value,
        else => return false,
    };
    const schema_object = switch (schema) {
        .object => |value| value,
        else => return false,
    };
    const actual = schema_object.get("required") orelse return false;
    const actual_array = switch (actual) {
        .array => |value| value,
        else => return false,
    };
    for (expected_array.items) |item| {
        const name = switch (item) {
            .string => |value| value,
            else => return false,
        };
        if (!jsonArrayContains(actual_array, name)) return false;
    }
    return true;
}

fn enumValuesPresent(selector: std.json.Value, schema: std.json.Value) bool {
    const selector_object = switch (selector) {
        .object => |value| value,
        else => return false,
    };
    const expected = selector_object.get("enumContains") orelse return true;
    const expected_array = switch (expected) {
        .array => |value| value,
        else => return false,
    };
    const schema_object = switch (schema) {
        .object => |value| value,
        else => return false,
    };
    const actual = schema_object.get("enum") orelse return false;
    const actual_array = switch (actual) {
        .array => |value| value,
        else => return false,
    };
    for (expected_array.items) |item| {
        const name = switch (item) {
            .string => |value| value,
            else => return false,
        };
        if (!jsonArrayContains(actual_array, name)) return false;
    }
    return true;
}

fn documentBytes(bundle: SchemaBundle, name: []const u8) ![]const u8 {
    if (bundle.documents.len > max_documents) return error.SchemaTooLarge;
    for (bundle.documents) |document| if (std.mem.eql(u8, document.name, name)) {
        if (document.bytes.len > max_document_bytes) return error.SchemaTooLarge;
        return document.bytes;
    };
    return error.MissingSchemaDocument;
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidJsonShape,
    };
    return object.get(name) orelse error.InvalidJsonShape;
}

fn arrayField(value: std.json.Value, name: []const u8) !std.json.Array {
    return switch (try objectField(value, name)) {
        .array => |item| item,
        else => error.InvalidJsonShape,
    };
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    return switch (try objectField(value, name)) {
        .string => |item| item,
        else => error.InvalidJsonShape,
    };
}

fn boolField(value: std.json.Value, name: []const u8) !bool {
    return switch (try objectField(value, name)) {
        .bool => |item| item,
        else => error.InvalidJsonShape,
    };
}

fn validateStringArray(array: std.json.Array) !void {
    if (array.items.len > max_methods) return error.ContractTooLarge;
    for (array.items, 0..) |item, index| {
        const text = switch (item) {
            .string => |value| value,
            else => return error.InvalidContract,
        };
        for (array.items[0..index]) |prior| if (switch (prior) {
            .string => |value| std.mem.eql(u8, text, value),
            else => false,
        }) return error.InvalidContract;
    }
}

fn jsonArrayContains(array: std.json.Array, needle: []const u8) bool {
    for (array.items) |item| if (switch (item) {
        .string => |value| std.mem.eql(u8, value, needle),
        else => false,
    }) return true;
    return false;
}

fn contains(items: []const []u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    if (!contains(list.items, value)) try list.append(allocator, try allocator.dupe(u8, value));
}

fn deinitStrings(list: *std.ArrayList([]u8), allocator: std.mem.Allocator) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

const stable_shapes =
    \\{"definitions":{"InitializeCapabilities":{"properties":{"experimentalApi":{"type":"boolean"},"optOutNotificationMethods":{"type":["array","null"]},"mcpServerOpenaiFormElicitation":{"type":"boolean"}}},"Thread":{"properties":{"isPinned":{"type":"boolean","future":true},"path":{"type":["string","null"]}}},"ThreadMetadataUpdateParams":{"properties":{"isPinned":{"type":["boolean","null"]}}},"ThreadListParams":{"properties":{"isPinned":{"type":["boolean","null"]}}},"ThreadForkParams":{"properties":{"lastTurnId":{"type":["string","null"]},"ephemeral":{"type":"boolean"}}},"ThreadItem":{"oneOf":[{"properties":{"type":{"enum":["commandExecution"]},"pluginId":{"type":["string","null"]},"scriptPath":{"type":["string","null"]}}}]},"PathUri":{"type":"string"},"SkillInterface":{"properties":{"iconSmallUrl":{"type":["string","null"]},"iconLargeUrl":{"type":["string","null"]}}},"PluginListParams":{"properties":{"forceRefetch":{"type":"boolean"}}},"PluginShareContext":{"properties":{"canPublishToWorkspace":{"type":["boolean","null"]}}},"PluginShareSaveResponse":{"properties":{"canPublishToWorkspace":{"type":["boolean","null"]}}},"AppToolSummary":{"properties":{"isEnabled":{"type":"boolean"},"disabledReason":{"type":["string","null"]},"isReadOnly":{"type":"boolean"}}},"ConfigRequirements":{"properties":{"browserUse":{"anyOf":[{"$ref":"#/definitions/BrowserUseRequirements"},{"type":"null"}]},"sqliteHome":{"type":["string","null"]},"logDir":{"type":["string","null"]},"modelCatalogJson":{"type":["string","null"]},"checkForUpdateOnStartup":{"type":["boolean","null"]},"allowLoginShell":{"type":["boolean","null"]},"feedback":{"anyOf":[{"$ref":"#/definitions/FeedbackRequirements"},{"type":"null"}]},"windowsSandboxPrivateDesktop":{"type":["boolean","null"]}}},"ExternalAgentConfigDetectParams":{"properties":{"maxSessionAgeDays":{"type":["integer","null"]},"maxSessions":{"type":["integer","null"]}}},"ExternalAgentConfigImportParams":{"properties":{"providerId":{"type":["string","null"]}}},"PlanType":{"type":"string","enum":["ent26"]},"AppMetadata":{"type":"object","properties":{"name":{"type":"string"},"firstPartyType":{"type":"string"}}}}}
;

const experimental_shapes =
    \\{"definitions":{"ThreadForkParams":{"type":"object","required":["threadId"],"properties":{"beforeTurnId":{"type":["string","null"]},"ephemeral":{"type":"boolean"},"excludeTurns":{"type":"boolean"},"deferGoalContinuation":{"type":"boolean"}}}}}
;

const TestBundles = struct {
    stable_client: []u8,
    stable_server: []u8,
    stable_notification: []u8,
    experimental_client: []u8,
    experimental_server: []u8,
    experimental_notification: []u8,

    fn deinit(self: *TestBundles, allocator: std.mem.Allocator) void {
        allocator.free(self.stable_client);
        allocator.free(self.stable_server);
        allocator.free(self.stable_notification);
        allocator.free(self.experimental_client);
        allocator.free(self.experimental_server);
        allocator.free(self.experimental_notification);
    }
};

fn methodSchema(allocator: std.mem.Allocator, methods: std.json.Array) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"oneOf\":[");
    for (methods.items, 0..) |method, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"properties\":{\"method\":{\"enum\":[");
        try std.json.Stringify.value(switch (method) {
            .string => |value| value,
            else => return error.InvalidContract,
        }, .{}, &output.writer);
        try output.writer.writeAll("]}}}");
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn makeTestBundles(allocator: std.mem.Allocator, baseline: std.json.Value) !TestBundles {
    const stable = try objectField(baseline, "stable");
    const experimental = try objectField(baseline, "experimental");
    const experimental_server_base = try methodSchema(allocator, try arrayField(stable, "requiredServerRequests"));
    defer allocator.free(experimental_server_base);
    const current_time_addition = ",{\"properties\":{\"method\":{\"enum\":[\"currentTime/read\"]}}}]}";
    return .{
        .stable_client = try methodSchema(allocator, try arrayField(stable, "requiredClientMethods")),
        .stable_server = try methodSchema(allocator, try arrayField(stable, "requiredServerRequests")),
        .stable_notification = try methodSchema(allocator, try arrayField(stable, "requiredNotifications")),
        .experimental_client = try methodSchema(allocator, try arrayField(experimental, "requiredClientMethods")),
        .experimental_server = try std.mem.concat(allocator, u8, &.{ experimental_server_base[0 .. experimental_server_base.len - 2], current_time_addition }),
        .experimental_notification = try methodSchema(allocator, try arrayField(stable, "requiredNotifications")),
    };
}

fn inspectTestBundles(allocator: std.mem.Allocator, baseline: *const std.json.Value, bundles: *const TestBundles, stable_shape_doc: []const u8, experimental_shape_doc: []const u8) !InspectionReport {
    const stable_docs = [_]Document{
        .{ .name = "ClientRequest.json", .bytes = bundles.stable_client },
        .{ .name = "ServerRequest.json", .bytes = bundles.stable_server },
        .{ .name = "ServerNotification.json", .bytes = bundles.stable_notification },
        .{ .name = "codex_app_server_protocol.v2.schemas.json", .bytes = stable_shape_doc },
    };
    const experimental_docs = [_]Document{
        .{ .name = "ClientRequest.json", .bytes = bundles.experimental_client },
        .{ .name = "ServerRequest.json", .bytes = bundles.experimental_server },
        .{ .name = "ServerNotification.json", .bytes = bundles.experimental_notification },
    };
    const experimental_docs_with_shapes = [_]Document{
        experimental_docs[0], experimental_docs[1], experimental_docs[2],
    };
    var adjusted = experimental_docs_with_shapes;
    adjusted[0].bytes = try mergeDefinitionsIntoMethodSchema(allocator, bundles.experimental_client, experimental_shape_doc);
    defer allocator.free(adjusted[0].bytes);
    return inspect(allocator, baseline, .{ .documents = &stable_docs }, .{ .documents = &adjusted }, .full);
}

fn mergeDefinitionsIntoMethodSchema(allocator: std.mem.Allocator, methods: []const u8, definitions: []const u8) ![]u8 {
    if (methods.len < 2 or definitions.len < 2) return error.InvalidJsonShape;
    return std.fmt.allocPrint(allocator, "{{\"definitions\":{s},\"oneOf\":{s}", .{ definitions[15 .. definitions.len - 1], methods[9..] });
}

test "baseline method-set cardinalities and exact compatible bundles" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, stable_shapes, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.compatible, report.status);
    try std.testing.expectEqual(@as(usize, 0), report.additive_server_requests.items.len);
}

test "additive client notification and object fields remain compatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const client_addition = ",{\"properties\":{\"method\":{\"enum\":[\"future/client\"]}}}]}";
    const notification_addition = ",{\"properties\":{\"method\":{\"enum\":[\"future/notification\"]}}}]}";
    const experimental_notification_addition = ",{\"properties\":{\"method\":{\"enum\":[\"future/experimental-notification\"]}}}]}";
    const old_client = bundles.stable_client;
    const old_notification = bundles.stable_notification;
    const old_experimental_notification = bundles.experimental_notification;
    bundles.stable_client = try std.mem.concat(std.testing.allocator, u8, &.{ old_client[0 .. old_client.len - 2], client_addition });
    bundles.stable_notification = try std.mem.concat(std.testing.allocator, u8, &.{ old_notification[0 .. old_notification.len - 2], notification_addition });
    bundles.experimental_notification = try std.mem.concat(std.testing.allocator, u8, &.{ old_experimental_notification[0 .. old_experimental_notification.len - 2], experimental_notification_addition });
    std.testing.allocator.free(old_client);
    std.testing.allocator.free(old_notification);
    std.testing.allocator.free(old_experimental_notification);
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, stable_shapes, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.compatible, report.status);
    try std.testing.expectEqual(@as(usize, 1), report.additive_client_methods.items.len);
    try std.testing.expectEqual(@as(usize, 2), report.additive_notifications.items.len);
}

test "missing required method and discriminator drift are incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const needle = "externalAgentConfig/import/recordHistory";
    const offset = std.mem.indexOf(u8, bundles.stable_client, needle) orelse return error.TestExpectedEqual;
    @memcpy(bundles.stable_client[offset .. offset + needle.len], "externalAgentConfig/import/recordHistorx");
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, stable_shapes, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expect(report.missing_required.items.len != 0);
}

test "required shape kind and nullability drift are incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const drifted = try std.testing.allocator.dupe(u8, stable_shapes);
    defer std.testing.allocator.free(drifted);
    const kind_needle = "\"isPinned\":{\"type\":\"boolean\"";
    const kind_offset = std.mem.indexOf(u8, drifted, kind_needle) orelse return error.TestExpectedEqual;
    @memcpy(drifted[kind_offset + kind_needle.len - 8 .. kind_offset + kind_needle.len - 1], "integer");
    const nullability_needle = "\"path\":{\"type\":[\"string\",\"null\"]}";
    const nullability_offset = std.mem.indexOf(u8, drifted, nullability_needle) orelse return error.TestExpectedEqual;
    const null_offset = nullability_offset + nullability_needle.len - 7;
    @memcpy(drifted[null_offset .. null_offset + 4], "bool");
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, drifted, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 2), report.shape_failures.items.len);
}

test "discriminated variant and required enum drift are incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const drifted = try std.testing.allocator.dupe(u8, stable_shapes);
    defer std.testing.allocator.free(drifted);
    const discriminator = "commandExecution";
    const discriminator_offset = std.mem.indexOf(u8, drifted, discriminator) orelse return error.TestExpectedEqual;
    drifted[discriminator_offset + discriminator.len - 1] = 'x';
    const plan = "ent26";
    const plan_offset = std.mem.indexOf(u8, drifted, plan) orelse return error.TestExpectedEqual;
    drifted[plan_offset + plan.len - 1] = '7';
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, drifted, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 3), report.shape_failures.items.len);
}

test "unclassified additive server request fails full profile" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const addition = ",{\"properties\":{\"method\":{\"enum\":[\"future/server\"]}}}]}";
    const old = bundles.experimental_server;
    bundles.experimental_server = try std.mem.concat(std.testing.allocator, u8, &.{ old[0 .. old.len - 2], addition });
    std.testing.allocator.free(old);
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, stable_shapes, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expectEqual(@as(usize, 1), report.unclassified_server_requests.items.len);
}

test "missing experimental current time request is incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const method = "currentTime/read";
    const offset = std.mem.indexOf(u8, bundles.experimental_server, method) orelse return error.TestExpectedEqual;
    bundles.experimental_server[offset + method.len - 1] = 'x';
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, stable_shapes, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expect(contains(report.missing_required.items, method));
}

test "missing experimental notification is incompatible" {
    var baseline = try parseBaseline(std.testing.allocator);
    defer baseline.deinit();
    var bundles = try makeTestBundles(std.testing.allocator, baseline.value);
    defer bundles.deinit(std.testing.allocator);
    const method = "error";
    const offset = std.mem.indexOf(u8, bundles.experimental_notification, method) orelse return error.TestExpectedEqual;
    bundles.experimental_notification[offset + method.len - 1] = 'x';
    var report = try inspectTestBundles(std.testing.allocator, &baseline.value, &bundles, stable_shapes, experimental_shapes);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.incompatible, report.status);
    try std.testing.expect(contains(report.missing_required.items, method));
}
