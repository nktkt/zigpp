# Zig++ for Neovim

Filetype detection, Vim-regex syntax highlighting, and LSP diagnostics for
`.zpp` files. Pure Lua, no external plugin dependencies. Requires Neovim
**0.10+** for the modern `vim.lsp.start` API.

## Install

1. Build the `zpp` binary from the repo root:
   ```sh
   cd ../..
   zig build
   ```
   This produces `zig-out/bin/zpp`.

2. Make sure `zpp` is on your `$PATH`, or pass an explicit `cmd` to `setup`.

3. Add the plugin to your runtimepath. Either symlink this directory:
   ```sh
   ln -s "$(pwd)" ~/.config/nvim/pack/zigpp/start/zigpp
   ```
   Or use a plugin manager. Example **lazy.nvim** spec:
   ```lua
   {
     dir = "/absolute/path/to/zigpp/editors/neovim",
     name = "zigpp",
     ft = "zigpp",
     config = function()
       require("zigpp").setup({
         -- cmd = { "/absolute/path/to/zig-out/bin/zpp", "lsp" },
       })
     end,
   }
   ```

## What you get

- `.zpp` files are recognized as filetype `zigpp`.
- Syntax highlighting (Vim regex, no Tree-sitter required).
- The built-in `vim.lsp` client auto-attaches to `zpp lsp` on first `.zpp`
  buffer. Diagnostics are pulled by Neovim via `textDocument/diagnostic`
  (E0001, E0002, E0003, E0004, E0010).

## Configuration

`require("zigpp").setup({ ... })` accepts:

| Option         | Default                                       | Description                                     |
| -------------- | --------------------------------------------- | ----------------------------------------------- |
| `cmd`          | `{ "zpp", "lsp" }`                            | Command launched by `vim.lsp.start`.            |
| `root_markers` | `{ "build.zig.zon", "build.zig", ".git" }`    | Project-root markers, walked up from the file.  |

## Status

Research-stage. The syntax file is heuristic; the LSP server only implements
pull diagnostics — no completions, no formatting, no go-to-definition yet.
