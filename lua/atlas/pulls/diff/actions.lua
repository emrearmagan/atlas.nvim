local M = {}

local picker = require("atlas.ui.picker")

local pull_actions = require("atlas.pulls.actions")
local review_api = require("atlas.pulls.diff.review")
local notes = require("atlas.pulls.notes")

---@param session AtlasDiffSession
local function reload_notes(session)
	if not session.note_target then
		return
	end
	local items = notes.list(session.note_target)
	if items then
		session.notes = items
	end
end

---@param session AtlasDiffSession
---@param action AtlasPullAction
local function run(session, action)
	local context = review_api.action_context(session)
	if not context then
		return
	end
	action.run(context, function(result, err)
		if session.closed then
			return
		end
		if result and not err then
			reload_notes(session)
			review_api.reload(session)
		end
	end)
end

---@param session AtlasDiffSession
local function open_in_browser(session)
	local context = review_api.action_context(session)
	if context then
		pull_actions.run("open_in_browser", context)
	end
end

---@param session AtlasDiffSession
function M.toggle_detail_panel(session)
	local context = session.review
	if context == nil then
		return
	end

	local detail_ui = require("atlas.ui.detail")
	local detail = require("atlas.pulls.ui.detail")
	if detail_ui.is_showing("pulls", session.tabpage) then
		detail.close()
		return
	end

	detail.open(context.pr, {
		provider = context.provider,
		on_update = function(pr)
			detail.refresh(pr)
			if session.closed or session.review == nil then
				return
			end
			session.review.pr = pr
			review_api.reload(session)
		end,
	})
end

---@param session AtlasDiffSession
function M.start_or_submit(session)
	local review = session.review
	if not review or (review.pr.state ~= "open" and review.pr.state ~= "draft") then
		return
	end
	local reviews = review.provider.capabilities.reviews or {}
	if review.data.review.pending then
		if reviews.submit_review then
			run(session, pull_actions.submit_review)
		else
			open_in_browser(session)
		end
	elseif reviews.start_review then
		run(session, pull_actions.start_review)
	end
end

---@param session AtlasDiffSession
function M.approve(session)
	local review = session.review
	local context = review_api.action_context(session)
	if not review or not context or not pull_actions.is_available("approve", context) then
		return
	end
	if review.data.review.pending and not (review.provider.capabilities.reviews or {}).submit_review then
		open_in_browser(session)
		return
	end
	run(session, pull_actions.approve)
end

---@param session AtlasDiffSession
function M.request_changes(session)
	local review = session.review
	local context = review_api.action_context(session)
	if not review or not context or not pull_actions.is_available("request_changes", context) then
		return
	end
	if review.data.review.pending and not (review.provider.capabilities.reviews or {}).submit_review then
		open_in_browser(session)
		return
	end
	run(session, pull_actions.request_changes)
end

---@param session AtlasDiffSession
function M.open(session)
	local review = session.review
	if not review then
		return
	end
	local context = review_api.action_context(session)
	if not context then
		return
	end
	local reviews = review.provider.capabilities.reviews or {}
	local pending = review.data.review.pending == true
	local reviewable = review.pr.state == "open" or review.pr.state == "draft"
	local items = {
		{
			id = "toggle_detail_panel",
			label = "Toggle pull request details",
		},
	}

	if pending then
		if reviewable and reviews.submit_review then
			items[#items + 1] = pull_actions.submit_review
		elseif reviewable then
			items[#items + 1] = {
				id = "finish_review",
				label = "Finish review in browser",
				run = function()
					open_in_browser(session)
				end,
			}
		end
		if reviews.discard_review then
			items[#items + 1] = pull_actions.discard_review
		end
	elseif reviewable and reviews.start_review then
		items[#items + 1] = pull_actions.start_review
	end
	local can_complete = reviewable and (not pending or reviews.submit_review ~= nil)
	if can_complete and reviews.approve and pull_actions.is_available("approve", context) then
		items[#items + 1] = pull_actions.approve
	end
	if can_complete and reviews.request_changes and pull_actions.is_available("request_changes", context) then
		items[#items + 1] = pull_actions.request_changes
	end
	picker.select({
		title = "Review action",
		items = items,
		kind = "atlas_diff_actions",
		format_item = function(action)
			return action.label
		end,
		on_select = function(action)
			if not action then
				return
			end
			if action.id == "toggle_detail_panel" then
				M.toggle_detail_panel(session)
				return
			end
			run(session, action)
		end,
	})
end

return M
