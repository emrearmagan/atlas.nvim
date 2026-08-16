local M = {}

local clients = require("atlas.providers.github.client")
local mapping = require("atlas.providers.github.mapping")

---@param domain "pulls"|"issues"
---@return table
function M.new(domain)
	local cli = clients[domain]
	local api = {}

	---@param slug string
	---@param query string|nil
	---@param on_done fun(users: { account_id: string, display_name: string }[]|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	function api.get_assignable_users(slug, query, on_done)
		if type(slug) ~= "string" or slug == "" then
			on_done(nil, "Missing repository slug")
			return nil
		end

		local q = vim.trim(tostring(query or "")):lower()
		return cli.gh(
			{ "api", "--paginate", string.format("repos/%s/assignees?per_page=100", slug) },
			function(result, err)
				if err or type(result) ~= "table" then
					on_done(nil, err)
					return
				end

				local users = {}
				for _, raw in ipairs(result) do
					local user = mapping.identity(raw)
					if user and user.login ~= "" then
						if q == "" or user.name:lower():find(q, 1, true) or user.login:lower():find(q, 1, true) then
							table.insert(users, { account_id = user.login, display_name = user.name })
						end
					end
				end
				on_done(users, nil)
			end,
			{ action = "Fetch assignable users", slug = slug }
		)
	end

	return api
end

return M
