const User = struct {
    id: u64,
    name: []const u8,

    pub const hash = zpp.derive.Hash(@This());
    pub const json = zpp.derive.Json(@This());
};
