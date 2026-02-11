-- api.lua: Bitbucket REST API client using curl
local config = require("atlas.common.config")
local http = require("atlas.common.http")

-- Get environment variables
---@return BitbucketAuthOptions auth_opts
local function get_env()
  local env = {}

  -- Check environment variables first, fall back to config
  env.user = os.getenv("BITBUCKET_USER") or config.options.bitbucket.user
  env.token = os.getenv("BITBUCKET_TOKEN") or config.options.bitbucket.token
  env.workspace = os.getenv("BITBUCKET_WORKSPACE") or config.options.bitbucket.workspace
  env.account_id = os.getenv("BITBUCKET_ACCOUNT_ID") or config.options.bitbucket.account_id

  return env
end

-- Validate environment variables
---@return boolean valid
local function validate_env()
  local env = get_env()
  if not env.user or not env.token or not env.workspace or not env.account_id then
    vim.notify("Missing Bitbucket environment variables. Please check your setup.", vim.log.levels.ERROR)
    return false
  end
  return true
end

---Execute curl command asynchronously
---@param method string
---@param endpoint string
---@param callback? fun(T?: table, err?: string)
local function curl_request(method, endpoint, callback)
  if not validate_env() then
    if callback and vim.is_callable(callback) then
      callback(nil, "Missing environment variables")
    end
    return
  end

  local env = get_env()
  local url = "https://api.bitbucket.org/2.0" .. endpoint
  
  -- Build auth header
  local auth = vim.base64.encode(env.user .. ":" .. env.token)
  local headers = {
    ["Authorization"] = "Basic " .. auth,
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }

  http.curl_request(method, url, headers, nil, callback)
end

---@class Bitbucket.API
local M = {}

-- Get pull requests for a repository (with pagination)
---@param workspace string
---@param repo string
---@param callback fun(prs?: table, err?: string)
function M.get_pull_requests(workspace, repo, callback)
  local all_prs = {}
  
  local function fetch_page(url)
    local endpoint = url or string.format("/repositories/%s/%s/pullrequests?state=OPEN&pagelen=50", workspace, repo)
    
    curl_request("GET", endpoint, function(result, err)
      if err then
        callback(nil, err)
        return
      end

      if result and result.values then
        -- Add PRs from this page
        for _, pr in ipairs(result.values) do
          table.insert(all_prs, pr)
        end
        
        -- Check if there's a next page
        if result.next then
          -- Extract just the path and query from the next URL
          local next_path = result.next:match("https://api%.bitbucket%.org/2%.0(.*)")
          if next_path then
            fetch_page(next_path)
          else
            callback({ values = all_prs }, nil)
          end
        else
          -- No more pages, return all PRs
          callback({ values = all_prs }, nil)
        end
      else
        callback({ values = all_prs }, nil)
      end
    end)
  end
  
  fetch_page()
end

-- Get PR details including participants (for approvals/needs work)
---@param workspace string
---@param repo string
---@param pr_id number
---@param callback fun(pr?: table, err?: string)
function M.get_pull_request(workspace, repo, pr_id, callback)
  local endpoint = string.format("/repositories/%s/%s/pullrequests/%d", workspace, repo, pr_id)
  curl_request("GET", endpoint, function(result, err)
    if callback then
      callback(result, err)
    end
  end)
end

-- Get PR comments count
---@param workspace string
---@param repo string
---@param pr_id number
---@param callback fun(comments?: table, err?: string)
function M.get_pr_comments(workspace, repo, pr_id, callback)
  local endpoint = string.format("/repositories/%s/%s/pullrequests/%d/comments", workspace, repo, pr_id)
  curl_request("GET", endpoint, callback)
end

-- Get PR build statuses
---@param workspace string
---@param repo string
---@param commit_hash string
---@param callback fun(statuses?: table, err?: string)
function M.get_build_statuses(workspace, repo, commit_hash, callback)
  local endpoint = string.format("/repositories/%s/%s/commit/%s/statuses", workspace, repo, commit_hash)
  curl_request("GET", endpoint, callback)
end

