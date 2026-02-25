const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Align = enum {
    left,
    right,
};

pub const Column = struct {
    title: []const u8,
    width: usize,
    alignment: Align = .left,
};

pub fn formatHeader(allocator: Allocator, columns: []const Column) ![]u8 {
    var titles: std.ArrayListUnmanaged([]const u8) = .empty;
    defer titles.deinit(allocator);

    try titles.ensureTotalCapacity(allocator, columns.len);
    for (columns) |column| {
        titles.appendAssumeCapacity(column.title);
    }

    return formatRow(allocator, columns, titles.items);
}

pub fn formatRow(allocator: Allocator, columns: []const Column, cells: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (columns, 0..) |column, idx| {
        const value = if (idx < cells.len) cells[idx] else "";
        try appendCell(&out, allocator, value, column.width, column.alignment);
        if (idx + 1 < columns.len) {
            try out.appendSlice(allocator, "  ");
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendCell(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    value: []const u8,
    width: usize,
    alignment: Align,
) !void {
    const clipped = if (value.len > width) value[0..width] else value;
    const padding = width - clipped.len;

    if (alignment == .right) {
        try appendSpaces(out, allocator, padding);
    }

    try out.appendSlice(allocator, clipped);

    if (alignment == .left) {
        try appendSpaces(out, allocator, padding);
    }
}

fn appendSpaces(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, count: usize) !void {
    if (count == 0) return;
    try out.ensureUnusedCapacity(allocator, count);
    for (0..count) |_| {
        out.appendAssumeCapacity(' ');
    }
}
