local M = {}

local md_editor = require("atlas.ui.popups.editor")
local picker = require("atlas.ui.picker")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local notify = require("atlas.core.notify")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local detail = require("atlas.issues.ui.detail.state")

---@return IssuesCommentsCapability|nil
local function get_comments()
	local provider = detail.provider
	return provider and provider.capabilities.comments or nil
end

---@param issue Issue
---@return AtlasMarkdownCompletionProvider|nil
local function get_completion(issue)
	local comments = get_comments()
	if comments and comments.comment_completion then
		return comments.comment_completion({
			issue = issue,
			details = detail.current_details,
			comments = state.comments(),
		})
	end
	return nil
end

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
	local comments = get_comments()
	if not comments or not comments.add_comment then
		return
	end
	md_editor.open({
		key = "issue-comment-add",
		title = " Add Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		completion = get_completion(issue),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			notify.loading("Adding comment...")
			comments.add_comment(issue, text, function(created, err)
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
	if not item then
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
	local comments = get_comments()
	if not comments or not comments.add_comment then
		return
	end
	local completion = get_completion(issue)
	local mention = ""
	if completion and completion.format_mention then
		mention = completion.format_mention(comment.author) or ""
	end
	local initial_text = mention ~= "" and (mention .. " ") or ""

	local parent = entry.thread_root or comment
	md_editor.open({
		key = "issue-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = initial_text,
		completion = completion,
		preview = comment_threads.render_comment(comment, math.max(math.floor(vim.o.columns * 0.5), 80)),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			notify.loading("Sending reply...")
			local function done(created, err)
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
			end
			if comments.reply_comment then
				comments.reply_comment(issue, parent, text, done)
			else
				comments.add_comment(issue, text, done)
			end
		end,
	})
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.edit(issue, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item then
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
	local comments = get_comments()
	if not comments or not comments.edit_comment then
		return
	end
	md_editor.open({
		key = "issue-comment-edit-" .. tostring(comment.id),
		title = " Edit Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = tostring(comment.body or ""),
		completion = get_completion(issue),
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
	if not item then
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
	local comments = get_comments()
	if not comments or not comments.delete_comment then
		return
	end

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
	local comments = get_comments()
	if not comments or not comments.add_reaction then
		notify.warn("Provider does not support reactions")
		return
	end
	local options = comments.reaction_options or {}
	if #options == 0 then
		notify.warn("No reactions available for this provider")
		return
	end
	---@type IssueComment
	local target = item.entity
	local choices = {}
	for _, opt in ipairs(options) do
		table.insert(choices, {
			key = opt.key,
			label = string.format("%s  %s", opt.emoji or opt.key, opt.label or opt.key),
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
