const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn line(allocator: Allocator, can_go_back: bool, can_run: bool) Allocator.Error![]u8 {
    if (can_go_back and can_run) {
        return allocator.dupe(u8, "j/k:Move  Enter:Open  Esc/q:Back  r:Run Build  R:Reload  Ctrl+C:Quit");
    }
    if (can_go_back) {
        return allocator.dupe(u8, "j/k:Move  Enter:Open  Esc/q:Back  R:Reload  Ctrl+C:Quit");
    }
    return allocator.dupe(u8, "j/k:Move  Enter:Open  q:Quit  R:Reload  Ctrl+C:Quit");
}
