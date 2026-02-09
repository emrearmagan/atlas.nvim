local state = require("atlas.bitbucket-board-state")
local util = require("atlas.common.util")

---@class Bitbucket.UI
local M = {}

function M.create_window()
  -- Backdrop
  local dim_buf = vim.api.nvim_create_buf(false, true)
  state.dim_win = vim.api.nvim_open_win(dim_buf, false, {
    relative = "editor",
    width = vim.o.columns,
    height = vim.o.lines,
    row = 0,
    col = 0,
    style = "minimal",
    focusable = false,
    zindex = 44,
  })
  vim.api.nvim_set_option_value("winblend", 50, { win = state.dim_win })
  vim.api.nvim_set_option_value("winhighlight", "Normal:BitbucketDim", { win = state.dim_win })
  vim.api.nvim_set_hl(0, "BitbucketDim", { bg = "#000000" })

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })

  local height = 42
  local width = 160

  state.win = vim.api.nvim_open_win(state.buf, true, {
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2 - 1,
    relative = "editor",
    style = "minimal",
    border = { " ", " ", " ", " ", " ", " ", " ", " " },
    title = { { "  Bitbucket PRs ", "StatusLineTerm" } },
    title_pos = "center",
    zindex = 45,
  })

  vim.api.nvim_win_set_hl_ns(state.win, state.ns)
  vim.api.nvim_set_option_value("cursorline", true, { win = state.win })
  vim.api.nvim_set_option_value("winhighlight", "CursorLine:BitbucketCursorLine", { win = state.win })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = state.buf,
    callback = function()
      if state.dim_win and vim.api.nvim_win_is_valid(state.dim_win) then
        vim.api.nvim_win_close(state.dim_win, true)
        state.dim_win = nil
      end
    end,
  })

  vim.api.nvim_set_current_win(state.win)
end

return M
