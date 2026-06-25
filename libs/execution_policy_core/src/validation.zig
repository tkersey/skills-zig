const std = @import("std");
const atom = @import("atom.zig");
const condition = @import("condition.zig");
const errors = @import("errors.zig");
const schema = @import("schema.zig");

pub fn validatePolicy(allocator: std.mem.Allocator, policy: *const schema.Policy) !errors.ValidationReport {
    var validator = Validator.init(allocator);
    defer validator.deinit();
    try validator.validate(policy);
    return validator.finish();
}

const Validator = struct {
    allocator: std.mem.Allocator,
    builder: errors.Builder,
    declared_atoms: std.ArrayList([]const u8) = .empty,
    custom_authority_atoms: std.ArrayList([]const u8) = .empty,
    action_ids: std.ArrayList([]const u8) = .empty,
    rollback_action_ids: std.ArrayList([]const u8) = .empty,
    selected_action_ids: std.ArrayList([]const u8) = .empty,
    rollback_referenced_ids: std.ArrayList([]const u8) = .empty,
    shielded_action_ids: std.ArrayList([]const u8) = .empty,
    observation_ids: std.ArrayList([]const u8) = .empty,
    terminal_ids: std.ArrayList([]const u8) = .empty,
    obligation_ids: std.ArrayList([]const u8) = .empty,
    dimension_ids: std.ArrayList([]const u8) = .empty,
    condition_atoms: std.ArrayList([]u8) = .empty,
    saw_reference_error: bool = false,
    saw_graph_error: bool = false,
    saw_atom_error: bool = false,
    saw_obligation_error: bool = false,
    saw_unknown_error: bool = false,
    saw_safety_error: bool = false,

    fn init(allocator: std.mem.Allocator) Validator {
        return .{
            .allocator = allocator,
            .builder = errors.Builder.init(allocator),
        };
    }

    fn deinit(self: *Validator) void {
        self.builder.deinit();
        self.declared_atoms.deinit(self.allocator);
        self.custom_authority_atoms.deinit(self.allocator);
        self.action_ids.deinit(self.allocator);
        self.rollback_action_ids.deinit(self.allocator);
        self.selected_action_ids.deinit(self.allocator);
        self.rollback_referenced_ids.deinit(self.allocator);
        self.shielded_action_ids.deinit(self.allocator);
        self.observation_ids.deinit(self.allocator);
        self.terminal_ids.deinit(self.allocator);
        self.obligation_ids.deinit(self.allocator);
        self.dimension_ids.deinit(self.allocator);
        for (self.condition_atoms.items) |item| self.allocator.free(item);
        self.condition_atoms.deinit(self.allocator);
        self.* = undefined;
    }

    fn finish(self: *Validator) !errors.ValidationReport {
        return self.builder.finish();
    }

    fn validate(self: *Validator, policy: *const schema.Policy) !void {
        if (policy.root() != .object) {
            try self.add(.schema_invalid, "$");
            return;
        }
        const root = policy.root().object;

        try self.requireString(root, "policy_id", "$.policy_id");
        try self.requireInteger(root, "revision", "$.revision");

        try self.gatherCustomAuthority(root);
        try self.validateDeclaredAtoms(root);
        try self.validateObservations(root);
        try self.validateTerminals(root);
        try self.validatePotential(root);
        try self.validateActions(root);
        try self.validateObligations(root);
        try self.validateShield(root);
        try self.validateRules(root);
        try self.validateUnknowns(root);
        try self.validateActionReferences(root);
        try self.validateActionCycles(root);
        try self.validateActionReachability();
        try self.validateRollbackReachability();
        try self.validateOutcomeClosure(root);
        try self.validateReadiness(root);
    }

    fn gatherCustomAuthority(self: *Validator, root: std.json.ObjectMap) !void {
        try self.gatherCustomAuthorityArray(root.get("safety_invariants"), "$.safety_invariants");
        try self.gatherCustomAuthorityArray(root.get("forbidden_states"), "$.forbidden_states");
    }

    fn gatherCustomAuthorityArray(self: *Validator, maybe_value: ?std.json.Value, base_path: []const u8) !void {
        const value = maybe_value orelse return;
        if (value != .array) {
            try self.add(.schema_invalid, base_path);
            return;
        }
        for (value.array.items, 0..) |row, index| {
            if (row != .object) {
                try self.addIndex(.schema_invalid, base_path, index, "");
                continue;
            }
            const atoms_value = row.object.get("custom_atoms") orelse continue;
            if (atoms_value != .array) {
                try self.addIndex(.schema_invalid, base_path, index, ".custom_atoms");
                continue;
            }
            for (atoms_value.array.items, 0..) |item, atom_index| {
                if (item != .string) {
                    try self.addIndex2(.schema_invalid, base_path, index, ".custom_atoms", atom_index, "");
                    continue;
                }
                try self.custom_authority_atoms.append(self.allocator, item.string);
            }
        }
    }

    fn validateDeclaredAtoms(self: *Validator, root: std.json.ObjectMap) !void {
        const atoms_value = root.get("declared_atoms") orelse {
            try self.add(.schema_invalid, "$.declared_atoms");
            return;
        };
        if (atoms_value != .array) {
            try self.add(.schema_invalid, "$.declared_atoms");
            return;
        }
        for (atoms_value.array.items, 0..) |item, index| {
            if (item != .string) {
                try self.addIndex(.schema_invalid, "$.declared_atoms", index, "");
                continue;
            }
            const parsed = atom.parse(item.string) catch {
                try self.addIndex(.atom_invalid, "$.declared_atoms", index, "");
                self.saw_atom_error = true;
                continue;
            };
            if (contains(self.declared_atoms.items, item.string)) {
                try self.addIndex(.id_duplicate, "$.declared_atoms", index, "");
                continue;
            }
            if (parsed.kind == .custom and !contains(self.custom_authority_atoms.items, item.string)) {
                try self.addIndex(.atom_unknown, "$.declared_atoms", index, "");
                self.saw_atom_error = true;
            }
            try self.declared_atoms.append(self.allocator, item.string);
        }
    }

    fn validateObservations(self: *Validator, root: std.json.ObjectMap) !void {
        const observations = root.get("observations") orelse return;
        if (observations != .array) {
            try self.add(.schema_invalid, "$.observations");
            return;
        }
        for (observations.array.items, 0..) |row, index| {
            const obj = try self.objectAt(row, "$.observations", index) orelse continue;
            const id = try self.requiredStringAt(obj, "id", "$.observations", index) orelse continue;
            try self.validateStableId(id, "$.observations", index, ".id");
            try self.appendUnique(&self.observation_ids, id, "$.observations", index);
            if (obj.get("outcomes")) |outcomes| {
                try self.requireStringArray(outcomes, "$.observations", index, ".outcomes");
                if (outcomes == .array) {
                    for (outcomes.array.items, 0..) |outcome, outcome_index| {
                        if (outcome != .string) continue;
                        atom.validateStableId(outcome.string) catch {
                            try self.addIndex2(.atom_invalid, "$.observations", index, ".outcomes", outcome_index, "");
                            self.saw_atom_error = true;
                        };
                    }
                }
            }
        }
    }

    fn validateTerminals(self: *Validator, root: std.json.ObjectMap) !void {
        const terminals = root.get("terminals") orelse return;
        if (terminals != .array) {
            try self.add(.schema_invalid, "$.terminals");
            return;
        }
        for (terminals.array.items, 0..) |row, index| {
            const obj = try self.objectAt(row, "$.terminals", index) orelse continue;
            const id = try self.optionalStringAt(obj, "id", "$.terminals", index) orelse
                (try self.optionalStringAt(obj, "name", "$.terminals", index) orelse {
                    try self.addIndex(.schema_invalid, "$.terminals", index, ".id");
                    continue;
                });
            try self.validateStableId(id, "$.terminals", index, ".id");
            try self.appendUnique(&self.terminal_ids, id, "$.terminals", index);
            try self.validateConditionField(obj, "condition", "$.terminals", index);
        }
    }

    fn validateObligations(self: *Validator, root: std.json.ObjectMap) !void {
        const obligations = root.get("obligations") orelse return;
        if (obligations != .array) {
            try self.add(.schema_invalid, "$.obligations");
            return;
        }
        for (obligations.array.items, 0..) |row, index| {
            const obj = try self.objectAt(row, "$.obligations", index) orelse continue;
            const id = try self.requiredStringAt(obj, "id", "$.obligations", index) orelse continue;
            try self.validateStableId(id, "$.obligations", index, ".id");
            try self.appendUnique(&self.obligation_ids, id, "$.obligations", index);
            const closer = stringField(obj, "closing_action_id") orelse {
                try self.addIndex(.obligation_uncovered, "$.obligations", index, ".closing_action_id");
                self.saw_obligation_error = true;
                continue;
            };
            if (!contains(self.actionIdsFromRoot(root), closer)) {
                try self.addIndex(.reference_unknown, "$.obligations", index, ".closing_action_id");
                self.saw_reference_error = true;
                self.saw_obligation_error = true;
            }
        }
    }

    fn validatePotential(self: *Validator, root: std.json.ObjectMap) !void {
        const dimensions = root.get("potential_dimensions") orelse return;
        if (dimensions != .array) {
            try self.add(.schema_invalid, "$.potential_dimensions");
            return;
        }
        for (dimensions.array.items, 0..) |row, index| {
            const obj = try self.objectAt(row, "$.potential_dimensions", index) orelse continue;
            const id = try self.requiredStringAt(obj, "id", "$.potential_dimensions", index) orelse continue;
            try self.validateStableId(id, "$.potential_dimensions", index, ".id");
            try self.appendUnique(&self.dimension_ids, id, "$.potential_dimensions", index);
            if (stringField(obj, "direction")) |direction| {
                if (!std.mem.eql(u8, direction, "minimize") and !std.mem.eql(u8, direction, "maximize")) {
                    try self.addIndex(.schema_invalid, "$.potential_dimensions", index, ".direction");
                }
            } else try self.addIndex(.schema_invalid, "$.potential_dimensions", index, ".direction");
        }
    }

    fn validateActions(self: *Validator, root: std.json.ObjectMap) !void {
        const actions = root.get("actions") orelse {
            try self.add(.schema_invalid, "$.actions");
            return;
        };
        if (actions != .array) {
            try self.add(.schema_invalid, "$.actions");
            return;
        }
        for (actions.array.items, 0..) |row, index| {
            const obj = try self.objectAt(row, "$.actions", index) orelse continue;
            const id = try self.requiredStringAt(obj, "id", "$.actions", index) orelse continue;
            try self.validateStableId(id, "$.actions", index, ".id");
            try self.appendUnique(&self.action_ids, id, "$.actions", index);
            if (boolField(obj, "rollback_only") == true) try self.rollback_action_ids.append(self.allocator, id);
            try self.validateConditionField(obj, "precondition", "$.actions", index);
            if (obj.get("requires_actions")) |requires| try self.requireStringArray(requires, "$.actions", index, ".requires_actions");
            if (obj.get("rollback_actions")) |rollback| {
                if (rollback == .array) {
                    for (rollback.array.items) |item| if (item == .string) try self.rollback_referenced_ids.append(self.allocator, item.string);
                }
                try self.requireStringArray(rollback, "$.actions", index, ".rollback_actions");
            }
            if (obj.get("results")) |results| try self.validateActionResults(results, index);
        }
    }

    fn validateShield(self: *Validator, root: std.json.ObjectMap) !void {
        if (root.get("safety_shield")) |shield| {
            if (shield != .array) {
                try self.add(.schema_invalid, "$.safety_shield");
                return;
            }
            for (shield.array.items, 0..) |row, index| {
                const obj = try self.objectAt(row, "$.safety_shield", index) orelse continue;
                const action_id = stringField(obj, "action_id") orelse {
                    try self.addIndex(.schema_invalid, "$.safety_shield", index, ".action_id");
                    continue;
                };
                try self.shielded_action_ids.append(self.allocator, action_id);
                if (!contains(self.action_ids.items, action_id)) {
                    try self.addIndex(.reference_unknown, "$.safety_shield", index, ".action_id");
                    self.saw_reference_error = true;
                }
                if (stringField(obj, "response")) |response| {
                    if (!validShieldResponse(response)) {
                        try self.addIndex(.schema_invalid, "$.safety_shield", index, ".response");
                    }
                }
                try self.validateConditionField(obj, "condition", "$.safety_shield", index);
            }
        }
        const actions = root.get("actions") orelse return;
        if (actions != .array) return;
        for (actions.array.items, 0..) |row, index| {
            if (row != .object) continue;
            const id = stringField(row.object, "id") orelse continue;
            if (boolField(row.object, "risky") == true and !contains(self.shielded_action_ids.items, id)) {
                try self.addIndex(.risky_action_unshielded, "$.actions", index, ".risky");
                self.saw_safety_error = true;
            }
        }
    }

    fn validateRules(self: *Validator, root: std.json.ObjectMap) !void {
        const rules = root.get("policy_rules") orelse {
            try self.add(.schema_invalid, "$.policy_rules");
            return;
        };
        if (rules != .array) {
            try self.add(.schema_invalid, "$.policy_rules");
            return;
        }
        var rule_ids: std.ArrayList([]const u8) = .empty;
        defer rule_ids.deinit(self.allocator);
        for (rules.array.items, 0..) |row, index| {
            const obj = try self.objectAt(row, "$.policy_rules", index) orelse continue;
            if (try self.requiredStringAt(obj, "id", "$.policy_rules", index)) |id| {
                try self.validateStableId(id, "$.policy_rules", index, ".id");
                if (contains(rule_ids.items, id)) {
                    try self.addIndex(.id_duplicate, "$.policy_rules", index, ".id");
                } else try rule_ids.append(self.allocator, id);
            }
            try self.validateConditionField(obj, "condition", "$.policy_rules", index);
            if (obj.get("actions")) |actions| {
                if (actions != .array) {
                    try self.addIndex(.schema_invalid, "$.policy_rules", index, ".actions");
                } else {
                    for (actions.array.items, 0..) |item, action_index| {
                        if (item != .string) {
                            try self.addIndex2(.schema_invalid, "$.policy_rules", index, ".actions", action_index, "");
                            continue;
                        }
                        if (!contains(self.action_ids.items, item.string)) {
                            try self.addIndex2(.reference_unknown, "$.policy_rules", index, ".actions", action_index, "");
                            self.saw_reference_error = true;
                        } else try self.selected_action_ids.append(self.allocator, item.string);
                    }
                }
            }
            if (stringField(obj, "terminal")) |terminal| {
                if (!contains(self.terminal_ids.items, terminal)) {
                    try self.addIndex(.reference_unknown, "$.policy_rules", index, ".terminal");
                    self.saw_reference_error = true;
                }
            }
        }
    }

    fn validateUnknowns(self: *Validator, root: std.json.ObjectMap) !void {
        const unknowns = root.get("unknowns") orelse return;
        if (unknowns != .array) {
            try self.add(.schema_invalid, "$.unknowns");
            return;
        }
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.allocator);
        for (unknowns.array.items, 0..) |row, index| {
            const obj = try self.objectAt(row, "$.unknowns", index) orelse continue;
            const id = try self.requiredStringAt(obj, "id", "$.unknowns", index) orelse continue;
            try self.validateStableId(id, "$.unknowns", index, ".id");
            if (contains(ids.items, id)) try self.addIndex(.id_duplicate, "$.unknowns", index, ".id") else try ids.append(self.allocator, id);
            if (boolField(obj, "critical") == true) {
                const observation_id = stringField(obj, "observation_id") orelse {
                    try self.addIndex(.critical_unknown_unobservable, "$.unknowns", index, ".observation_id");
                    self.saw_unknown_error = true;
                    continue;
                };
                if (!contains(self.observation_ids.items, observation_id)) {
                    try self.addIndex(.reference_unknown, "$.unknowns", index, ".observation_id");
                    self.saw_reference_error = true;
                    self.saw_unknown_error = true;
                }
                const resolver = stringField(obj, "resolver_action_id") orelse {
                    try self.addIndex(.critical_unknown_unobservable, "$.unknowns", index, ".resolver_action_id");
                    self.saw_unknown_error = true;
                    continue;
                };
                if (!contains(self.action_ids.items, resolver)) {
                    try self.addIndex(.reference_unknown, "$.unknowns", index, ".resolver_action_id");
                    self.saw_reference_error = true;
                    self.saw_unknown_error = true;
                }
            }
        }
    }

    fn validateActionReferences(self: *Validator, root: std.json.ObjectMap) !void {
        const actions = root.get("actions") orelse return;
        if (actions != .array) return;
        for (actions.array.items, 0..) |row, index| {
            if (row != .object) continue;
            if (row.object.get("requires_actions")) |requires| {
                if (requires != .array) continue;
                for (requires.array.items, 0..) |item, dep_index| {
                    if (item != .string) continue;
                    if (!contains(self.action_ids.items, item.string)) {
                        try self.addIndex2(.reference_unknown, "$.actions", index, ".requires_actions", dep_index, "");
                        self.saw_reference_error = true;
                    }
                }
            }
            if (row.object.get("rollback_actions")) |rollback| {
                if (rollback != .array) continue;
                for (rollback.array.items, 0..) |item, rollback_index| {
                    if (item != .string) continue;
                    if (!contains(self.action_ids.items, item.string)) {
                        try self.addIndex2(.reference_unknown, "$.actions", index, ".rollback_actions", rollback_index, "");
                        self.saw_reference_error = true;
                    }
                }
            }
        }
    }

    fn validateActionCycles(self: *Validator, root: std.json.ObjectMap) !void {
        const actions = root.get("actions") orelse return;
        if (actions != .array) return;
        for (self.action_ids.items) |id| {
            var visiting: std.ArrayList([]const u8) = .empty;
            defer visiting.deinit(self.allocator);
            if (try self.actionHasCycle(root, id, &visiting)) {
                try self.add(.action_cycle, "$.actions");
                self.saw_graph_error = true;
                return;
            }
        }
    }

    fn actionHasCycle(self: *Validator, root: std.json.ObjectMap, id: []const u8, visiting: *std.ArrayList([]const u8)) !bool {
        if (contains(visiting.items, id)) return true;
        try visiting.append(self.allocator, id);
        defer _ = visiting.pop();
        const obj = actionObject(root, id) orelse return false;
        const requires = obj.get("requires_actions") orelse return false;
        if (requires != .array) return false;
        for (requires.array.items) |item| {
            if (item == .string and try self.actionHasCycle(root, item.string, visiting)) return true;
        }
        return false;
    }

    fn validateActionReachability(self: *Validator) !void {
        for (self.action_ids.items) |id| {
            if (contains(self.rollback_action_ids.items, id)) continue;
            if (!contains(self.selected_action_ids.items, id)) {
                try self.add(.action_unreachable, "$.actions");
                self.saw_graph_error = true;
                return;
            }
        }
    }

    fn validateRollbackReachability(self: *Validator) !void {
        for (self.rollback_action_ids.items) |id| {
            if (!contains(self.rollback_referenced_ids.items, id)) {
                try self.add(.action_unreachable, "$.actions");
                self.saw_graph_error = true;
                return;
            }
        }
    }

    fn validateOutcomeClosure(self: *Validator, root: std.json.ObjectMap) !void {
        const actions = root.get("actions") orelse return;
        if (actions != .array) return;
        for (actions.array.items, 0..) |row, index| {
            if (row != .object) continue;
            const results = row.object.get("results") orelse continue;
            if (results != .object) continue;
            var it = results.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .array) continue;
                for (entry.value_ptr.array.items, 0..) |item, atom_index| {
                    if (item != .string) continue;
                    if (!self.atomIsClosed(item.string)) {
                        try self.addIndex2(.outcome_dangling, "$.actions", index, ".results", atom_index, "");
                        self.saw_graph_error = true;
                    }
                }
            }
        }
    }

    fn validateReadiness(self: *Validator, root: std.json.ObjectMap) !void {
        const readiness = root.get("readiness") orelse return;
        if (readiness != .object) {
            try self.add(.schema_invalid, "$.readiness");
            return;
        }
        const derived = DerivedReadiness{
            .source_current = true,
            .obligations_covered = !self.saw_obligation_error,
            .critical_unknowns_observable_or_blocked = !self.saw_unknown_error,
            .actions_bounded = self.action_ids.items.len > 0 and !self.saw_graph_error,
            .policy_references_valid = !self.saw_reference_error and !self.saw_atom_error,
            .policy_closed = !self.saw_graph_error,
            .safety_shield_complete = !self.saw_safety_error,
            .potential_complete = self.dimension_ids.items.len > 0,
            .terminal_states_complete = self.terminal_ids.items.len > 0,
            .downstream_runtime_ready = true,
        };
        try self.compareReadiness(readiness.object, "source_current", derived.source_current);
        try self.compareReadiness(readiness.object, "obligations_covered", derived.obligations_covered);
        try self.compareReadiness(readiness.object, "critical_unknowns_observable_or_blocked", derived.critical_unknowns_observable_or_blocked);
        try self.compareReadiness(readiness.object, "actions_bounded", derived.actions_bounded);
        try self.compareReadiness(readiness.object, "policy_references_valid", derived.policy_references_valid);
        try self.compareReadiness(readiness.object, "policy_closed", derived.policy_closed);
        try self.compareReadiness(readiness.object, "safety_shield_complete", derived.safety_shield_complete);
        try self.compareReadiness(readiness.object, "potential_complete", derived.potential_complete);
        try self.compareReadiness(readiness.object, "terminal_states_complete", derived.terminal_states_complete);
        try self.compareReadiness(readiness.object, "downstream_runtime_ready", derived.downstream_runtime_ready);
        try self.compareReadiness(readiness.object, "policy_ready", derived.policyReady());
    }

    fn compareReadiness(self: *Validator, readiness: std.json.ObjectMap, key: []const u8, derived: bool) !void {
        const value = readiness.get(key) orelse return;
        if (value != .bool) {
            const path = try std.fmt.allocPrint(self.allocator, "$.readiness.{s}", .{key});
            defer self.allocator.free(path);
            try self.add(.schema_invalid, path);
            return;
        }
        if (value.bool != derived) {
            const path = try std.fmt.allocPrint(self.allocator, "$.readiness.{s}", .{key});
            defer self.allocator.free(path);
            try self.add(.source_stale, path);
        }
    }

    fn validateActionResults(self: *Validator, results: std.json.Value, action_index: usize) !void {
        if (results != .object) {
            try self.addIndex(.schema_invalid, "$.actions", action_index, ".results");
            return;
        }
        var it = results.object.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "success") and !std.mem.eql(u8, entry.key_ptr.*, "failure")) {
                try self.addIndex(.schema_invalid, "$.actions", action_index, ".results");
                continue;
            }
            if (entry.value_ptr.* != .array) {
                try self.addIndex(.schema_invalid, "$.actions", action_index, ".results");
                continue;
            }
            for (entry.value_ptr.array.items, 0..) |item, atom_index| {
                if (item != .string) {
                    try self.addIndex2(.schema_invalid, "$.actions", action_index, ".results", atom_index, "");
                    continue;
                }
                try self.validateDeclaredAtom(item.string, "$.actions", action_index, ".results");
            }
        }
    }

    fn validateConditionField(self: *Validator, obj: std.json.ObjectMap, key: []const u8, base_path: []const u8, index: usize) !void {
        const value = obj.get(key) orelse return;
        var owned = condition.parseOwned(self.allocator, value) catch {
            try self.addIndex(.schema_invalid, base_path, index, ".");
            return;
        };
        defer owned.deinit(self.allocator);
        for (owned.all) |item| try self.validateConditionAtom(item, base_path, index);
        for (owned.any) |item| try self.validateConditionAtom(item, base_path, index);
        for (owned.none) |item| try self.validateConditionAtom(item, base_path, index);
    }

    fn validateConditionAtom(self: *Validator, item: []const u8, base_path: []const u8, index: usize) !void {
        try self.validateDeclaredAtom(item, base_path, index, ".condition");
        try self.condition_atoms.append(self.allocator, try self.allocator.dupe(u8, item));
    }

    fn validateDeclaredAtom(self: *Validator, item: []const u8, base_path: []const u8, index: usize, suffix: []const u8) !void {
        _ = atom.parse(item) catch {
            try self.addIndex(.atom_invalid, base_path, index, suffix);
            self.saw_atom_error = true;
            return;
        };
        if (!contains(self.declared_atoms.items, item)) {
            try self.addIndex(.atom_unknown, base_path, index, suffix);
            self.saw_atom_error = true;
        }
        if (std.mem.startsWith(u8, item, "custom:") and !contains(self.custom_authority_atoms.items, item)) {
            try self.addIndex(.atom_unknown, base_path, index, suffix);
            self.saw_atom_error = true;
        }
    }

    fn atomIsClosed(self: *Validator, item: []const u8) bool {
        if (std.mem.startsWith(u8, item, "terminal:")) return true;
        if (std.mem.eql(u8, item, "fact:replan") or std.mem.eql(u8, item, "custom:replan")) return true;
        if (contains(self.condition_atoms.items, item)) return true;
        return false;
    }

    fn requireString(self: *Validator, root: std.json.ObjectMap, key: []const u8, path: []const u8) !void {
        const value = root.get(key) orelse {
            try self.add(.schema_invalid, path);
            return;
        };
        if (value != .string or value.string.len == 0) try self.add(.schema_invalid, path);
    }

    fn requireInteger(self: *Validator, root: std.json.ObjectMap, key: []const u8, path: []const u8) !void {
        const value = root.get(key) orelse {
            try self.add(.schema_invalid, path);
            return;
        };
        if (value != .integer) try self.add(.schema_invalid, path);
    }

    fn objectAt(self: *Validator, value: std.json.Value, base_path: []const u8, index: usize) !?std.json.ObjectMap {
        if (value != .object) {
            try self.addIndex(.schema_invalid, base_path, index, "");
            return null;
        }
        return value.object;
    }

    fn requiredStringAt(self: *Validator, obj: std.json.ObjectMap, key: []const u8, base_path: []const u8, index: usize) !?[]const u8 {
        const value = obj.get(key) orelse {
            const suffix = try std.fmt.allocPrint(self.allocator, ".{s}", .{key});
            defer self.allocator.free(suffix);
            try self.addIndex(.schema_invalid, base_path, index, suffix);
            return null;
        };
        if (value != .string or value.string.len == 0) {
            const suffix = try std.fmt.allocPrint(self.allocator, ".{s}", .{key});
            defer self.allocator.free(suffix);
            try self.addIndex(.schema_invalid, base_path, index, suffix);
            return null;
        }
        return value.string;
    }

    fn optionalStringAt(self: *Validator, obj: std.json.ObjectMap, key: []const u8, base_path: []const u8, index: usize) !?[]const u8 {
        const value = obj.get(key) orelse return null;
        if (value != .string or value.string.len == 0) {
            const suffix = try std.fmt.allocPrint(self.allocator, ".{s}", .{key});
            defer self.allocator.free(suffix);
            try self.addIndex(.schema_invalid, base_path, index, suffix);
            return null;
        }
        return value.string;
    }

    fn requireStringArray(self: *Validator, value: std.json.Value, base_path: []const u8, index: usize, suffix: []const u8) !void {
        if (value != .array) {
            try self.addIndex(.schema_invalid, base_path, index, suffix);
            return;
        }
        for (value.array.items, 0..) |item, item_index| {
            if (item != .string) try self.addIndex2(.schema_invalid, base_path, index, suffix, item_index, "");
        }
    }

    fn appendUnique(self: *Validator, list: *std.ArrayList([]const u8), id: []const u8, base_path: []const u8, index: usize) !void {
        if (contains(list.items, id)) {
            try self.addIndex(.id_duplicate, base_path, index, ".id");
        } else try list.append(self.allocator, id);
    }

    fn validateStableId(self: *Validator, id: []const u8, base_path: []const u8, index: usize, suffix: []const u8) !void {
        atom.validateStableId(id) catch {
            try self.addIndex(.atom_invalid, base_path, index, suffix);
            self.saw_atom_error = true;
        };
    }

    fn add(self: *Validator, code: errors.ErrorCode, path: []const u8) !void {
        try self.builder.add(code, path);
    }

    fn addIndex(self: *Validator, code: errors.ErrorCode, base_path: []const u8, index: usize, suffix: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]{s}", .{ base_path, index, suffix });
        defer self.allocator.free(path);
        try self.add(code, path);
    }

    fn addIndex2(self: *Validator, code: errors.ErrorCode, base_path: []const u8, index: usize, suffix: []const u8, index2: usize, suffix2: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]{s}[{d}]{s}", .{ base_path, index, suffix, index2, suffix2 });
        defer self.allocator.free(path);
        try self.add(code, path);
    }

    fn actionIdsFromRoot(self: *Validator, root: std.json.ObjectMap) []const []const u8 {
        _ = root;
        return self.action_ids.items;
    }
};

