const std = @import("std");

pub fn main() !void {
    var x = init();
    var y = x;
    _ = y;
}
