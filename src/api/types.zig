const std = @import("std");

const Allocator = std.mem.Allocator;

pub const CiProduct = struct {
    id: []u8,
    name: []u8,
    bundle_id: []u8,
};

pub const CiWorkflow = struct {
    id: []u8,
    name: []u8,
    is_enabled: bool,
};

pub const CiBuildRun = struct {
    id: []u8,
    number: []u8,
    source_branch_or_tag: []u8,
    status: []u8,
    completion_status: []u8,
    created_date: []u8,
    started_date: []u8,
    finished_date: []u8,
};

pub const CiBuildAction = struct {
    id: []u8,
    name: []u8,
    action_type: []u8,
    status: []u8,
    started_date: []u8,
    finished_date: []u8,
};

const AppRelationship = struct {
    data: ?struct {
        id: []const u8,
    } = null,
};

const IncludedApp = struct {
    id: []const u8,
    type: ?[]const u8 = null,
    attributes: struct {
        bundleId: ?[]const u8 = null,
    } = .{},
};

const IncludedRef = struct {
    id: []const u8,
    type: ?[]const u8 = null,
    attributes: struct {
        name: ?[]const u8 = null,
    } = .{},
};

pub fn freeProducts(allocator: Allocator, items: []CiProduct) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.name);
        allocator.free(item.bundle_id);
    }
    allocator.free(items);
}

pub fn freeWorkflows(allocator: Allocator, items: []CiWorkflow) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.name);
    }
    allocator.free(items);
}

pub fn freeBuildRuns(allocator: Allocator, items: []CiBuildRun) void {
    for (items) |item| {
        freeBuildRunFields(allocator, item);
    }
    allocator.free(items);
}

pub fn freeBuildActions(allocator: Allocator, items: []CiBuildAction) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.name);
        allocator.free(item.action_type);
        allocator.free(item.status);
        allocator.free(item.started_date);
        allocator.free(item.finished_date);
    }
    allocator.free(items);
}

pub fn freeBuildRun(allocator: Allocator, item: CiBuildRun) void {
    freeBuildRunFields(allocator, item);
}

pub fn parseProducts(allocator: Allocator, json_body: []const u8) ![]CiProduct {
    const Response = struct {
        data: []const struct {
            id: []const u8,
            attributes: struct {
                name: ?[]const u8 = null,
                bundleId: ?[]const u8 = null,
            } = .{},
            relationships: struct {
                app: ?AppRelationship = null,
            } = .{},
        },
        included: ?[]const IncludedApp = null,
    };

    var parsed = try std.json.parseFromSlice(Response, allocator, json_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(CiProduct) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.id);
            allocator.free(item.name);
            allocator.free(item.bundle_id);
        }
        list.deinit(allocator);
    }

    for (parsed.value.data) |raw| {
        const related_app_id = if (raw.relationships.app) |app_rel|
            if (app_rel.data) |app_data| app_data.id else null
        else
            null;
        const bundle = raw.attributes.bundleId orelse lookupIncludedBundleId(parsed.value.included, related_app_id);
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, raw.id),
            .name = try dupOrDefault(allocator, raw.attributes.name, "(no name)"),
            .bundle_id = try dupOrDefault(allocator, bundle, "-"),
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn parseWorkflows(allocator: Allocator, json_body: []const u8) ![]CiWorkflow {
    const Response = struct {
        data: []const struct {
            id: []const u8,
            attributes: struct {
                name: ?[]const u8 = null,
                isEnabled: ?bool = null,
            } = .{},
        },
    };

    var parsed = try std.json.parseFromSlice(Response, allocator, json_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(CiWorkflow) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.id);
            allocator.free(item.name);
        }
        list.deinit(allocator);
    }

    for (parsed.value.data) |raw| {
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, raw.id),
            .name = try dupOrDefault(allocator, raw.attributes.name, "(no name)"),
            .is_enabled = raw.attributes.isEnabled orelse false,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn parseBuildRuns(allocator: Allocator, json_body: []const u8) ![]CiBuildRun {
    const Response = struct {
        data: []const RawBuildRun,
        included: ?[]const IncludedRef = null,
    };

    var parsed = try std.json.parseFromSlice(Response, allocator, json_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(CiBuildRun) = .empty;
    errdefer {
        for (list.items) |item| freeBuildRunFields(allocator, item);
        list.deinit(allocator);
    }

    for (parsed.value.data) |raw| {
        try list.append(allocator, try fromRawBuildRun(allocator, raw, parsed.value.included));
    }

    return list.toOwnedSlice(allocator);
}

pub fn parseBuildRun(allocator: Allocator, json_body: []const u8) !CiBuildRun {
    const Response = struct {
        data: RawBuildRun,
        included: ?[]const IncludedRef = null,
    };

    var parsed = try std.json.parseFromSlice(Response, allocator, json_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return fromRawBuildRun(allocator, parsed.value.data, parsed.value.included);
}

pub fn parseBuildActions(allocator: Allocator, json_body: []const u8) ![]CiBuildAction {
    const Response = struct {
        data: []const struct {
            id: []const u8,
            attributes: struct {
                name: ?[]const u8 = null,
                actionType: ?[]const u8 = null,
                status: ?[]const u8 = null,
                completionStatus: ?[]const u8 = null,
                startedDate: ?[]const u8 = null,
                finishedDate: ?[]const u8 = null,
            } = .{},
        },
    };

    var parsed = try std.json.parseFromSlice(Response, allocator, json_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(CiBuildAction) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.id);
            allocator.free(item.name);
            allocator.free(item.action_type);
            allocator.free(item.status);
            allocator.free(item.started_date);
            allocator.free(item.finished_date);
        }
        list.deinit(allocator);
    }

    for (parsed.value.data) |raw| {
        const status_value = raw.attributes.completionStatus orelse raw.attributes.status;
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, raw.id),
            .name = try dupOrDefault(allocator, raw.attributes.name, "(no name)"),
            .action_type = try dupOrDefault(allocator, raw.attributes.actionType, "-"),
            .status = try dupOrDefault(allocator, status_value, "-"),
            .started_date = try dupOrDefault(allocator, raw.attributes.startedDate, "-"),
            .finished_date = try dupOrDefault(allocator, raw.attributes.finishedDate, "-"),
        });
    }

    return list.toOwnedSlice(allocator);
}