const DerivedReadiness = struct {
    source_current: bool,
    obligations_covered: bool,
    critical_unknowns_observable_or_blocked: bool,
    actions_bounded: bool,
    policy_references_valid: bool,
    policy_closed: bool,
    safety_shield_complete: bool,
    potential_complete: bool,
    terminal_states_complete: bool,
    downstream_runtime_ready: bool,

    fn policyReady(self: DerivedReadiness) bool {
        return self.source_current and self.obligations_covered and self.critical_unknowns_observable_or_blocked and self.actions_bounded and self.policy_references_valid and self.policy_closed and self.safety_shield_complete and self.potential_complete and self.terminal_states_complete and self.downstream_runtime_ready;
    }
};

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn actionObject(root: std.json.ObjectMap, id: []const u8) ?std.json.ObjectMap {
    const actions = root.get("actions") orelse return null;
    if (actions != .array) return null;
    for (actions.array.items) |row| {
        if (row != .object) continue;
        const row_id = stringField(row.object, "id") orelse continue;
        if (std.mem.eql(u8, row_id, id)) return row.object;
    }
    return null;
}

fn contains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn validShieldResponse(response: []const u8) bool {
    return std.mem.eql(u8, response, "return_to_spec") or
        std.mem.eql(u8, response, "rollback") or
        std.mem.eql(u8, response, "blocked");
}

