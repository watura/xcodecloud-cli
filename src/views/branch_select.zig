const std = @import("std");
const table = @import("../widgets/table.zig");
const types = @import("../api/types.zig");

const Allocator = std.mem.Allocator;

const columns = [_]table.Column{
    .{ .title = "Branch", .width = 40 },
    .{ .title = "Kind", .width = 10 },
};

pub fn header(allocator: Allocator) ![]u8 {
    return table.formatHeader(allocator, &columns);
}

pub fn row(allocator: Allocator, item: types.ScmGitReference) ![]u8 {
    const cells = [_][]const u8{ item.name, item.kind };
    return table.formatRow(allocator, &columns, &cells);
}
