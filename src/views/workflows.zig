const std = @import("std");
const table = @import("../widgets/table.zig");
const types = @import("../api/types.zig");

const Allocator = std.mem.Allocator;

const columns = [_]table.Column{
    .{ .title = "Workflow", .width = 36 },
    .{ .title = "Enabled", .width = 8 },
};

pub fn header(allocator: Allocator) ![]u8 {
    return table.formatHeader(allocator, &columns);
}

pub fn row(allocator: Allocator, item: types.CiWorkflow) ![]u8 {
    const enabled = if (item.is_enabled) "yes" else "no";
    const cells = [_][]const u8{ item.name, enabled };
    return table.formatRow(allocator, &columns, &cells);
}
