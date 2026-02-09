local M = {}

local api = vim.api
local state = require("atlas.jira-board-state")
local config = require("atlas.common.config")
local render = require("atlas.jira-board-render")
local util = require("atlas.jira-util")
local helper = require("atlas.jira-board-helper")
local sprint = require("atlas.jira-api.sprint")
local common_ui = require("atlas.common.ui")
local board_ui = require("atlas.jira-board-ui")
local log = require("atlas.common.log")

local function ensure_window()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    board_ui.create_window()
    util.setup_static_highlights()
  end
end

local cache_dir = vim.fn.stdpath("cache") .. "/atlas/jira"
local cache_file = cache_dir .. "/issues.json"

local function ensure_cache_dir()
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
end

local function load_cache_from_disk()
  if vim.fn.filereadable(cache_file) == 1 then
    local f = io.open(cache_file, "r")
    if f then
      local content = f:read("*all")
      f:close()
      local ok, cache_data = pcall(vim.json.decode, content)
      if ok and cache_data then
        state.cache = cache_data
      end
    end
  end
end

local function save_cache_to_disk()
  ensure_cache_dir()
  local ok, encoded = pcall(vim.json.encode, state.cache)
  if not ok then
    log.jira("Failed to encode cache: " .. tostring(encoded))
    return
  end
  
  local f, err = io.open(cache_file, "w")
  if not f then
    log.jira("Failed to open cache file for writing: " .. tostring(err))
    return
  end
  
  f:write(encoded)
  f:close()
end

local function is_cache_valid(cache_entry)
  if not cache_entry or not cache_entry.timestamp then
    return false
  end
  
  local ttl = config.options.cache_ttl or 0
  if ttl == 0 then
    return false -- Cache disabled
  end
  
  local age = os.time() - cache_entry.timestamp
  return age < ttl
end

function M.refresh_view()
  local cache_key = helper.get_cache_key(state.project_key, state.current_view)
  state.cache[cache_key] = nil
  save_cache_to_disk()
  M.load_view(state.project_key, state.current_view)
end

local function set_expanded_recursive(nodes, expanded)
  for _, node in ipairs(nodes) do
    if node.children and #node.children > 0 then
      node.expanded = expanded
      set_expanded_recursive(node.children, expanded)
    end
  end
end

function M.set_all_expanded(expanded)
  if not state.tree then
    return
  end
  set_expanded_recursive(state.tree, expanded)

  local cursor = api.nvim_win_get_cursor(state.win)
  render.clear(state.buf)
  render.render_issue_tree(state.tree, state.current_view)

  local line_count = api.nvim_buf_line_count(state.buf)
  if cursor[1] > line_count then
    cursor[1] = line_count
  end
  api.nvim_win_set_cursor(state.win, cursor)
end

function M.toggle_node()
  local cursor = api.nvim_win_get_cursor(state.win)
  local node = helper.get_node_at_cursor()

  if node and node.children and #node.children > 0 then
    node.expanded = not node.expanded
    render.clear(state.buf)
    render.render_issue_tree(state.tree, state.current_view)

    local line_count = api.nvim_buf_line_count(state.buf)
    if cursor[1] > line_count then
      cursor[1] = line_count
    end
    api.nvim_win_set_cursor(state.win, cursor)
  end
end

function M.get_query_names()
  local queries = config.options.queries or {}
  local names = {}
  for name, _ in pairs(queries) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

function M.handle_cr()
  local cursor = api.nvim_win_get_cursor(state.win)
  local row = cursor[1] - 1

  if state.current_view == "JQL" then
    if row == state.jql_line then
      M.prompt_jql()
      return
    end

    local query_name = state.query_map[row]
    if query_name then
      M.switch_query(query_name)
      return
    end
  end

  -- Check if cursor is on an issue line
  local node = helper.get_node_at_cursor()
  if node and node.key then
    board_ui.show_issue_details_popup(node)
  else
    -- Fallback to toggle node if it's not an issue line
    M.toggle_node()
  end
end

function M.prompt_jql()
  board_ui.open_jql_input(state.custom_jql or "", function(input)
    state.custom_jql = input
    state.current_query = "Custom JQL"
    M.load_view(state.project_key, "JQL")
  end)
end

function M.switch_query(query_name)
  local queries = config.options.queries or {}
  state.current_query = query_name

  local jql = queries[query_name]
  state.custom_jql = jql:format(state.project_key)

  M.load_view(state.project_key, "JQL")
end

