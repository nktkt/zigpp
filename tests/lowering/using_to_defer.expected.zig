const std = @import("std");

pub fn main() !void {
    var x = std.heap.page_allocator.create(u32) catch return; defer x.deinit();
}
