const std = @import("std");
const jwt = @import("../auth/jwt.zig");
const endpoints = @import("endpoints.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const max_http_attempts: u8 = 3;
const retry_base_delay_ns: u64 = 250 * std.time.ns_per_ms;

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

    pub fn fetchArtifactContent(self: *Client, artifact: types.CiArtifact) ![]u8 {
        if (std.mem.startsWith(u8, artifact.download_url, "mock://")) {
            return mockLogContent(self.allocator, artifact);
        }

        var attempt: u8 = 0;
        while (attempt < max_http_attempts) : (attempt += 1) {
            var sink: std.Io.Writer.Allocating = .init(self.allocator);
            defer sink.deinit();

            const result = self.http.fetch(.{
                .location = .{ .url = artifact.download_url },
                .method = .GET,
                .response_writer = &sink.writer,
            }) catch |err| {
                if (attempt + 1 < max_http_attempts and isRetryableFetchError(err)) {
                    resetHttpClient(self);
                    std.Thread.sleep(retryDelayNs(attempt));
                    continue;
                }
                return err;
            };

            if (result.status.class() != .success) {
                if (attempt + 1 < max_http_attempts and isRetryableStatus(result.status)) {
                    resetHttpClient(self);
                    std.Thread.sleep(retryDelayNs(attempt));
                    continue;
                }
                return mapHttpStatusToError(result.status);
            }

            const raw = try self.allocator.dupe(u8, sink.written());
            if (isLogBundleArtifactType(artifact.file_type) or isZipData(raw)) {
                defer self.allocator.free(raw);
                return decodeLogBundleContent(self.allocator, raw);
            }

            return normalizeViewerText(self.allocator, raw);
        }

        return error.HttpRequestFailed;
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

        var attempt: u8 = 0;
        while (attempt < max_http_attempts) : (attempt += 1) {
            var sink: std.Io.Writer.Allocating = .init(self.allocator);
            defer sink.deinit();

            const result = self.http.fetch(.{
                .location = .{ .url = artifact.download_url },
                .method = .GET,
                .response_writer = &sink.writer,
            }) catch |err| {
                if (attempt + 1 < max_http_attempts and isRetryableFetchError(err)) {
                    resetHttpClient(self);
                    std.Thread.sleep(retryDelayNs(attempt));
                    continue;
                }
                return err;
            };

            if (result.status.class() != .success) {
                if (attempt + 1 < max_http_attempts and isRetryableStatus(result.status)) {
                    resetHttpClient(self);
                    std.Thread.sleep(retryDelayNs(attempt));
                    continue;
                }
                return mapHttpStatusToError(result.status);
            }

            var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(sink.written());
            return out_path;
        }

        return error.HttpRequestFailed;
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

        var headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
        };

        var attempt: u8 = 0;
        while (attempt < max_http_attempts) : (attempt += 1) {
            var sink: std.Io.Writer.Allocating = .init(self.allocator);
            defer sink.deinit();

            const result = self.http.fetch(.{
                .location = .{ .url = url },
                .method = method,
                .payload = payload,
                .extra_headers = if (payload != null) headers[0..3] else headers[0..2],
                .response_writer = &sink.writer,
            }) catch |err| {
                if (attempt + 1 < max_http_attempts and isRetryableFetchError(err)) {
                    resetHttpClient(self);
                    std.Thread.sleep(retryDelayNs(attempt));
                    continue;
                }
                return err;
            };

            if (result.status.class() != .success) {
                if (attempt + 1 < max_http_attempts and isRetryableStatus(result.status)) {
                    resetHttpClient(self);
                    std.Thread.sleep(retryDelayNs(attempt));
                    continue;
                }
                return mapHttpStatusToError(result.status);
            }

            return self.allocator.dupe(u8, sink.written());
        }

        return error.HttpRequestFailed;
    }
};

fn retryDelayNs(attempt: u8) u64 {
    return retry_base_delay_ns * (@as(u64, attempt) + 1);
}

fn isRetryableStatus(status: std.http.Status) bool {
    const code: u16 = @intFromEnum(status);
    return code == 429 or code == 500 or code == 502 or code == 503 or code == 504;
}

fn mapHttpStatusToError(status: std.http.Status) anyerror {
    return switch (@intFromEnum(status)) {
        401 => error.Unauthorized,
        403 => error.Forbidden,
        404 => error.NotFound,
        429 => error.RateLimited,
        else => error.HttpRequestFailed,
    };
}

fn isRetryableFetchError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        => true,
        else => false,
    };
}

fn resetHttpClient(self: *Client) void {
    self.http.deinit();
    self.http = .{ .allocator = self.allocator };
}

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

