local releases = require("atlas.ui.repository.pages.releases")

local M = {}

---@param pages table<string, RepositoryPage>
---@return RepositoryPage[]
function M.pages(pages)
	return { pages.overview, pages.issues, pages.pulls, pages.builds, pages.branches, pages.tags, releases }
end

return M
