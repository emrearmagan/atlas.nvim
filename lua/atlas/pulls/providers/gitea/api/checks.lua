local M = {}

local cli = require("atlas.pulls.providers.gitea.api.cli")
local mapper = require("atlas.pulls.providers.gitea.api.mapper")

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_builds(pr, opts, on_done)
	opts = opts or {}
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	-- Use the head SHA for CI statuses
	local sha = tostring((type(pr._raw) == "table" and type(pr._raw.head) == "table" and pr._raw.head.sha) or
		(type(pr.source) == "table" and pr.source.commit_hash) or "")

	if sha == "" then
		vim.schedule(function()
			on_done({}, nil)
		end)
		return nil
	end

	local cache_key = string.format("gitea_pulls:builds:%s:%s", slug, sha)
	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("repos/%s/statuses/%s", slug, sha)
	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done({}, nil)
			return
		end

		if type(result) ~= "table" then
			cli.set_mem(cache_key, {})
			on_done({}, nil)
			return
		end

		local builds = {}
		-- Deduplicate by context (keep latest)
		local seen = {}
		for _, raw in ipairs(result) do
			if type(raw) == "table" then
				local ctx = tostring(raw.context or "")
				if not seen[ctx] then
					seen[ctx] = true
					table.insert(builds, mapper.to_build(raw))
				end
			end
		end

		cli.set_mem(cache_key, builds)
		on_done(builds, nil)
	end, {
		action = "Fetch CI statuses",
		slug = slug,
		sha = sha,
	})
end

return M
