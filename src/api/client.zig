const std = @import("std");
const jwt = @import("../auth/jwt.zig");
const endpoints = @import("endpoints.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const Client = struct {
    allocator: Allocator,
    http: std.http.Client,
    credentials: ?jwt.Credentials,
    auth_warning: ?[]u8,

    pub fn init(allocator: Allocator) !Client {
        var client = Client{
            .allocator = allocator,
            .http = .{ .allocator = allocator },
            .credentials = null,
            .auth_warning = null,
        };

        client.credentials = jwt.loadCredentialsFromEnv(allocator) catch |err| blk: {
            client.auth_warning = try std.fmt.allocPrint(
                allocator,
                "Environment variables missing/invalid ({s}); using mock data",
                .{@errorName(err)},
            );
            break :blk null;
        };

        return client;
    }

    pub fn deinit(self: *Client) void {
        if (self.credentials) |*creds| {
            jwt.deinitCredentials(self.allocator, creds);
        }
        if (self.auth_warning) |warning| {
            self.allocator.free(warning);
        }
        self.http.deinit();
    }

    pub fn authWarning(self: *const Client) ?[]const u8 {
        return self.auth_warning;
    }

    pub fn listProducts(self: *Client) ![]types.CiProduct {
        if (self.credentials == null) return mockProducts(self.allocator);

        const body = try self.requestJson(.GET, endpoints.ciProducts(), null);
        defer self.allocator.free(body);

        return types.parseProducts(self.allocator, body);
    }

    pub fn listWorkflows(self: *Client, product_id: []const u8) ![]types.CiWorkflow {
        if (self.credentials == null) return mockWorkflows(self.allocator, product_id);

        const path = try endpoints.workflowsForProduct(self.allocator, product_id);
        defer self.allocator.free(path);

        const body = try self.requestJson(.GET, path, null);
        defer self.allocator.free(body);

        return types.parseWorkflows(self.allocator, body);
    }

    pub fn listBuildRuns(self: *Client, workflow_id: []const u8) ![]types.CiBuildRun {
        if (self.credentials == null) return mockBuildRuns(self.allocator, workflow_id);

        const path = try endpoints.buildRunsForWorkflow(self.allocator, workflow_id);
        defer self.allocator.free(path);

        const body = try self.requestJson(.GET, path, null);
        defer self.allocator.free(body);

        return types.parseBuildRuns(self.allocator, body);
    }

    pub fn createBuildRun(self: *Client, workflow_id: []const u8) !types.CiBuildRun {
        if (self.credentials == null) {
            return mockCreatedBuildRun(self.allocator, workflow_id);
        }

        const payload = try endpoints.createBuildRunPayload(self.allocator, workflow_id);
        defer self.allocator.free(payload);

        const body = try self.requestJson(.POST, "/v1/ciBuildRuns", payload);
        defer self.allocator.free(body);

        return types.parseBuildRun(self.allocator, body);
    }

    pub fn getBuildRun(self: *Client, build_run_id: []const u8) !types.CiBuildRun {
        if (self.credentials == null) return mockBuildRunDetail(self.allocator, build_run_id);

        const path = try endpoints.buildRunById(self.allocator, build_run_id);
        defer self.allocator.free(path);

        const body = try self.requestJson(.GET, path, null);
        defer self.allocator.free(body);

        return types.parseBuildRun(self.allocator, body);
    }

    pub fn listBuildActions(self: *Client, build_run_id: []const u8) ![]types.CiBuildAction {
        if (self.credentials == null) return mockBuildActions(self.allocator, build_run_id);

        const path = try endpoints.buildActionsForRun(self.allocator, build_run_id);
        defer self.allocator.free(path);

        const body = try self.requestJson(.GET, path, null);
        defer self.allocator.free(body);

        return types.parseBuildActions(self.allocator, body);
    }

    pub fn listArtifactsForAction(self: *Client, action_id: []const u8) ![]types.CiArtifact {
        if (self.credentials == null) return mockArtifactsForAction(self.allocator, action_id);

        const path = try endpoints.artifactsForAction(self.allocator, action_id);
        defer self.allocator.free(path);

        const body = try self.requestJson(.GET, path, null);
        defer self.allocator.free(body);

        return types.parseArtifacts(self.allocator, body);
    }

    pub fn downloadArtifact(self: *Client, artifact: types.CiArtifact) ![]u8 {
        try std.fs.cwd().makePath("downloads");

        const safe_name = try sanitizeFileNameAlloc(self.allocator, artifact.file_name);
        defer self.allocator.free(safe_name);

        const out_path = try std.fmt.allocPrint(self.allocator, "downloads/{s}", .{safe_name});
        errdefer self.allocator.free(out_path);

        if (std.mem.startsWith(u8, artifact.download_url, "mock://")) {
            var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll("mock artifact content\n");
            return out_path;
        }

        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();

        const result = try self.http.fetch(.{
            .location = .{ .url = artifact.download_url },
            .method = .GET,
            .response_writer = &sink.writer,
        });
        if (result.status.class() != .success) return error.HttpRequestFailed;

        var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(sink.written());

        return out_path;
    }

    fn requestJson(
        self: *Client,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
    ) ![]u8 {
        const creds = self.credentials orelse return error.MissingCredentials;

        const token = try jwt.generateToken(self.allocator, creds, std.time.timestamp());
        defer self.allocator.free(token);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
        defer self.allocator.free(auth_header);

        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ endpoints.base_url, path });
        defer self.allocator.free(url);

        var sink: std.Io.Writer.Allocating = .init(self.allocator);
        defer sink.deinit();

        var headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
        };

        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .extra_headers = if (payload != null) headers[0..3] else headers[0..2],
            .response_writer = &sink.writer,
        });

        if (result.status.class() != .success) {
            return error.HttpRequestFailed;
        }

        return self.allocator.dupe(u8, sink.written());
    }
};

