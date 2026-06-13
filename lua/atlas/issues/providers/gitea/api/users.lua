local M = {}

local cli = require("atlas.issues.providers.gitea.api.cli")
local mapper = require("atlas.issues.providers.gitea.api.mapper")

---@param on_done fun(user: IssueUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_user(on_done)
	local cache_key = "gitea_issues:myself"
	local cached, ok = cli.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return cli.get("/user", function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local user = mapper.to_user(result)
		if user then
			cli.set_cache(cache_key, user)
		end
		on_done(user, nil)
	end, {
		action = "Gitea issues fetch user",
	})
end

---@param slug string
---@param query string|nil
---@param on_done fun(users: IssueUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_assignable_users(slug, query, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local q = vim.trim(tostring(query or ""))
	local endpoint = string.format("/repos/%s/assignees?limit=50", slug)

	return cli.get(endpoint, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		local users = {}
		for _, raw in ipairs(result) do
			local user = mapper.to_user(raw)
			if user then
				if
					q == ""
					or user.display_name:lower():find(q:lower(), 1, true)
					or user.account_id:lower():find(q:lower(), 1, true)
				then
					table.insert(users, user)
				end
			end
		end
		on_done(users, nil)
	end, {
		action = "Gitea fetch assignable users",
		slug = slug,
	})
end

return M
