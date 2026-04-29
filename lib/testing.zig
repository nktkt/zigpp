//! Test helpers for end-user Zig++ code: seeded random property tests and
//! golden-file (snapshot) comparison. Both helpers are self-contained and
//! free of compiler dependencies — this is the downstream-facing partner to
//! `compiler/property.zig`, which exercises the lowerer itself.

const std = @import("std");

/// Run a property test: generate `iterations` random inputs via `gen`, pass
/// each to `check`, and fail on the first violation. The seed makes failures
/// reproducible.
///
/// `gen` must be `fn (std.mem.Allocator, *std.Random.DefaultPrng) !T` and
/// `check` must be `fn (T) anyerror!void`. We take them as `comptime anytype`
/// because Zig has no closures — passing function pointers with a
/// concrete signature would force every call site to declare `T` up front,
/// while comptime-resolved function values let `T` be inferred from `gen`.
pub fn property(
    allocator: std.mem.Allocator,
    iterations: usize,
    seed: u64,
    comptime gen: anytype,
    comptime check: anytype,
) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const input = try gen(allocator, &prng);
        // Free `input` if it owns memory (slices, arrays of pointers).
        // Scalars take this branch as a no-op via comptime dispatch.
        defer freeIfNeeded(allocator, input);

        check(input) catch |err| {
            const rendered = std.fmt.allocPrint(
                allocator,
                "{any}",
                .{input},
            ) catch "<allocPrint OOM>";
            defer if (!std.mem.eql(u8, rendered, "<allocPrint OOM>"))
                allocator.free(rendered);

            std.debug.print(
                "[zpp.testing] property failed at iter {d}, seed=0x{x}\n",
                .{ i, seed },
            );
            std.debug.print("[zpp.testing] input: {s}\n", .{rendered});
            std.debug.print("[zpp.testing] error: {s}\n", .{@errorName(err)});
            return err;
        };
    }
}

fn freeIfNeeded(allocator: std.mem.Allocator, input: anytype) void {
    const T = @TypeOf(input);
    const ti = @typeInfo(T);
    if (ti == .pointer and ti.pointer.size == .slice) {
        allocator.free(input);
    }
}

/// Compare `actual` against the file at `snapshot_path` (resolved against
/// the current working directory). On first run — when the file does not
/// exist — we *write* `actual` to the path and return success, so the
/// snapshot is created lazily by simply running the test once. Subsequent
/// runs require byte-exact equality.
pub fn snapshot(actual: []const u8, snapshot_path: []const u8) !void {
    const cwd = std.fs.cwd();

    // Try reading the snapshot. If missing, create it and succeed.
    const max_size: usize = 16 * 1024 * 1024;
    const expected = cwd.readFileAlloc(
        std.heap.page_allocator,
        snapshot_path,
        max_size,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(snapshot_path)) |dir| {
                cwd.makePath(dir) catch {};
            }
            try cwd.writeFile(.{ .sub_path = snapshot_path, .data = actual });
            return;
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(expected);

    if (std.mem.eql(u8, expected, actual)) return;

    std.debug.print("[zpp.testing] snapshot mismatch at {s}\n", .{snapshot_path});
    const exp_preview = expected[0..@min(80, expected.len)];
    const act_preview = actual[0..@min(80, actual.len)];
    std.debug.print(
        "[zpp.testing]   expected ({d} bytes): \"{s}\"...\n",
        .{ expected.len, exp_preview },
    );
    std.debug.print(
        "[zpp.testing]   actual   ({d} bytes): \"{s}\"...\n",
        .{ actual.len, act_preview },
    );
    return error.SnapshotMismatch;
}

// ---------- generators ----------

/// Generator factory: returns a function that yields a uniformly random
/// integer of type `T`. Plain free function form (no curry trick) — caller
/// writes `genInt(u32)(allocator, &prng)`.
pub fn genInt(comptime T: type) fn (std.mem.Allocator, *std.Random.DefaultPrng) std.mem.Allocator.Error!T {
    return struct {
        fn gen(_: std.mem.Allocator, prng: *std.Random.DefaultPrng) std.mem.Allocator.Error!T {
            return prng.random().int(T);
        }
    }.gen;
}

/// Generator factory: returns a function that yields a freshly allocated
/// `[]u8` of length 0..=max_len with random byte contents. Caller frees.
pub fn genBytes(comptime max_len: usize) fn (std.mem.Allocator, *std.Random.DefaultPrng) std.mem.Allocator.Error![]u8 {
    return struct {
        fn gen(allocator: std.mem.Allocator, prng: *std.Random.DefaultPrng) std.mem.Allocator.Error![]u8 {
            const r = prng.random();
            const len = r.uintLessThan(usize, max_len + 1);
            const buf = try allocator.alloc(u8, len);
            r.bytes(buf);
            return buf;
        }
    }.gen;
}

// ---------- inline tests ----------

fn alwaysOk(_: u32) anyerror!void {
    return;
}

test "property runs the requested number of iterations on a trivial check" {
    try property(std.testing.allocator, 32, 0xC0FFEE, genInt(u32), alwaysOk);
}

// Counter shared between the test and the failing check. Module-level
// because `check` is comptime-resolved and can't capture locals.
var fail_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn failOnFifth(_: u32) anyerror!void {
    const n = fail_counter.fetchAdd(1, .monotonic) + 1;
    if (n == 5) return error.TestExpected;
}

test "property propagates the first error and stops" {
    fail_counter.store(0, .monotonic);
    const result = property(std.testing.allocator, 100, 0xABCDEF, genInt(u32), failOnFifth);
    try std.testing.expectError(error.TestExpected, result);
    try std.testing.expectEqual(@as(u32, 5), fail_counter.load(.monotonic));
}

test "snapshot creates the file on first call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const file_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ dir_path, "snap.txt" },
    );
    defer std.testing.allocator.free(file_path);

    try snapshot("hello world", file_path);

    const got = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        file_path,
        1024,
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "snapshot succeeds when bytes match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const file_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ dir_path, "snap.txt" },
    );
    defer std.testing.allocator.free(file_path);

    try snapshot("same bytes", file_path);
    try snapshot("same bytes", file_path);
}

test "snapshot returns SnapshotMismatch when bytes differ" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const file_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ dir_path, "snap.txt" },
    );
    defer std.testing.allocator.free(file_path);

    try snapshot("first version", file_path);
    try std.testing.expectError(
        error.SnapshotMismatch,
        snapshot("second version", file_path),
    );
}

test "genBytes yields slices within the requested length bound" {
    var prng = std.Random.DefaultPrng.init(42);
    const gen = genBytes(16);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const buf = try gen(std.testing.allocator, &prng);
        defer std.testing.allocator.free(buf);
        try std.testing.expect(buf.len <= 16);
    }
}