fn expectOnlyCode(report: errors.ValidationReport, code: errors.ErrorCode) !void {
    try std.testing.expect(report.errors.len >= 1);
    try std.testing.expectEqual(code, report.errors[0].code);
}

const valid_policy_json =
    \\{
    \\  "policy_id": "p1",
    \\  "revision": 1,
    \\  "declared_atoms": ["fact:start", "fact:done", "terminal:success", "fact:replan"],
    \\  "actions": [
    \\    {"id": "a1", "results": {"success": ["fact:done"]}}
    \\  ],
    \\  "policy_rules": [
    \\    {"id": "r1", "priority": 1, "condition": {"all": ["fact:start"]}, "actions": ["a1"]},
    \\    {"id": "r2", "priority": 2, "condition": {"all": ["fact:done"]}, "terminal": "success"}
    \\  ],
    \\  "terminals": [
    \\    {"id": "success", "condition": {"all": ["terminal:success"]}}
    \\  ],
    \\  "potential_dimensions": [
    \\    {"id": "risk", "direction": "minimize", "terminal_threshold": 0}
    \\  ],
    \\  "readiness": {
    \\    "source_current": true,
    \\    "obligations_covered": true,
    \\    "critical_unknowns_observable_or_blocked": true,
    \\    "actions_bounded": true,
    \\    "policy_references_valid": true,
    \\    "policy_closed": true,
    \\    "safety_shield_complete": true,
    \\    "potential_complete": true,
    \\    "terminal_states_complete": true,
    \\    "downstream_runtime_ready": true,
    \\    "policy_ready": true
    \\  }
    \\}
