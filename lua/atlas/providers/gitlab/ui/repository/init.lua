local releases = require("atlas.ui.repository.pages.releases")

local M = {}

---@return RepositoryPage[]
function M.pages()
	return { releases }
end

return M
