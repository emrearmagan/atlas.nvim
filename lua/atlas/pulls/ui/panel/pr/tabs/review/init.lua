---@class PullsCommentsTab : PullsPanelTabModule
local M = {}

local md_editor = require("atlas.ui.popups.editor")
local footer = require("atlas.ui.components.footer")
local renderer = require("atlas.pulls.ui.panel.pr.tabs.review.renderer")
local state = require("atlas.pulls.ui.panel.pr.tabs.review.state")
local keymaps = require("atlas.pulls.ui.panel.pr.tabs.review.keymaps")

local AUTHOR_COMPLETION_MODULES = {
	github = "atlas.pulls.providers.github.completion.author",
	gitlab = "atlas.pulls.providers.gitlab.completion.author",
	bitbucket = "atlas.pulls.providers.bitbucket.completion.author",
}

---@return AtlasMarkdownCompletionProvider|nil
local function author_completion()
	local provider = require("atlas.pulls.state").provider
	local mod_path = provider and AUTHOR_COMPLETION_MODULES[provider.id]
	if not mod_path then
		return nil
	end
	local ok, mod = pcall(require, mod_path)
	if not ok or type(mod) ~= "table" or type(mod.build_completion) ~= "function" then
		return nil
	end
	return mod.build_completion()
end

---@type { cancel: fun() }[]
local in_flight = {}

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		handle.cancel()
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
end

---@param comment PullsComment|nil
---@return boolean
local function is_own_comment(comment)
	local current_user = require("atlas.pulls.state").current_user
	if not current_user or not comment or not comment.author then
		return false
	end
	local author_id = tostring(comment.author.id or "")
	local user_id = tostring(current_user.id or "")
	return author_id ~= "" and user_id ~= "" and author_id == user_id
end

---@param pr PullRequest
---@param opts { key: string, title: string, initial_text: string|nil, on_save: fun(text: string|nil) }
local function open_md_editor(pr, opts)
	md_editor.open({
		key = opts.key,
		title = opts.title,
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = opts.initial_text,
		completion = author_completion(),
		on_save = opts.on_save,
	})
end

-- -----------------------------------------------------------------------------
-- Lifecycle
-- -----------------------------------------------------------------------------

---@param pr PullRequest
---@param _repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, _repo, refresh, opts)
	cancel_all()
	state.reset()

	local provider = get_provider()
	if provider == nil or type(provider.fetch_comments) ~= "function" then
		state.comments = "Provider does not support comments"
		refresh()
		return
	end

	local pr_id = tostring(pr.id or "")
	state.comments = "loading"
	footer.notify("loading", string.format("Loading comments for #%s...", pr_id))

	track(provider.fetch_comments(pr, opts, function(comments, err)
		if err then
			state.comments = err
			footer.notify("error", string.format("Failed to load comments for #%s", pr_id))
		else
			state.comments = comments or {}
			footer.notify("success", string.format("Comments loaded for #%s", pr_id), 1200)
		end
		refresh()
	end))
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width)
	return renderer.render(pr, width, state.comments)
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	local k = entry.kind
	return k == "header"
		or k == "content"
		or k == "thread_header"
		or k == "thread_content"
		or k == "hunk_header"
		or k == "hunk_line"
		or k == "file_header"
end

---@param _pr PullRequest
---@param entry table
function M.on_enter(_pr, entry)
	if entry.kind == "hunk_header" and entry.hunk_key then
		state.collapsed_hunks[entry.hunk_key] = not (state.collapsed_hunks[entry.hunk_key] == true)
		return true
	end

	local comment = entry.comment
	if comment ~= nil and entry.entity_kind == "comment" then
		local url = tostring(comment.html_url or "")
		if url ~= "" then
			vim.ui.open(url)
		end
		return
	end
	local task = entry.task
	if task ~= nil and entry.entity_kind == "task" then
		local url = nil
		if task._raw and task._raw.links then
			url = tostring(task._raw.links.html or "")
		end
		if url and url ~= "" then
			vim.ui.open(url)
		end
	end
end

function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	keymaps.setup(buf, refresh)
end

function M.deactivate(buf)
	if buf ~= nil then
		keymaps.teardown(buf)
	end
	cancel_all()
end

---@param fn fun(comments: PullsComment[])
local function with_comments(fn)
	local list = state.comments
	if type(list) ~= "table" then
		return
	end
	---@cast list PullsComment[]
	fn(list)
end

---@param comment_id string|number
---@param updater fun(comment: PullsComment)
local function update_comment(comment_id, updater)
	with_comments(function(list)
		for _, c in ipairs(list) do
			if tostring(c.id) == tostring(comment_id) then
				updater(c)
				return
			end
		end
	end)
end

---@param comment_id string|number
local function remove_comment(comment_id)
	with_comments(function(list)
		for i = #list, 1, -1 do
			if tostring(list[i].id) == tostring(comment_id) then
				table.remove(list, i)
			end
		end
	end)
end

---@param comment PullsComment
local function append_comment(comment)
	with_comments(function(list)
		table.insert(list, comment)
	end)
end

---@param comment PullsComment
local function upsert_comment(comment)
	with_comments(function(list)
		for i, existing in ipairs(list) do
			if tostring(existing.id) == tostring(comment.id) then
				list[i] = comment
				return
			end
		end
		table.insert(list, comment)
	end)
