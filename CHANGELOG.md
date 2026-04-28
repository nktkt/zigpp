# Changelog

All notable changes to Zig++ are documented here, newest first. Each entry
corresponds to one git commit. The project is research-stage; there are no
versioned releases yet, so this is effectively a development log.

## Unreleased

### Added (commit `e743581` — VS Code extension + README refresh)

- `editors/vscode/` — minimal VS Code extension. Plain JavaScript, no build
  step. Registers `.zpp` syntax highlighting via TextMate grammar
  (~50 keywords, comments, strings, numbers, `@`-builtins, function/type
  names) and connects to `zpp lsp` for real-time diagnostics. Critical
  detail: opts into pull-model diagnostics so the LSP server's
  `textDocument/diagnostic`-only surface is exercised.
- README refreshed: diagnostics table now lists all five implemented codes;
  test-status numbers match current CI; editor-support section added.

### Added (commit `1cf8610` — E0004 allocator-mismatch)

- New check `checkAllocatorMismatch`. Heuristic: pulls the first
  `<ident>.<create-method>(` from the RHS of `own var <name> = ...;` as the
  create allocator, then scans the enclosing block for `<other>.destroy(<name>)`
  / `<other>.free(<name>)`. Mismatched ident text is flagged as E0004.
- Bonus fix: `checkOwnership::isHandled` now also accepts allocator-mediated
  release (`<allocator>.destroy(<name>)` or `<allocator>.free(<name>)`) as
  satisfying the deinit obligation. Without this, the new E0004 fixture
  produced a phantom E0001 alongside the intended E0004.
- Wired into `cmdCheck`, the integration test runner, and the LSP server.
- New fixture `tests/diagnostics/E0004_allocator_mismatch.zpp`.
- 5/6 of the diagnostic codes declared in `compiler/diagnostics.zig::Code` are
  now implemented (E0020 still requires structural impl checking, deferred).

### Added (commit `c2ebcda` — E0003 double-deinit)

- New check `checkDoubleDeinit`. Counts `<name>.deinit(` calls per
  `own var <name>` declaration in the same scope; the second-and-subsequent
  are flagged. Anchored at the second call site so the diagnostic points at
  where the bug manifests.
- Wired into `cmdCheck`, the integration test runner, and the LSP server.
- New fixture `tests/diagnostics/E0003_double_deinit.zpp`.
- Documented limitation: rebinding via `using` / `move` is not recognized
  as resetting the count.

### Added (commit `ab5a3a2` — `zpp lsp` + CI hardening)

- Minimal Language Server over stdio (JSON-RPC 2.0 with Content-Length
  framing). Methods: `initialize`, `initialized`, `shutdown`, `exit`,
  `textDocument/diagnostic`. Pull model only — no in-memory document state;
  every diagnostic request re-reads the file from disk and runs the four
  current sema checks. Unknown methods get -32601 for requests, are silently
  ignored for notifications. Malformed JSON is logged to stderr and skipped
  without crashing.
- CI gains two smoke steps: `zpp fmt --check .` (project must stay canonical)
  and an LSP `initialize` handshake (server must respond with `"capabilities"`).

### Added (commit `12b2b66` — `zpp fmt`)

- Whitespace-only formatter (`compiler/fmt.zig`). Four mechanical passes:
  trim trailing whitespace, leading-tab to 4-space, single trailing newline,
  collapse 2+ blank lines to one. Mid-line tabs are intentionally preserved.
- `zpp fmt [path]` rewrites in place; `zpp fmt --check [path]` reports what
  would change and exits 1 if any file is dirty (CI-friendly).
- 11 inline tests; project's existing 24 `.zpp` files are already canonical
  on first run.

### Added (commit `bf03daa` — `zpp migrate`)

- Zig → Zig++ rewriter. `compiler/migrate.zig` finds adjacent
  `var <name> = <expr>;` + `defer <name>.deinit();` line pairs (matched
  indentation and identifier) and rewrites them to a single
  `using <name> = <expr>;`.
- `zpp migrate <dir>` is dry-run by default (prints suggestions); `--apply`
  rewrites files in place. Reverse-order splicing keeps earlier byte offsets
  valid across multiple suggestions in one file.
- 10 inline tests covering canonical pair, name/indent mismatches, blank-line
  separation, `try` in expr, multi-suggestion files.

### Added (commit `4ef2d76` — `zpp doc`)

- Project-wide Markdown reference generator. `compiler/doc_extract.zig` is a
  pure-extraction module that walks the lexer token stream and pulls out
  every `trait`, `extern interface`, `effects(...)`-annotated function, and
  `derive(.{...})` postfix.
- `tools/zpp_doc.zig::run` aggregates across files, sorts trait names
  alphabetically, partitions traits vs. extern interfaces, and emits
  `<dir>/.zpp-doc/REFERENCE.md` with sectioned headings + tables. Empty
  sections are omitted.

### Added (commit `d70f962` — derive runtime end-to-end)

- `lib/derive.zig` with deterministic stub generators for `Hash`, `Debug`,
  `Json` (returning namespace types with fixed-output methods so behavior
  tests can assert byte-exact). `lib/zpp.zig` umbrella re-exports `derive`,
  `owned`, `contracts` under a single import surface.
- `compiler/derive_lower.zig` now prepends `const zpp = @import("zpp");` to
  the file when any derive postfix fires (and the import isn't already
  present). The lowered code is now executable provided the user wires the
  `zpp` module in their build.
- `tests/test_runner.zig` behavior runner's synthesized build.zig now
  resolves `lib/zpp.zig` via `realpathAlloc` and addImport's it into the
  test binary's module so `derive_demo.zpp` actually compiles + runs.
