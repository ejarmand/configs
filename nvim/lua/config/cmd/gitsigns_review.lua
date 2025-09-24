local M = {}

local gitsigns = require('gitsigns')
local last_hunk = nil
local review_enabled = false

local function preview_current_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]

  local hunks = gitsigns.get_hunks(bufnr)
  if not hunks then return end

  for _, hunk in ipairs(hunks) do
    local start_line = hunk.added.start
    local end_line = hunk.added.start + hunk.added.count - 1

    if line >= start_line and line <= end_line then
      if last_hunk ~= hunk then
        gitsigns.preview_hunk_inline()
        last_hunk = hunk
      end
      return
    end
  end

  last_hunk = nil
end

function M.toggle()
  if review_enabled then
    vim.api.nvim_clear_autocmds({ group = 'GitsignsReview' })
    review_enabled = false
    print("Gitsigns review OFF")
  else
    vim.api.nvim_create_augroup('GitsignsReview', { clear = true })
    vim.api.nvim_create_autocmd('CursorMoved', {
      group = 'GitsignsReview',
      callback = preview_current_hunk,
    })
    review_enabled = true
    print("Gitsigns review ON")
  end
end

return M

