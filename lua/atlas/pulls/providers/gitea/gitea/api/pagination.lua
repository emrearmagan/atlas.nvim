local service = require("atlas.providers.gitea.gitea.client").pulls
local json = require("atlas.core.json")

local M = {}

---@param value any
---@return boolean
local function is_list(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if key ~= "__http_status" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
			return false
		end
	end
	return true
end

---@class AtlasGiteaPaginationOpts
---@field page_size? integer
---@field max_items? integer
---@field accept? fun(value: any): boolean
---@field invalid_response? string
---@field post_filtered? boolean

---Fetch a paginated Gitea list. The API stops returning values after
---the last page, so this does not need provider-specific response headers.
---@param endpoint string
---@param params table<string, any>|nil
---@param opts AtlasGiteaPaginationOpts|nil
---@param on_done fun(values: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_all(endpoint, params, opts, on_done)
	opts = opts or {}
	local page_size = math.max(1, math.min(50, tonumber(opts.page_size) or 50))
	local max_items = tonumber(opts.max_items)
	local page = 1
	local values = {}
	local empty_pages = 0
	local active, cancelled, finished

	---@param result table[]|nil
	---@param err string|nil
	local function finish(result, err)
		if cancelled or finished then
			return
		end
		finished = true
		on_done(result, err)
	end

	local fetch_page
	function fetch_page()
		local query = {}
		for key, value in pairs(params or {}) do
			query[key] = value
		end
		query.page = page
		query.limit = page_size

		local requested_page = page
		local handle = service.request("GET", endpoint .. service.query(query), nil, function(result, err)
			if cancelled or finished then
				return
			end
			if err then
				finish(nil, err)
				return
			end
			result = json.nilify(result) or {}
			if not is_list(result) then
				finish(nil, opts.invalid_response or "Invalid paginated response")
				return
			end

			for _, value in ipairs(result) do
				if opts.accept == nil or opts.accept(value) then
					table.insert(values, value)
					if max_items and #values >= max_items then
						finish(values, nil)
						return
					end
				end
			end

			if opts.post_filtered then
				empty_pages = #result == 0 and empty_pages + 1 or 0
				-- Timeline and review rows are paginated before the server removes
				-- hidden entries. Scan past one empty page because later pages may
				-- still contain visible rows.
				if empty_pages >= 2 then
					finish(values, nil)
					return
				end
			elseif #result == 0 then
				finish(values, nil)
				return
			end

			page = page + 1
			fetch_page()
		end)

		-- A mocked request may complete synchronously. Do not overwrite the
		-- handle for a later page in that case.
		if not finished and not cancelled and page == requested_page then
			active = handle
		end
	end

	fetch_page()
	return {
		cancel = function()
			cancelled = true
			if active and active.cancel then
				active.cancel()
			end
		end,
	}
end

return M
