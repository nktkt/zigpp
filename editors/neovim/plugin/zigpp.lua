if vim.g.loaded_zigpp == 1 then return end
vim.g.loaded_zigpp = 1

require("zigpp").setup({})
