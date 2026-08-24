local M = {}

local picker = require("atlas.ui.picker")
local pull_actions = require("atlas.pulls.actions")
local notify = require("atlas.core.notify")
local review = require("atlas.pulls.actions.review")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local detail = require("atlas.pulls.ui.detail.state")

---@param pr PullRequest
---@return AtlasMarkdownCompletionProvider|nil
local function author_completion(pr)
	local provider = detail.provider
	local comments_capability = provider and provider.capabilities.comments
	if not comments_capability or not comments_capability.comment_completion then
		return nil
	end
	local reviewers = require("atlas.pulls.ui.detail.tabs.overview.state").reviewers
	local conversation = state.comments(false)
	return comments_capability.comment_completion({
		pr = pr,
		comments = conversation,
		tasks = state.comments(true),
		reviewers = type(reviewers) == "table" and reviewers or nil,
		conversation = conversation,
	})
end

---@param pr PullRequest
---@param comment PullsComment|nil
---@return AtlasReviewActionContext|nil
local function action_context(pr, comment)
	local provider = detail.provider
	if not provider then
		return nil
	end
	local items = state.comments(comment and comment.is_task == true or false)
	return {
		provider = provider,
		pr = pr,
		items = items,
		completion = author_completion(pr),
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
		notify = function(level, message, duration)
			if state.is_current(pr) then
				notify.show(level, message, { timeout = duration })
			end
		end,
	}
end

---@param pr PullRequest
---@param on_update (fun(pr: PullRequest, result: PullsActionResult|nil))|nil
---@param result PullsActionResult
local function complete_action(pr, on_update, result)
	if on_update then
		on_update(pr, result)
	else
		require("atlas.pulls.ui.detail").select(pr, { force_refresh = true })
	end
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
			complete_action(pr, on_update, result)
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
		review.add_comment(context, nil, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.reply(pr, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item then
		return
	end
	if item.kind == "description" then
		M.add(pr, refresh)
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type PullsComment
	local comment = item.entity
	if comment.is_task then
		return
	end
	local context = action_context(pr, comment)
	if context then
		review.add_comment(context, { parent = comment }, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.edit(pr, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item then
		return
	end
	if item.kind == "review" then
		---@type PullsReviewHistoryEntry
		local review_entry = item.entity
		local context = action_context(pr, nil)
		if context then
			review.edit_review(context, review_entry, on_done(pr, refresh))
		end
		return
	end
	if item.kind == "description" then
		local provider = detail.provider
		if provider then
			pull_actions.run("edit_description", { provider = provider, pr = pr }, on_done(pr, refresh))
		end
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type PullsComment
	local comment = item.entity
	local context = action_context(pr, comment)
	if context then
		review.edit_comment(context, comment, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.delete(pr, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item then
		return
	end
	if item.kind == "description" then
		notify.info("The pull request description cannot be deleted", { timeout = 1200 })
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type PullsComment
	local comment = item.entity
	local context = action_context(pr, comment)
	if context then
		review.delete_comment(context, comment, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.react(pr, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item or (item.kind ~= "comment" and item.kind ~= "description") then
		return
	end
	local provider = detail.provider
	if item.kind == "description" then
		if provider == nil or provider.id ~= "github" then
			return
		end
		---@type GitHubPullRequestDetails
		local details = item.entity
		if details.reactions == nil then
			return
		end
	end
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.add_reaction then
		return
	end
	local options = comments.reaction_options or {}
	if #options == 0 then
		notify.warn("No reactions available for this provider")
		return
	end
	local target = item.entity
	local choices = {}
	for _, option in ipairs(options) do
		table.insert(choices, {
			key = option.key,
			label = string.format("%s  %s", option.emoji or option.key, option.label or option.key),
		})
	end
	picker.select({
		title = "Add reaction",
		items = choices,
		format_item = function(choice)
			return choice.label
		end,
		on_select = function(selected)
			if selected == nil then
				return
			end
			notify.loading("Adding reaction...")
			comments.add_reaction(pr, item, selected.key, function(ok, err)
				if not state.is_current(pr) then
					return
				end
				if err then
					notify.error("Reaction failed: " .. tostring(err))
					return
				end
				if ok then
					target.reactions = target.reactions or {}
					target.reactions[selected.key] = (tonumber(target.reactions[selected.key]) or 0) + 1
				end
				notify.success("Reaction added", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.toggle_task(pr, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item or item.kind ~= "comment" then
		return
	end
	---@type PullsComment
	local task = item.entity
	if not task.is_task then
		return
	end
	local context = action_context(pr, task)
	if context then
		review.toggle_task(context, task, on_done(pr, refresh))
	end
end

return M
