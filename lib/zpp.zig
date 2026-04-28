//! Umbrella module that gathers the runtime libraries the Zig++ frontend's
//! lowered code may reference. Users wire this into their build.zig as the
//! `zpp` module so that lowered references like `zpp.derive.Hash(@This())`
//! resolve.

pub const derive = @import("derive.zig");
pub const owned = @import("owned.zig");
pub const contracts = @import("contracts.zig");
