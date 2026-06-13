local M = {}

local cli = require("atlas.pulls.providers.gitea.api.cli")
local mapper = require("atlas.pulls.providers.gitea.api.mapper")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	opts = opts or {}
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("gitea_pulls:commits:%s:%s", slug, tostring(pr.id))
	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("repos/%s/pulls/%s/commits", slug, tostring(pr.id))
	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local commits = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			table.insert(commits, mapper.to_commit(raw))
		end

		cli.set_mem(cache_key, commits)
		on_done(commits, nil)
	end, {
		action = "Fetch PR commits",
		slug = slug,
		number = pr.id,
	})
end

return M
