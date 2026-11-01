---@class GiteaPullRequest : PullRequest
---@field lines_added number|nil
---@field lines_removed number|nil
---@field mergeable boolean|nil
---@field merge_base string|nil

---@class GiteaPullRequestDetails : PullRequestDetails
---@field assignees AtlasUser[]
---@field labels PullsLabel[]

local api = require("atlas.pulls.providers.forge.gitea.api")
local comments_api = require("atlas.pulls.providers.forge.gitea.api.comments")
local forge = require("atlas.pulls.providers.forge")
local pipelines = require("atlas.pulls.pipelines.forge.gitea")
local reviews_api = require("atlas.pulls.providers.forge.gitea.api.reviews")
local service = require("atlas.providers.forge.gitea.api")

require("atlas.pulls.providers.forge.gitea.config")

return forge.new(service, api, comments_api, reviews_api, pipelines)
