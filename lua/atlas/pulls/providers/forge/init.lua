local config = require("atlas.config")
local git = require("atlas.core.git")
local query = require("atlas.pulls.providers.forge.query")
local request_scope = require("atlas.core.requests")

local M = {}

---@param provider_id ForgeProviderId
---@return AtlasPullsViewConfig[]
function M.views(provider_id)
	local configured = (config.domain_options(provider_id, "pulls") or {}).views
	if not configured or #configured == 0 then
		configured = { { name = "Pull Requests", key = "1", layout = "compact" } }
	end
	return vim.tbl_map(function(view)
		return vim.tbl_extend("force", {}, view)
	end, configured)
end

---@param target AtlasTarget
---@return AtlasPullsViewConfig
function M.view_for_target(target)
	return { name = "Search", layout = "compact", repo = target.repo_full_name }
end

local function resolve_view(provider_id, view, on_done)
	if not view.current_repo then
		on_done(view)
		return nil
	end
	return git.local_repository(vim.fn.getcwd(), function(target)
		local resolved = vim.tbl_extend("force", {}, view)
		if target and target.provider == provider_id then
			resolved.repo = target.repo_full_name
		end
		on_done(resolved)
	end)
end

---@param provider_id ForgeProviderId
---@param pullrequests ForgePullRequestsApi
---@param view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return AtlasRequestScope
function M.fetch_pullrequests(provider_id, pullrequests, view, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_view(provider_id, view, done)
	end, function(resolved)
		local api_view, statuses = query.for_api(resolved)
		local fetch = vim.trim(api_view.repo or "") == "" and pullrequests.search_global or pullrequests.list
		requests.run(function(done)
			return fetch(api_view, statuses, opts, done)
		end, function(page, err)
			page = page or { items = {} }
			page.query = query.resolve(resolved)
			on_done(page, err and { err } or nil)
		end)
	end)
	return requests
end

---@param fetch_comments fun(pr: PullRequest, opts: { force_refresh: boolean|nil }|nil, on_done: fun(result: { comments: PullsComment[], events: PullsActivityEntry[] }|nil, err: string|nil)): { cancel: fun() }|nil
---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(fetch_comments, pr, opts, on_done)
	return fetch_comments(pr, opts, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local ordered = {}
		local sequence = 0
		local function add(kind, created_at, entity, id)
			sequence = sequence + 1
			table.insert(ordered, {
				sequence = sequence,
				item = {
					id = id,
					kind = kind,
					created_at = created_at,
					entity = entity,
				},
			})
		end

		for _, comment in ipairs(result.comments) do
			add("comment", comment.created_at, comment, "comment:" .. tostring(comment.id))
		end
		for index, event in ipairs(result.events) do
			local created_at = event.date
			local id = table.concat({ "activity", created_at, event.kind, tostring(index) }, ":")
			add("activity", created_at, event, id)
		end

		table.sort(ordered, function(left, right)
			if left.item.created_at == right.item.created_at then
				return left.sequence < right.sequence
			end
			return left.item.created_at < right.item.created_at
		end)

		local items = {}
		for _, value in ipairs(ordered) do
			table.insert(items, value.item)
		end
		on_done(items, nil)
	end)
end

return M
