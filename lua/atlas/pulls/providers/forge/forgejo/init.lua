---@class ForgejoPullRequest : PullRequest
---@field lines_added number|nil
---@field lines_removed number|nil
---@field mergeable boolean|nil
---@field merge_base string|nil

---@class ForgejoPullRequestDetails : PullRequestDetails
---@field assignees AtlasUser[]
---@field labels PullsLabel[]

require("atlas.pulls.providers.forge.forgejo.config")

return require("atlas.pulls.providers.forge").new("forgejo")
