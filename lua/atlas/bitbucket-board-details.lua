---@class Bitbucket.Details
local M = {}

local api = vim.api
local state = require("atlas.bitbucket-board-state")

function M.show_help_popup()
  local help_content = {
    { section = "Navigation & View" },
    { k = "j/k", d = "Navigate between PRs" },
    { k = "<Tab>", d = "Toggle Node (Expand/Collapse)" },
    { k = "H", d = "Show Help" },
    { k = "q", d = "Close Board" },
    { k = "r", d = "Refresh current view" },

    { section = "PR Actions" },
    { k = "<CR>", d = "Show PR Details (Popup)" },
    { k = "o", d = "Open PR in Browser" },
    { k = "gx", d = "Open PR in Browser" },
  }

  local lines = { " Bitbucket Keybindings", " " .. ("━"):rep(50) }
  local hls = {}
  
  table.insert(hls, { row = 0, col = 1, end_col = -1, hl = "Title" })
  table.insert(hls, { row = 1, col = 0, end_col = -1, hl = "Comment" })
  
  local row = 2
  for _, item in ipairs(help_content) do
    if item.section then
      table.insert(lines, "")
      table.insert(lines, " " .. item.section)
      table.insert(hls, { row = row + 1, col = 1, end_col = -1, hl = "Label" })
      row = row + 2
    else
      local line = ("   %-18s %s"):format(item.k, item.d)
      table.insert(lines, line)
      table.insert(hls, { row = row, col = 3, end_col = 3 + #item.k, hl = "Special" })
      row = row + 1
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local width = 60
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = "minimal",
    border = "rounded",
    title = " Help ",
    title_pos = "center",
  })

  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, -1, hl.hl, hl.row, hl.col, hl.end_col)
  end

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
  
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
end

---Format time ago
---@param timestamp string
---@return string
local function format_time_ago(timestamp)
  if not timestamp then return "N/A" end
  
  local year, month, day, hour, min, sec = timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then return "N/A" end
  
  local time = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })
  
  local diff = os.time() - time
  local days = math.floor(diff / 86400)
  local hours = math.floor((diff % 86400) / 3600)
  local mins = math.floor((diff % 3600) / 60)
  
  if days > 0 then
    return days .. "d ago"
  elseif hours > 0 then
    return hours .. "h ago"
  else
    return mins .. "m ago"
  end
end

---Get build status icon and highlight
local function get_build_display(status)
  if not status then
    return "N/A", "Comment"
  elseif status == "SUCCESSFUL" then
    return "✓ Success", "BitbucketBuildSuccess"
  elseif status == "FAILED" then
    return "✗ Failed", "BitbucketBuildFailed"
  elseif status == "INPROGRESS" then
    return "◐ In Progress", "BitbucketBuildInProgress"
  else
    return status, "Comment"
  end
end

