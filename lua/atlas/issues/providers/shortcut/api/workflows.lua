---@class ShortcutWorkflowState
---@field id integer
---@field workflow_id integer
---@field workflow_name string
---@field name string
---@field position integer

local M = {}

local service = require("atlas.providers.shortcut.client")

---@param on_done fun(states: ShortcutWorkflowState[]|nil, err: string|nil)
---@param opts? { force_refresh?: boolean }
---@return { cancel: fun() }|nil
function M.list_states(on_done, opts)
	if not (opts and opts.force_refresh) then
		local cached, found = service.get_memory_cache("workflow_states")
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", "/workflows", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		---@cast result table[]
		local states = {}
		for _, workflow in ipairs(result) do
			for _, state in ipairs(workflow.states) do
				table.insert(states, {
					id = state.id,
					workflow_id = workflow.id,
					workflow_name = tostring(workflow.name),
					name = tostring(state.name),
					position = state.position,
				})
			end
		end
		service.set_memory_cache("workflow_states", states)
		on_done(states, nil)
	end, { action = "Fetch Shortcut workflows" })
end

return M
