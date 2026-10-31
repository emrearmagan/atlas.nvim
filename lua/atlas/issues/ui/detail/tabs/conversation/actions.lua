local M = {}

local completion = require("atlas.completion")
local issue_actions = require("atlas.issues.actions")
local md_editor = require("atlas.ui.popups.editor")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local notify = require("atlas.core.notify")
local reactions = require("atlas.ui.shared.reactions")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local detail = require("atlas.issues.ui.detail.state")

---@class IssuesConversationLine
---@field comment IssueComment|nil
---@field thread_root IssueComment|nil

---@param issue Issue
---@param amount integer
local function adjust_comment_count(issue, amount)
	if issue.comment_count == nil then
		return
	end
	issue.comment_count = math.max(0, (tonumber(issue.comment_count) or 0) + amount)
	local on_update = detail.on_update
	if on_update then
		on_update(issue, nil)
	end
end

---@param issue Issue
---@param refresh fun()
function M.add(issue, refresh)
	local comments = detail.provider.capabilities.comments
	md_editor.open({
		key = "issue-comment-add",
		completion = {
			context = { provider = detail.provider.id, issue = { key = issue.key } },
		},
		title = " Add Comment ",
		width_ratio = 0.7,
		height_ratio = 0.5,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			notify.loading("Adding comment...")
			comments.add_comment(issue, text, nil, function(created, err)
				if not state.is_current(issue) then
					return
				end
				if err then
					notify.error("Add comment failed: " .. err)
					return
				end
				if created then
					state.upsert_comment(created)
					adjust_comment_count(issue, 1)
				end
				notify.success("Comment added", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

---@param issue Issue
---@param entry IssuesConversationLine
---@param refresh fun()
function M.reply(issue, entry, refresh)
	local comment = entry.comment
	if not comment then
		return
	end
	if state.is_description(comment) then
		M.add(issue, refresh)
		return
	end
	local comments = detail.provider.capabilities.comments
	local mention = completion.format_mention(detail.provider, comment.author)

	local parent = entry.thread_root or comment
	md_editor.open({
		key = "issue-comment-reply-" .. tostring(comment.id),
		completion = {
			context = { provider = detail.provider.id, issue = { key = issue.key } },
		},
		title = " Reply to Comment ",
		initial_text = mention and (mention .. " "),
		width_ratio = 0.7,
		height_ratio = 0.5,
		preview = comment_threads.render_comment(comment, math.max(math.floor(vim.o.columns * 0.7), 80)),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			notify.loading("Sending reply...")
			comments.add_comment(issue, text, { parent = parent }, function(created, err)
				if not state.is_current(issue) then
					return
				end
				if err then
					notify.error("Reply failed: " .. err)
					return
				end
				if created then
					state.upsert_comment(created)
					adjust_comment_count(issue, 1)
				end
				notify.success("Reply added", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

---@param issue Issue
---@param entry IssuesConversationLine
---@param refresh fun()
function M.edit(issue, entry, refresh)
	local comment = entry.comment
	if not comment then
		return
	end
	if state.is_description(comment) then
		issue_actions.run("edit_issue", { provider = detail.provider, issue = issue }, function(result)
			require("atlas.issues.ui.detail").apply_action_result(issue, detail.on_update, result)
		end)
		return
	end
	local comments = detail.provider.capabilities.comments
	md_editor.open({
		key = "issue-comment-edit-" .. tostring(comment.id),
		completion = {
			context = { provider = detail.provider.id, issue = { key = issue.key } },
		},
		title = " Edit Comment ",
		width_ratio = 0.7,
		height_ratio = 0.5,
		initial_text = tostring(comment.body or ""),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			notify.loading("Editing comment...")
			comments.edit_comment(issue, comment, text, function(updated, err)
				if not state.is_current(issue) then
					return
				end
				if err then
					notify.error("Edit failed: " .. err)
					return
				end
				if updated then
					state.upsert_comment(updated)
				else
					comment.body = text
				end
				notify.success("Comment updated", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

---@param issue Issue
---@param entry IssuesConversationLine
---@param refresh fun()
function M.delete(issue, entry, refresh)
	local comment = entry.comment
	if not comment or state.is_description(comment) then
		return
	end
	local comments = detail.provider.capabilities.comments

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		notify.loading("Deleting comment...")
		comments.delete_comment(issue, comment, function(_, err)
			if not state.is_current(issue) then
				return
			end
			if err then
				notify.error("Delete failed: " .. err)
				return
			end
			state.remove_comment(comment)
			adjust_comment_count(issue, -1)
			notify.success("Comment deleted", { timeout = 1200 })
			refresh()
		end)
	end)
end

---@param issue Issue
---@param entry IssuesConversationLine
---@param refresh fun()
function M.react(issue, entry, refresh)
	local comment = entry.comment
	if not comment or comment.deleted then
		return
	end
	-- TODO: Reacting to the description doesn't update the overview's reactions until the details are reloaded.
	reactions.pick(detail.provider.capabilities.comments.reactions, issue, comment, function()
		return state.is_current(issue)
	end, refresh)
end

return M