const RawBuildRun = struct {
    id: []const u8,
    attributes: struct {
        number: ?u64 = null,
        sourceBranchOrTag: ?[]const u8 = null,
        status: ?[]const u8 = null,
        completionStatus: ?[]const u8 = null,
        createdDate: ?[]const u8 = null,
        startedDate: ?[]const u8 = null,
        finishedDate: ?[]const u8 = null,
    } = .{},
    relationships: struct {
        sourceBranchOrTag: ?struct {
            data: ?struct {
                id: []const u8,
            } = null,
        } = null,
    } = .{},
};

fn fromRawBuildRun(
    allocator: Allocator,
    raw: RawBuildRun,
    included_refs: ?[]const IncludedRef,
) !CiBuildRun {
    const related_ref_id = if (raw.relationships.sourceBranchOrTag) |rel|
        if (rel.data) |ref_data| ref_data.id else null
    else
        null;
    const branch = raw.attributes.sourceBranchOrTag orelse lookupIncludedRefName(included_refs, related_ref_id);
    return .{
        .id = try allocator.dupe(u8, raw.id),
        .number = try formatNumberOrDash(allocator, raw.attributes.number),
        .source_branch_or_tag = try dupOrDefault(allocator, branch, "-"),
        .status = try dupOrDefault(allocator, raw.attributes.status, "-"),
        .completion_status = try dupOrDefault(allocator, raw.attributes.completionStatus, "-"),
        .created_date = try dupOrDefault(allocator, raw.attributes.createdDate, "-"),
        .started_date = try dupOrDefault(allocator, raw.attributes.startedDate, "-"),
        .finished_date = try dupOrDefault(allocator, raw.attributes.finishedDate, "-"),
    };
}

fn freeBuildRunFields(allocator: Allocator, item: CiBuildRun) void {
    allocator.free(item.id);
    allocator.free(item.number);
    allocator.free(item.source_branch_or_tag);
    allocator.free(item.status);
    allocator.free(item.completion_status);
    allocator.free(item.created_date);
    allocator.free(item.started_date);
    allocator.free(item.finished_date);
}

fn dupOrDefault(allocator: Allocator, value: ?[]const u8, default_value: []const u8) ![]u8 {
    return allocator.dupe(u8, value orelse default_value);
}

fn formatNumberOrDash(allocator: Allocator, maybe_number: ?u64) ![]u8 {
    if (maybe_number) |number| {
        return std.fmt.allocPrint(allocator, "{d}", .{number});
    }
    return allocator.dupe(u8, "-");
}

fn lookupIncludedBundleId(
    included_apps: ?[]const IncludedApp,
    maybe_app_id: ?[]const u8,
) ?[]const u8 {
    const app_id = maybe_app_id orelse return null;
    const apps = included_apps orelse return null;
    for (apps) |app| {
        if (std.mem.eql(u8, app.id, app_id)) {
            return app.attributes.bundleId;
        }
    }
    return null;
}

fn lookupIncludedRefName(
    included_refs: ?[]const IncludedRef,
    maybe_ref_id: ?[]const u8,
) ?[]const u8 {
    const ref_id = maybe_ref_id orelse return null;
    const refs = included_refs orelse return null;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.id, ref_id)) {
            return ref.attributes.name;
        }
    }
    return null;
}
