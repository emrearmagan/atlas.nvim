local uv = vim.uv or vim.loop

local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_timer = nil
local spinner_win = nil
local spinner_buf = nil

---@param msg? string
function M.start_loading(msg)
  msg = msg or "Loading..."

  if spinner_win and vim.api.nvim_win_is_valid(spinner_win) then
    return
  end

  spinner_buf = vim.api.nvim_create_buf(false, true)
  local width = #msg + 4
  local height = 1
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  spinner_win = vim.api.nvim_open_win(spinner_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    zindex = 200,
  })

  local idx = 1
  spinner_timer = uv.new_timer()
  if not spinner_timer then
    return
  end

  spinner_timer:start(
    0,
    100,
    vim.schedule_wrap(function()
      if not spinner_buf or not vim.api.nvim_buf_is_valid(spinner_buf) then
        return
      end
      local frame = spinner_frames[idx]
      vim.api.nvim_buf_set_lines(spinner_buf, 0, -1, false, { " " .. frame .. " " .. msg })
      idx = (idx % #spinner_frames) + 1
    end)
  )
end

function M.stop_loading()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
  if spinner_win and vim.api.nvim_win_is_valid(spinner_win) then
    vim.api.nvim_win_close(spinner_win, true)
    spinner_win = nil
  end
  if spinner_buf and vim.api.nvim_buf_is_valid(spinner_buf) then
    vim.api.nvim_buf_delete(spinner_buf, { force = true })
    spinner_buf = nil
  end
end

return M
