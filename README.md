# Zig++

[![ci](https://github.com/nktkt/zigpp/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nktkt/zigpp/actions/workflows/ci.yml)

A research-stage frontend compiler that lowers `.zpp` source — Zig with extra
language affordances — into plain `.zig` and hands it off to the upstream Zig
toolchain.

> Status: **proof of concept**. The full design is laid out in
> `Zig++ Design Draft v0.1`; this repository contains the minimum-but-actually-
> running implementation, not the finished language.

## What this is

Zig++ is the experiment of asking: *"what would C++ have looked like if it had
been built on Zig instead of C?"* The constraint is to add high-level
abstractions without breaking Zig's core principle that **costs are visible**:

- No hidden control flow.
- No hidden allocations.
- No hidden destructors.
- No macros.

The added surface so far:

- Named `trait` interfaces.
- `impl Trait` (static dispatch via comptime generics) and `dyn Trait` (explicit
  fat-pointer dispatch).
- Explicit RAII via the `using` keyword.
- Affine ownership markers: `own var`, `move`.
- `effects(.noalloc, .io, ...)` annotations on functions.
- A small set of compile-time ownership checks.

Everything goes through a text/lexer-based lowering pipeline that produces
human-readable Zig — you can read the output and understand what happened.

## Pipeline

```
.zpp source
   |
   v
+--+----------------------------------+
|  Zig++ frontend                     |
|    line rules (using/own/move/...)  |
|    structural trait lowering        |
|    ownership checks (E0001/2/10)    |
+--+----------------------------------+
   |
   v   generated .zig
   |
   v
+--+--------------+
|  zig (upstream) |
+--+--------------+
   |
   v   binary / library
```

The `compiler/` directory implements the frontend; everything else (codegen,
linking, optimization) is delegated to Zig itself.

## Requirements

- **Zig 0.15.2.** This is what was installed during development; later versions
  may break the build.zig. The project's `build.zig.zon` advertises
  `minimum_zig_version = "0.15.0"`.

## Quick start

```sh
# Build the zpp binary and the zpp_lib static library.
zig build

# Run all unit tests (lexer, lowering, ownership checks, etc.).
zig build test

# Run the .zpp integration test suite.
zig build test-zpp

# Lower a single .zpp file and print the generated .zig to stdout.
./zig-out/bin/zpp lower path/to/file.zpp

# Walk a project directory, lower every .zpp into <dir>/.zpp-out/.
./zig-out/bin/zpp build path/to/project

# Lower a project, then build and run it via `zig build run`.
./zig-out/bin/zpp run examples/hello_runnable
# -> hello, zigpp!

# Run all ownership / effect checks on a project (no codegen).
./zig-out/bin/zpp check examples
# -> [zpp] checked 5 files, 0 findings
```

## Language features

### `using` — explicit RAII

```zig
using file = try File.open("log.txt");
try file.writeAll("hello\n");
```

Lowers to:

```zig
var file = try File.open("log.txt"); defer file.deinit();
try file.writeAll("hello\n");
```

Spelled-out at the call site. No invisible destructor at scope exit.

### `trait` — named interfaces

```zig
trait Writer {
    fn write(self, bytes: []const u8) !usize;
    fn flush(self) !void;
}
```

Lowers to a real Zig fat-pointer struct with a vtable and dispatch wrappers:

```zig
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
```

### `impl Trait` and `dyn Trait`

```zig
fn emit(w: impl Writer, msg: []const u8) !void { _ = try w.write(msg); }
fn logAll(w: dyn Writer, msgs: []const []const u8) !void { ... }
```

`impl Writer` lowers to `anytype` — comptime-monomorphized static dispatch.
`dyn Writer` lowers to `Writer` — the fat-pointer struct above.

### `own` / `move`

```zig
own var buf = try Buffer.init(allocator, 4096);
var moved = move buf;       // buf is now dead
consume(move moved);
```

Both keywords are stripped at codegen — they're affine-ownership markers for
the static checker, not runtime constructs.

### `effects(...)`

```zig
effects(.noalloc, .noio)
pub fn hashBytes(bytes: []const u8) u64 { ... }
```

Lines consisting solely of `effects(...)` are stripped at codegen and recorded
for the analyzer. Functions tagged `.noalloc` get a hidden-allocation check.

## Diagnostics

Three real ownership/effect checks ship with this proof of concept:

| Code  | Meaning                                  | Detection                                                      |
| ----- | ---------------------------------------- | -------------------------------------------------------------- |
| E0001 | Owned value was not deinitialized        | `own var x = ...` with no matching `using x` or `x.deinit()`   |
| E0002 | Owned value used after move              | Use of an identifier later than its `move` site, in same scope |
| E0010 | Hidden allocation in `noalloc` function  | Allocator method calls or pass-through inside `effects(.noalloc)` body |

These are token-stream checks, not a full semantic pass — sufficient for the
fixture suite, intentionally limited otherwise.

## Repo layout

```
zigpp/
  build.zig            top-level build script
  build.zig.zon        package manifest
  compiler/            frontend
    lexer.zig            Zig++ tokenizer (Zig + Zig++-specific keywords)
    lower_to_zig.zig     line-level lowering rules + pipeline entry
    trait_lower.zig      structural trait -> vtable lowering
    checks.zig           ownership / noalloc analyzers
    project.zig          recursive .zpp -> .zig project walker
    diagnostics.zig      diagnostic types and code constants
    parser.zig, sema.zig, ast.zig   stubs for future AST-based pipeline
    root.zig             zpp_lib import surface
  lib/                 runtime support library (zpp.* namespace)
    owned.zig            Owned(T), Borrow(T), ArenaScope, DeinitGuard
    contracts.zig        requires / ensures / invariant
    dyn.zig, traits.zig, async.zig, testing.zig (skeletons)
  tools/               CLI binaries
    zpp.zig              main `zpp` driver
    zpp_fmt.zig, zpp_lsp.zig, zpp_doc.zig, zpp_migrate.zig (skeletons)
  examples/            .zpp demos
    hello_runnable/      end-to-end runnable Zig++ program
    hello_trait.zpp, owned_file.zpp, dyn_plugin.zpp, async_group.zpp
  tests/               integration runner + fixtures
    test_runner.zig      walks fixtures, dispatches per category
    compile/             must-lower-cleanly fixtures
    behavior/            programs whose stdout/stderr is asserted
    lowering/            byte-exact .expected.zig golden tests
    diagnostics/         must-emit-Exxxx fixtures
    no_hidden_alloc/     positive .noalloc conformance
```

## Test status

```
zig build               OK
zig build test          OK   (52 inline tests across the compiler modules)
zig build test-zpp      passed: 15  failed: 0  skipped: 0
```

Categories exercised:

- `compile/` — fixtures must lower without error.
- `behavior/` — fixture is lowered, compiled, run; stdout/stderr is asserted.
- `lowering/` — fixture is lowered and compared byte-exact to a `.expected.zig`.
- `diagnostics/` — fixture must produce a specific Exxxx finding from `checks.zig`.
- `no_hidden_alloc/` — fixture must produce zero E0010 findings (positive case).

## What's intentionally not done

- No real parser yet. The lowering and the checks operate on the token stream
  with brace counting and a single-line lexical state. Documented limitations
  apply (multi-line strings, multi-line `effects(...)` calls, scope rebinding
  for `move`).
- `zpp fmt`, `zpp doc`, `zpp lsp`, `zpp migrate` are CLI placeholders that panic on use.
- `derive(.{Hash, Json, ...})` is in the design but not lowered.
- `extern interface` blocks pass through verbatim — only bare `trait` is lowered.
- The `lib/` runtime helpers are real but minimal; many functions are skeletons.

## Design reference

The full language vision lives in the original *Zig++ Design Draft v0.1*. This
repo implements only the most load-bearing slice of it — enough to demonstrate
that the pipeline works end-to-end and that the headline features (`using`,
`trait`, `impl`, `dyn`, ownership/effect checks) can be lowered to plain Zig
without invisible cost.

## License

MIT. See [LICENSE](LICENSE).
