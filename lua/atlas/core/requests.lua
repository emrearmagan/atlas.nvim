local M = {}

---@class AtlasRequestScope
---@field run fun(start: fun(done: fun(...: any)): { cancel: fun() }|nil, on_done: fun(...: any)): { cancel: fun() }|nil
---@field all fun(starts: table<string, fun(done: fun(value: any, err: string|nil)): { cancel: fun() }|nil>, on_done: fun(values: table<string, any>, errors: table<string, string>))
---@field cancel fun()

---@return AtlasRequestScope
function M.new()
	local handles = {}
	local cancelled = false
	local scope = {}

	function scope.run(start, on_done)
		if cancelled then
			return nil
		end
		local finished = false
		local handle
		handle = start(function(...)
			if cancelled or finished then
				return
			end
			finished = true
			if handle then
				handles[handle] = nil
			end
			on_done(...)
		end)
		if handle and not finished then
			if cancelled then
				pcall(handle.cancel)
			else
				handles[handle] = true
			end
		end
		return handle
	end

	function scope.all(starts, on_done)
		if cancelled then
			return
		end
		local remaining = 0
		local values = {}
		local errors = {}
		for _ in pairs(starts) do
			remaining = remaining + 1
		end
		if remaining == 0 then
			on_done(values, errors)
			return
		end
		for key, start in pairs(starts) do
			scope.run(start, function(value, err)
				values[key] = value
				errors[key] = err
				remaining = remaining - 1
				if remaining == 0 then
					on_done(values, errors)
				end
			end)
		end
	end

	function scope.cancel()
		if cancelled then
			return
		end
		cancelled = true
		for handle in pairs(handles) do
			pcall(handle.cancel)
		end
		handles = {}
	end

	return scope
end

return M
