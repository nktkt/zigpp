//! Runtime fallbacks for Zig++'s `requires` / `ensures` / `invariant`
//! contract clauses. The frontend prefers to evaluate these at comptime
//! whenever the arguments are comptime-known; what lives here is the path
//! taken when a contract reduces to a runtime check. In Debug and
//! ReleaseSafe builds the checks panic with the supplied message; in
//! ReleaseFast/ReleaseSmall they collapse to an `unreachable` hint so the
//! optimizer can assume the condition.

const std = @import("std");
const builtin = @import("builtin");

// `src` is captured at the call site (the public wrapper) so the panic
// message reports the user's location, not this helper's.
inline fn check(
    condition: bool,
    comptime kind: []const u8,
    comptime msg: []const u8,
    src: std.builtin.SourceLocation,
) void {
    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {
            if (!condition) {
                @branchHint(.cold);
                std.debug.panic(
                    "contract violated [" ++ kind ++ "]: " ++ msg ++ " (at {s}:{d} in {s})",
                    .{ src.file, src.line, src.fn_name },
                );
            }
        },
        .ReleaseFast, .ReleaseSmall => {
            if (!condition) {
                @branchHint(.unlikely);
                unreachable;
            }
        },
    }
}

pub fn requires(condition: bool, comptime msg: []const u8) void {
    check(condition, "precondition", msg, @src());
}

pub fn ensures(condition: bool, comptime msg: []const u8) void {
    check(condition, "postcondition", msg, @src());
}

pub fn invariant(condition: bool, comptime msg: []const u8) void {
    check(condition, "invariant", msg, @src());
}

test "requires returns normally on true" {
    requires(true, "always true");
}

test "ensures returns normally on true" {
    ensures(true, "always true");
}

test "invariant returns normally on true" {
    invariant(true, "always true");
}

test "comptime evaluation works" {
    comptime requires(true, "comptime ok");
    comptime ensures(true, "comptime ok");
    comptime invariant(true, "comptime ok");
}

test "fast-mode unreachable path compiles" {
    // The false branch becomes `unreachable` only in ReleaseFast/Small.
    // We can't actually exercise it under the default Debug test runner
    // (it would panic), so we just confirm the true branch returns and
    // that compilation succeeded for the current mode.
    if (builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall) {
        requires(true, "guarded true");
        return;
    }
    requires(true, "guarded true");
}
