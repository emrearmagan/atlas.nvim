local service = require("atlas.providers.gitea.client")
local request_scope = require("atlas.core.requests")

local M = {}

---@param endpoint string
---@param params table<string, any>|nil
---@param opts { page_size?: integer, max_items?: integer }|nil
---@param on_done fun(values: table[]|nil, err: string|nil)
---@param ctx table|nil
---@return { cancel: fun() }
function M.fetch_all(endpoint, params, opts, on_done, ctx)
	opts = opts or {}
	local page_size = math.max(1, math.min(50, opts.page_size or 50))
	local max_items = opts.max_items
	local page = 1
	local values = {}
	local requests = request_scope.new()
	local finished = false

	---@param result table[]|nil
	---@param err string|nil
	local function finish(result, err)
		if finished then
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

		requests.run(function(done)
			return service.request("GET", endpoint .. service.query(query), nil, done, ctx)
		end, function(result, err)
			if finished then
				return
			end
			if err then
				finish(nil, err)
				return
			end
			local items = result == vim.NIL and {} or result
			for _, value in ipairs(items) do
				table.insert(values, value)
				if max_items and #values >= max_items then
					finish(values, nil)
					return
				end
			end

			if #items < page_size then
				finish(values, nil)
				return
			end

			page = page + 1
			fetch_page()
		end)
	end

	fetch_page()
	return requests
end

return M
