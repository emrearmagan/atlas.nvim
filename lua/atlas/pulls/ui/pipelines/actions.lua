local M = {}

local notify = require("atlas.core.notify")

---@class PullsPipelineActionContext
---@field pr PullRequest
---@field pipeline PullsPipeline
---@field job PullsPipelineJob|nil

---@class PullsPipelineAction
---@field id string
---@field label string
---@field confirm string|nil
---@field is_available fun(ctx: PullsPipelineActionContext): boolean, string|nil
---@field run fun(ctx: PullsPipelineActionContext, done: fun(err: string|nil))

local PROVIDER_ACTIONS = {
	bitbucket = require("atlas.pulls.providers.bitbucket.actions.pipelines"),
	github = require("atlas.pulls.providers.github.actions.pipelines"),
	gitlab = require("atlas.pulls.providers.gitlab.actions.pipelines"),
}

---@param provider PullsProvider|nil
---@param ctx PullsPipelineActionContext
---@param on_select fun(action: PullsPipelineAction)
function M.open(provider, ctx, on_select)
	local available = {}
	for _, action in ipairs(PROVIDER_ACTIONS[(provider or {}).id] or {}) do
		if action.is_available(ctx) then
			table.insert(available, action)
		end
	end
	if #available == 0 then
		notify.warn("No pipeline actions available")
		return
	end

	vim.ui.select(available, {
		prompt = "Choose pipeline action",
		kind = "atlas_pipeline_actions",
		format_item = function(action)
			return action.label
		end,
	}, function(action)
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
	end)
end

return M
