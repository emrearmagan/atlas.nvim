local overview = require("atlas.ui.repository.pages.overview")
local issues = require("atlas.ui.repository.pages.issues")
local builds = require("atlas.ui.repository.pages.builds")
local branches = require("atlas.ui.repository.pages.branches")
local tags = require("atlas.ui.repository.pages.tags")
local commits = require("atlas.ui.repository.pages.commits")

---@class RepositoryPage
---@field key string
---@field label string
---@field icon string

local M = {}

---@param provider PullsProvider|IssuesProvider
---@return RepositoryPage[]
function M.get(provider)
	local pages = { overview, issues, builds, branches, tags, commits }
	local ui = provider.capabilities.ui and provider.capabilities.ui.repository
	if ui then
		vim.list_extend(pages, ui.pages())
	end
	return pages
end

return M
