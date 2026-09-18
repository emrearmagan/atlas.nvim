local M = {}

local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local pipeline_api = require("atlas.pulls.pipelines")
local notify = require("atlas.core.notify")

---@param provider PullsProvider|nil
---@param ctx PullsPipelineActionContext
---@param on_select fun(action: PullsPipelineAction)
function M.open(provider, ctx, on_select)
	local available = {}
	local pipelines = provider and pipeline_api.get(provider)
	local pipeline_actions = pipelines and pipelines.actions or {}
	for _, action in ipairs(pipeline_actions) do
		if action.is_available(ctx) then
			table.insert(available, action)
		end
	end
	if #available == 0 then
		notify.warn("No pipeline actions available")
		return
	end

	picker.select({
		title = "Choose pipeline action",
		items = available,
		format_item = icons.format_action,
		on_select = function(action)
			if not action then
				return
			end
			if not action.confirm then
				on_select(action)
				return
			end
			vim.ui.input({ prompt = action.confirm .. " [y/N]: " }, function(input)
				local answer = vim.trim(tostring(input or "")):lower()
				if answer == "y" or answer == "yes" then
					on_select(action)
				end
			end)
		end,
	})
end

return M
