const std = @import("std");

const Allocator = std.mem.Allocator;

pub const base_url = "https://api.appstoreconnect.apple.com";

pub fn ciProducts() []const u8 {
    return "/v1/ciProducts?include=app";
}

pub fn workflowsForProduct(allocator: Allocator, product_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/v1/ciProducts/{s}/workflows", .{product_id});
}

pub fn buildRunsForWorkflow(allocator: Allocator, workflow_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "/v1/ciWorkflows/{s}/buildRuns?include=sourceBranchOrTag&limit=50",
        .{workflow_id},
    );
}

pub fn buildRunById(allocator: Allocator, build_run_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "/v1/ciBuildRuns/{s}?include=sourceBranchOrTag",
        .{build_run_id},
    );
}

pub fn buildActionsForRun(allocator: Allocator, build_run_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/v1/ciBuildRuns/{s}/actions", .{build_run_id});
}

pub fn createBuildRunPayload(allocator: Allocator, workflow_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"data\":{{\"type\":\"ciBuildRuns\",\"relationships\":{{\"workflow\":{{\"data\":{{\"type\":\"ciWorkflows\",\"id\":\"{s}\"}}}}}}}}}}",
        .{workflow_id},
    );
}
