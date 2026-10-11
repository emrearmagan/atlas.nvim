local M = {}

local completion = require("atlas.completion")
local md_editor = require("atlas.ui.popups.editor")
local picker = require("atlas.ui.picker")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local notify = require("atlas.core.notify")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local detail = require("atlas.issues.ui.detail.state")

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
---@param entry table
---@param refresh fun()
function M.reply(issue, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item or item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
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
---@param entry table
---@param refresh fun()
function M.edit(issue, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item or item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
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
					updated.parent_id = updated.parent_id or comment.parent_id
					updated._raw = vim.tbl_extend("keep", updated._raw or {}, comment._raw or {})
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
---@param entry table
---@param refresh fun()
function M.delete(issue, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item or item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
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
---@param entry table
---@param refresh fun()
function M.react(issue, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item or item.kind ~= "comment" then
		return
	end
	local comments = detail.provider.capabilities.comments
	local options = comments.reaction_options
	---@type IssueComment
	local target = item.entity
	picker.select({
		title = "Add reaction",
		items = options,
		format_item = function(option)
			return string.format("%s  %s", option.emoji or option.key, option.label or option.key)
		end,
		on_select = function(selected)
			if selected == nil then
				return
			end
			notify.loading("Adding reaction...")
			comments.add_reaction(issue, item, selected.key, function(ok, err)
				if not state.is_current(issue) then
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

return M
