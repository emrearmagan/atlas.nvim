local M = {}

local actions = require("atlas.pulls.actions")

---@param context AtlasReviewActionContext
---@param opts { finish_review: fun(), on_done: fun(result: PullsActionResult|nil, err: string|nil) }
function M.open(context, opts)
	local items = {}
	local reviews = context.provider.capabilities.reviews or {}
	local pending = context.data and context.data.review.pending == true
	local reviewable = context.pr.state == "open" or context.pr.state == "draft"
	if pending then
		if reviewable then
			if reviews.submit_review then
				table.insert(items, actions.submit_review)
			else
				table.insert(items, {
					id = "finish_review",
					label = "Finish review in browser",
					run = function()
						opts.finish_review()
						return true
					end,
				})
			end
		end
		if reviews.discard_review then
			table.insert(items, actions.discard_review)
		end
	elseif reviewable and reviews.start_review then
		table.insert(items, actions.start_review)
	end
	local can_complete = reviewable and (not pending or reviews.submit_review ~= nil)
	if can_complete and reviews.approve and actions.is_available("toggle_approval", context) then
		table.insert(items, actions.approve)
	end
	if can_complete and reviews.request_changes and actions.is_available("request_changes", context) then
		table.insert(items, actions.request_changes)
	end
	if #items == 0 then
		return
	end

	vim.ui.select(items, {
		prompt = "Review action",
		kind = "atlas_diff_actions",
		format_item = function(action)
			return action.label
		end,
	}, function(action)
		if action then
			action.run(context, opts.on_done)
		end
	end)
end

return M
