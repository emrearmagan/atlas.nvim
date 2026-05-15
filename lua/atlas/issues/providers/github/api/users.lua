local M = {}

local cli = require("atlas.issues.providers.github.api.cli")
local normalizer = require("atlas.issues.providers.github.api.mapper")

---@param on_done fun(user: IssueUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_user(on_done)
	local cache_key = "github_issues:myself"
	local cached, ok = cli.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end

	return cli.gh({ "api", "user" }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local user = normalizer.to_user(result)
		if user then
			cli.set_cache(cache_key, user)
		end
		on_done(user, nil)
	end, {
		action = "Issues fetch user",
	})
end

---@param slug string
---@param query string|nil
---@param on_done fun(users: IssueUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_assignable_users(slug, query, on_done)
	if type(slug) ~= "string" or slug == "" then
		on_done(nil, "Missing repository slug")
		return nil
	end

	local q = vim.trim(tostring(query or ""))
	return cli.gh(
		{ "api", "--paginate", string.format("repos/%s/assignees?per_page=100", slug) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err)
				return
			end
			local users = {}
			for _, raw in ipairs(result) do
				local user = normalizer.to_user(raw)
				if user then
					if q == "" or user.display_name:lower():find(q:lower(), 1, true) or user.account_id:lower():find(q:lower(), 1, true) then
						table.insert(users, user)
					end
				end
			end
			on_done(users, nil)
		end
	)
end

return M