end

-- -----------------------------------------------------------------------------
-- Actions
-- -----------------------------------------------------------------------------

---@param pr PullRequest
---@param refresh fun()
function M.add_comment(pr, refresh)
	local provider = get_provider()
	if not provider or type(provider.add_comment) ~= "function" then
		return
	end

	open_md_editor(pr, {
		key = "pr-comment-add",
		title = " Add Comment ",
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Adding comment...")
			track(provider.add_comment(pr, text, nil, function(comment, err)
				if err then
					footer.notify("error", "Add comment failed: " .. err)
					return
				end
				if comment then
					append_comment(comment)
				end
				footer.notify("success", "Comment added", 1200)
				refresh()
			end))
		end,
	})
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.reply_comment(pr, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.reply_comment) ~= "function" then
		return
	end

	local comment = entry.comment
	if not comment then
		return
	end

	local completion = author_completion()
	local mention = ""
	if completion and type(completion.format_mention) == "function" then
		mention = completion.format_mention(comment.author) or ""
	end
	local initial_text = mention ~= "" and (mention .. " ") or ""

	open_md_editor(pr, {
		key = "pr-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		initial_text = initial_text,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Sending reply...")
			track(provider.reply_comment(pr, comment, text, function(reply, err)
				if err then
					footer.notify("error", "Reply failed: " .. err)
					return
				end

				if reply then
					--- just in case you know
					if reply.parent_id == nil then
						reply.parent_id = comment.id
					end
					append_comment(reply)
				end
				footer.notify("success", "Reply added", 1200)
				refresh()
			end))
		end,
	})
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.edit_comment(pr, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.edit_comment) ~= "function" then
		return
	end
	local comment = entry.comment
	if not comment or not is_own_comment(comment) then
		return
	end

	open_md_editor(pr, {
		key = "pr-comment-edit-" .. tostring(comment.id),
		title = " Edit Comment ",
		initial_text = comment.content_raw or "",
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Editing comment...")
			local desired = vim.tbl_extend("force", {}, comment, { content_raw = text })
			track(provider.edit_comment(pr, desired, function(updated, err)
				if err then
					footer.notify("error", "Edit failed: " .. err)
					return
				end
				if updated then
					upsert_comment(updated)
				else
					update_comment(comment.id, function(c)
						c.content_raw = text
					end)
				end
				footer.notify("success", "Comment updated", 1200)
				refresh()
			end))
		end,
	})
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.delete_comment(pr, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.delete_comment) ~= "function" then
		return
	end
	local comment = entry.comment
	if not comment or not is_own_comment(comment) then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		footer.notify("loading", "Deleting comment...")
		track(provider.delete_comment(pr, comment, function(ok, err)
			if err then
				footer.notify("error", "Delete failed: " .. err)
				return
			end
			if ok then
				remove_comment(comment.id)
			end
			footer.notify("success", "Comment deleted", 1200)
			refresh()
		end))
	end)
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.toggle_task(pr, entry, refresh)
	local provider = get_provider()
	local comment = entry and entry.comment
	if comment == nil or not comment.is_task then
		footer.notify("warn", "Not a task")
		return
	end
	if not provider or type(provider.edit_comment) ~= "function" then
		footer.notify("error", "Provider does not support comment edits")
		return
	end

	local is_resolved = comment.state == "RESOLVED"
	local desired = vim.deepcopy(comment)
	if is_resolved then
		desired.state = nil
	else
		desired.state = "RESOLVED"
	end
	footer.notify("loading", is_resolved and "Reopening task..." or "Resolving task...")
	track(provider.edit_comment(pr, desired, function(updated, err)
		if err then
			footer.notify("error", tostring(err))
			return
		end
		if updated then
			upsert_comment(updated)
		else
			update_comment(comment.id, function(c)
				c.state = desired.state
			end)
		end
		footer.notify("success", is_resolved and "Task reopened" or "Task resolved", 1200)
		refresh()
	end))
end

---@param pr PullRequest
---@param refresh fun()
function M.add_task(pr, refresh)
	local provider = get_provider()
	if not provider or type(provider.add_comment) ~= "function" then
		footer.notify("error", "Provider does not support comments")
		return
	end

	local panel_state = require("atlas.pulls.ui.panel.pr.state")
	local win = require("atlas.ui.layout").win_id("detail")
	local parent = nil
	if win and vim.api.nvim_win_is_valid(win) then
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local ent = (panel_state.line_map or {})[lnum]
		if ent and ent.comment then
			parent = ent.comment
		end
	end

	local is_github = provider.id == "github"
	local initial = is_github and "- [ ] " or ""

	open_md_editor(pr, {
		key = "pr-task-add-" .. tostring(pr.id or ""),
		title = " Add Task ",
		initial_text = initial,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				footer.notify("warn", "Task cannot be empty")
				return
			end
			footer.notify("loading", "Adding task...")
			local opts = is_github and { parent = parent } or { parent = parent, is_task = true }
			track(provider.add_comment(pr, text, opts, function(_, err)
				if err then
					footer.notify("error", tostring(err))
					return
				end
				footer.notify("success", "Task added", 1200)
				refresh()
			end))
		end,
	})
end

return M
