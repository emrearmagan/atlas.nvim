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

---@param repository AtlasTarget
---@param branch string|nil
---@return AtlasPullsViewConfig
function M.repository_view(repository, branch)
	return { name = "Search", layout = "compact", repo = repository.repo_full_name, head = branch }
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
			if resolved.head then
				page.items = vim.tbl_filter(function(pr)
					return pr.source.branch == resolved.head
				end, page.items)
			end
			page.query = query.resolve(resolved)
			on_done(page, err and { err } or nil)
		end)
	end)
	return requests
end

return M
