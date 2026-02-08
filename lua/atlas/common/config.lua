---@class Bitbucket.Common.Config
local M = {}

local FALLBACKS = {
  story_point_field = "customfield_10035",
  custom_fields = {},
}

---@class BitbucketAuthOptions
---@field user string Bitbucket username
---@field token string Bitbucket app password or token
---@field workspace string Bitbucket workspace slug
---@field account_id string Your Bitbucket account ID

---@class BitbucketRepoConfig
---@field workspace string Workspace slug
---@field repo string Repository slug

---@class BitbucketViewConfig
---@field name string Display name for the view
---@field key string Keyboard shortcut key
---@field filter fun(pr: table, account_id: string): boolean Filter function

---@alias EnrichmentLevel "all" | "user" | "none"

---@class JiraAuthOptions
---@field base string URL of your Jira instance (e.g. https://your-domain.atlassian.net)
---@field email? string Your Jira email (required for basic auth)
---@field token string Your Jira API token or PAT
---@field type? "basic"|"pat" Authentication type (default: "basic")
---@field api_version? "2"|"3" API version to use (default: "3")
---@field limit? number Global limit of tasks when calling API

---@class JiraViewConfig
---@field name string Display name for the view
---@field key string Keyboard shortcut key
---@field jql? string JQL query (supports %s for project_key placeholder)

---@class UnifiedConfig
---@field bitbucket BitbucketAuthOptions
---@field repos BitbucketRepoConfig[] List of repositories to monitor
---@field cache_ttl? number Cache time-to-live in seconds (default: 300 = 5 minutes)
---@field bitbucket_views? BitbucketViewConfig[] Custom Bitbucket views (first one opens by default)
---@field display_build_status? EnrichmentLevel Fetch build status: "all", "user", "none" (default: "user")
---@field display_approvals? EnrichmentLevel Fetch approvals/needs work: "all", "user", "none" (default: "user")
---@field jira JiraAuthOptions
---@field projects? table<string, table> Project-specific overrides
---@field active_sprint_query? string JQL for active sprint tab
---@field queries? table<string, string> Saved JQL queries
---@field jira_views? JiraViewConfig[] Custom Jira views (first one opens by default, JQL always present)
M.defaults = {
  bitbucket = {
    user = "",
    token = "",
    workspace = "",
    account_id = "",
  },
  repos = {},
  cache_ttl = 0, -- Disabled by default, set to 300 for 5 min cache
  display_build_status = "user", -- Fetch build status for: "all", "user", or "none"
  display_approvals = "user", -- Fetch approvals/needs work for: "all", "user", or "none"
  bitbucket_views = {
    {
      name = "My PRs",
      key = "m",
      filter = function(pr, account_id)
        return pr.author and pr.author.account_id == account_id
      end,
    },
    {
      name = "Team PRs",
      key = "t",
      filter = function(pr, account_id)
        return not (pr.author and pr.author.account_id == account_id)
      end,
    },
  },
  jira = {
    base = "",
    email = "",
    token = "",
    type = "basic",
    api_version = "3",
    limit = 200,
  },
  jira_group_by_status = true, -- Group issues by status category (To Do, In Progress, Done)
  projects = {},
  active_sprint_query = "project = '%s' AND sprint in openSprints() ORDER BY Rank ASC",
  queries = {
    ["Next sprint"] = "project = '%s' AND sprint in futureSprints() ORDER BY Rank ASC",
    ["Backlog"] = "project = '%s' AND (issuetype IN standardIssueTypes() OR issuetype = Sub-task) AND (sprint IS EMPTY OR sprint NOT IN openSprints()) AND statusCategory != Done ORDER BY Rank ASC",
    ["My Tasks"] = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC",
  },
  jira_views = {
    {
      name = "Active Sprint",
      key = "S",
    },
  },
}

---@type UnifiedConfig
M.options = vim.deepcopy(M.defaults)

---@param opts UnifiedConfig
function M.setup(opts)
  opts = opts or {}
  
  if opts.bitbucket then
    if opts.bitbucket.repos then
      opts.repos = opts.bitbucket.repos
    end
    if opts.bitbucket.display_build_status then
      opts.display_build_status = opts.bitbucket.display_build_status
    end
    if opts.bitbucket.display_approvals then
      opts.display_approvals = opts.bitbucket.display_approvals
    end
    if opts.bitbucket.views then
      opts.bitbucket_views = opts.bitbucket.views
    end
  end
  
  if opts.jira then
    if opts.jira.projects then
      opts.projects = opts.jira.projects
    end
    if opts.jira.queries then
      opts.queries = opts.jira.queries
    end
    if opts.jira.views then
      opts.jira_views = opts.jira.views
    end
  end
  
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

---@param project_key string|nil
---@return table
function M.get_project_config(project_key)
  local projects = M.options.projects or {}
  local p_config = projects[project_key] or {}

  return {
    story_point_field = p_config.story_point_field or FALLBACKS.story_point_field,
    custom_fields = p_config.custom_fields or FALLBACKS.custom_fields,
  }
end

return M
