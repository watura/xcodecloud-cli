const std = @import("std");
const table = @import("../widgets/table.zig");
const types = @import("../api/types.zig");

const Allocator = std.mem.Allocator;

const columns = [_]table.Column{
    .{ .title = "Product", .width = 30 },
    .{ .title = "Bundle ID", .width = 36 },
};

pub fn header(allocator: Allocator) ![]u8 {
    return table.formatHeader(allocator, &columns);
}

pub fn row(allocator: Allocator, item: types.CiProduct) ![]u8 {
    const cells = [_][]const u8{ item.name, item.bundle_id };
    return table.formatRow(allocator, &columns, &cells);
}