fn mockLogContent(allocator: Allocator, artifact: types.CiArtifact) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\2026-02-25T08:11:00.102Z [INFO] Build action started: {s}
        \\2026-02-25T08:11:01.001Z [INFO] Select Xcode 16.1 (16B40)
        \\2026-02-25T08:11:02.942Z [INFO] Resolve Swift Package dependencies
        \\2026-02-25T08:11:03.487Z [INFO] Clean build folder
        \\2026-02-25T08:11:05.014Z [INFO] Run script: ci_prebuild.sh
        \\2026-02-25T08:11:05.622Z [WARN] Optional secret \"SLACK_WEBHOOK\" is not set; notifications disabled
        \\2026-02-25T08:11:08.913Z [INFO] xcodebuild -workspace SampleApp.xcworkspace -scheme SampleApp -configuration Release -destination generic/platform=iOS -derivedDataPath /Volumes/workspace/DerivedData
        \\2026-02-25T08:11:17.275Z [INFO] CompileSwiftSources normal arm64 com.apple.xcode.tools.swift.compiler
        \\2026-02-25T08:11:23.144Z [INFO] Ld /Volumes/workspace/Build/Products/Release-iphoneos/SampleApp.app/SampleApp normal
        \\2026-02-25T08:11:24.552Z [INFO] CodeSign /Volumes/workspace/Build/Products/Release-iphoneos/SampleApp.app
        \\2026-02-25T08:11:25.097Z [INFO] Build Succeeded (143.8 sec)
        \\2026-02-25T08:11:25.314Z [INFO] Archive written to /Volumes/workspace/Artifacts/SampleApp.xcarchive
        \\2026-02-25T08:11:25.978Z [INFO] Upload artifact complete: {s}
        \\2026-02-25T08:11:26.001Z [INFO] Done
    ,
        .{ artifact.file_name, artifact.file_name },
    );
}

fn decodeLogBundleContent(allocator: Allocator, zipped: []const u8) ![]u8 {
    try std.fs.cwd().makePath(".context/tmp");

    const zip_path = try std.fmt.allocPrint(
        allocator,
        ".context/tmp/log_bundle_{d}.zip",
        .{std.time.nanoTimestamp()},
    );
    defer allocator.free(zip_path);

    {
        var file = try std.fs.cwd().createFile(zip_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(zipped);
    }
    defer std.fs.cwd().deleteFile(zip_path) catch {};

    const list = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "unzip", "-Z1", zip_path },
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "LOG_BUNDLE decode failed ({s}). Use d:Download.",
            .{@errorName(err)},
        );
    };
    defer allocator.free(list.stdout);
    defer allocator.free(list.stderr);

    if (!termExitedZero(list.term)) {
        return allocator.dupe(u8, "LOG_BUNDLE list failed. Use d:Download.");
    }

    const entry = selectLogBundleEntry(list.stdout) orelse {
        return allocator.dupe(u8, "LOG_BUNDLE had no extractable files. Use d:Download.");
    };

    const extracted = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "unzip", "-p", zip_path, entry },
        .max_output_bytes = 32 * 1024 * 1024,
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "LOG_BUNDLE extraction failed ({s}). Use d:Download.",
            .{@errorName(err)},
        );
    };
    defer allocator.free(extracted.stderr);

    if (!termExitedZero(extracted.term)) {
        allocator.free(extracted.stdout);
        return allocator.dupe(u8, "LOG_BUNDLE extraction failed. Use d:Download.");
    }

    return normalizeViewerText(allocator, extracted.stdout);
}

fn selectLogBundleEntry(listing: []const u8) ?[]const u8 {
    var first_file: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, listing, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0 or line[line.len - 1] == '/') continue;
        if (first_file == null) {
            first_file = line;
        }
        if (isPreferredLogFile(line)) {
            return line;
        }
    }
    return first_file;
}

fn isPreferredLogFile(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".log") or
        endsWithIgnoreCase(path, ".txt") or
        endsWithIgnoreCase(path, ".json") or
        endsWithIgnoreCase(path, ".xml") or
        endsWithIgnoreCase(path, ".md") or
        endsWithIgnoreCase(path, ".xcactivitylog");
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn isLogBundleArtifactType(file_type: []const u8) bool {
    return std.mem.eql(u8, file_type, "LOG_BUNDLE");
}

fn isZipData(data: []const u8) bool {
    if (data.len < 4) return false;
    if (data[0] != 'P' or data[1] != 'K') return false;
    return (data[2] == 3 and data[3] == 4) or
        (data[2] == 5 and data[3] == 6) or
        (data[2] == 7 and data[3] == 8);
}

fn normalizeViewerText(allocator: Allocator, content: []u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(content)) {
        return content;
    }
    allocator.free(content);
    return allocator.dupe(u8, "Artifact content is binary/non-UTF8. Use d:Download.");
}

fn termExitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
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