function M.cycle_jql_query()
  local query_names = M.get_query_names()
  if #query_names == 0 then
    return
  end

  local current_idx = 0
  for i, name in ipairs(query_names) do
    if name == state.current_query then
      current_idx = i
      break
    end
  end

  local next_idx = (current_idx % #query_names) + 1
  M.switch_query(query_names[next_idx])
end

function M.setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = state.buf }

  -- Clear existing buffer keymaps
  local keys_to_clear = {
    "q", "r", "i", "c", "s", "y", "f", "a",
    "H", "J", "K",
    "j", "k", "<Tab>", "<CR>",
    "za", "?", "gx",
  }
  for _, k in ipairs(keys_to_clear) do
    pcall(vim.api.nvim_buf_del_keymap, state.buf, "n", k)
  end

  -- General
  vim.keymap.set("n", "q", function()
    if state.win and api.nvim_win_is_valid(state.win) then
      api.nvim_win_close(state.win, true)
    end
  end, opts)

  vim.keymap.set("n", "r", function()
    require("atlas.jira-board").refresh_view()
  end, opts)

  -- Navigation
  local function navigate_to_next_issue(direction)
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local total_lines = vim.api.nvim_buf_line_count(state.buf)
    local start, stop, step = current_line + 1, total_lines, 1
    
    if direction == "up" then
      start, stop, step = current_line - 1, 1, -1
    end
    
    for line = start, stop, step do
      if state.line_map[line - 1] then
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        return
      end
    end
  end
  
  vim.keymap.set("n", "j", function()
    navigate_to_next_issue("down")
  end, opts)
  
  vim.keymap.set("n", "k", function()
    navigate_to_next_issue("up")
  end, opts)
  
  vim.keymap.set("n", "<Tab>", function()
    require("atlas.jira-board").toggle_node()
  end, opts)
  vim.keymap.set("n", "za", function()
    require("atlas.jira-board").toggle_node()
  end, opts)
  vim.keymap.set("n", "<CR>", function()
    require("atlas.jira-board").handle_cr()
  end, opts)

  -- View switching - Dynamic custom views
  local custom_views = config.options.jira_views or {}
  for _, view in ipairs(custom_views) do
    vim.keymap.set("n", view.key, function()
      require("atlas.jira-board").load_view(state.project_key, view.name)
    end, opts)
  end

  -- JQL view (always present)
  vim.keymap.set("n", "J", function()
    if state.current_view == "JQL" then
      require("atlas.jira-board").cycle_jql_query()
    else
      require("atlas.jira-board").load_view(state.project_key, "JQL")
    end
  end, opts)
  
  -- Help view (always present)
  vim.keymap.set("n", "H", function()
    require("atlas.jira-board").load_view(state.project_key, "Help")
  end, opts)
  
  -- Search
  vim.keymap.set("n", "?", function()
    require("atlas.jira-board").search_issues()
  end, opts)
  
  -- Favorites
  vim.keymap.set("n", "s", function()
    require("atlas.jira-board").toggle_favorite()
  end, opts)
  
  vim.keymap.set("n", "f", function()
    require("atlas.jira-board").show_favorites()
  end, opts)

  -- Issue Actions
  vim.keymap.set("n", "K", function()
    require("atlas.jira-board").show_issue_details()
  end, opts)
  vim.keymap.set("n", "a", function()
    require("atlas.jira-board").show_issue_actions()
  end, opts)
  vim.keymap.set("n", "gx", function()
    require("atlas.jira-board").open_in_browser()
  end, opts)
  vim.keymap.set("n", "i", function()
    require("atlas.jira-board").create_issue()
  end, opts)
  vim.keymap.set("n", "y", function()
    require("atlas.jira-board").copy_issue_key()
  end, opts)
  vim.keymap.set("n", "c", function()
    require("atlas.jira-board").add_comment()
  end, opts)
end

