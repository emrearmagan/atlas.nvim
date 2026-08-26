local M = {}

local actions = require("atlas.pulls.actions")

---@type AtlasPullAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasPullAction
local function register(action)
	table.insert(ACTIONS, action)
end

-- register(actions.approve)
-- register(actions.request_changes)
register(actions.decline)
register(actions.edit_title)
register(actions.edit_description)
register(actions.ready_for_review)
register(actions.convert_to_draft)
-- register(actions.edit_reviewers)

-- register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasPullActionId
---@return AtlasPullAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
