local M = {}

local action_runner = require("atlas.core.actions")
local pull_actions = require("atlas.pulls.actions")
local reactions = require("atlas.ui.shared.reactions")
local review = require("atlas.pulls.actions.review")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local detail = require("atlas.pulls.ui.detail.state")

---@class PullsConversationLine
---@field comment PullsComment|nil
---@field review_entry PullsReviewHistoryEntry|nil

---@param pr PullRequest
---@param comment PullsComment|nil
---@return AtlasReviewActionContext|nil
local function action_context(pr, comment)
	local provider = detail.provider
	if not provider then
		return nil
	end
	return {
		provider = provider,
		pr = pr,
		comment = comment,
		conversation = state.comments(),
		upsert_comment = function(created)
			if state.is_current(pr) then
				state.upsert_comment(created)
			end
		end,
		remove_comment = function(removed)
			if state.is_current(pr) then
				state.remove_comment(removed)
			end
		end,
	}
end

---@param pr PullRequest
---@param refresh fun()
---@return fun(result: PullsActionResult|nil, err: string|nil)
local function on_done(pr, refresh)
	local on_update = detail.on_update
	return function(result, err)
		if not result or err then
			return
		end
		if result.changed_pr then
			require("atlas.pulls.ui.detail").apply_action_result(pr, on_update, result)
		elseif state.is_current(pr) then
			refresh()
		end
	end
end

---@param pr PullRequest
---@param refresh fun()
function M.add(pr, refresh)
	local context = action_context(pr, nil)
	if context then
		action_runner.run(review.add_comment, context, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry PullsConversationLine
---@param refresh fun()
function M.reply(pr, entry, refresh)
	local comment = entry.comment
	if not comment or comment.is_task then
		return
	end
	if state.is_description(comment) then
		M.add(pr, refresh)
		return
	end
	local context = action_context(pr, comment)
	if context then
		action_runner.run(review.add_comment, context, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry PullsConversationLine
---@param refresh fun()
function M.edit(pr, entry, refresh)
	local review_entry = entry.review_entry
	if review_entry then
		local context = action_context(pr, nil)
		if context then
			context.review_entry = review_entry
			action_runner.run(review.edit_review, context, on_done(pr, refresh))
		end
		return
	end
	local comment = entry.comment
	if not comment then
		return
	end
	if state.is_description(comment) then
		local context = { provider = detail.provider, pr = pr, details = detail.current_details }
		pull_actions.run("edit_pr", context, on_done(pr, refresh))
		return
	end
	local context = action_context(pr, comment)
	if context then
		action_runner.run(review.edit_comment, context, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry PullsConversationLine
---@param refresh fun()
function M.delete(pr, entry, refresh)
	local comment = entry.comment
	if not comment or state.is_description(comment) then
		return
	end
	local context = action_context(pr, comment)
	if context then
		action_runner.run(review.delete_comment, context, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry PullsConversationLine
---@param refresh fun()
function M.react(pr, entry, refresh)
	local comment = entry.comment
	if not comment or comment.deleted then
		return
	end
	-- TODO: Reacting to the description doesn't update the overview's reactions until the details are reloaded.
	reactions.pick(detail.provider.capabilities.comments.reactions, pr, comment, function()
		return state.is_current(pr)
	end, refresh)
end

---@param pr PullRequest
---@param entry PullsConversationLine
---@param refresh fun()
function M.toggle_task(pr, entry, refresh)
	local task = entry.comment
	if not task or not task.is_task then
		return
	end
	local context = action_context(pr, task)
	if context then
		action_runner.run(review.toggle_task, context, on_done(pr, refresh))
	end
end

return M
