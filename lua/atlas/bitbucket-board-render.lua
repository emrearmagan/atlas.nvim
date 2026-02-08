local state = require("atlas.bitbucket-board-state")
local util = require("atlas.common.util")

local MAX = {
  TITLE = 70,
  AUTHOR = 15,
  REPO = 20,
  COMMENTS = 3,
  TASKS = 3,
  APPROVALS = 5,
  UPDATED = 10,
}

local M = {}

local function truncate(str, max)
  -- Safety: ensure str is a string
  if type(str) ~= "string" then
    str = tostring(str or "")
  end
  
  if vim.fn.strdisplaywidth(str) <= max then
    return str
  end
  return vim.fn.strcharpart(str, 0, max - 1) .. "…"
end

local function get_totals(node)
  local spent = node.time_spent or 0
  local estimate = node.time_estimate or 0

  for _, child in ipairs(node.children or {}) do
    local s, e = get_totals(child)
    spent = spent + s
    estimate = estimate + e
  end

  return spent, estimate
end

---@param width integer
local function render_progress_bar(spent, estimate, width)
  local total = math.max(estimate, spent)
  if total <= 0 then
    return ("▰"):rep(width), 0
  end

  local ratio = spent / total
  local filled_len = math.floor(ratio * width)
  filled_len = math.min(width, math.max(0, filled_len))

  local bar = ("▰"):rep(filled_len) .. ("▱"):rep(width - filled_len)
  return bar, filled_len
end

local function add_hl(hls, start_col, text, hl)
  local width = text:len()
  table.insert(hls, {
    start_col = start_col,
    end_col = start_col + width,
    hl = hl,
  })
end

-- ---------------------------------------------
-- Helpers
-- ---------------------------------------------
local function get_issue_icon_OLD(node)
  local type = node.type or ""
  if type == "Bug" then
    return "", "BitbucketIconBug"
  elseif type == "Story" then
    return "", "BitbucketIconStory"
  elseif type == "Task" then
    return "", "BitbucketIconTask"
  elseif type == "Sub-task" or type == "Subtask" then
    return "󰙅", "BitbucketIconSubTask"
  elseif type == "Sub-Test" or type == "Sub Test Execution" then
    return "󰙨", "BitbucketIconTest"
  elseif type == "Sub Design" then
    return "󰟶", "BitbucketIconDesign"
  elseif type == "Sub Overhead" then
    return "󱖫", "BitbucketIconOverhead"
  elseif type == "Sub-Imp" then
    return "", "BitbucketIconImp"
  end

  return "●", "BitbucketIconStory"
end

local function get_issue_icon(node)
  local type = node.type or ""
  if type == "repo" then
    return "", "BitbucketIconRepo"
  end
  
  if node.build_status == "SUCCESSFUL" then
    return "●", "BitbucketBuildSuccess"
  elseif node.build_status == "FAILED" then
    return "●", "BitbucketBuildFailed"
  elseif node.build_status then
    return "◐", "BitbucketBuildInProgress"
  end

  return "●", "Comment"
end

---@param spent number
---@param estimate number
---@return string col1_str
---@return string col1_hl
local function get_time_display_info(spent, estimate)
  local col1_str = ""
  local col1_hl = "Comment"
  local remaining = math.max(0, estimate - spent)

  if estimate == 0 and spent > 0 then
    col1_str = ("%s"):format(util.format_time(spent))
    col1_hl = "WarningMsg"
  elseif estimate > 0 then
    col1_str = ("%s/%s"):format(util.format_time(spent), util.format_time(estimate))

    if remaining > 0 then
      col1_hl = "Comment"
    else
      local overdue = spent - estimate
      if overdue > 0 then
        col1_hl = "Error"
      else
        col1_str = util.format_time(spent) .. " "
        col1_hl = "exgreen"
      end
    end
  elseif spent == 0 and estimate == 0 then
    col1_str = "-"
    col1_hl = "Comment"
  end

  return col1_str, col1_hl
