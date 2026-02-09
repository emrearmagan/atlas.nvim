---@class Bitbucket.Board
local M = {}

local api = vim.api
local state = require("atlas.bitbucket-board-state")
local config = require("atlas.common.config")
local render = require("atlas.bitbucket-board-render")
local util = require("atlas.common.util")
local bb_api = require("atlas.bitbucket-api.api")
local bb_util = require("atlas.bitbucket-util")
local common_ui = require("atlas.common.ui")
local board_ui = require("atlas.bitbucket-board-ui")
local helper = require("atlas.bitbucket-board-helper")
local log = require("atlas.common.log")

local function ensure_window()
  if not state.win or not api.nvim_win_is_valid(state.win) then
    board_ui.create_window()
    util.setup_static_highlights()
  end
end

local function position_cursor_on_first_pr()
  vim.schedule(function()
    if not state.win or not api.nvim_win_is_valid(state.win) then
      return
    end
    
    for row = 0, api.nvim_buf_line_count(state.buf) - 1 do
      if state.line_map[row] then
        api.nvim_win_set_cursor(state.win, {row + 1, 0})
        return
      end
    end
  end)
end

function M.toggle_node()
  local cursor = api.nvim_win_get_cursor(state.win)
  local row = cursor[1] - 1
  local node = state.line_map[row]

  if node and node.type == "repo" and node.children and #node.children > 0 then
    node.expanded = not node.expanded
    render.clear(state.buf)
    render.render_pr_tree(state.tree, state.current_view)

    local line_count = api.nvim_buf_line_count(state.buf)
    if cursor[1] > line_count then
      cursor[1] = line_count
    end
    api.nvim_win_set_cursor(state.win, cursor)
  end
end