;

fn validateText(allocator: std.mem.Allocator, text: []const u8) !errors.ValidationReport {
    var policy = try schema.parseArtifact(schema.Policy, allocator, text);
    defer policy.deinit(allocator);
    return validatePolicy(allocator, &policy);
}

test "valid policy report is ok" {
    var report = try validateText(std.testing.allocator, valid_policy_json);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());
}

test "validation reports duplicate ids" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a"},{"id":"a"}],"policy_rules":[]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .id_duplicate);
}

test "validation reports unknown condition atom" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","condition":{"all":["fact:missing"]},"actions":["a"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .atom_unknown);
}

test "validation reports undeclared custom atom authority" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["custom:x"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .atom_unknown);
}

test "validation reports action dependency cycle" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a","requires_actions":["b"]},{"id":"b","requires_actions":["a"]}],"policy_rules":[{"id":"r","actions":["a","b"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .action_cycle);
}

test "validation reports unreachable action" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a"},{"id":"b"}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .action_unreachable);
}

test "validation reports dangling action outcome" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a","fact:orphan"],"actions":[{"id":"a","results":{"success":["fact:orphan"]}}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .outcome_dangling);
}

test "validation reports critical unknown without observation or resolver" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}],"unknowns":[{"id":"u","critical":true}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .critical_unknown_unobservable);
}