---Show PR details popup (Jira-style)
---@param pr table The PR object with all fields
function M.show_pr_details(pr)
  if not pr then
    vim.notify("No PR data available", vim.log.levels.WARN)
    return
  end

  -- Get build status display
  local build_text, build_hl = get_build_display(pr.build_status)
  
  -- Build the content lines (Jira-style)
  local lines = {
    " #" .. (pr.id or "?") .. ": " .. (pr.title or "Untitled"),
    " " .. ("━"):rep(math.min(60, 4 + #(pr.title or "Untitled"))),
    (" Author:   %s"):format(pr.author and pr.author.display_name or "Unknown"),
    (" Repo:     %s/%s"):format(pr.workspace or "", pr.repo or ""),
    (" Updated:  %s"):format(format_time_ago(pr.updated_on)),
  }
  
  local hls = {}
  local next_row = 0
  
  -- Header highlight
  table.insert(hls, { row = next_row, col = 1, end_col = 2 + #tostring(pr.id or "?"), hl = "Title" })
  next_row = next_row + 1
  table.insert(hls, { row = next_row, col = 0, end_col = -1, hl = "Comment" })
  next_row = next_row + 1
  
  -- Author
  table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
  table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketAuthor" })
  next_row = next_row + 1
  
  -- Repo
  table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
  table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketRepo" })
  next_row = next_row + 1
  
  -- Updated
  table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
  table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketTime" })
  next_row = next_row + 1
  
  -- Branches
  table.insert(lines, (" Source:   %s"):format(pr.source_branch or "N/A"))
  table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
  table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketBranch" })
  next_row = next_row + 1
  
  table.insert(lines, (" Target:   %s"):format(pr.destination_branch or "N/A"))
  table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
  table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketBranch" })
  next_row = next_row + 1
  
  -- Commit
  if pr.commit_hash then
    table.insert(lines, (" Commit:   %s"):format(pr.commit_hash))
    table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
    table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "Number" })
    next_row = next_row + 1
  end
  
  -- Metrics
  if pr.comment_count and pr.comment_count > 0 then
    table.insert(lines, (" Comments: %s 󰍩"):format(pr.comment_count))
    table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
    table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketComments" })
    next_row = next_row + 1
  end
  
  if pr.task_count and pr.task_count > 0 then
    table.insert(lines, (" Tasks:    %s ☑"):format(pr.task_count))
    table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
    table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "Number" })
    next_row = next_row + 1
  end
  
  if pr.approvals or pr.total_reviewers then
    table.insert(lines, (" Approvals: %s/%s ✓"):format(pr.approvals or 0, pr.total_reviewers or 0))
    table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
    table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "BitbucketApproved" })
    next_row = next_row + 1
  end
  
  if pr.needs_work and pr.needs_work > 0 then
    table.insert(lines, (" Needs Work: %s ●"):format(pr.needs_work))
    table.insert(hls, { row = next_row, col = 1, end_col = 12, hl = "Label" })
    table.insert(hls, { row = next_row, col = 13, end_col = -1, hl = "BitbucketNeedsWork" })
    next_row = next_row + 1
  end
  
  -- Build status
  table.insert(lines, (" Build:    %s"):format(build_text))
  table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
  table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = build_hl })
  next_row = next_row + 1
  
  -- Draft
  if pr.is_draft then
    table.insert(lines, (" Draft:    Yes"))
    table.insert(hls, { row = next_row, col = 1, end_col = 10, hl = "Label" })
    table.insert(hls, { row = next_row, col = 11, end_col = -1, hl = "WarningMsg" })
    next_row = next_row + 1
  end
  
  -- Close source branch
  local close_branch = pr.close_source_branch and "Yes" or "No"
  table.insert(lines, (" Close Branch: %s"):format(close_branch))
  table.insert(hls, { row = next_row, col = 1, end_col = 14, hl = "Label" })
  table.insert(hls, { row = next_row, col = 15, end_col = -1, hl = pr.close_source_branch and "String" or "Comment" })
  next_row = next_row + 1
  
  -- Description
  if pr.description and pr.description ~= "" then
    table.insert(lines, "")
    next_row = next_row + 1
    table.insert(lines, " Description:")
    table.insert(hls, { row = next_row, col = 1, end_col = -1, hl = "Label" })
    next_row = next_row + 1
    
    local desc_lines = vim.split(pr.description, "\n")
    for i, line in ipairs(desc_lines) do
      if i > 10 then
        table.insert(lines, " ...")
        next_row = next_row + 1
        break
      end
      local truncated = line
      if #line > 80 then
        truncated = line:sub(1, 77) .. "..."
      end
      table.insert(lines, " " .. truncated)
      table.insert(hls, { row = next_row, col = 1, end_col = -1, hl = "Comment" })
      next_row = next_row + 1
    end
  end
  
  -- Create buffer
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  
  -- Apply highlights
  for _, h in ipairs(hls) do
    local end_col = h.end_col
    if end_col == -1 then
      end_col = #lines[h.row + 1]
    end
    api.nvim_buf_set_extmark(buf, state.ns, h.row, h.col, {
      end_col = end_col,
      hl_group = h.hl,
    })
  end
  
  -- Calculate width
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = width + 2
  local height = #lines
  
  -- Create window (near cursor, like Jira)
  local win = api.nvim_open_win(buf, false, {
    relative = "cursor",
    width = width,
    height = height,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
    focusable = false,
  })
  
  -- Auto-close on cursor move
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
    buffer = state.buf,
    once = true,
    callback = function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end,
  })
end

return M
