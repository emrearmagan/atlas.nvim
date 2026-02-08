---@class Bitbucket.Util
local M = {}

local config = require("atlas.common.config")
local bb_api = require("atlas.bitbucket-api.api")

---Normalize PR fields to ensure all required fields exist
---@param pr table
---@return table
local function normalize_pr(pr)
  local normalized = vim.tbl_extend("keep", pr, {
    key = pr.key or ("#" .. (pr.id or "")),
    time_spent = pr.time_spent or 0,
    time_estimate = pr.time_estimate or 0,
    assignee = pr.assignee or (pr.author and pr.author.display_name) or "Unknown",
    status = pr.status or pr.state or "OPEN",
    is_draft = pr.is_draft or pr.draft or false,
  })
  
  if type(normalized.summary) ~= "string" then
    normalized.summary = pr.title or "Untitled PR"
  end
  
  return normalized
end

---Build tree structure from PRs (repos as parent nodes)
---@param prs table[]
---@return table[]
function M.build_pr_tree(prs)
  local tree = {}
  local repos_map = {}
  
  for _, pr in ipairs(prs) do
    local normalized_pr = normalize_pr(pr)
    local repo_key = string.format("%s/%s", normalized_pr.workspace or "", normalized_pr.repo or "")
    if not repos_map[repo_key] then
      local repo_node = {
        type = "repo",
        key = repo_key,
        summary = "",
        workspace = normalized_pr.workspace,
        repo = normalized_pr.repo,
        children = {},
        expanded = true,
        time_spent = 0,
        time_estimate = 0,
        assignee = nil,
        status = "Repository",
      }
      repos_map[repo_key] = repo_node
      table.insert(tree, repo_node)
    end
    table.insert(repos_map[repo_key].children, normalized_pr)
  end
  
  return tree
end

local cache_dir = vim.fn.stdpath("cache") .. "/bitbucket"
local cache_file = cache_dir .. "/prs.json"

---Generate cache key for a repo
---@param workspace string
---@param repo string
---@return string
function M.get_cache_key(workspace, repo)
  return workspace .. "/" .. repo
end

---Ensure cache directory exists
local function ensure_cache_dir()
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
end

---Save cache to disk
---@param cache table
function M.save_cache_to_disk(cache)
  ensure_cache_dir()
  local ok, json_str = pcall(vim.json.encode, cache)
  if ok and json_str then
    vim.fn.writefile({ json_str }, cache_file)
  end
end

---Load cache from disk
---@return table
function M.load_cache_from_disk()
  local cache = {}
  if vim.fn.filereadable(cache_file) == 1 then
    local ok, content = pcall(vim.fn.readfile, cache_file)
    if ok and content then
      local json_str = table.concat(content, "\n")
      local ok2, cache_data = pcall(vim.json.decode, json_str)
      if ok2 and cache_data then
        cache = cache_data
      end
    end
  end
  return cache
end

---Check if cache entry is valid
---@param cache_entry table|nil
---@return boolean
function M.is_cache_valid(cache_entry)
  if not cache_entry or not cache_entry.timestamp then
    return false
  end
  
  local ttl = config.options.cache_ttl or 300
  local now = os.time()
  return (now - cache_entry.timestamp) < ttl
end

---Enrich PR with additional data (approvals, build status)
---@param workspace string
---@param repo string
---@param pr table
---@param is_my_pr boolean
---@param callback fun(enriched_pr: table)
function M.enrich_pr(workspace, repo, pr, is_my_pr, callback)
  local enriched = vim.tbl_extend("force", pr, {
    workspace = workspace,
    repo = repo,
    key = "#" .. (pr.id or ""),
    summary = pr.title or "Untitled PR",
    source_branch = pr.source and pr.source.branch and pr.source.branch.name or "unknown",
    destination_branch = pr.destination and pr.destination.branch and pr.destination.branch.name or "unknown",
    url = pr.links and pr.links.html and pr.links.html.href or "",
    comment_count = pr.comment_count or 0,
    approvals = 0,
    needs_work = 0,
    total_reviewers = 0,
    build_status = nil,
    task_count = pr.task_count or 0,
    is_draft = pr.draft or false,
    commit_hash = pr.source and pr.source.commit and pr.source.commit.hash and pr.source.commit.hash:sub(1, 7) or nil,
    time_spent = 0,
    time_estimate = 0,
    assignee = pr.author and pr.author.display_name or "Unknown",
    status = pr.state or "OPEN",
  })

  local display_build = config.options.display_build_status or "user"
  local display_approvals = config.options.display_approvals or "user"
  
  local should_fetch_build = display_build == "all" or (display_build == "user" and is_my_pr)
  local should_fetch_approvals = display_approvals == "all" or (display_approvals == "user" and is_my_pr)

  if should_fetch_approvals then
    bb_api.get_pull_request(workspace, repo, pr.id, function(pr_details, pr_err)
      if not pr_err and pr_details and pr_details.participants then
        enriched.total_reviewers = #pr_details.participants
        for _, participant in ipairs(pr_details.participants) do
          if participant.approved then
            enriched.approvals = enriched.approvals + 1
          end
          if participant.state == "changes_requested" then
            enriched.needs_work = enriched.needs_work + 1
          end
        end
      end

      if should_fetch_build then
        local commit_hash = pr.source and pr.source.commit and pr.source.commit.hash
        if commit_hash then
          bb_api.get_build_statuses(workspace, repo, commit_hash, function(statuses, status_err)
            if not status_err and statuses and statuses.values and #statuses.values > 0 then
              local latest = statuses.values[1]
              enriched.build_status = latest.state
            end
            callback(enriched)
          end)
        else
          callback(enriched)
        end
      else
        callback(enriched)
      end
    end)
  elseif should_fetch_build then
    local commit_hash = pr.source and pr.source.commit and pr.source.commit.hash
    if commit_hash then
      bb_api.get_build_statuses(workspace, repo, commit_hash, function(statuses, status_err)
        if not status_err and statuses and statuses.values and #statuses.values > 0 then
          local latest = statuses.values[1]
          enriched.build_status = latest.state
        end
        callback(enriched)
      end)
    else
      callback(enriched)
    end
  else
    callback(enriched)
  end
end

return M
