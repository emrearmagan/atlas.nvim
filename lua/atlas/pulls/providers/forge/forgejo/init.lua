---@class ForgejoPullRequest : PullRequest
---@field lines_added number|nil
---@field lines_removed number|nil
---@field mergeable boolean|nil
---@field merge_base string|nil

---@class ForgejoPullRequestDetails : PullRequestDetails
---@field assignees AtlasUser[]
---@field labels PullsLabel[]

local api = require("atlas.pulls.providers.forge.forgejo.api")
local comments_api = require("atlas.pulls.providers.forge.forgejo.api.comments")
local forge = require("atlas.pulls.providers.forge")
local pipelines = require("atlas.pulls.pipelines.forge.forgejo")
local reviews_api = require("atlas.pulls.providers.forge.forgejo.api.reviews")
local service = require("atlas.providers.forge.forgejo.api")

require("atlas.pulls.providers.forge.forgejo.config")

return forge.new(service, api, comments_api, reviews_api, pipelines)
