return {
    "mason-org/mason.nvim",
    dependencies = { "mason-org/mason-lspconfig.nvim" },
    PATH = "append",
    config = function()
        require("mason").setup({})
    end,
}
