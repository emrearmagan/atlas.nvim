local deployments = require("atlas.providers.bitbucket.ui.repository.deployments")

local M = {}

---@return RepositoryPage[]
function M.pages()
	return { deployments }
end

return M
