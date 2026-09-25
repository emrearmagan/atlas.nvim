local deployments = require("atlas.providers.bitbucket.ui.repository.deployments")

local M = {}

---@param pages table<string, RepositoryPage>
---@return RepositoryPage[]
function M.pages(pages)
	return { pages.overview, pages.pulls, pages.builds, pages.branches, pages.tags, deployments }
end

return M