test "validation reports obligation without closer" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}],"obligations":[{"id":"o"}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .obligation_uncovered);
}

test "validation accepts obligation closer declared later in policy" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:start","fact:done"],"actions":[{"id":"close","results":{"success":["fact:done"]}}],"policy_rules":[{"id":"r1","actions":["close"]},{"id":"r2","condition":{"all":["fact:done"]}}],"obligations":[{"id":"proof","closing_action_id":"close"}]}
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());
}

test "validation accepts terminal name alias without id error" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:start","terminal:success"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]},{"id":"done","terminal":"success"}],"terminals":[{"name":"success"}]}
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.ok());
}

test "validation rejects unstable generated atom ids" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"bad action"}],"policy_rules":[{"id":"r","actions":["bad action"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .atom_invalid);

    var outcome_report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}],"observations":[{"id":"obs1","outcomes":["needs review"]}]}
    );
    defer outcome_report.deinit(std.testing.allocator);
    try expectOnlyCode(outcome_report, .atom_invalid);
}

test "validation rejects unknown rollback refs and shield responses" {
    var rollback_report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a","rollback_actions":["missing"]},{"id":"rollback","rollback_only":true}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer rollback_report.deinit(std.testing.allocator);
    try expectOnlyCode(rollback_report, .reference_unknown);

    var shield_report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a","risky":true}],"policy_rules":[{"id":"r","actions":["a"]}],"safety_shield":[{"action_id":"a","response":"retun_to_spec"}]}
    );
    defer shield_report.deinit(std.testing.allocator);
    try expectOnlyCode(shield_report, .schema_invalid);
}

test "validation reports risky action without shield" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a","risky":true}],"policy_rules":[{"id":"r","actions":["a"]}]}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .risky_action_unshielded);
}

test "validation reports readiness contradiction" {
    var report = try validateText(std.testing.allocator,
        \\{"policy_id":"p","revision":1,"declared_atoms":["fact:a"],"actions":[{"id":"a"}],"policy_rules":[{"id":"r","actions":["a"]}],"readiness":{"policy_ready":true}}
    );
    defer report.deinit(std.testing.allocator);
    try expectOnlyCode(report, .source_stale);
}
