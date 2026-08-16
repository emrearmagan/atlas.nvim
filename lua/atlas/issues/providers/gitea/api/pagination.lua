local service = require("atlas.providers.gitea.client").issues

local M = {}

---@param value any
---@return table[]|nil
local function list_values(value)
	if value == nil or value == vim.NIL then
		return {}
	end
	if type(value) ~= "table" then
		return nil
	end
	for key in pairs(value) do
		if key ~= "__http_status" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
			return nil
		end
	end
	return value
end

---@param endpoint string
---@param params table<string, any>|nil
---@param opts { invalid_response: string, post_filtered: boolean|nil }
---@param on_done fun(values: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_all(endpoint, params, opts, on_done)
	opts = opts or {}
	local page = 1
	local values = {}
	local empty_pages = 0
	local active, cancelled, finished

	local function finish(result, err)
		if cancelled or finished then
			return
		end
		finished = true
		on_done(result, err)
	end

	local fetch_page
	function fetch_page()
		local query = vim.tbl_extend("force", {}, params or {}, { page = page, limit = 50 })
		local requested_page = page
		local handle = service.request("GET", endpoint .. service.query(query), nil, function(result, err)
			if cancelled or finished then
				return
			end
			if err then
				finish(nil, err)
				return
			end
			local items = list_values(result)
			if items == nil then
				finish(nil, opts.invalid_response)
				return
			end

			vim.list_extend(values, items)
			if opts.post_filtered then
				empty_pages = #items == 0 and empty_pages + 1 or 0
				if empty_pages >= 2 then
					finish(values, nil)
					return
				end
			elseif #items == 0 then
				finish(values, nil)
				return
			end

			page = page + 1
			fetch_page()
		end)

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