- New fixture `tests/behavior/derive_demo.zpp` proves `derive(.{Debug})`
  works at runtime: lower → zig build → spawn → assert stderr `"debug ok\n"`.

### Added (commit `6c16a84` — derive postfix lowering + LICENSE)

- `compiler/derive_lower.zig`: matches `} derive(.{ X, Y, ... });` after a
  struct decl and rewrites it to inject `pub const x = zpp.derive.X(@This());`
  lines inside the struct body, dropping the `derive(...)` suffix.
- Indentation inferred from the struct body's first non-blank field line;
  the closing `};` uses the original `derive` line's indent. Handles
  trailing commas, multi-line trait lists, multiple structs per file. Bare
  `derive` identifiers and non-postfix calls pass through unchanged.
- 11 inline tests, plus byte-equal golden fixture `tests/lowering/derive_basic`.
- Project gains an MIT LICENSE; README's "Unlicensed research code" line
  becomes "MIT. See LICENSE."

### Added (commit `7e4bf5c` — `extern interface` + macOS CI)

- `compiler/trait_lower.zig` matcher generalized: also accepts
  `kw_extern kw_interface ident lbrace`, producing the same fat-pointer
  struct + vtable + dispatch wrappers + `from(impl)` factory as bare
  `trait`. The semantic difference (extern interface = ABI stability for
  plugins) is documented as future work; same Zig output for now.
- `examples/dyn_plugin.zpp` got minimal Zig 0.15 fixups so its lowered
  output actually compiles and dispatches at runtime.
- New behavior fixture `extern_interface_dispatch.zpp` proves the new
  matcher end-to-end via the runner.
- CI matrix expanded to include `macos-latest`.

### Added (commit `b0e17bf` — GitHub Actions CI)

- Workflow `.github/workflows/ci.yml`. Runs on every push to main and PR.
  Installs Zig 0.15.2 via `mlugg/setup-zig`, caches `.zig-cache`, runs
  `zig build`, `zig build test`, `zig build test-zpp`, plus smoke tests
  `zpp run examples/hello_runnable` (must print `"hello, zigpp!"`) and
  `zpp check examples` (must be clean).
- README gets a status badge.

### Added (commit `6c6823e` — `zpp check`)

- Project-wide sema runner. `cmdCheck` walks every `.zpp` under a directory
  (default `.`), runs the three checks then in scope (`checkOwnership`,
  `checkUseAfterMove`, `checkNoAlloc`), and prints findings as
  `<path>:<line>:<col>: <code> <message>`. Exit 0 on clean, 1 on findings.
- Bonus fix: `checkOwnership` now treats `move <name>` as satisfying the
  deinit obligation (transferred ownership; the moved-from binding is
  dead). Without this, every `own var x; ... var y = move x;` produced a
  spurious E0001 — the canonical `examples/owned_file.zpp` hit it.

### Added (commit `d7dfb31` — trait `from(impl)` factory + behavior test)

- Trait lowering now emits `pub fn from(impl_ptr: anytype) Name { ... }`
  alongside the dispatch wrappers. The factory recovers `ImplT` via
  `@typeInfo(@TypeOf(impl_ptr)).pointer.child`, generates one wrapper per
  method on a comptime-anonymous struct that `@ptrCast/@alignCast`s back
  to `*ImplT` and forwards the call, and returns a fat pointer. This is
  what makes the trait struct actually constructible without hand-writing
  a vtable.
- `examples/hello_runnable` now uses real trait dispatch
  (`Greeter.from(&hello)`); a behavior fixture `trait_dispatch.zpp` asserts
  the program's stderr byte-for-byte after lower → zig build → execute.

### Initial (commit `0f7afc0`)

The initial commit covered everything that came before opening up to public
GitHub. Headlines:

- **Pipeline**: `.zpp source → frontend (lex / line rules / structural
  lowering) → generated .zig → upstream Zig`. End-to-end runnable via
  `zpp lower`, `zpp build`, `zpp run`.
- **Line-level lowering rules**: `using x = expr;` → `var x = expr; defer
  x.deinit();`; strip `own` / `move` / `owned` keywords; strip standalone
  `effects(...)` lines; substitute `dyn <Trait>` → `<Trait>` and
  `impl <Trait>` → `anytype`. All four respect string/comment lexical state.
- **Structural lowering**: `trait Name { ... }` rewrites to a Zig
  fat-pointer struct with a `VTable` and per-method dispatch wrappers.
- **Token-based sema** (E0001 owned-not-deinit, E0002 use-after-move, E0010
  hidden-allocation-in-noalloc) — three passes that operate on the lexer's
  token stream and use brace counting for scope.
- **Behavior test runner** (`tests/test_runner.zig`) walks
  `tests/{compile,behavior,lowering,diagnostics,no_hidden_alloc}/`,
  dispatches by category, runs lowering + (for `behavior/`) a real
  `zig build` + spawn + stdout/stderr capture cycle.
- **Runtime support library** (`lib/`): `Owned(T)`, `Borrow(T)`,
  `ArenaScope`, `DeinitGuard`, `requires`/`ensures`/`invariant`. All
  allocator-first.
- **CLI**: `version`, `help`, `lower`, `build`, `run` working end-to-end;
  the rest are TODO panics at this point.
- **Lexer** with all 12 Zig++-specific keywords plus a 21-keyword Zig
  subset, two-character operators (`==`, `=>`, `->`, `..`, `...`, etc.),
  string/char/`//`/`///`/`//!` recognition.
- **Examples**: `hello_runnable/` (end-to-end runnable), `hello_trait`,
  `owned_file`, `dyn_plugin`, `async_group` (syntax demos).
