local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local layout = require("atlas.ui.layout")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
local md_editor = require("atlas.ui.popups.markdown_editor")
local footer = require("atlas.ui.components.footer")

local function cursor_entry()
	local win = layout.win_id("detail")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return (panel_state.line_map or {})[lnum]
end

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
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

---@param refresh fun()
local function add_comment(refresh)
	local provider = get_provider()
	local pr = panel_state.current_pr
	if not pr or not provider or type(provider.add_comment) ~= "function" then
		return
	end
	md_editor.open({
		key = "pr-comment-add",
		title = " Add Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Adding comment...")
			provider.add_comment(pr, text, nil, function(comment, err)
				if err then
					footer.notify("error", "Add comment failed: " .. err)
					return
				end
				if type(comment) == "table" and type(state.comments) == "table" then
					table.insert(state.comments, comment)
				end
				footer.notify("success", "Comment added", 1200)
				refresh()
			end)
		end,
	})
end

---@param refresh fun()
local function reply_to_current(refresh)
	local entry = cursor_entry()
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local provider = get_provider()
	local pr = panel_state.current_pr
	if not pr or not provider or type(provider.reply_comment) ~= "function" then
		return
	end
	local comment = entry.comment
	local author = comment.author or {}
	local mention = tostring(author.nickname or author.name or "")
	local initial_text = mention ~= "" and ("@" .. mention .. " ") or ""

	md_editor.open({
		key = "pr-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = initial_text,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Sending reply...")
			provider.reply_comment(pr, comment, text, function(reply, err)
				if err then
					footer.notify("error", "Reply failed: " .. err)
					return
				end
				if type(reply) == "table" and type(state.comments) == "table" then
					table.insert(state.comments, reply)
				end
				footer.notify("success", "Reply added", 1200)
				refresh()
			end)
		end,
	})
end

---@param refresh fun()
local function edit_current(refresh)
	local entry = cursor_entry()
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local comment = entry.comment
	if not is_own_comment(comment) then
		footer.notify("warn", "You can only edit your own comments")
		return
	end
	local provider = get_provider()
	local pr = panel_state.current_pr
	if not pr or not provider or type(provider.edit_comment) ~= "function" then
		return
	end

	md_editor.open({
		key = "pr-comment-edit-" .. tostring(comment.id),
		title = " Edit Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = comment.content_raw or "",
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Editing comment...")
			local updated = vim.tbl_extend("force", {}, comment, { content_raw = text })
			provider.edit_comment(pr, updated, function(_, err)
				if err then
					footer.notify("error", "Edit failed: " .. err)
					return
				end
				if type(state.comments) == "table" then
					for i, c in ipairs(state.comments) do
						if c.id == comment.id then
							state.comments[i].content_raw = text
							break
						end
					end
				end
				footer.notify("success", "Comment updated", 1200)
				refresh()
			end)
		end,
	})
end

---@param refresh fun()
local function delete_current(refresh)
	local entry = cursor_entry()
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local comment = entry.comment
	if not is_own_comment(comment) then
		footer.notify("warn", "You can only delete your own comments")
		return
	end
	local provider = get_provider()
	local pr = panel_state.current_pr
	if not pr or not provider or type(provider.delete_comment) ~= "function" then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		footer.notify("loading", "Deleting comment...")
		provider.delete_comment(pr, comment, function(ok, err)
			if err then
				footer.notify("error", "Delete failed: " .. err)
				return
			end
			if ok and type(state.comments) == "table" then
				for i, c in ipairs(state.comments) do
					if c.id == comment.id then
						table.remove(state.comments, i)
						break
					end
				end
			end
			footer.notify("success", "Comment deleted", 1200)
			refresh()
		end)
	end)
end

---@param refresh fun()
local function add_reaction(refresh)
	local entry = cursor_entry()
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local provider = get_provider()
	local pr = panel_state.current_pr
	if not pr or not provider or type(provider.add_reaction) ~= "function" then
		footer.notify("warn", "Provider does not support reactions")
		return
	end
	local options = state.reaction_options or {}
	if #options == 0 then
		footer.notify("warn", "No reactions available for this provider")
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
		format_item = function(item) return item.label end,
	}, function(selected)
		if selected == nil then
			return
		end
		footer.notify("loading", "Adding reaction...")
		provider.add_reaction(pr, comment, selected.key, function(ok, err)
			if err then
				footer.notify("error", "Reaction failed: " .. tostring(err))
				return
			end
			if ok and type(state.comments) == "table" then
				for _, c in ipairs(state.comments) do
					if c.id == comment.id then
						c.reactions = c.reactions or {}
						c.reactions[selected.key] = (tonumber(c.reactions[selected.key]) or 0) + 1
						break
					end
				end
			end
			footer.notify("success", "Reaction added", 1200)
			refresh()
		end)
	end)
end

---@param refresh fun()
local function toggle_thread(refresh)
	local entry = cursor_entry()
	if not entry then
		return
	end
	local root = entry.thread_root or entry.comment
	if not root then
		return
	end
	state.toggle(root.id)
	refresh()
end

---@param key string|string[]|nil
---@return string|string[]|nil
local function single_or_list(key)
	if key == nil then
		return nil
	end
	if type(key) == "table" then
		return #key == 1 and key[1] or key
	end
	return key
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local items = {
		{
			key = { "a", "i" },
			desc = "Add comment",
			opts = { nowait = true, silent = true },
			callback = function() add_comment(refresh) end,
		},
		{
			key = "c",
			desc = "Reply to comment",
			opts = { nowait = true, silent = true },
			callback = function() reply_to_current(refresh) end,
		},
		{
			key = "e",
			desc = "Edit comment",
			opts = { nowait = true, silent = true },
			callback = function() edit_current(refresh) end,
		},
		{
			key = "d",
			desc = "Delete comment",
			opts = { nowait = true, silent = true },
			callback = function() delete_current(refresh) end,
		},
		{
			key = "gr",
			desc = "Add reaction",
			opts = { nowait = true, silent = true },
			callback = function() add_reaction(refresh) end,
		},
	}

	local fold_key = single_or_list(resolver.resolve("ui.toggle_fold"))
	if fold_key ~= nil then
		table.insert(items, {
			key = fold_key,
			desc = "Expand / collapse thread",
			opts = { nowait = true, silent = true },
			callback = function() toggle_thread(refresh) end,
		})
	end

	help.register("Panel", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {
		{ key = { "a", "i" } },
		{ key = "c" },
		{ key = "e" },
		{ key = "d" },
		{ key = "gr" },
	}
	local fold_key = single_or_list(resolver.resolve("ui.toggle_fold"))
	if fold_key ~= nil then
		table.insert(items, { key = fold_key })
	end
	help.remove("Panel", items, { buffer = buf })
end

return M
