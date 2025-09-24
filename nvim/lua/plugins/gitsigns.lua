-- lua/plugins/gitsigns.lua
return {
  'lewis6991/gitsigns.nvim',
  config = function()
    require('gitsigns').setup()
	local review = require('config.cmd.gitsigns_review')

	vim.api.nvim_create_user_command('GitReview', review.toggle, {})
  end,
}


