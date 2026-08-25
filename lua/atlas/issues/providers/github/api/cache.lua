local M = {}

local cli = require("atlas.providers.github.client")
local normalizer = require("atlas.issues.providers.github.api.mapper")

---@param key string
local function invalidate_issue(key)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		return
	end

	for _, with_relationships in ipairs({ false, true }) do
		cli.delete_mem(
			string.format("github_issues:details:%s#%d:relationships:%s", slug, number, tostring(with_relationships))
		)
	end
end

---@param key string
local function invalidate_conversation(key)
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		return
	end

	cli.delete_mem(string.format("github_issues:conversation:%s#%d", slug, number))
end

---@param key string
function M.invalidate(key)
	invalidate_issue(key)
	invalidate_conversation(key)
end

return M
