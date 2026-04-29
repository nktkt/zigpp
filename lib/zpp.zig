//! Umbrella module that gathers the runtime libraries the Zig++ frontend's
//! lowered code may reference. Users wire this into their build.zig as the
//! `zpp` module so that lowered references like `zpp.derive.Hash(@This())`
//! resolve.

pub const contracts = @import("contracts.zig");
pub const derive = @import("derive.zig");
pub const owned = @import("owned.zig");
// `async` is a reserved keyword in Zig, so the field is named `tasks`.
pub const tasks = @import("async.zig");
pub const testing = @import("testing.zig");
pub const traits = @import("traits.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
