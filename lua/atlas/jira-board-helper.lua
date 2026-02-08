local state = require("atlas.jira-board-state")

local M = {}

M.get_node_at_cursor = function()
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local row = cursor[1] - 1
  local node = state.line_map[row]
  return node
end

M.get_cache_key = function(project_key, view_name)
  local key = project_key .. ":" .. view_name
  if view_name == "JQL" then
    key = key .. ":" .. (state.current_query or "Custom JQL")
    if state.current_query == "Custom JQL" then
      key = key .. ":" .. (state.custom_jql or "")
    end
  end
  return key
end

function M.with_valid_win(fn)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return vim.api.nvim_win_call(state.win, fn)
  end
end

function M.save_view_if_same(view_name)
  if state.current_view ~= view_name then
    return nil
  end

  return M.with_valid_win(function()
    return vim.fn.winsaveview()
  end)
end

function M.restore_view(view)
  if not view then
    return
  end

  M.with_valid_win(function()
    local line_count = vim.api.nvim_buf_line_count(state.buf)
    if view.lnum > line_count then
      view.lnum = line_count
    end
    vim.fn.winrestview(view)
  end)
end

return M