-- Get PR commits (with pagination)
---@param workspace string
---@param repo string
---@param pr_id number
---@param callback fun(commits?: table, err?: string)
function M.get_pr_commits(workspace, repo, pr_id, callback)
  local all_commits = {}
  
  local function fetch_page(url)
    local endpoint = url or string.format("/repositories/%s/%s/pullrequests/%d/commits", workspace, repo, pr_id)
    
    curl_request("GET", endpoint, function(result, err)
      if err then
        callback(nil, err)
        return
      end

      if result and result.values then
        for _, commit in ipairs(result.values) do
          table.insert(all_commits, commit)
        end
        
        if result.next then
          local next_path = result.next:match("https://api%.bitbucket%.org/2%.0(.*)")
          if next_path then
            fetch_page(next_path)
          else
            callback({ values = all_commits }, nil)
          end
        else
          callback({ values = all_commits }, nil)
        end
      else
        callback({ values = all_commits }, nil)
      end
    end)
  end
  
  fetch_page()
end

---@param workspace string
---@param repo string
---@param pr_id number
---@param callback fun(diffstat?: table, err?: string)
function M.get_pr_diffstat(workspace, repo, pr_id, callback)
  local endpoint = string.format("/repositories/%s/%s/pullrequests/%d/diffstat", workspace, repo, pr_id)
  
  curl_request("GET", endpoint, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    if result and result.values then
      callback(result, nil)
    else
      callback({ values = {} }, nil)
    end
  end)
end

-- Get PR statuses (build/pipeline statuses with pagination)
---@param workspace string
---@param repo string
---@param pr_id number
---@param callback fun(statuses?: table, err?: string)
function M.get_pr_statuses(workspace, repo, pr_id, callback)
  local all_statuses = {}
  
  local function fetch_page(url)
    local endpoint = url or string.format("/repositories/%s/%s/pullrequests/%d/statuses", workspace, repo, pr_id)
    
    curl_request("GET", endpoint, function(result, err)
      if err then
        callback(nil, err)
        return
      end

      if result and result.values then
        for _, status in ipairs(result.values) do
          table.insert(all_statuses, status)
        end
        
        if result.next then
          local next_path = result.next:match("https://api%.bitbucket%.org/2%.0(.*)")
          if next_path then
            fetch_page(next_path)
          else
            callback({ values = all_statuses }, nil)
          end
        else
          callback({ values = all_statuses }, nil)
        end
      else
        callback({ values = all_statuses }, nil)
      end
    end)
  end
  
  fetch_page()
end

---@param workspace string
---@param repo string
---@param pr_id number
---@param callback fun(tasks?: table, err?: string)
function M.get_pr_tasks(workspace, repo, pr_id, callback)
  local all_tasks = {}
  
  local function fetch_page(url)
    local endpoint = url or string.format("/repositories/%s/%s/pullrequests/%d/tasks", workspace, repo, pr_id)
    
    curl_request("GET", endpoint, function(result, err)
      if err then
        callback(nil, err)
        return
      end

      if result and result.values then
        for _, task in ipairs(result.values) do
          table.insert(all_tasks, task)
        end
        
        if result.next then
          local next_path = result.next:match("https://api%.bitbucket%.org/2%.0(.*)")
          if next_path then
            fetch_page(next_path)
          else
            callback({ values = all_tasks }, nil)
          end
        else
          callback({ values = all_tasks }, nil)
        end
      else
        callback({ values = all_tasks }, nil)
      end
    end)
  end
  
  fetch_page()
end

---Search repositories in a workspace (with server-side filtering)
---@param workspace string
---@param query string Search query (searches name, slug, description)
---@param callback fun(repos?: table, err?: string)
function M.search_repositories(workspace, query, callback)
  local all_repos = {}
  local log = require("atlas.common.log")
  
  -- Build search query - searches in name, slug, and description
  local search_query = string.format('name~"%s" OR slug~"%s" OR description~"%s"', query, query, query)
  local encoded_query = search_query:gsub(" ", "%%20"):gsub('"', "%%22")
  
  local function fetch_page(url)
    local endpoint = url or string.format("/repositories/%s?q=%s&pagelen=50", workspace, encoded_query)
    
    -- Log the search query for debugging
    log.bitbucket("Searching repos with query: " .. search_query)
    
    curl_request("GET", endpoint, function(result, err)
      if err then
        callback(nil, err)
        return
      end

      if result and result.values then
        for _, repo in ipairs(result.values) do
          table.insert(all_repos, repo)
        end
        
        if result.next then
          local next_path = result.next:match("https://api%.bitbucket%.org/2%.0(.*)")
          if next_path then
            fetch_page(next_path)
          else
            callback({ values = all_repos }, nil)
          end
        else
          callback({ values = all_repos }, nil)
        end
      else
        callback({ values = all_repos }, nil)
      end
    end)
  end
  
  fetch_page()
end

return M
