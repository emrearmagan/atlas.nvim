local M = {}

local md_editor = require("atlas.ui.popups.editor")
local statusline = require("atlas.ui.statusline")
local review_threads = require("atlas.ui.components.review_threads")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
end

---@param pr PullRequest
---@return AtlasMarkdownCompletionProvider|nil
local function author_completion(pr)
	local provider = get_provider()
	local comments_capability = provider and provider.capabilities.comments
	if not comments_capability or not comments_capability.comment_completion then
		return nil
	end
	local comments = require("atlas.pulls.ui.panel.pr.tabs.review.state").comments
	local reviewers = require("atlas.pulls.ui.panel.pr.tabs.overview.state").reviewers
	return comments_capability.comment_completion({
		pr = pr,
		comments = type(comments) == "table" and comments or {},
		reviewers = type(reviewers) == "table" and reviewers or nil,
		conversation = type(state.comments) == "table" and state.comments or nil,
	})
end

---@param fn fun(list: PullsComment[])
local function with_comments(fn)
	local list = state.comments
	if type(list) ~= "table" then
		return
	end
	---@cast list PullsComment[]
	fn(list)
end

---@param comment PullsComment
---@return boolean
local function is_own_comment(comment)
	local current_user = require("atlas.pulls.state").current_user
	if not current_user or not comment.author then
		return false
	end
	return comment.author.nickname == current_user.username or comment.author.name == current_user.name
end

---@param pr PullRequest
---@param refresh fun()
function M.add(pr, refresh)
	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.add_comment then
		return
	end
	md_editor.open({
		key = "pr-comment-add",
		title = " Add Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		completion = author_completion(pr),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			statusline.notify("loading", "Adding comment...")
			comments.add_comment(pr, text, nil, function(comment, err)
				if err then
					statusline.notify("error", "Add comment failed: " .. err)
					return
				end
				if type(comment) == "table" then
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

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.reply(pr, entry, refresh)
	if not entry or entry.entity_kind ~= "comment" or not entry.comment then
		return
	end
	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.add_comment then
		return
	end
	local comment = entry.comment
	local completion = author_completion(pr)
	local mention = ""
	if completion and completion.format_mention then
		mention = completion.format_mention(comment.author) or ""
	end
	local initial_text = mention ~= "" and (mention .. " ") or ""
	md_editor.open({
		key = "pr-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = initial_text,
		completion = completion,
		preview = review_threads.render_comment(comment, math.max(math.floor(vim.o.columns * 0.5), 80)),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			statusline.notify("loading", "Sending reply...")
			comments.add_comment(pr, text, {
				parent = comment,
				pending = comment.state == "PENDING",
			}, function(reply, err)
				if err then
					statusline.notify("error", "Reply failed: " .. err)
					return
				end
				if type(reply) == "table" then
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

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.edit(pr, entry, refresh)
	if not entry or entry.entity_kind ~= "comment" or not entry.comment then
		return
	end
	local comment = entry.comment
	if not is_own_comment(comment) then
		statusline.notify("warn", "You can only edit your own comments")
		return
	end
	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.edit_comment then
		return
	end

	md_editor.open({
		key = "pr-comment-edit-" .. tostring(comment.id),
		title = " Edit Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = comment.content_raw or "",
		completion = author_completion(pr),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			statusline.notify("loading", "Editing comment...")
			local updated = vim.tbl_extend("force", {}, comment, { content_raw = text })
			comments.edit_comment(pr, updated, function(_, err)
				if err then
					statusline.notify("error", "Edit failed: " .. err)
					return
				end
				with_comments(function(list)
					for _, c in ipairs(list) do
						if c.id == comment.id then
							c.content_raw = text
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

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.delete(pr, entry, refresh)
	if not entry or entry.entity_kind ~= "comment" or not entry.comment then
		return
	end
	local comment = entry.comment
	if tostring(comment.id) == "__body__" then
		statusline.notify("info", "The pull request description cannot be deleted", 1200)
		return
	end
	if not is_own_comment(comment) then
		statusline.notify("warn", "You can only delete your own comments")
		return
	end
	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.delete_comment then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		statusline.notify("loading", "Deleting comment...")
		comments.delete_comment(pr, comment, function(ok, err)
			if err then
				statusline.notify("error", "Delete failed: " .. err)
				return
			end
			if ok then
				with_comments(function(list)
					for i, c in ipairs(list) do
						if c.id == comment.id then
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

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.react(pr, entry, refresh)
	if not entry or entry.entity_kind ~= "comment" or not entry.comment then
		return
	end
	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.add_reaction then
		return
	end
	local options = comments.reaction_options or {}
	if #options == 0 then
		statusline.notify("warn", "No reactions available for this provider")
		return
	end
	local comment = entry.comment
	local choices = {}
	for _, option in ipairs(options) do
		table.insert(choices, {
			key = option.key,
			label = string.format("%s  %s", option.emoji or option.key, option.label or option.key),
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
		comments.add_reaction(pr, comment, selected.key, function(ok, err)
			if err then
				statusline.notify("error", "Reaction failed: " .. tostring(err))
				return
			end
			if ok then
				with_comments(function(list)
					for _, current in ipairs(list) do
						if current.id == comment.id then
							current.reactions = current.reactions or {}
							current.reactions[selected.key] = (tonumber(current.reactions[selected.key]) or 0) + 1
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
