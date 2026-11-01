local notify = require("atlas.core.notify")
local discussions = require("atlas.providers.github.discussions")
local editor = require("atlas.ui.popups.editor")
local reactions = require("atlas.ui.shared.reactions")

local M = {}

---@param list GitHubDiscussionComment[]
---@param comment GitHubDiscussionComment
local function remove(list, comment)
	for index, item in ipairs(list) do
		if item == comment then
			table.remove(list, index)
			return
		end
	end
end

---@param panel GitHubDiscussionPanel
---@param root GitHubDiscussionComment|nil Top-level comment to reply to
---@param mention string|nil Author to mention in the reply
---@param render fun()
local function add_comment(panel, root, mention, render)
	local discussion = panel.discussion
	if type(discussion) ~= "table" then
		return
	end

	editor.open({
		key = root and ("discussion-comment-reply-" .. root.id) or ("discussion-comment-add-" .. discussion.number),
		completion = { context = { provider = "github", repository = panel.repo.full_name } },
		title = root and " Reply to Comment " or " Add Comment ",
		initial_text = mention and ("@" .. mention .. " "),
		width_ratio = 0.7,
		height_ratio = 0.5,
		on_save = function(text)
			if vim.trim(text) == "" then
				return
			end

			notify.loading(root and "Sending reply..." or "Adding comment...")
			discussions.add_comment(discussion, text, root, function(comment, err)
				if panel.discussion ~= discussion then
					return
				end

				if not comment then
					notify.error((root and "Reply" or "Add comment") .. " failed: " .. tostring(err))
					return
				end

				if root then
					table.insert(root.replies, comment)
					panel.expanded[root.id] = true
				else
					table.insert(discussion.thread, comment)
					discussion.comments = discussion.comments + 1
				end

				notify.success(root and "Reply added" or "Comment added", { timeout = 1200 })
				render()
			end)
		end,
	})
end

---@param panel GitHubDiscussionPanel
---@param render fun()
function M.add(panel, render)
	add_comment(panel, nil, nil, render)
end

---@param panel GitHubDiscussionPanel
---@param entry AtlasThreadLineMap|nil
---@param render fun()
function M.reply(panel, entry, render)
	if entry and entry.root then
		add_comment(panel, entry.root, entry.subject and entry.subject.author, render)
	elseif entry and entry.subject then
		add_comment(panel, nil, nil, render)
	end
end

---@param panel GitHubDiscussionPanel
---@param entry AtlasThreadLineMap|nil
---@param render fun()
function M.edit(panel, entry, render)
	local discussion = panel.discussion
	local comment = entry and entry.subject
	if not comment or type(discussion) ~= "table" then
		return
	end

	editor.open({
		key = "discussion-comment-edit-" .. comment.id,
		completion = { context = { provider = "github", repository = panel.repo.full_name } },
		title = comment == discussion.description and " Edit Description " or " Edit Comment ",
		initial_text = comment.body,
		width_ratio = 0.7,
		height_ratio = 0.5,
		on_save = function(text)
			if vim.trim(text) == "" then
				return
			end

			notify.loading("Editing comment...")
			discussions.edit_comment(discussion, comment, text, function(_, err)
				if panel.discussion ~= discussion then
					return
				end

				if err then
					notify.error("Edit failed: " .. err)
					return
				end

				comment.body = text
				notify.success("Comment updated", { timeout = 1200 })
				render()
			end)
		end,
	})
end

---@param panel GitHubDiscussionPanel
---@param entry AtlasThreadLineMap|nil
---@param render fun()
function M.delete(panel, entry, render)
	local discussion = panel.discussion
	local comment, root = entry and entry.subject, entry and entry.root
	if not comment or not root or type(discussion) ~= "table" then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end

		notify.loading("Deleting comment...")
		discussions.delete_comment(comment, function(_, err)
			if panel.discussion ~= discussion then
				return
			end

			if err then
				notify.error("Delete failed: " .. err)
				return
			end

			if comment == root and #root.replies > 0 then
				root.deleted = true
			else
				if comment ~= root then
					remove(root.replies, comment)
				end

				if comment == root or (root.deleted and #root.replies == 0) then
					remove(discussion.thread, root)
					discussion.comments = discussion.comments - 1
				end
			end

			notify.success("Comment deleted", { timeout = 1200 })
			render()
		end)
	end)
end

---@param panel GitHubDiscussionPanel
---@param entry AtlasThreadLineMap|nil
---@param render fun()
function M.react(panel, entry, render)
	local discussion = panel.discussion
	if entry and entry.subject and type(discussion) == "table" then
		reactions.pick(discussions.reactions, discussion, entry.subject, function()
			return panel.discussion == discussion
		end, render)
	end
end

---@param panel GitHubDiscussionPanel
---@param entry AtlasThreadLineMap|nil
---@param render fun()
function M.upvote(panel, entry, render)
	local discussion = panel.discussion
	local subject = entry and entry.subject
	if not subject or type(discussion) ~= "table" then
		return
	end

	notify.loading(subject.upvoted and "Removing upvote..." or "Upvoting...")
	discussions.toggle_upvote(subject, function(_, err)
		if panel.discussion ~= discussion then
			return
		end

		if err then
			notify.error("Upvote failed: " .. err)
			return
		end

		subject.upvotes = subject.upvotes + (subject.upvoted and -1 or 1)
		subject.upvoted = not subject.upvoted
		notify.success(subject.upvoted and "Upvoted" or "Upvote removed", { timeout = 1200 })
		render()
	end)
end

---@param panel GitHubDiscussionPanel
---@param entry AtlasThreadLineMap|nil
---@param render fun()
function M.answer(panel, entry, render)
	local discussion = panel.discussion
	local comment, root = entry and entry.subject, entry and entry.root
	if not comment or comment ~= root or type(discussion) ~= "table" then
		return
	end

	if not discussion.category.answerable then
		notify.warn("Answers are only available in answerable categories")
		return
	end

	notify.loading(comment.answer and "Unmarking answer..." or "Marking answer...")
	discussions.toggle_answer(comment, function(_, err)
		if panel.discussion ~= discussion then
			return
		end

		if err then
			notify.error("Answer failed: " .. err)
			return
		end

		local answer = not comment.answer
		for _, item in ipairs(discussion.thread) do
			item.answer = false
		end

		comment.answer = answer
		discussion.answered = answer
		notify.success(answer and "Marked as answer" or "Answer unmarked", { timeout = 1200 })
		render()
	end)
end

return M
