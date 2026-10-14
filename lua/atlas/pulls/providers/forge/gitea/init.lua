---@class GiteaPullRequest : PullRequest
---@field lines_added number|nil
---@field lines_removed number|nil
---@field mergeable boolean|nil
---@field merge_base string|nil

---@class GiteaPullRequestDetails : PullRequestDetails
---@field assignees AtlasUser[]
---@field labels PullsLabel[]

require("atlas.pulls.providers.forge.gitea.config")

return require("atlas.pulls.providers.forge").new("gitea")
