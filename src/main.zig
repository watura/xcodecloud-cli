const std = @import("std");
const vaxis = @import("vaxis");

const ApiClient = @import("api/client.zig").Client;
const RootApp = @import("app.zig").App;

pub const panic = vaxis.Panic.call;

pub fn main() !void {
    if (!std.posix.isatty(std.posix.STDIN_FILENO) or !std.posix.isatty(std.posix.STDOUT_FILENO)) {
        std.log.err("xcodecloud-cli requires an interactive TTY.", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var api = try ApiClient.init(allocator);
    defer api.deinit();

    var root = try RootApp.init(allocator, &api);
    defer root.deinit();

    var app = try vaxis.vxfw.App.init(allocator);
    defer app.deinit();

    try app.run(root.widget(), .{ .framerate = 30 });
}

test "imports" {
    std.testing.refAllDecls(@This());
}
