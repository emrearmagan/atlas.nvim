local M = {}

local cli = require("atlas.pulls.providers.gitea.api.cli")
local mapper = require("atlas.pulls.providers.gitea.api.mapper")
local logger = require("atlas.core.logger")
local git = require("atlas.core.git")

-- Resolve slug ("owner/repo") from view or from git repo root
---@param view AtlasGiteaPullsViewConfig
---@return string|nil
function M.resolve_slug(view)
	if view and view.repo and tostring(view.repo) ~= "" then
		return tostring(view.repo)
	end

	local root = git.repo_root()
	if root then
		local config = require("atlas.config")
		local paths = (((config.options.pulls or {}).repo_config or {}).paths) or {}
		if paths[root] then
			return paths[root]
		end
		local url = git.remote_url(root)
		if url then
			local info = git.parse_remote_url(url)
			if info then
				return info.slug
			end
		end
	end

	return nil
end

---@param view AtlasGiteaPullsViewConfig
---@param opts { force_load?: boolean, pagelen?: number }|nil
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.list_prs(view, opts, on_done)
	opts = opts or {}
	local slug = M.resolve_slug(view)
	if not slug or slug == "" then
		vim.schedule(function()
			on_done({}, { "No repository configured. Set view.repo or pulls.repo_config.paths" })
		end)
		return nil
	end

	local filter = type(view.filter) == "table" and view.filter or {}
	local state = tostring(filter.state or "open")

	-- Gitea uses "open" or "closed" as the state parameter
	local api_state = state
	if state == "merged" or state == "declined" then
		api_state = "closed"
	end

	local limit = math.max(1, math.min(50, tonumber(opts.pagelen) or 50))
	local endpoint = string.format(
		"repos/%s/pulls?state=%s&limit=%d&page=1",
		slug,
		api_state,
		limit
	)

	local cache_key = string.format("gitea_pulls:list:%s:%s:limit:%d", slug, api_state, limit)
	if not opts.force_load then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done({}, { err })
			return
		end

		if type(result) ~= "table" then
			on_done({}, nil)
			return
		end

		-- Filter merged/declined if the view requested a specific closed state
		local filtered = result
		if state == "merged" then
			filtered = vim.tbl_filter(function(raw)
				return type(raw) == "table" and raw.merged == true
			end, result)
		elseif state == "declined" then
			filtered = vim.tbl_filter(function(raw)
				return type(raw) == "table" and raw.merged ~= true
			end, result)
		end

		local groups = mapper.to_pull_request_groups(filtered, slug)
		cli.set_cache(cache_key, groups)
		logger.loginfo("Gitea pulls list complete", { slug = slug, count = #filtered, groups = #groups })
		on_done(groups, nil)
	end, {
		action = "List PRs",
		slug = slug,
		state = api_state,
	})
end

---@param pr PullRequest
---@param opts { force_load?: boolean }|nil
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_pr(pr, opts, on_done)
	opts = opts or {}
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("gitea_pulls:pr:%s:%s", slug, tostring(pr.id))
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("repos/%s/pulls/%s", slug, tostring(pr.id))
	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		if type(result) ~= "table" then
			on_done(nil, "PR not found")
			return
		end
		local fresh = mapper.to_pull_request(result, slug)
		if fresh then
			cli.set_mem(cache_key, fresh)
		end
		on_done(fresh, nil)
	end, {
		action = "Fetch PR",
		slug = slug,
		number = pr.id,
	})
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_diffstat(pr, opts, on_done)
	opts = opts or {}
	local slug = pr.repo_full_name or ""
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository info")
		end)
		return nil
	end

	local cache_key = string.format("gitea_pulls:diffstat:%s:%s", slug, tostring(pr.id))
	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("repos/%s/pulls/%s/files", slug, tostring(pr.id))
	return cli.tea({ endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local entries = {}
		for _, raw in ipairs(type(result) == "table" and result or {}) do
			table.insert(entries, mapper.to_diffstat_entry(raw))
		end

		cli.set_mem(cache_key, entries)
		on_done(entries, nil)
	end, {
		action = "Fetch PR diffstat",
		slug = slug,
		number = pr.id,
	})
end

---@param opts PullsCreatePROpts
---@param on_done fun(result: PullsCreatePRResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_pr(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local payload = {
		title = tostring(opts.title or ""),
		body = tostring(opts.body or ""),
		head = tostring(opts.head or ""),
		base = tostring(opts.base or ""),
	}
	if opts.draft then
		payload.draft = true
	end

	local reviewers = {}
	for _, r in ipairs(opts.reviewers or {}) do
		local id = tostring(r.provider_id or "")
		if id ~= "" then
			table.insert(reviewers, id)
		end
	end
	if #reviewers > 0 then
		payload.reviewers = reviewers
	end

	local endpoint = string.format("/repos/%s/pulls", slug)
	local body = vim.json.encode(payload)
	return cli.api("POST", endpoint, body, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local url = nil
		local id = nil
		if type(result) == "table" then
			url = type(result.html_url) == "string" and result.html_url or nil
			id = tonumber(result.number)
		end
		on_done({ id = id, url = url }, nil)
	end, { action = "Create PR", slug = slug })
end

return M
