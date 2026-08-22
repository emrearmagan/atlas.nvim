local M = {}

local md_editor = require("atlas.ui.popups.editor")
local picker = require("atlas.picker")
local statusline = require("atlas.ui.statusline")
local renderer = require("atlas.issues.ui.panel.issue.tabs.conversation.renderer")
local state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")

---@return IssuesProvider|nil
local function get_provider()
	return require("atlas.issues.state").provider
end

---@return IssuesCommentsCapability|nil
local function get_comments()
	local provider = get_provider()
	return provider and provider.capabilities.comments or nil
end

---@return AtlasMarkdownCompletionProvider|nil
local function get_completion()
	local comments = get_comments()
	if comments and comments.comment_completion then
		return comments.comment_completion()
	end
	return nil
end

---@param issue Issue
---@param amount integer
local function adjust_comment_count(issue, amount)
	local raw = issue._raw
	if type(raw) ~= "table" or raw.comment_count == nil then
		return
	end
	raw.comment_count = math.max(0, (tonumber(raw.comment_count) or 0) + amount)
	require("atlas.issues.ui.main").render()
end

---@param comment IssueComment
---@return boolean
local function is_own_comment(comment)
	local current_user = require("atlas.issues.state").current_user
	if not current_user or not comment.author then
		return false
	end
	return tostring(comment.author.account_id or "") == tostring(current_user.account_id or "")
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
		completion = get_completion(),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			local generation = state.generation
			statusline.notify("loading", "Adding comment...")
			comments.add_comment(issue, text, function(created, err)
				if not state.is_current(generation, issue) then
					return
				end
				if err then
					statusline.notify("error", "Add comment failed: " .. err)
					return
				end
				if created then
					state.upsert_comment(created)
					adjust_comment_count(issue, 1)
				end
				statusline.notify("success", "Comment added", 1200)
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
	if item.kind == "description" then
		M.add(issue, refresh)
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
	local completion = get_completion()
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
		preview = renderer.render_comment(comment, math.max(math.floor(vim.o.columns * 0.5), 80)),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			statusline.notify("loading", "Sending reply...")
			local generation = state.generation
			local function done(created, err)
				if not state.is_current(generation, issue) then
					return
				end
				if err then
					statusline.notify("error", "Reply failed: " .. err)
					return
				end
				if created then
					state.upsert_comment(created)
					adjust_comment_count(issue, 1)
				end
				statusline.notify("success", "Reply added", 1200)
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
	if item.kind == "description" then
		local provider = get_provider()
		local core = provider and provider.capabilities.core
		if not core or not core.update_description then
			return
		end
		---@type IssueDetails
		local details = item.entity
		local current = tostring(details.description or "")
		md_editor.open({
			key = "issue-description-edit-" .. tostring(issue.key),
			title = " Edit Description ",
			width_ratio = 0.5,
			height_ratio = 0.18,
			initial_text = current,
			completion = get_completion(),
			on_save = function(text)
				local content = text or ""
				if content == current then
					statusline.notify("info", "Description unchanged", 1200)
					return
				end
				local generation = state.generation
				statusline.notify("loading", "Updating description...")
				---@cast issue IssueDetails
				core.update_description(issue, content, function(ok, err)
					if not state.is_current(generation, issue) then
						return
					end
					if not ok then
						statusline.notify("error", "Description update failed: " .. tostring(err or "Unknown error"))
						return
					end
					issue.description = content
					statusline.notify("success", "Description updated", 1200)
					refresh()
				end)
			end,
		})
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
	if not is_own_comment(comment) then
		statusline.notify("warn", "You can only edit your own comments")
		return
	end
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
		completion = get_completion(),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			local generation = state.generation
			statusline.notify("loading", "Editing comment...")
			comments.edit_comment(issue, comment, text, function(updated, err)
				if not state.is_current(generation, issue) then
					return
				end
				if err then
					statusline.notify("error", "Edit failed: " .. err)
					return
				end
				if updated then
					updated.parent_id = updated.parent_id or comment.parent_id
					updated._raw = vim.tbl_extend("keep", updated._raw or {}, comment._raw or {})
					state.upsert_comment(updated)
				else
					comment.body = text
				end
				statusline.notify("success", "Comment updated", 1200)
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
	if item.kind == "description" then
		statusline.notify("info", "The issue description cannot be deleted", 1200)
		return
	end
	if item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
	if not is_own_comment(comment) then
		statusline.notify("warn", "You can only delete your own comments")
		return
	end
	local comments = get_comments()
	if not comments or not comments.delete_comment then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		local generation = state.generation
		statusline.notify("loading", "Deleting comment...")
		comments.delete_comment(issue, comment, function(_, err)
			if not state.is_current(generation, issue) then
				return
			end
			if err then
				statusline.notify("error", "Delete failed: " .. err)
				return
			end
			state.remove_comment(comment)
			adjust_comment_count(issue, -1)
			statusline.notify("success", "Comment deleted", 1200)
			refresh()
		end)
	end)
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.react(issue, entry, refresh)
	local item = entry and entry.conversation_item or nil
	if not item or (item.kind ~= "comment" and item.kind ~= "description") then
		return
	end
	local comments = get_comments()
	if not comments or not comments.add_reaction then
		statusline.notify("warn", "Provider does not support reactions")
		return
	end
	local options = comments.reaction_options or {}
	if #options == 0 then
		statusline.notify("warn", "No reactions available for this provider")
		return
	end
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
		format_item = function(item)
			return item.label
		end,
		on_select = function(selected)
			if selected == nil then
				return
			end
			local generation = state.generation
			statusline.notify("loading", "Adding reaction...")
			comments.add_reaction(issue, item, selected.key, function(ok, err)
				if not state.is_current(generation, issue) then
					return
				end
				if err then
					statusline.notify("error", "Reaction failed: " .. tostring(err))
					return
				end
				if ok then
					target.reactions = target.reactions or {}
					target.reactions[selected.key] = (tonumber(target.reactions[selected.key]) or 0) + 1
				end
				statusline.notify("success", "Reaction added", 1200)
				refresh()
			end)
		end,
	})
end

return M
