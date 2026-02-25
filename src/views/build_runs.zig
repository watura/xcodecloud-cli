const std = @import("std");
const table = @import("../widgets/table.zig");
const types = @import("../api/types.zig");
const timefmt = @import("../util/timefmt.zig");

const Allocator = std.mem.Allocator;

const columns = [_]table.Column{
    .{ .title = "#", .width = 5, .alignment = .right },
    .{ .title = "Branch", .width = 20 },
    .{ .title = "Status", .width = 12 },
    .{ .title = "Created", .width = 20 },
};

pub fn header(allocator: Allocator) ![]u8 {
    return table.formatHeader(allocator, &columns);
}

pub fn row(allocator: Allocator, item: types.CiBuildRun) ![]u8 {
    const status = if (!std.mem.eql(u8, item.completion_status, "-"))
        item.completion_status
    else
        item.status;

    const created = try timefmt.isoUtcToLocalAlloc(allocator, item.created_date);
    defer allocator.free(created);
    const cells = [_][]const u8{ item.number, item.source_branch_or_tag, status, created };
    return table.formatRow(allocator, &columns, &cells);
}
