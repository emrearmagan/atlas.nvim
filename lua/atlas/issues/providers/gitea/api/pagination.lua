local service = require("atlas.providers.gitea.client").issues
local json = require("atlas.core.json")
local request_scope = require("atlas.core.requests")

local M = {}

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
	local requests = request_scope.new()
	local finished = false

	local function finish(result, err)
		if finished then
			return
		end
		finished = true
		on_done(result, err)
	end

	local fetch_page
	function fetch_page()
		local query = vim.tbl_extend("force", {}, params or {}, { page = page, limit = 50 })
		requests.run(function(done)
			return service.request("GET", endpoint .. service.query(query), nil, done)
		end, function(result, err)
			if finished then
				return
			end
			if err then
				finish(nil, err)
				return
			end
			-- Both APIs return JSON null after the final timeline page.
			local items = result == vim.NIL and {} or result
			if not json.is_list(items) then
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
			elseif #items < 50 then
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
