local M = {}

local md_editor = require("atlas.ui.popups.editor")
local statusline = require("atlas.ui.statusline")
local renderer = require("atlas.issues.ui.panel.issue.tabs.conversation.renderer")
local state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")

---@return IssuesProvider|nil
local function get_provider()
	return require("atlas.issues.state").provider
end

---@return IssuesProviderPanel|nil
local function get_panel()
	local provider = get_provider()
	return provider and provider.panel or nil
end

---@return AtlasMarkdownCompletionProvider|nil
local function get_completion()
	local panel = get_panel()
	if panel and panel.comment_completion then
		return panel.comment_completion()
	end
	return nil
end

---@param fn fun(list: IssueComment[])
local function with_comments(fn)
	local list = state.comments
	if type(list) ~= "table" then
		return
	end
	---@cast list IssueComment[]
	fn(list)
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
	local provider = get_provider()
	if not provider or not provider.add_comment then
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
			statusline.notify("loading", "Adding comment...")
			provider.add_comment(issue, text, function(comment, err)
				if err then
					statusline.notify("error", "Add comment failed: " .. err)
					return
				end
				if comment then
					with_comments(function(list)
						table.insert(list, comment)
					end)
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
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local provider = get_provider()
	if not provider or not provider.reply_comment then
		return
	end
	local comment = entry.comment
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
			provider.reply_comment(issue, parent, text, function(reply, err)
				if err then
					statusline.notify("error", "Reply failed: " .. err)
					return
				end
				if reply then
					with_comments(function(list)
						table.insert(list, reply)
					end)
				end
				statusline.notify("success", "Reply added", 1200)
				refresh()
			end)
		end,
	})
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.edit(issue, entry, refresh)
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local comment = entry.comment
	if not is_own_comment(comment) then
		statusline.notify("warn", "You can only edit your own comments")
		return
	end
	local provider = get_provider()
	if not provider then
		return
	end

	if not provider.edit_comment then
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
			statusline.notify("loading", "Editing comment...")
			provider.edit_comment(issue, tostring(comment.id), text, function(updated, err)
				if err then
					statusline.notify("error", "Edit failed: " .. err)
					return
				end
				with_comments(function(list)
					for i, c in ipairs(list) do
						if tostring(c.id) == tostring(comment.id) then
							if updated then
								list[i] = updated
							else
								c.body = text
							end
							break
						end
					end
				end)
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
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local comment = entry.comment
	if not is_own_comment(comment) then
		statusline.notify("warn", "You can only delete your own comments")
		return
	end
	local provider = get_provider()
	if not provider or not provider.delete_comment then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		statusline.notify("loading", "Deleting comment...")
		provider.delete_comment(issue, tostring(comment.id), function(ok, err)
			if err then
				statusline.notify("error", "Delete failed: " .. err)
				return
			end
			if ok then
				with_comments(function(list)
					for i, c in ipairs(list) do
						if tostring(c.id) == tostring(comment.id) then
							table.remove(list, i)
							break
						end
					end
				end)
			end
			statusline.notify("success", "Comment deleted", 1200)
			refresh()
		end)
	end)
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.react(issue, entry, refresh)
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local provider = get_provider()
	if not provider or not provider.add_reaction then
		statusline.notify("warn", "Provider does not support reactions")
		return
	end
	local options = state.reaction_options or {}
	if #options == 0 then
		statusline.notify("warn", "No reactions available for this provider")
		return
	end
	local comment = entry.comment
	local choices = {}
	for _, opt in ipairs(options) do
		table.insert(choices, {
			key = opt.key,
			label = string.format("%s  %s", opt.emoji or opt.key, opt.label or opt.key),
		})
	end
	vim.ui.select(choices, {
		prompt = "Add reaction",
		format_item = function(item)
			return item.label
		end,
	}, function(selected)
		if selected == nil then
			return
		end
		statusline.notify("loading", "Adding reaction...")
		provider.add_reaction(issue, comment, selected.key, function(ok, err)
			if err then
				statusline.notify("error", "Reaction failed: " .. tostring(err))
				return
			end
			if ok then
				with_comments(function(list)
					for _, c in ipairs(list) do
						if tostring(c.id) == tostring(comment.id) then
							c.reactions = c.reactions or {}
							c.reactions[selected.key] = (tonumber(c.reactions[selected.key]) or 0) + 1
							break
						end
					end
				end)
			end
			statusline.notify("success", "Reaction added", 1200)
			refresh()
		end)
	end)
end

return M
