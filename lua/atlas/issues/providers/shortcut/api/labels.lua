local M = {}

local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local service = require("atlas.issues.providers.shortcut.api.service")

---@param on_done fun(labels: ShortcutIssueLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(on_done)
	local cached, found = service.get_memory_cache("labels")
	if found then
		on_done(cached, nil)
		return nil
	end

	return service.request("GET", "/labels?slim=true", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@cast result table[]
		local labels = {}
		for _, raw in ipairs(result) do
			table.insert(labels, mapper.to_label(raw))
		end
		service.set_memory_cache("labels", labels)
		on_done(labels, nil)
	end, { action = "Fetch Shortcut labels" })
end

return M
