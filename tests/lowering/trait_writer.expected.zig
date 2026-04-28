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

    pub fn from(impl_ptr: anytype) Writer {
        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;
        const gen = struct {
            fn write_wrapper(self: *anyopaque, bytes: []const u8) anyerror!usize {
                const t: *ImplT = @ptrCast(@alignCast(self));
                return t.write(bytes);
            }
            fn flush_wrapper(self: *anyopaque) anyerror!void {
                const t: *ImplT = @ptrCast(@alignCast(self));
                return t.flush();
            }
            const vt: VTable = .{ .write = write_wrapper, .flush = flush_wrapper };
        };
        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };
    }
};
