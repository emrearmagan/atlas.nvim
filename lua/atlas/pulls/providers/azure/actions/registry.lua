---@alias AtlasAzureActionId
---| AtlasPullActionId
---| "reopen"
---| "labels"
---| "open_repo"

local M = {}

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local icons = require("atlas.ui.shared.icons")
local pullrequests_api = require("atlas.pulls.providers.azure.api.pullrequests")
local search = require("atlas.pulls.providers.azure.actions.search")

---@type AtlasPullAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasPullAction
local function register(action)
	table.insert(ACTIONS, action)
end

register(actions.approve)
register(actions.request_changes)
register({
	id = "merge",
	label = "Merge PR",
	icon = icons.get("merge", "actions"),
	is_available = function(ctx)
		return ctx.pr ~= nil and ctx.pr.state == "open"
	end,
	run = function(ctx, done)
		local pr = assert(ctx.pr)
		require("atlas.pulls.ui.merge").open(pr, {
			on_cancel = function()
				done({ changed_pr = false, message = "Merge cancelled" }, nil)
			end,
			on_submit = function(options, completed)
				action_utils.notify(ctx, "loading", "Completing PR...")
				pullrequests_api.merge(pr, options, function(ok, err)
					if not ok then
						action_utils.notify(ctx, "error", err or "Completion failed")
						completed(false)
						return
					end
					completed(true)
					action_utils.notify(ctx, "success", "Completion requested", 1500)
					done({ changed_pr = true, message = "Completion requested" }, nil)
				end)
			end,
		})
	end,
})
register(actions.decline)
register({
	id = "reopen",
	label = "Reopen PR",
	icon = icons.get("reopen", "actions"),
	is_available = function(ctx)
		return ctx.pr ~= nil and ctx.pr.state == "declined"
	end,
	run = function(ctx, done)
		action_utils.notify(ctx, "loading", "Reopening PR...")
		pullrequests_api.reopen(assert(ctx.pr), function(ok, err)
			if not ok then
				action_utils.notify(ctx, "error", err or "Reopen failed")
				done(nil, err or "Reopen failed")
				return
			end
			action_utils.notify(ctx, "success", "PR reopened", 1200)
			done({ changed_pr = true, message = "Reopened" }, nil)
		end)
	end,
})
register(actions.edit_pr)
register({
	id = "labels",
	label = "Edit tags",
	icon = icons.get("label", "actions"),
	is_available = action_utils.has_pr,
	run = function(ctx, done)
		local pr = assert(ctx.pr)
		action_utils.notify(ctx, "loading", "Loading tags...")
		pullrequests_api.fetch_labels(pr, function(labels, err)
			if err then
				action_utils.notify(ctx, "error", err)
				done(nil, err)
				return
			end
			---@cast labels { name: string }[]
			local names = vim.tbl_map(function(label)
				return label.name
			end, labels)
			action_utils.notify(ctx, "success", "Tags loaded", 1200)
			vim.ui.input({ prompt = "Tags (separated by ;): ", default = table.concat(names, "; ") }, function(input)
				if input == nil then
					done({ changed_pr = false, message = "Edit tags cancelled" }, nil)
					return
				end
				local selected = {}
				for name in input:gmatch("[^;]+") do
					local tag = vim.trim(name)
					if tag ~= "" then
						table.insert(selected, tag)
					end
				end
				action_utils.notify(ctx, "loading", "Updating tags...")
				pullrequests_api.update_labels(pr, selected, labels, function(ok, update_err)
					if not ok then
						action_utils.notify(ctx, "error", update_err or "Update tags failed")
						done(nil, update_err or "Update tags failed")
						return
					end
					action_utils.notify(ctx, "success", "Tags updated", 1200)
					done({ changed_pr = true, message = "Tags updated" }, nil)
				end)
			end)
		end)
	end,
})
register(actions.ready_for_review)
register(actions.convert_to_draft)
register(actions.edit_reviewers)

register({ id = "search", label = "Search Pull Requests", icon = icons.get("search", "actions"), run = search.search })
register({ id = "open_repo", label = "Open Repo", icon = icons.get("search", "actions"), run = search.open_repo })
register({
	id = "search_pull_requests",
	label = "Open Search View",
	icon = icons.get("search", "actions"),
	run = search.open_view,
})
register({
	id = "edit_search",
	label = "Edit search",
	icon = icons.get("search", "actions"),
	is_available = function(context)
		local state = require("atlas.pulls.state")
		return state.provider == context.provider and state.search_view() ~= nil
	end,
	run = search.edit,
})

register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasAzureActionId
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
