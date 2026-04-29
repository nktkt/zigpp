//! Structured concurrency primitives for Zig++. Modeled on Zig 0.16's
//! "I/O as an interface" direction: tasks are spawned through an explicit
//! `TaskGroup` bound to an allocator, cancellation is cooperative via a
//! `CancellationToken`, and lifetimes are scoped — a `TaskGroup` owns the
//! `std.Thread` handles for every child it spawns and `join` is the
//! sole mechanism for retiring them.

const std = @import("std");
const builtin = @import("builtin");

/// Cooperative cancellation flag. Producers call `cancel`; consumers poll
/// `isCancelled` from inside their work loop and exit early when set.
///
/// Memory ordering: a single boolean transitions `false -> true` exactly
/// once. There is no payload to publish alongside it, so `.monotonic` on
/// both sides is sufficient — we only need atomicity, not synchronization
/// of other writes.
pub const CancellationToken = struct {
    flag: std.atomic.Value(bool),

    pub fn init() CancellationToken {
        return .{ .flag = std.atomic.Value(bool).init(false) };
    }

    pub fn cancel(self: *CancellationToken) void {
        self.flag.store(true, .monotonic);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        // `Value.load` takes `*Value`, not `*const Value`. Cast away const
        // for the read — the underlying op is a pure load and is safe to
        // perform through a shared-immutable view.
        const mut: *std.atomic.Value(bool) = @constCast(&self.flag);
        return mut.load(.monotonic);
    }
};

/// Lightweight wrapper around a `std.Thread` plus a per-task
/// `CancellationToken`. Useful when a single task needs an addressable
/// cancel signal without standing up a whole `TaskGroup`.
pub const Task = struct {
    thread: std.Thread,
    token: CancellationToken,

    pub fn cancel(self: *Task) void {
        self.token.cancel();
    }

    pub fn join(self: *Task) void {
        self.thread.join();
    }
};

/// Concurrent task runner. Owns the `std.Thread` handles for every
/// child thread spawned through it; `join` retires them in spawn order.
pub const TaskGroup = struct {
    allocator: std.mem.Allocator,
    threads: std.ArrayListUnmanaged(std.Thread),

    pub fn init(allocator: std.mem.Allocator) TaskGroup {
        return .{
            .allocator = allocator,
            .threads = .{},
        };
    }

    /// Spawns a new thread running `func(args...)`. Signature mirrors
    /// `std.Thread.spawn` (minus the `SpawnConfig`, which we pass empty
    /// to take the platform default stack size). Errors propagate from
    /// `std.Thread.spawn` plus `error.OutOfMemory` from the handle list.
    pub fn spawn(self: *TaskGroup, comptime func: anytype, args: anytype) !void {
        // Reserve list capacity *before* spawning so an OOM here can't
        // leak a running thread we have no way to track.
        try self.threads.ensureUnusedCapacity(self.allocator, 1);
        const t = try std.Thread.spawn(.{}, func, args);
        self.threads.appendAssumeCapacity(t);
    }

    /// Joins every still-tracked thread in spawn order, then clears the
    /// list (but preserves the underlying buffer — `deinit` releases it).
    /// Idempotent: a second call on an emptied group is a no-op.
    pub fn join(self: *TaskGroup) !void {
        for (self.threads.items) |t| {
            t.join();
        }
        self.threads.clearRetainingCapacity();
    }

    /// Releases the thread-handle buffer. If any threads are still
    /// un-joined we are in a leak: the threads keep running with
    /// references into now-dropped allocator memory. In safety builds
    /// (Debug / ReleaseSafe) we panic loudly. In release-fast/small we
    /// fall back to a defensive join so the binary at least doesn't
    /// detach into UB — the panic-vs-defensive-join split is intentional
    /// and trades a noisy bug report in dev for resilience in prod.
    pub fn deinit(self: *TaskGroup) void {
        if (self.threads.items.len != 0) {
            if (std.debug.runtime_safety) {
                std.debug.panic(
                    "TaskGroup.deinit called with {d} un-joined thread(s); call join() first",
                    .{self.threads.items.len},
                );
            } else {
                for (self.threads.items) |t| t.join();
            }
        }
        self.threads.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Single-shot result holder. The producer thread calls `set` exactly
/// once; consumers block on `wait` (or `get` after a known-completed
/// wait). Built on `std.Thread.ResetEvent` for the parking primitive.
///
/// Note: the `T` is plain-by-value — caller is responsible for the
/// lifetime of any pointers it contains. For `void`-typed futures use
/// `Future(void)` and rely on `set({})` / `wait()` purely for
/// synchronization.
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        event: std.Thread.ResetEvent = .{},
        value: T = undefined,

        pub fn init() Self {
            return .{};
        }

        pub fn set(self: *Self, v: T) void {
            self.value = v;
            self.event.set();
        }

        pub fn wait(self: *Self) T {
            self.event.wait();
            return self.value;
        }

        pub fn isReady(self: *Self) bool {
            return self.event.isSet();
        }
    };
}

// ---------------- tests ----------------

const testing = std.testing;

test "TaskGroup empty init/deinit" {
    var g = TaskGroup.init(testing.allocator);
    defer g.deinit();
    try g.join(); // no-op on empty group
}

test "TaskGroup spawns 4 threads that increment a shared counter" {
    const Worker = struct {
        fn run(counter: *std.atomic.Value(u32)) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    var counter = std.atomic.Value(u32).init(0);

    var g = TaskGroup.init(testing.allocator);
    defer g.deinit();

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try g.spawn(Worker.run, .{&counter});
    }
    try g.join();

    try testing.expectEqual(@as(u32, 4), counter.load(.monotonic));
}

test "CancellationToken init/cancel/isCancelled" {
    var tok = CancellationToken.init();
    try testing.expect(!tok.isCancelled());
    tok.cancel();
    try testing.expect(tok.isCancelled());
}

test "polling loop exits when cancellation is signaled" {
    const Poller = struct {
        fn run(token: *CancellationToken, observed: *std.atomic.Value(bool)) void {
            while (!token.isCancelled()) {
                std.Thread.yield() catch {};
            }
            observed.store(true, .monotonic);
        }
    };

    var token = CancellationToken.init();
    var observed = std.atomic.Value(bool).init(false);

    var g = TaskGroup.init(testing.allocator);
    defer g.deinit();

    try g.spawn(Poller.run, .{ &token, &observed });
    token.cancel();
    try g.join();

    try testing.expect(observed.load(.monotonic));
}

test "TaskGroup supports multiple sequential spawn/join cycles" {
    const Worker = struct {
        fn run(counter: *std.atomic.Value(u32)) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    var counter = std.atomic.Value(u32).init(0);

    var g = TaskGroup.init(testing.allocator);
    defer g.deinit();

    try g.spawn(Worker.run, .{&counter});
    try g.spawn(Worker.run, .{&counter});
    try g.join();

    try g.spawn(Worker.run, .{&counter});
    try g.spawn(Worker.run, .{&counter});
    try g.join();

    try testing.expectEqual(@as(u32, 4), counter.load(.monotonic));
}

test "Future(u32) blocks until set, then returns the value" {
    const Producer = struct {
        fn run(fut: *Future(u32)) void {
            fut.set(42);
        }
    };

    var fut = Future(u32).init();
    var g = TaskGroup.init(testing.allocator);
    defer g.deinit();

    try g.spawn(Producer.run, .{&fut});
    const got = fut.wait();
    try g.join();

    try testing.expectEqual(@as(u32, 42), got);
}

comptime {
    // Reference Task so the type compiles even when no inline test uses it.
    _ = Task;
    _ = builtin;
}
