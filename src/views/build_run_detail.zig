const std = @import("std");
const table = @import("../widgets/table.zig");
const types = @import("../api/types.zig");
const timefmt = @import("../util/timefmt.zig");

const Allocator = std.mem.Allocator;

const action_columns = [_]table.Column{
    .{ .title = "Action", .width = 26 },
    .{ .title = "Type", .width = 10 },
    .{ .title = "Status", .width = 10 },
    .{ .title = "Started", .width = 19 },
    .{ .title = "Finished", .width = 19 },
};

pub fn actionHeader(allocator: Allocator) ![]u8 {
    return table.formatHeader(allocator, &action_columns);
}

pub fn actionRow(allocator: Allocator, item: types.CiBuildAction) ![]u8 {
    const started = try timefmt.isoUtcToLocalAlloc(allocator, item.started_date);
    defer allocator.free(started);
    const finished = try timefmt.isoUtcToLocalAlloc(allocator, item.finished_date);
    defer allocator.free(finished);

    const cells = [_][]const u8{
        item.name,
        item.action_type,
        item.status,
        started,
        finished,
    };
    return table.formatRow(allocator, &action_columns, &cells);
}

pub fn summaryLine(allocator: Allocator, run: types.CiBuildRun) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Run #{s}  Branch:{s}  Status:{s}/{s}",
        .{ run.number, run.source_branch_or_tag, run.status, run.completion_status },
    );
}
