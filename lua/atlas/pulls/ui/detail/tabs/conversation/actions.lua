local M = {}

local picker = require("atlas.picker")
local pull_actions = require("atlas.pulls.actions")
local notify = require("atlas.core.notify")
local review = require("atlas.pulls.actions.review")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.ui.detail.state").provider
end

---@param pr PullRequest
---@return AtlasMarkdownCompletionProvider|nil
local function author_completion(pr)
	local provider = get_provider()
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
	local provider = get_provider()
	if not provider then
		return nil
	end
	local items = state.comments(comment and comment.is_task == true or false)
	return {
		provider = provider,
		pr = pr,
		items = items,
		completion = author_completion(pr),
		upsert_comment = state.upsert_comment,
		remove_comment = state.remove_comment,
	}
end

---@param pr PullRequest
---@param refresh fun()
---@return fun(result: PullsActionResult|nil, err: string|nil)
local function on_done(pr, refresh)
	return function(result, err)
		if not result or err then
			return
		end
		if result.changed_pr then
			require("atlas.pulls.ui.detail").action_result(pr, result)
		else
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
		local provider = get_provider()
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
	if item.kind == "description" and item.entity.reactions == nil then
		return
	end
	local provider = get_provider()
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
