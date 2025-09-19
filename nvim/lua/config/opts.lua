-- text options
vim.opt.nu = true
vim.opt.relativenumber = true
vim.opt.cursorline = true
vim.opt.smartindent = true
vim.opt.foldmethod = "indent"
vim.opt.foldlevelstart = 84
vim.opt.termguicolors = true
vim.opt.tabstop = 4
-- preserve tabs in files
vim.opt.expandtab = false
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.textwidth = 0
vim.opt.wrapmargin = 0
vim.opt.wrap = false

-- Color/theme options
vim.cmd('colorscheme torte')
--vim.api.nvim_set_hl(0, "Normal", { bg = "NONE" })
--vim.api.nvim_set_hl(0, "NormalNC", { bg = "NONE" })
--vim.api.nvim_set_hl(0, "EndOfBuffer", { bg = "NONE" })

-- Define base highlight groups that nvim-cmp depends on BEFORE lazy.nvim loads
-- This prevents the "Invalid highlight color: 'fg'" error by ensuring these groups exist
--vim.api.nvim_set_hl(0, "Pmenu", { fg = "#ffffff", bg = "#000000" })
--vim.api.nvim_set_hl(0, "Comment", { fg = "#808080", bg = "NONE" })
--vim.api.nvim_set_hl(0, "Special", { fg = "#00ffff", bg = "NONE" })
