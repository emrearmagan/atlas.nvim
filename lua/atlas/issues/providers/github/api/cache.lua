local M = {}

local cli = require("atlas.providers.github.client")
local normalizer = require("atlas.issues.providers.github.api.mapper")

---@param key string
function M.invalidate(key)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		return
	end

	for _, with_relationships in ipairs({ false, true }) do
		cli.delete_mem(
			string.format("github_issues:details:%s#%d:relationships:%s", slug, number, tostring(with_relationships))
		)
	end

	cli.delete_mem(string.format("github_issues:conversation:%s#%d", slug, number))
end

return M
