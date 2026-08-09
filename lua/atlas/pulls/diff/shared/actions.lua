local M = {}

local actions = require("atlas.pulls.actions")

---@alias AtlasDiffActionId
---| "submit_review"
---| "approve"
---| "request_changes"

---@type { id: AtlasDiffActionId, label: string, run: fun(context: AtlasReviewActionContext, on_done: fun(result: PullsActionResult|nil, err: string|nil)): boolean }[]
local ACTIONS = {
	actions.submit_review,
	actions.approve,
	actions.request_changes,
}

---@param context AtlasReviewActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
function M.open(context, on_done)
	local items = {}
	local reviews = context.provider.capabilities.reviews or {}
	for _, action in ipairs(ACTIONS) do
		if reviews[action.id] then
			table.insert(items, action)
		end
	end

	vim.ui.select(items, {
		prompt = "Review action",
		kind = "atlas_diff_actions",
		format_item = function(action)
			return action.label
		end,
	}, function(action)
		if action then
			action.run(context, on_done)
		end
	end)
end

return M
