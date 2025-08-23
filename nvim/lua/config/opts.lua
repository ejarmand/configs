vim.opt.nu = true
vim.opt.relativenumber = true
vim.opt.cursorline = true
vim.opt.smartindent = true
vim.opt.foldmethod = "indent"
vim.opt.foldlevelstart = 84

-- Force true color support for homebrew neovim on remote servers
vim.env.COLORTERM = "truecolor"
vim.env.TERM = "xterm-256color"

if vim.fn.has("termguicolors") == 1 then
  vim.opt.termguicolors = true
end

vim.env.NVIM_TUI_ENABLE_TRUE_COLOR = 1

-- Set a colorscheme that supports termguicolors
vim.cmd('colorscheme habamax')

-- Function to set transparent background
local function set_transparent_bg()
  vim.cmd('highlight Normal guibg=NONE ctermbg=NONE')
  vim.cmd('highlight NormalFloat guibg=NONE ctermbg=NONE')
  vim.cmd('highlight NonText guibg=NONE ctermbg=NONE')
  vim.cmd('highlight LineNr guibg=NONE ctermbg=NONE')
  vim.cmd('highlight SignColumn guibg=NONE ctermbg=NONE')
end

-- Apply transparency immediately
set_transparent_bg()

-- Re-apply transparency after any colorscheme change
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = set_transparent_bg,
})
