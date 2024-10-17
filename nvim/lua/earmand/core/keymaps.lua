vim.g.mapleader = " "

local keymap = vim.keymap

keymap.set("n", "<leader>sh", "<C-w>s", { desc = "Split window horizontal"})
keymap.set("n", "<leader>se", "<C-w>=", { desc = "Set window size equal"})
keymap.set("n", "<leader>sv", "<C-w>v", { desc = "Split window vertical"})
keymap.set("n", "<leader>sx", "<cmd>Close<CR>", { desc = "close current window"})