function M.setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = state.buf }

  -- Close window
  vim.keymap.set("n", "q", function()
    if state.win and api.nvim_win_is_valid(state.win) then
      api.nvim_win_close(state.win, true)
    end
  end, opts)

  -- Refresh (force bypass cache)
  vim.keymap.set("n", "r", function()
    require("atlas.bitbucket-board").refresh(true)
  end, opts)

  -- Navigation
  local function navigate_to_next_pr(direction)
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
    navigate_to_next_pr("down")
  end, opts)
  
  vim.keymap.set("n", "k", function()
    navigate_to_next_pr("up")
  end, opts)

  local views = config.options.bitbucket_views or {}
  for _, view in ipairs(views) do
    if view.key then
      vim.keymap.set("n", view.key, function()
        require("atlas.bitbucket-board").load_view(view.name)
      end, opts)
    end
  end

  vim.keymap.set("n", "<Tab>", function()
    local views = config.options.bitbucket_views or {}
    if #views == 0 then return end
    local idx = nil
    for i, v in ipairs(views) do
      if v.name == state.current_view then idx = i break end
    end
    idx = idx or 1
    local next_idx = (idx % #views) + 1
    require("atlas.bitbucket-board").load_view(views[next_idx].name)
  end, opts)

  vim.keymap.set("n", "<S-Tab>", function()
    local views = config.options.bitbucket_views or {}
    if #views == 0 then return end
    local idx = nil
    for i, v in ipairs(views) do
      if v.name == state.current_view then idx = i break end
    end
    idx = idx or 1
    local prev_idx = idx - 1
    if prev_idx < 1 then prev_idx = #views end
    require("atlas.bitbucket-board").load_view(views[prev_idx].name)
  end, opts)

  vim.keymap.set("n", "za", function()
    require("atlas.bitbucket-board").toggle_node()
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    require("atlas.bitbucket-board").show_pr_details()
  end, opts)
  vim.keymap.set("n", "K", function()
    require("atlas.bitbucket-board").show_pr_details()
  end, opts)

  vim.keymap.set("n", "a", function()
    require("atlas.bitbucket-board").show_pr_actions()
  end, opts)

  vim.keymap.set("n", "gx", function()
    require("atlas.bitbucket-board").open_pr_in_browser()
  end, opts)

  vim.keymap.set("n", "H", function()
    local details = require("atlas.bitbucket-board-details")
    details.show_help_popup()
  end, opts)
end

function M.load_view_with_all_prs(prs)
  vim.schedule(function()
    ensure_window()
    state.prs = prs
    state.tree = bb_util.build_pr_tree(prs)
    render.clear(state.buf)
    render.render_pr_tree(state.tree, state.current_view)
    M.setup_keymaps()
    position_cursor_on_first_pr()
  end)
end

function M.load_view(view_name)
  local old_view = helper.save_view_if_same(view_name)
  
  state.current_view = view_name
  
  if view_name == "Help" then
    vim.schedule(function()
      ensure_window()
      state.tree = {}
      state.line_map = {}
      render.clear(state.buf)
      render.render_help()
      helper.restore_view(old_view)
      M.setup_keymaps()
    end)
    return
  end

  -- Filter PRs based on view
  local views = config.options.bitbucket_views or {}
  local view_config = nil
  for _, v in ipairs(views) do
    if v.name == view_name then
      view_config = v
      break
    end
  end

  if not view_config then
    vim.notify("View not found: " .. view_name, vim.log.levels.ERROR)
    return
  end

  -- Filter all_prs based on view filter
  local filtered_prs = {}
  local account_id = config.options.bitbucket.account_id
  for _, pr in ipairs(state.all_prs) do
    if view_config.filter(pr, account_id) then
      table.insert(filtered_prs, pr)
    end
  end
  
  -- Check if any PRs need enrichment
  local display_build = config.options.display_build_status or "user"
  local display_approvals = config.options.display_approvals or "user"
  
  local prs_needing_enrichment = {}
  for _, pr in ipairs(filtered_prs) do
    local is_my_pr = pr.author and pr.author.account_id == account_id
    
    -- Determine what enrichment this PR needs based on config
    local should_fetch_build = display_build == "all" or (display_build == "user" and is_my_pr)
    local should_fetch_approvals = display_approvals == "all" or (display_approvals == "user" and is_my_pr)
    
    -- Check if PR needs enrichment based on what we want to fetch
    local needs_enrichment = false
    if should_fetch_approvals and pr.total_reviewers == nil then
      needs_enrichment = true
    end
    if should_fetch_build and pr.build_status == nil then
      needs_enrichment = true
    end
    
    if needs_enrichment then
      table.insert(prs_needing_enrichment, pr)
    end
  end
  
  -- If no enrichment needed, render immediately
  if #prs_needing_enrichment == 0 then
    vim.schedule(function()
      ensure_window()
      state.prs = filtered_prs
      state.tree = bb_util.build_pr_tree(filtered_prs)
      render.clear(state.buf)
      render.render_pr_tree(state.tree, state.current_view)
      helper.restore_view(old_view)
      M.setup_keymaps()
      position_cursor_on_first_pr()
    end)
    return
  end
  
  -- Enrich PRs for this view
  local total_to_enrich = #prs_needing_enrichment
  
  log.bitbucket("Loading view '" .. view_name .. "' with " .. #filtered_prs .. " PR(s), " .. total_to_enrich .. " need additional data")
  
  common_ui.start_loading("Loading " .. view_name .. "...")
  local enriched_count = 0
  
  for _, pr in ipairs(prs_needing_enrichment) do
    local is_my_pr = pr.author and pr.author.account_id == account_id
    bb_util.enrich_pr(pr.workspace, pr.repo, pr, is_my_pr, function(enriched_pr)
      enriched_count = enriched_count + 1
      
      -- Update the PR in state.all_prs
      for i, p in ipairs(state.all_prs) do
        if p.id == enriched_pr.id and p.workspace == enriched_pr.workspace and p.repo == enriched_pr.repo then
          state.all_prs[i] = enriched_pr
          break
        end
      end
      
      -- Update in filtered_prs
      for i, p in ipairs(filtered_prs) do
        if p.id == enriched_pr.id then
          filtered_prs[i] = enriched_pr
          break
        end
      end
      
      -- When all PRs for this view are enriched
      if enriched_count == total_to_enrich then
        -- Update cache for all repos
        local ok1, err1 = pcall(function()
          local repos_to_cache = {}
          for _, p in ipairs(state.all_prs) do
            local key = p.workspace .. "/" .. p.repo
            if not repos_to_cache[key] then
              repos_to_cache[key] = {
                workspace = p.workspace,
                repo = p.repo,
                prs = {}
              }
            end
            table.insert(repos_to_cache[key].prs, p)
          end
          
          for _, repo_data in pairs(repos_to_cache) do
            local cache_key = bb_util.get_cache_key(repo_data.workspace, repo_data.repo)
            state.cache[cache_key] = {
              data = { values = repo_data.prs },
              timestamp = os.time(),
            }
          end
          bb_util.save_cache_to_disk(state.cache)
        end)
        
        if not ok1 then
          vim.notify("Error updating cache: " .. tostring(err1), vim.log.levels.ERROR)
        end
        
        log.bitbucket("Loading complete for '" .. view_name .. "', rendering UI")
        vim.schedule(function()
          common_ui.stop_loading()
          ensure_window()
          state.prs = filtered_prs
          state.tree = bb_util.build_pr_tree(filtered_prs)
          render.clear(state.buf)
          render.render_pr_tree(state.tree, state.current_view)
          helper.restore_view(old_view)
          M.setup_keymaps()
          position_cursor_on_first_pr()
        end)
      end
    end)
  end
end

function M.show_pr_details()
  local cursor = api.nvim_win_get_cursor(state.win)
  local row = cursor[1] - 1
  local item = state.line_map[row]

  if not item then
    vim.notify("No PR found at cursor", vim.log.levels.WARN)
    return
  end
  
  if item.type == "repo" then
    M.toggle_node()
    return
  end

  local details = require("atlas.bitbucket-board-details")
  details.show_pr_details(item)
end

function M.open_pr_in_browser()
  local pr = helper.get_pr_at_cursor()

  if not pr then
    vim.notify("No PR found at cursor", vim.log.levels.WARN)
    return
  end
  
  -- Ensure URL is properly set
  local url = pr.url
  if not url or url == "" then
    url = pr.links and pr.links.html and pr.links.html.href
  end
  
  if not url or url == "" then
    vim.notify("No URL available for PR #" .. (pr.id or "unknown"), vim.log.levels.WARN)
    return
  end

  vim.ui.open(url)
end

function M.open_pr_build()
  local pr = helper.get_pr_at_cursor()
  if not pr then
    vim.notify("No PR found at cursor", vim.log.levels.WARN)
    return
  end
  
  if not pr.build_url or pr.build_url == "" then
    vim.notify("No build URL available for PR #" .. (pr.id or "unknown"), vim.log.levels.WARN)
    return
  end

  vim.ui.open(pr.build_url)
end

function M.show_pr_actions()
  local pr = helper.get_pr_at_cursor()
  if not pr then
    vim.notify("No PR found at cursor", vim.log.levels.WARN)
    return
  end

  local details = require("atlas.bitbucket-board-details")
  local actions = {
    { label = "View full details", fn = function() details.show_pr_full_details(pr) end },
    { label = "View comments", fn = function() details.show_pr_comments_view(pr) end },
    { label = "View commits", fn = function() details.show_pr_commits_view(pr) end },
    { label = "Open build", fn = function() M.open_pr_build() end },
  }

  local labels = {}
  for _, a in ipairs(actions) do
    table.insert(labels, a.label)
  end

  vim.ui.select(labels, {
    prompt = "PR #" .. (pr.id or "?") .. " – choose action:",
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

function M.refresh(force)
  local repos = config.options.repos

  if not repos or #repos == 0 then
    vim.notify("No repositories configured. Please add repos in setup().", vim.log.levels.ERROR)
    return
  end

  log.bitbucket("Starting refresh (force=" .. tostring(force) .. ") for " .. #repos .. " repo(s)")

  -- Load cache from disk on first refresh
  if not force and vim.tbl_isempty(state.cache) then
    state.cache = bb_util.load_cache_from_disk()
    if not vim.tbl_isempty(state.cache) then
      log.bitbucket("Loaded cache from disk")
    end
  end
  common_ui.start_loading("Loading pull requests...")

  local all_prs = {}
  local completed = 0
  local total = #repos

  for _, repo_config in ipairs(repos) do
    local cache_key = bb_util.get_cache_key(repo_config.workspace, repo_config.repo)
    local cached = state.cache[cache_key]
    
    -- Use cache if valid and not forcing refresh
    if not force and bb_util.is_cache_valid(cached) then
      completed = completed + 1
      
      if cached.data and cached.data.values then
        for _, pr in ipairs(cached.data.values) do
          table.insert(all_prs, pr)
        end
      end
      
      if completed == total then
        vim.schedule(function()
          common_ui.stop_loading()
          state.all_prs = all_prs
          
          -- Load first view (which will enrich only the filtered PRs)
          local views = config.options.bitbucket_views or {}
          if #views > 0 then
            M.load_view(views[1].name)
          else
            M.load_view_with_all_prs(all_prs)
          end
        end)
      end
    else
      -- Fetch from API
      bb_api.get_pull_requests(repo_config.workspace, repo_config.repo, function(result, err)
        completed = completed + 1

        if err then
          vim.schedule(function()
            vim.notify(
              string.format("Error fetching PRs from %s/%s: %s", repo_config.workspace, repo_config.repo, err or "unknown error"),
              vim.log.levels.ERROR
            )
          end)
        elseif result and result.values then
          if #result.values == 0 then
            -- No PRs in this repo, continue
            if completed == total then
              vim.schedule(function()
                common_ui.stop_loading()
                state.all_prs = all_prs
                
                -- Load first view
                local views = config.options.bitbucket_views or {}
                if #views > 0 then
                  M.load_view(views[1].name)
                else
                  M.load_view_with_all_prs(all_prs)
                end
              end)
            end
          else
            -- Just add raw PRs without enrichment
            for _, pr in ipairs(result.values) do
              -- Add basic fields
              pr.workspace = repo_config.workspace
              pr.repo = repo_config.repo
              pr.source_branch = pr.source and pr.source.branch and pr.source.branch.name or "unknown"
              pr.destination_branch = pr.destination and pr.destination.branch and pr.destination.branch.name or "unknown"
              pr.url = pr.links and pr.links.html and pr.links.html.href or ""
              pr.commit_hash = pr.source and pr.source.commit and pr.source.commit.hash and pr.source.commit.hash:sub(1, 7) or nil
              pr.is_draft = pr.draft or false
              
              table.insert(all_prs, pr)
            end
            
            -- When all repos are fetched
            if completed == total then
              log.bitbucket("Fetched " .. #all_prs .. " PR(s) total from all repos")
              vim.schedule(function()
                common_ui.stop_loading()
                state.all_prs = all_prs
                
                -- Load first view (which will enrich only the filtered PRs)
                local views = config.options.bitbucket_views or {}
                if #views > 0 then
                  M.load_view(views[1].name)
                else
                  -- No views, show all (and enrich all)
                  M.load_view_with_all_prs(all_prs)
                end
              end)
            end
          end
        end

        -- If this was the last repo and no PRs were found anywhere
        if completed == total and #all_prs == 0 then
          vim.schedule(function()
            common_ui.stop_loading()
            state.all_prs = all_prs
            
            -- Load first view
            local views = config.options.bitbucket_views or {}
            if #views > 0 then
              M.load_view(views[1].name)
            else
              M.load_view_with_all_prs(all_prs)
            end
          end)
        end
      end)
    end
  end
end

function M.open()
  -- If already open, just focus
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_set_current_win(state.win)
    return
  end

  -- Validate config
  local bb = config.options.bitbucket
  if not bb.user or bb.user == "" or not bb.token or bb.token == "" then
    vim.notify("Bitbucket configuration is missing. Please run setup() with credentials.", vim.log.levels.ERROR)
    return
  end

  M.refresh()
end

return M
