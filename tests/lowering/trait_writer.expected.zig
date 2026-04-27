pub const Writer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (self: *anyopaque, bytes: []const u8) anyerror!usize,
        flush: *const fn (self: *anyopaque) anyerror!void,
    };

    pub fn write(self: Writer, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, bytes);
    }

    pub fn flush(self: Writer) anyerror!void {
        return self.vtable.flush(self.ptr);
    }
};