end

---@param node JiraIssueNode
---@param is_root boolean
---@param bar_width integer
---@return string col1_str
---@return string col1_hl
---@return string col2_str
---@return string bar_str
---@return integer bar_filled_len
local function get_right_part_info(node, is_root, bar_width)
  local time_str = ""
  local time_hl = "Comment"
  local assignee_str = ""
  local bar_str = ""
  local bar_filled_len = 0

  if is_root then
    local spent, estimate = get_totals(node)
    local bar, filled = render_progress_bar(spent, estimate, bar_width)
    bar_str = bar
    bar_filled_len = filled
    time_str, time_hl = get_time_display_info(spent, estimate)
  else
    local spent = node.time_spent or 0
    local estimate = node.time_estimate or 0
    time_str, time_hl = get_time_display_info(spent, estimate)
  end

  local ass = truncate(node.assignee or "Unassigned", MAX.AUTHOR - 2)
  assignee_str = " " .. ass

  return time_str, time_hl, assignee_str, bar_str, bar_filled_len
end

local function get_pr_right_part_info(node, is_root)
  if is_root then
    local comments = type(node.comment_count) == "string" and node.comment_count or ""
    local tasks = type(node.task_count) == "string" and node.task_count or ""
    local approvals = type(node.approvals) == "string" and node.approvals or ""
    local author = (node.author and node.author.display_name) or ""
    local repo = node.repo or ""
    local updated = "Updated"
    return comments, tasks, approvals, author, repo, updated
  end
  
  local comments = tostring(node.comment_count or 0)
  local tasks = tostring(node.task_count or 0)
  
  local approvals = "-"
  if node.total_reviewers and node.total_reviewers > 0 then
    approvals = string.format("%d/%d", node.approvals or 0, node.total_reviewers)
  end
  
  local author = truncate((node.author and node.author.display_name) or "Unknown", MAX.AUTHOR)
  local repo = truncate(string.format("%s/%s", node.workspace or "", node.repo or ""), MAX.REPO)
  local updated = util.format_relative_time(node.updated_on)
  
  return comments, tasks, approvals, author, repo, updated
end

