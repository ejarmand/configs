local opt = vim.opt

opt.relativenumber = true
opt.number = true

-- tabs 
opt.tabstop = 4
opt.shiftwidth = 4
opt.expandtab = false
opt.autoindent = true


-- others
opt.wrap = false

opt.ignorecase = true
opt.smartcase = true

opt.cursorline = true

opt.backspace = "indent,eol,start"

opt.clipboard:append("unnamedplus")

-- windows
opt.splitright = true
opt.splitbelow = true

-- colors
opt.termguicolors = true
opt.background = "dark"
opt.signcolumn = "yes"

