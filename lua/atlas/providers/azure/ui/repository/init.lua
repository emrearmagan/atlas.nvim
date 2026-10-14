local M = {}

---@param pages table<string, RepositoryPage>
---@return RepositoryPage[]
function M.pages(pages)
	return { pages.overview, pages.branches, pages.tags }
end

return M