fn mockProducts(allocator: Allocator) ![]types.CiProduct {
    const items = try allocator.alloc(types.CiProduct, 2);
    errdefer allocator.free(items);

    items[0] = .{
        .id = try allocator.dupe(u8, "product-demo-1"),
        .name = try allocator.dupe(u8, "Sample iOS App"),
        .bundle_id = try allocator.dupe(u8, "com.example.sampleapp"),
    };
    items[1] = .{
        .id = try allocator.dupe(u8, "product-demo-2"),
        .name = try allocator.dupe(u8, "Sample macOS App"),
        .bundle_id = try allocator.dupe(u8, "com.example.samplemac"),
    };

    return items;
}

fn mockWorkflows(allocator: Allocator, _: []const u8) ![]types.CiWorkflow {
    const items = try allocator.alloc(types.CiWorkflow, 2);
    errdefer allocator.free(items);

    items[0] = .{
        .id = try allocator.dupe(u8, "workflow-demo-main"),
        .name = try allocator.dupe(u8, "Main Branch Build"),
        .is_enabled = true,
    };
    items[1] = .{
        .id = try allocator.dupe(u8, "workflow-demo-release"),
        .name = try allocator.dupe(u8, "Release Candidate"),
        .is_enabled = true,
    };

    return items;
}

fn mockBuildRuns(allocator: Allocator, _: []const u8) ![]types.CiBuildRun {
    const items = try allocator.alloc(types.CiBuildRun, 3);
    errdefer allocator.free(items);

    items[0] = try mockBuildRun(
        allocator,
        "run-demo-101",
        "101",
        "main",
        "finished",
        "succeeded",
        "2026-02-25T08:10:00Z",
        "2026-02-25T08:11:00Z",
        "2026-02-25T08:18:00Z",
    );
    items[1] = try mockBuildRun(
        allocator,
        "run-demo-100",
        "100",
        "main",
        "finished",
        "failed",
        "2026-02-24T14:00:00Z",
        "2026-02-24T14:01:00Z",
        "2026-02-24T14:09:00Z",
    );
    items[2] = try mockBuildRun(
        allocator,
        "run-demo-99",
        "99",
        "release/1.5",
        "running",
        "-",
        "2026-02-24T11:00:00Z",
        "2026-02-24T11:01:00Z",
        "-",
    );

    return items;
}