function M.load_view(project_key, view_name)
  log.jira("Loading view '" .. view_name .. "' for project '" .. project_key .. "'")
  local old_view = helper.save_view_if_same(view_name)

  state.project_key = project_key
  state.current_view = view_name

  -- HELP VIEW
  if view_name == "Help" then
    board_ui.show_help_popup()
    return
  end

  -- JQL INIT
  if view_name == "JQL" and not state.current_query then
    local query_names = M.get_query_names()
    if #query_names > 0 then
      state.current_query = query_names[1]
      local queries = config.options.queries or {}
      state.custom_jql = queries[state.current_query]:format(project_key)
    else
      state.current_query = "Custom JQL"
    end
  end

  -- Load cache from disk on first access
  if vim.tbl_isempty(state.cache) then
    load_cache_from_disk()
    if not vim.tbl_isempty(state.cache) then
      log.jira("Loaded cache from disk")
    end
  end

  local cache_key = helper.get_cache_key(project_key, view_name)
  local cache_entry = state.cache[cache_key]
  local cached_issues = nil
  
  if cache_entry and is_cache_valid(cache_entry) then
    cached_issues = cache_entry.data
    log.jira("Using cached data for '" .. view_name .. "'")
  end

  local function process_issues(issues, from_cache)
    vim.schedule(function()
      common_ui.stop_loading()
      ensure_window()

      render.clear(state.buf)

      if not issues or #issues == 0 then
        state.tree = {}
        render.render_issue_tree(state.tree, state.current_view)
        log.jira("No issues found in '" .. view_name .. "'")
        vim.notify("No issues found in " .. view_name .. ".", vim.log.levels.WARN)
      else
        log.jira("Fetched " .. #issues .. " issue(s) for '" .. view_name .. "'" .. (from_cache and " (from cache)" or ""))
        state.tree = util.build_issue_tree(issues)
        render.render_issue_tree(state.tree, state.current_view)
      end

      helper.restore_view(old_view)
      M.setup_keymaps()
    end)
  end

  if cached_issues then
    process_issues(cached_issues, true)
    return
  end

  common_ui.start_loading("Loading " .. view_name .. " for " .. project_key .. "...")

  local fetch_fn
  
  -- Check if it's a custom view
  local custom_views = config.options.jira_views or {}
  local custom_view = nil
  for _, v in ipairs(custom_views) do
    if v.name == view_name then
      custom_view = v
      break
    end
  end
  
  if custom_view then
    if custom_view.jql then
      -- Custom view with JQL
      fetch_fn = function(pk, cb)
        local jql = custom_view.jql:format(pk)
        sprint.get_issues_by_jql(pk, jql, cb)
      end
    else
      -- Custom view without JQL (use active sprint by default)
      fetch_fn = function(pk, cb)
        sprint.get_active_sprint_issues(pk, cb)
      end
    end
  elseif view_name == "Active Sprint" then
    fetch_fn = function(pk, cb)
      sprint.get_active_sprint_issues(pk, cb)
    end
  elseif view_name == "JQL" then
    fetch_fn = function(pk, cb)
      sprint.get_issues_by_jql(pk, state.custom_jql, cb)
    end
  end
  
  if not fetch_fn then
    vim.schedule(function()
      common_ui.stop_loading()
      vim.notify("Unknown view: " .. view_name, vim.log.levels.ERROR)
    end)
    return
  end

  fetch_fn(project_key, function(issues, err)
    if err then
      vim.schedule(function()
        common_ui.stop_loading()
        vim.notify("Error: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    state.cache[cache_key] = {
      data = issues,
      timestamp = os.time(),
    }
    save_cache_to_disk()
    process_issues(issues, false)
  end)
end

function M.show_issue_details()
  local node = helper.get_node_at_cursor()
  if not node then
    return
  end

  board_ui.show_issue_details_popup(node)
end

function M.show_issue_actions()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    vim.notify("No issue selected", vim.log.levels.WARN)
    return
  end

  local actions = {
    { label = "Show details", fn = function() board_ui.show_issue_details_popup(node) end },
    { label = "Read task", fn = function() M.read_task() end },
    { label = "Edit task", fn = function() M.edit_issue() end },
    { label = "Open in browser", fn = function() M.open_in_browser() end },
    { label = "Update status", fn = function() M.change_status() end },
    { label = "Change assignee", fn = function() M.change_assignee() end },
    { label = "Child issues", fn = function() M.show_child_issues() end },
    { label = "Parent & children", fn = function() M.show_parent_issue() end },
  }

  local labels = {}
  for _, a in ipairs(actions) do
    table.insert(labels, a.label)
  end

  vim.ui.select(labels, {
    prompt = "Issue " .. node.key .. " – choose action:",
    format_item = function(item) return item end,
  }, function(choice)
    if not choice then return end
    for _, a in ipairs(actions) do
      if a.label == choice then
        a.fn()
        break
      end
    end
  end)
end

function M.change_status()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    return
  end

  common_ui.start_loading("Fetching transitions for " .. node.key .. "...")
  local jira_api = require("atlas.jira-api.api")
  jira_api.get_transitions(node.key, function(transitions, err)
    vim.schedule(function()
      common_ui.stop_loading()
      if err then
        vim.notify("Error fetching transitions: " .. err, vim.log.levels.ERROR)
        return
      end

      if #transitions == 0 then
        vim.notify("No available transitions for " .. node.key, vim.log.levels.WARN)
        return
      end

      local choices = {}
      local id_map = {}
      for _, t in ipairs(transitions) do
        table.insert(choices, t.name)
        id_map[t.name] = t.id
      end

      vim.ui.select(choices, { prompt = "Select Status for " .. node.key .. ":" }, function(choice)
        if not choice then
          return
        end
        local transition_id = id_map[choice]

        common_ui.start_loading("Updating status to " .. choice .. "...")
        jira_api.transition_issue(node.key, transition_id, function(_, t_err)
          vim.schedule(function()
            common_ui.stop_loading()
            if t_err then
              vim.notify("Error updating status: " .. t_err, vim.log.levels.ERROR)
              return
            end

            vim.notify("Updated " .. node.key .. " to " .. choice, vim.log.levels.INFO)
            M.refresh_view()
          end)
        end)
      end)
    end)
  end)
end

function M.change_assignee()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    return
  end

  local jira_api = require("atlas.jira-api.api")
  local choices = { "Assign to Me", "Unassign" }

  vim.ui.select(choices, { prompt = "Change Assignee for " .. node.key .. ":" }, function(choice)
    if not choice then
      return
    end

    if choice == "Assign to Me" then
      common_ui.start_loading("Fetching your account info...")
      jira_api.get_myself(function(me, m_err)
        vim.schedule(function()
          common_ui.stop_loading()
          if m_err or not me or not me.accountId then
            vim.notify("Error fetching account info: " .. (m_err or "Unknown error"), vim.log.levels.ERROR)
            return
          end

          common_ui.start_loading("Assigning " .. node.key .. " to you...")
          jira_api.assign_issue(node.key, me.accountId, function(_, a_err)
            vim.schedule(function()
              common_ui.stop_loading()
              if a_err then
                vim.notify("Error assigning issue: " .. a_err, vim.log.levels.ERROR)
                return
              end
              vim.notify("Assigned " .. node.key .. " to you", vim.log.levels.INFO)
              M.refresh_view()
            end)
          end)
        end)
      end)
    elseif choice == "Unassign" then
      common_ui.start_loading("Unassigning " .. node.key .. "...")
      jira_api.assign_issue(node.key, "-1", function(_, a_err)
        vim.schedule(function()
          common_ui.stop_loading()
          if a_err then
            vim.notify("Error unassigning issue: " .. a_err, vim.log.levels.ERROR)
            return
          end
          vim.notify("Unassigned " .. node.key, vim.log.levels.INFO)
          M.refresh_view()
        end)
      end)
    end
  end)
end

function M.read_task()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    return
  end

  require("atlas.issue").open(node.key)
end

function M.edit_issue()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    return
  end

  require("atlas.edit").open(node.key)
end

function M.create_issue()
  local node = helper.get_node_at_cursor()
  local parent_key = nil

  if node then
    if node.parent then
      parent_key = node.parent
    elseif node.key then
      parent_key = node.key
    end
  end

  require("atlas.create").open(state.project_key, parent_key)
end

function M.copy_issue_key()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    vim.notify("No issue selected", vim.log.levels.WARN)
    return
  end

  vim.fn.setreg("+", node.key)
  vim.fn.setreg('"', node.key)
  vim.notify("Copied " .. node.key .. " to clipboard", vim.log.levels.INFO)
end

function M.add_comment()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    vim.notify("No issue selected", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Add comment to " .. node.key .. ": " }, function(comment)
    if not comment or comment == "" then
      return
    end

    local jira_api = require("atlas.jira-api.api")
    common_ui.start_loading("Adding comment...")
    
    jira_api.add_comment(node.key, comment, function(_, err)
      vim.schedule(function()
        common_ui.stop_loading()
        if err then
          vim.notify("Error adding comment: " .. err, vim.log.levels.ERROR)
          return
        end
        vim.notify("Comment added to " .. node.key, vim.log.levels.INFO)
      end)
    end)
  end)
end

function M.open_in_browser()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    return
  end

  local base = config.options.jira.base
  if not base or base == "" then
    vim.notify("Jira base URL is not configured", vim.log.levels.ERROR)
    return
  end

  if not base:match("/$") then
    base = base .. "/"
  end

  local url = base .. "browse/" .. node.key
  vim.ui.open(url)
end

function M.show_child_issues()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    return
  end

  -- Switch to JQL view and set query to find child issues
  state.custom_jql = 'parent = "' .. node.key .. '"'
  state.current_query = "Child Issues of " .. node.key
  M.load_view(state.project_key, "JQL")
end

function M.show_parent_issue()
  local node = helper.get_node_at_cursor()
  if not node or not node.parent then
    vim.notify("Issue does not have a parent or parent not found.", vim.log.levels.WARN)
    return
  end

  state.custom_jql = string.format('key = "%s" OR parent = "%s"', node.parent, node.parent)
  state.current_query = "Parent & Children of " .. node.parent
  M.load_view(state.project_key, "JQL")
end

function M.toggle_favorite()
  local node = helper.get_node_at_cursor()
  if not node or not node.key then
    vim.notify("No issue selected", vim.log.levels.WARN)
    return
  end
  
  if state.favorites[node.key] then
    state.favorites[node.key] = nil
    vim.notify(string.format("Removed %s from favorites", node.key), vim.log.levels.INFO)
  else
    state.favorites[node.key] = true
    vim.notify(string.format("Added %s to favorites", node.key), vim.log.levels.INFO)
  end
  
  -- Save favorites to disk
  M.save_favorites()
  
  -- Re-render to update the star indicator
  M.refresh_view()
end

function M.save_favorites()
  local favorites_file = vim.fn.stdpath("cache") .. "/atlas/jira/favorites.json"
  ensure_cache_dir()
  
  local favorites_list = {}
  for key, _ in pairs(state.favorites) do
    table.insert(favorites_list, key)
  end
  
  local ok, encoded = pcall(vim.json.encode, favorites_list)
  if ok then
    local file = io.open(favorites_file, "w")
    if file then
      file:write(encoded)
      file:close()
    end
  end
end

function M.load_favorites()
  local favorites_file = vim.fn.stdpath("cache") .. "/atlas/jira/favorites.json"
  
  if vim.fn.filereadable(favorites_file) == 1 then
    local file = io.open(favorites_file, "r")
    if file then
      local content = file:read("*a")
      file:close()
      
      local ok, decoded = pcall(vim.json.decode, content)
      if ok and decoded then
        state.favorites = {}
        for _, key in ipairs(decoded) do
          state.favorites[key] = true
        end
      end
    end
  end
end

function M.show_favorites()
  if not next(state.favorites) then
    vim.notify("No favorite issues yet. Press 's' on an issue to star it.", vim.log.levels.INFO)
    return
  end
  
  local keys = {}
  for key, _ in pairs(state.favorites) do
    table.insert(keys, key)
  end
  
  state.custom_jql = string.format('key in (%s)', table.concat(keys, ","))
  state.current_query = "Favorites"
  M.load_view(state.project_key, "JQL")
end

function M.search_issues()
  vim.ui.input({ prompt = "Search issues (text or JQL): " }, function(input)
    if not input or input == "" then
      return
    end
    
    -- Check if input looks like a ticket key (e.g., PROJ-1234)
    if input:match("^[A-Z]+-%d+$") then
      state.custom_jql = string.format('key = "%s"', input)
      state.current_query = "Search: " .. input
    -- Check if input contains JQL operators
    elseif input:match("[=<>~]") or input:lower():match("^order by") or input:lower():match(" and ") or input:lower():match(" or ") then
      state.custom_jql = input
      state.current_query = "Search: " .. input
    else
      -- Plain text search - search in summary and description
      state.custom_jql = string.format(
        'project = "%s" AND (summary ~ "%s" OR description ~ "%s") ORDER BY updated DESC',
        state.project_key,
        input,
        input
      )
      state.current_query = "Search: " .. input
    end
    
    M.load_view(state.project_key, "JQL")
  end)
end

function M.open(project_key)
  -- If already open, just focus
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_set_current_win(state.win)
    return
  end

  -- Validate Config
  local jc = config.options.jira
  if not jc.base or jc.base == "" or not jc.email or jc.email == "" or not jc.token or jc.token == "" then
    vim.notify("Jira configuration is missing. Please run setup() with base, email, and token.", vim.log.levels.ERROR)
    return
  end

  if not project_key then
    project_key = vim.fn.input("Jira Project Key: ")
  end

  if not project_key or project_key == "" then
    vim.notify("Project key is required", vim.log.levels.ERROR)
    return
  end

  -- Load favorites from disk
  M.load_favorites()
  
  -- Load first custom view by default, or "Active Sprint" as fallback
  local custom_views = config.options.jira_views or {}
  local default_view = "Active Sprint"
  if #custom_views > 0 then
    default_view = custom_views[1].name
  end
  
  M.load_view(project_key, default_view)
end

return M
