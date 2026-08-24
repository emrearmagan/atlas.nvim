local M = {}

local service = require("atlas.pulls.providers.azure.api.service")
local mapper = require("atlas.pulls.providers.azure.api.mapper")
local users_api = require("atlas.pulls.providers.azure.api.users")
local request_scope = require("atlas.core.requests")

---@param view AtlasAzurePullsViewConfig
---@param opts { force_refresh?: boolean, pagelen: integer, state: string, skip?: integer, user_id?: string }
---@param on_done fun(page: PullsPage, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local skip = opts.skip or 0
	local params = {
		["searchCriteria.status"] = opts.state,
		["$top"] = opts.pagelen,
		["$skip"] = skip,
	}
	local scope = view.scope or "assigned_to_me"
	if scope == "assigned_to_me" then
		params["searchCriteria.reviewerId"] = opts.user_id
	elseif scope == "created_by_me" then
		params["searchCriteria.creatorId"] = opts.user_id
	end
	for key, value in pairs(view.extra_params or {}) do
		if key ~= "searchCriteria.status" and key ~= "$top" and key ~= "$skip" then
			params[key] = value
		end
	end

	local endpoint = "/" .. service.url_encode(view.project) .. "/_apis/git"
	if view.repository and view.repository ~= "" then
		endpoint = endpoint .. "/repositories/" .. service.url_encode(view.repository)
	end
	endpoint = endpoint .. "/pullrequests" .. service.build_query(params)

	local cache_key = "pullrequests:" .. endpoint
	if not opts.force_refresh then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done({ items = {} }, err)
			return
		end
		local page = {
			items = mapper.to_pull_requests(result.value),
			next_cursor = #result.value == opts.pagelen and { [opts.state] = tostring(skip + opts.pagelen) } or nil,
		}
		service.set_cache(cache_key, page)
		on_done(page, nil)
	end, { action = "List pull requests" })
end

---@param pages table<string, PullsPage>
---@return PullRequest[]
local function merge_results(pages)
	local pulls = {}
	for _, page in pairs(pages) do
		vim.list_extend(pulls, page.items)
	end
	table.sort(pulls, function(left, right)
		return left.updated_on > right.updated_on
	end)
	return pulls
end

---@param view AtlasAzurePullsViewConfig
---@param api_states string[]
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_states(view, api_states, opts, on_done)
	if not view.project or view.project == "" then
		on_done({ items = {} }, { "Azure pull request views require a project" })
		return nil
	end

	local states = {}
	for _, state in ipairs(api_states) do
		if opts.cursor == nil or opts.cursor[state] ~= nil then
			table.insert(states, state)
		end
	end

	local scope = request_scope.new()
	local function fetch_pages(user_id)
		local starts = {}
		for _, state in ipairs(states) do
			local planned_state = state
			starts[planned_state] = function(done)
				return M.fetch_pullrequests(view, {
					force_refresh = opts.force_refresh,
					pagelen = opts.pagelen or 50,
					state = planned_state,
					skip = opts.cursor and tonumber(opts.cursor[planned_state]) or nil,
					user_id = user_id,
				}, done)
			end
		end
		scope.all(starts, function(pages, errors)
			local collected_errors = {}
			local next_cursor = {}
			for _, state in ipairs(states) do
				if errors[state] then
					table.insert(collected_errors, errors[state])
				elseif pages[state].next_cursor then
					next_cursor[state] = pages[state].next_cursor[state]
				end
			end
			on_done({
				items = merge_results(pages),
				next_cursor = next(next_cursor) and next_cursor or nil,
			}, #collected_errors > 0 and collected_errors or nil)
		end)
	end

	if view.scope == "all" then
		fetch_pages(nil)
	else
		scope.run(users_api.fetch_user, function(user, err)
			if err then
				on_done({ items = {} }, { err })
				return
			end
			fetch_pages(user.id)
		end)
	end
	return scope
end

return M