fn mockCreatedBuildRun(allocator: Allocator, _: []const u8) !types.CiBuildRun {
    return mockBuildRun(
        allocator,
        "run-demo-new",
        "102",
        "main",
        "created",
        "-",
        "2026-02-25T09:00:00Z",
        "-",
        "-",
    );
}

fn mockBuildRunDetail(allocator: Allocator, build_run_id: []const u8) !types.CiBuildRun {
    return mockBuildRun(
        allocator,
        build_run_id,
        "101",
        "main",
        "finished",
        "succeeded",
        "2026-02-25T08:10:00Z",
        "2026-02-25T08:11:00Z",
        "2026-02-25T08:18:00Z",
    );
}

fn mockBuildActions(allocator: Allocator, _: []const u8) ![]types.CiBuildAction {
    const items = try allocator.alloc(types.CiBuildAction, 3);
    errdefer allocator.free(items);

    items[0] = try mockAction(
        allocator,
        "action-prepare",
        "Prepare Build",
        "PREPARE",
        "succeeded",
        "2026-02-25T08:11:00Z",
        "2026-02-25T08:12:00Z",
    );
    items[1] = try mockAction(
        allocator,
        "action-build",
        "Compile & Test",
        "BUILD",
        "succeeded",
        "2026-02-25T08:12:00Z",
        "2026-02-25T08:16:00Z",
    );
    items[2] = try mockAction(
        allocator,
        "action-export",
        "Export Artifacts",
        "EXPORT",
        "succeeded",
        "2026-02-25T08:16:00Z",
        "2026-02-25T08:18:00Z",
    );

    return items;
}

fn mockBuildRun(
    allocator: Allocator,
    id: []const u8,
    number: []const u8,
    branch: []const u8,
    status: []const u8,
    completion: []const u8,
    created: []const u8,
    started: []const u8,
    finished: []const u8,
) !types.CiBuildRun {
    return .{
        .id = try allocator.dupe(u8, id),
        .number = try allocator.dupe(u8, number),
        .source_branch_or_tag = try allocator.dupe(u8, branch),
        .status = try allocator.dupe(u8, status),
        .completion_status = try allocator.dupe(u8, completion),
        .created_date = try allocator.dupe(u8, created),
        .started_date = try allocator.dupe(u8, started),
        .finished_date = try allocator.dupe(u8, finished),
    };
}

fn mockAction(
    allocator: Allocator,
    id: []const u8,
    name: []const u8,
    action_type: []const u8,
    status: []const u8,
    started: []const u8,
    finished: []const u8,
) !types.CiBuildAction {
    return .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .action_type = try allocator.dupe(u8, action_type),
        .status = try allocator.dupe(u8, status),
        .started_date = try allocator.dupe(u8, started),
        .finished_date = try allocator.dupe(u8, finished),
    };
}

fn mockArtifactsForAction(allocator: Allocator, action_id: []const u8) ![]types.CiArtifact {
    const items = try allocator.alloc(types.CiArtifact, 2);
    errdefer allocator.free(items);

    items[0] = .{
        .id = try allocator.dupe(u8, "artifact-log"),
        .file_name = try allocator.dupe(u8, "build.log"),
        .file_type = try allocator.dupe(u8, "LOG"),
        .download_url = try std.fmt.allocPrint(allocator, "mock://{s}/build.log", .{action_id}),
    };
    items[1] = .{
        .id = try allocator.dupe(u8, "artifact-xcresult"),
        .file_name = try allocator.dupe(u8, "result.xcresult"),
        .file_type = try allocator.dupe(u8, "XCODE_RESULT_BUNDLE"),
        .download_url = try std.fmt.allocPrint(allocator, "mock://{s}/result.xcresult", .{action_id}),
    };
    return items;
}

fn sanitizeFileNameAlloc(allocator: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (raw) |c| {
        const safe = switch (c) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0 => '_',
            else => c,
        };
        try out.append(allocator, safe);
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "artifact.bin");
    }
    return out.toOwnedSlice(allocator);
}
