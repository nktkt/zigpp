//! Structured concurrency primitives for Zig++. Modeled on Zig 0.16's
//! "I/O as an interface" direction: tasks are spawned through an explicit
//! `TaskGroup` bound to an allocator, cancellation is cooperative via a
//! `CancellationToken`, and lifetimes are scoped — leaving a group's
//! `join`/`deinit` window cancels any still-running children.

const std = @import("std");

pub const Task = struct {
    const Self = @This();

    handle: ?*anyopaque = null,

    pub fn cancel(self: *Self) void {
        _ = self;
        @panic("TODO: Task.cancel not yet implemented");
    }
};

pub const CancellationToken = struct {
    const Self = @This();

    cancelled: bool = false,

    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled;
    }

    pub fn cancel(self: *Self) void {
        self.cancelled = true;
    }
};

pub const TaskGroup = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    token: CancellationToken = .{},

    pub fn init(allocator: std.mem.Allocator) TaskGroup {
        return .{ .allocator = allocator };
    }

    pub fn spawn(self: *Self, comptime f: anytype, args: anytype) !void {
        _ = self;
        _ = f;
        _ = args;
        @panic("TODO: TaskGroup.spawn not yet implemented");
    }

    pub fn join(self: *Self) !void {
        _ = self;
        @panic("TODO: TaskGroup.join not yet implemented");
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        @panic("TODO: TaskGroup.deinit not yet implemented");
    }
};

pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        state: ?T = null,

        pub fn await_(self: *Self) T {
            _ = self;
            @panic("TODO: Future.await not yet implemented");
        }
    };
}
