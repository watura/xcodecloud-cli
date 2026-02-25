const std = @import("std");
const table = @import("../widgets/table.zig");
const types = @import("../api/types.zig");

const Allocator = std.mem.Allocator;

const artifact_columns = [_]table.Column{
    .{ .title = "File", .width = 30 },
    .{ .title = "Type", .width = 20 },
    .{ .title = "Download URL", .width = 70 },
};

pub fn artifactHeader(allocator: Allocator) ![]u8 {
    return table.formatHeader(allocator, &artifact_columns);
}

pub fn artifactRow(allocator: Allocator, item: types.CiArtifact) ![]u8 {
    const cells = [_][]const u8{
        item.file_name,
        item.file_type,
        item.download_url,
    };
    return table.formatRow(allocator, &artifact_columns, &cells);
}