-- ---------------------------------------------
-- Render ONE issue line
-- ---------------------------------------------
local function render_issue_line(node, depth, row)
  local indent = ("    "):rep(depth - 1)
  local icon, icon_hl = get_issue_icon(node)

  local expand_icon = " "
  if node.children and #node.children > 0 then
    expand_icon = node.expanded and "" or ""
  end

  local is_root = depth == 1
  local is_header = node.type == "header"

  local key = node.key or ""
  local title = truncate(node.summary or "", MAX.TITLE)
  local pts = ""

  local highlights = {}
  local col = #indent

  -- LEFT --------------------------------------------------
  local left = ("%s%s %s %s %s %s"):format(indent, expand_icon, icon, key, title, pts)

  add_hl(highlights, col, expand_icon, "Comment")
  col = col + #expand_icon + 1

  add_hl(highlights, col, icon, icon_hl)
  col = col + #icon + 1

  add_hl(highlights, col, key, depth == 1 and "Title" or "LineNr")
  col = col + #key + 1

  add_hl(highlights, col, title, depth == 1 and "BitbucketTopLevel" or "BitbucketPRTitle")
  col = col + #title + 1

  add_hl(highlights, col, pts, "BitbucketStoryPoint")

  -- RIGHT -------------------------------------------------
  local right_part
  if is_root and not is_header then
    local total_width = vim.api.nvim_win_get_width(state.win or 0)
    local left_width = vim.fn.strdisplaywidth(left)
    local padding = (" "):rep(math.max(1, total_width - left_width - 1))
    local full_line = left .. padding
    
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
    vim.api.nvim_buf_set_lines(state.buf, row, row + 1, false, { full_line })
    vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
    
    for _, h in ipairs(highlights) do
      vim.api.nvim_buf_set_extmark(state.buf, state.ns, row, h.start_col, {
        end_col = h.end_col,
        hl_group = h.hl,
      })
    end
    return full_line, highlights
  end
  
  local comments, tasks, approvals, author, repo, updated = get_pr_right_part_info(node, is_root)
  
  local comments_pad = (" "):rep(MAX.COMMENTS - vim.fn.strdisplaywidth(comments))
  local tasks_pad = (" "):rep(MAX.TASKS - vim.fn.strdisplaywidth(tasks))
  local approvals_pad = (" "):rep(MAX.APPROVALS - vim.fn.strdisplaywidth(approvals))
  local author_pad = (" "):rep(MAX.AUTHOR - vim.fn.strdisplaywidth(author))
  local repo_pad = (" "):rep(MAX.REPO - vim.fn.strdisplaywidth(repo))
  local updated_pad = (" "):rep(MAX.UPDATED - vim.fn.strdisplaywidth(updated))
  
  right_part = string.format("%s%s  %s%s  %s%s  %s%s  %s%s  %s%s",
    comments, comments_pad,
    tasks, tasks_pad,
    approvals, approvals_pad,
    author, author_pad,
    repo, repo_pad,
    updated, updated_pad
  )

  local total_width = vim.api.nvim_win_get_width(state.win or 0)
  local left_width = vim.fn.strdisplaywidth(left)
  local padding = (" "):rep(math.max(1, total_width - left_width - vim.fn.strdisplaywidth(right_part) - 1))

  local full_line = left .. padding .. right_part

  local right_col_start = #left + #padding
  
  local current_col = right_col_start
  
  add_hl(highlights, current_col, comments, "Comment")
  current_col = current_col + #comments + #comments_pad + 2
  
  add_hl(highlights, current_col, tasks, "Comment")
  current_col = current_col + #tasks + #tasks_pad + 2
  
  add_hl(highlights, current_col, approvals, "Comment")
  current_col = current_col + #approvals + #approvals_pad + 2
  
  local author_colors = {
    "#f38ba8", -- red
    "#fab387", -- peach
    "#f9e2af", -- yellow
    "#a6e3a1", -- green
    "#94e2d5", -- teal
    "#89dceb", -- sky
    "#89b4fa", -- blue
    "#cba6f7", -- mauve
    "#f5c2e7", -- pink
    "#eba0ac", -- maroon
    "#f5e0dc", -- rosewater
    "#b4befe", -- lavender
    "#74c7ec", -- sapphire
    "#f2cdcd", -- flamingo
    "#e78284", -- red variant
    "#ef9f76", -- peach variant
    "#e5c890", -- yellow variant
    "#a6d189", -- green variant
    "#81c8be", -- teal variant
    "#85c1dc", -- sky variant
  }
  
  local repo_colors = {
    "#94e2d5", -- teal
    "#89dceb", -- sky
    "#89b4fa", -- blue
    "#cba6f7", -- mauve
    "#f5c2e7", -- pink
    "#b4befe", -- lavender
    "#74c7ec", -- sapphire
    "#f2cdcd", -- flamingo
    "#81c8be", -- teal variant
    "#85c1dc", -- sky variant
  }
  
  local author_name = (node.author and node.author.display_name) or "Unknown"
  local author_hash = 0
  for i = 1, #author_name do
    author_hash = author_hash + author_name:byte(i)
  end
  local author_color = author_colors[(author_hash % #author_colors) + 1]
  local author_hl_name = "BitbucketAuthor_" .. author_name:gsub("[^%w]", "_")
  vim.api.nvim_set_hl(0, author_hl_name, { fg = author_color })
  add_hl(highlights, current_col, author, author_hl_name)
  current_col = current_col + #author + #author_pad + 2
  
  local repo_name = string.format("%s/%s", node.workspace or "", node.repo or "")
  local repo_hash = 0
  for i = 1, #repo_name do
    repo_hash = repo_hash + repo_name:byte(i)
  end
  local repo_color = repo_colors[(repo_hash % #repo_colors) + 1]
  local repo_hl_name = "BitbucketRepo_" .. repo_name:gsub("[^%w]", "_")
  vim.api.nvim_set_hl(0, repo_hl_name, { fg = repo_color })
  add_hl(highlights, current_col, repo, repo_hl_name)
  current_col = current_col + #repo + #repo_pad + 2
  
  add_hl(highlights, current_col, updated, "Comment")

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
  vim.api.nvim_buf_set_lines(state.buf, row, row + 1, false, { full_line })
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })

  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(state.buf, state.ns, row, h.start_col, {
      end_col = h.end_col,
      hl_group = h.hl,
    })
  end
  
  if not is_root and node.is_draft then
    local icon_col = #indent + #expand_icon + 1
    vim.api.nvim_buf_set_extmark(state.buf, state.ns, row, 0, {
      virt_text = { { "DRAFT", "BitbucketDraft" } },
      virt_text_pos = "overlay",
      virt_text_win_col = icon_col - 6,
    })
  end

  return full_line, highlights
end

local function render_header(view)
  local config = require("atlas.common.config")
  local custom_views = config.options.bitbucket_views or {}
  
  local left_tabs = {}
  local right_tabs = {
    { name = "Refresh", key = "r" },
    { name = "Help", key = "?" },
  }
  
  for _, v in ipairs(custom_views) do
    table.insert(left_tabs, { name = v.name, key = v.key })
  end

  local header_left = "  "
  local hls = {}

  for _, tab in ipairs(left_tabs) do
    local is_active = (view == tab.name)
    local tab_str = (" %s (%s) "):format(tab.name, tab.key)
    local start_col = #header_left
    header_left = header_left .. tab_str .. "  "

    table.insert(hls, {
      row = 0,
      start_col = start_col,
      end_col = start_col + #tab_str,
      hl = is_active and "BitbucketTabActive" or "BitbucketTabInactive",
    })
  end
  
  local header_right = ""
  for _, tab in ipairs(right_tabs) do
    local tab_str = (" %s (%s) "):format(tab.name, tab.key)
    header_right = header_right .. tab_str .. "  "
  end
  
  local win_width = vim.api.nvim_win_get_width(state.win or 0)
  local padding = (" "):rep(math.max(1, win_width - vim.fn.strdisplaywidth(header_left) - vim.fn.strdisplaywidth(header_right)))
  local header = header_left .. padding .. header_right
  
  local right_start = #header_left + #padding
  for _, tab in ipairs(right_tabs) do
    local is_active = (view == tab.name)
    local tab_str = (" %s (%s) "):format(tab.name, tab.key)
    
    table.insert(hls, {
      row = 0,
      start_col = right_start,
      end_col = right_start + #tab_str,
      hl = is_active and "BitbucketTabActive" or "BitbucketTabInactive",
    })
    right_start = right_start + #tab_str + 2
  end

  local header_lines = { header, "" }

  if false then
    -- JQL Input Line
    local jql_display = state.custom_jql or ""
    local jql_line = "    󰭎 JQL Query: " .. jql_display
    table.insert(header_lines, jql_line)
    state.jql_line = #header_lines - 1
    table.insert(hls, { row = state.jql_line, start_col = 4, end_col = 18, hl = "Keyword" })
    table.insert(hls, { row = state.jql_line, start_col = 19, end_col = -1, hl = "String" })

    -- Border for JQL line
    table.insert(
      hls,
      { row = state.jql_line, start_col = 2, virt_text = { { "│", "Comment" } }, virt_text_pos = "overlay" }
    )

    -- Virtual text hint for JQL input
    table.insert(hls, {
      row = state.jql_line,
      start_col = 0,
      virt_text = {
        { "󰋖 Press ", "BitbucketHelp" },
        { "<CR>", "BitbucketKey" },
        { " to edit query ", "BitbucketHelp" },
      },
      virt_text_pos = "right_align",
    })
    table.insert(header_lines, "    ")
    -- Border for empty line
    table.insert(
      hls,
      { row = #header_lines - 1, start_col = 2, virt_text = { { "│", "Comment" } }, virt_text_pos = "overlay" }
    )

    -- Saved Queries Header
    local sq_line = "    󱔗 Saved Queries:"
    table.insert(header_lines, sq_line)
    local sq_row = #header_lines - 1
    table.insert(hls, { row = sq_row, start_col = 4, end_col = -1, hl = "Title" })
    -- Border for SQ header
    table.insert(hls, { row = sq_row, start_col = 2, virt_text = { { "│", "Comment" } }, virt_text_pos = "overlay" })

    -- Virtual text hint for Saved Queries
    table.insert(hls, {
      row = sq_row,
      start_col = 0,
      virt_text = {
        { "(Press ", "BitbucketHelp" },
        { "<CR>", "BitbucketKey" },
        { " to apply) ", "BitbucketHelp" },
      },
      virt_text_pos = "right_align",
    })

    -- Saved Queries List
    local config = require("atlas.common.config")
    local queries = config.options.queries or {}
    local query_names = {}
    for name, _ in pairs(queries) do
      table.insert(query_names, name)
    end
    table.sort(query_names)

    state.query_map = {}
    for _, name in ipairs(query_names) do
      local is_active = (state.current_query == name)
      local line = ("      %s"):format(name)
      local row = #header_lines
      table.insert(header_lines, line)
      state.query_map[row] = name

      -- Border for item
      table.insert(hls, { row = row, start_col = 2, virt_text = { { "│", "Comment" } }, virt_text_pos = "overlay" })

      table.insert(hls, { row = row, start_col = 6, end_col = -1, hl = is_active and "BitbucketSubTabActive" or "Comment" })
    end
    table.insert(header_lines, "    ")
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, header_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })

  for _, h in ipairs(hls) do
    local opts = {}
    if h.hl then
      opts.hl_group = h.hl
    end
    if h.end_col and h.end_col ~= -1 then
      opts.end_col = h.end_col
    end
    if h.virt_text then
      opts.virt_text = h.virt_text
      opts.virt_text_pos = h.virt_text_pos
    end
    vim.api.nvim_buf_set_extmark(state.buf, state.ns, h.row, h.start_col, opts)
  end
end

-- ---------------------------------------------
-- Render TREE into buffer
-- ---------------------------------------------
function M.render_pr_tree(issues, view, depth, row)
  depth = depth or 1
  row = row or 2

  if depth == 1 then
    state.line_map = {}
    if view then
      render_header(view)
      
      local header_node = {
        key = "ID",
        summary = "Title",
        comment_count = "󰍩",
        task_count = "☑",
        approvals = "✓",
        author = { display_name = "Author" },
        workspace = "Workspace",
        repo = "Repo",
        updated_on = "2000-01-01T00:00:00.000000+00:00",
        type = "header",
        children = {},
        expanded = false,
      }
      
      state.line_map[row] = nil
      render_issue_line(header_node, 1, row)
      
      vim.api.nvim_buf_set_extmark(state.buf, state.ns, row, 0, {
        end_line = row + 1,
        hl_group = "Comment",
      })
      
      row = row + 1
      
    end
  end

  for i, node in ipairs(issues) do
    if depth == 1 and i > 1 then
      vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
      vim.api.nvim_buf_set_lines(state.buf, row, row + 1, false, { "" })
      vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
      row = row + 1
    end

    state.line_map[row] = node
    render_issue_line(node, depth, row)
    row = row + 1

    if node.children and #node.children > 0 and node.expanded then
      row = M.render_pr_tree(node.children, view, depth + 1, row)
    end
  end

  return row
end

-- ---------------------------------------------
-- Clear buffer
-- ---------------------------------------------
---@param buf integer
function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
