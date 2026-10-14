---@class GiteaIssueLabel : IssueLabel
---@field id integer

---@class GiteaIssueMilestone : IssueMilestone
---@field id integer
---@field progress_percentage number|nil
---@field open_issues integer|nil
---@field closed_issues integer|nil

---@class GiteaIssue : Issue
---@field number integer
---@field repo_full_name string
---@field is_pinned boolean
---@field is_locked boolean
---@field content_version integer|nil
---@field due_date string|nil

---@class GiteaIssueDetails : IssueDetails
---@field content_version integer|nil
---@field due_date string|nil
---@field labels GiteaIssueLabel[]
---@field milestone GiteaIssueMilestone|nil

require("atlas.issues.providers.forge.gitea.config")

return require("atlas.issues.providers.forge").new("gitea")
