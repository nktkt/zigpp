local M = {}

-- Default config, overridable by setup()
M.config = {
  cmd = { "zpp", "lsp" },
  root_markers = { "build.zig.zon", "build.zig", ".git" },
}

local function shallow_merge(dst, src)
  if type(src) ~= "table" then return dst end
  for k, v in pairs(src) do
    dst[k] = v
  end
  return dst
end

-- Walk up from `start_dir` looking for any of `markers`. Returns the first
-- ancestor directory that contains one of them, or nil if none is found.
local function find_root(start_dir, markers)
  local dir = start_dir
  while dir and dir ~= "" do
    for _, marker in ipairs(markers) do
      local candidate = dir .. "/" .. marker
      if vim.loop.fs_stat(candidate) then
        return dir
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

function M._on_zpp_filetype(bufnr)
  -- Defensive guard: vim.lsp.start landed in Neovim 0.8 but the modern
  -- single-arg form we rely on is 0.10+. Bail quietly on older versions.
  if not (vim.lsp and vim.lsp.start) then
    vim.notify("[zigpp] vim.lsp.start unavailable; need Neovim 0.10+", vim.log.levels.WARN)
    return
  end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  local start_dir = (fname ~= "" and vim.fn.fnamemodify(fname, ":p:h")) or vim.fn.getcwd()
  local root = find_root(start_dir, M.config.root_markers) or start_dir

  vim.lsp.start({
    name = "zigpp",
    cmd = M.config.cmd,
    root_dir = root,
    capabilities = vim.lsp.protocol.make_client_capabilities(),
  })
end

function M.setup(opts)
  shallow_merge(M.config, opts or {})

  vim.filetype.add({
    extension = {
      zpp = "zigpp",
    },
  })

  local group = vim.api.nvim_create_augroup("ZigppLsp", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "zigpp",
    callback = function(args)
      M._on_zpp_filetype(args.buf)
    end,
  })
end

return M
