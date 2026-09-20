local releases = require("atlas.providers.github.ui.repository.releases")

local M = {}

---@return RepositoryPage[]
function M.pages()
	return { releases }
end

return M
