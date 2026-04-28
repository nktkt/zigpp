# Zig++ for VS Code

Syntax highlighting and LSP diagnostics for `.zpp` files.

## Install (development)

1. Build the `zpp` binary in the repo root:
   ```sh
   cd ../..
   zig build
   ```
   This produces `zig-out/bin/zpp`.

2. Make sure `zpp` is on your PATH, OR set `zigpp.serverPath` in your VS Code settings to the absolute path of the binary.

3. Symlink this directory into your VS Code extensions folder:
   ```sh
   ln -s "$(pwd)" ~/.vscode/extensions/zigpp-0.0.1
   ```
   Then reload VS Code.

4. Install the LSP client dependency:
   ```sh
   npm install
   ```

## What you get

- Syntax highlighting for `.zpp` files
- Real-time diagnostics from `zpp lsp` (E0001 owned-not-deinit, E0002 use-after-move, E0003 double-deinit, E0004 allocator-mismatch, E0010 hidden-allocation-in-noalloc)
- Pull-model diagnostics: VS Code asks the server on file open and after edits

## Configuration

- `zigpp.serverPath`: path to the `zpp` executable (default: `"zpp"`, looked up on PATH)
- `zigpp.serverArgs`: arguments passed to the server (default: `["lsp"]`)

## Status

Research-stage. The grammar is heuristic; the LSP server is minimal. No formatting, no completions, no go-to-definition yet.
