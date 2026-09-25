local overview = require("atlas.ui.repository.pages.overview")
local issues = require("atlas.ui.repository.pages.issues")
local pulls = require("atlas.ui.repository.pages.pulls")
local builds = require("atlas.ui.repository.pages.builds")
local branches = require("atlas.ui.repository.pages.branches")
local tags = require("atlas.ui.repository.pages.tags")

---@class RepositoryPage
---@field key string
---@field label string
---@field icon string
---@field open fun(opts: { buf: integer, win: integer, sidebar_buf: integer, repo: AtlasRepositoryDetails, provider: PullsProvider|IssuesProvider, statusline: AtlasStatusline })
---@field close fun(buf: integer)

local M = {}

---@param provider PullsProvider|IssuesProvider
---@return RepositoryPage[]
function M.get(provider)
	local ui = provider.capabilities.ui and provider.capabilities.ui.repository
	if ui then
		return ui.pages({
			overview = overview,
			issues = issues,
			pulls = pulls,
			builds = builds,
			branches = branches,
			tags = tags,
		})
	end
	return { overview, issues, pulls, builds, branches, tags }
end

return M
