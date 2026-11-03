---@class ForgejoIssueLabel : IssueLabel
---@field id integer

---@class ForgejoIssueMilestone : IssueMilestone
---@field id integer
---@field progress_percentage number|nil
---@field open_issues integer|nil
---@field closed_issues integer|nil

---@class ForgejoIssue : Issue
---@field repo_full_name string
---@field number integer
---@field is_pinned boolean
---@field is_locked boolean
---@field due_date string|nil

---@class ForgejoIssueDetails : IssueDetails
---@field due_date string|nil
---@field labels ForgejoIssueLabel[]
---@field milestone ForgejoIssueMilestone|nil

local forge = require("atlas.issues.providers.forge")
local issues_api = require("atlas.issues.providers.forge.api.issues")
local service = require("atlas.providers.forge.forgejo.api")

require("atlas.issues.providers.forge.forgejo.config")

local issues = issues_api.new(service)
issues.set_locked = nil

return forge.new(service, issues)
