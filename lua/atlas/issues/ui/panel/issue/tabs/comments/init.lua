---@class IssuesCommentsTab : IssuesPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local spinner = require("atlas.ui.components.spinner")
local threads = require("atlas.ui.components.threadsv2")
local footer = require("atlas.ui.components.footer")
local md_editor = require("atlas.ui.popups.editor")
local state = require("atlas.issues.ui.panel.issue.tabs.comments.state")
local keymaps = require("atlas.issues.ui.panel.issue.tabs.comments.keymaps")

local PADDING_X = 1

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

---@return IssuesProvider|nil
local function get_provider()
	return require("atlas.issues.state").provider
end

---@param comment IssueComment
---@return boolean
local function is_own_comment(comment)
	local issues_state = require("atlas.issues.state")
	local current_user = issues_state.current_user
	if current_user == nil or comment.author == nil then
		return false
	end
	return tostring(comment.author.account_id or "") == tostring(current_user.account_id or "")
end

---@param comment IssueComment
---@return string
local function find_root_id(comment)
	if comment.parent_id == nil then
		return tostring(comment.id)
	end
	for _, c in ipairs(state.comments or {}) do
		if tostring(c.id) == tostring(comment.parent_id) then
			return find_root_id(c)
		end
	end
	return tostring(comment.parent_id)
end

---@param comments IssueComment[]
---@return IssueComment[]
local function build_comment_tree(comments)
	local by_id = {}
	for _, c in ipairs(comments) do
		c.children = {}
		by_id[tostring(c.id or "")] = c
	end

	local roots = {}
	for _, c in ipairs(comments) do
		if c.parent_id ~= nil then
			local parent = by_id[tostring(c.parent_id)]
			if parent ~= nil then
				table.insert(parent.children, c)
			else
				table.insert(roots, c)
			end
		else
			table.insert(roots, c)
		end
	end

	local function sort_children(list)
		for _, c in ipairs(list) do
			if #c.children > 0 then
				table.sort(c.children, function(a, b)
					local ac = tostring(a.created or "")
					local bc = tostring(b.created or "")
					if ac == bc then
						return tostring(a.id or "") < tostring(b.id or "")
					end
					return ac < bc
				end)
				sort_children(c.children)
			end
		end
	end

	sort_children(roots)
	return roots
end

---@return IssuesProviderPanel|nil
local function get_panel()
	local issues_state = require("atlas.issues.state")
	local provider = issues_state.provider
	return provider and provider.panel or nil
end

---@param body string
---@return string
local function resolve_body(body)
	local panel = get_panel()
	if panel and type(panel.resolve_comment_body) == "function" then
		return panel.resolve_comment_body(body)
	end
	return body
end

---@return AtlasMarkdownCompletionProvider|nil
local function get_completion()
	local panel = get_panel()
	if panel and type(panel.comment_completion) == "function" then
		return panel.comment_completion()
	end
	return nil
end

---@param comment IssueComment
---@return AtlasThreadV2Item
local function to_thread_item(comment)
	local author = comment.author and comment.author.display_name or "Unknown"
	local body = resolve_body(tostring(comment.body or ""))

	local footer_items = {
		string.format("%s (c)", icons.general("reply")),
	}
	if is_own_comment(comment) then
		table.insert(footer_items, string.format("%s (e)", icons.general("edit")))
		table.insert(footer_items, string.format("%s (d)", icons.general("delete")))
	end

	---@type AtlasThreadV2Item
	local item = {
		icon = icons.general("user"),
		author = author,
		right_text = utils.relative_time_text(comment.created),
		content = body ~= "" and body or nil,
		footer_items = footer_items,
		meta = { comment = comment },
		line_map = { kind = "comment", comment = comment },
	}

	if comment.children and #comment.children > 0 then
		item.children = {}
		for _, child in ipairs(comment.children) do
			table.insert(item.children, to_thread_item(child))
		end
	end

	return item
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	opts = opts or {}
	local provider = get_provider()
	if not provider or not provider.fetch_comments then
		return
	end

	local force_refresh = opts.force_refresh == true
	if not force_refresh and state.comments ~= nil then
		return
	end

	cancel_all()
	state.is_loading = true
	state.issue = issue

	local issue_key = tostring(issue.key or "")
	footer.notify("loading", string.format("Loading comments for %s...", issue_key))

	track(provider.fetch_comments(issue_key, { force_load = force_refresh }, function(comments, err)
		state.is_loading = false

		if err then
			state.comments = {}
			footer.notify("error", string.format("Failed to load comments for %s", issue_key))
		else
			state.comments = comments or {}
			footer.notify("success", string.format("Comments loaded for %s (%d)", issue_key, #state.comments), 1200)
		end

		refresh()
	end))
end

---@param issue Issue
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(issue, width)
	local lines = {}
	local spans = {}

	local count_text = state.comments and tostring(#state.comments) or "..."
	utils.push(lines, spans, string.format("Comments (%s)", count_text), "AtlasColumnHeader", PADDING_X)

	if state.is_loading then
		utils.push(lines, spans, spinner.with_text("Loading comments..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end

	if not state.comments or #state.comments == 0 then
		utils.push(lines, spans, "No comments.", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end

	local roots = build_comment_tree(state.comments)
	local thread_items = {}
	for _, comment in ipairs(roots) do
		table.insert(thread_items, to_thread_item(comment))
	end

	local t_lines, t_spans, t_line_map = threads.render(thread_items, width, {
		padding_x = PADDING_X,
		mode = "tree",
		author_hl = function(_, author)
			return highlights.dynamic_for(author)
		end,
		icon_hl_fn = function(item)
			return highlights.dynamic_for(tostring(item.author or ""))
		end,
	})

	utils.append_block(lines, spans, { lines = t_lines, highlights = t_spans })

	local line_map = {}
	for lnum, entry in pairs(t_line_map or {}) do
		line_map[#lines - #t_lines + lnum] = entry
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "comment"
end

---@param issue Issue
---@param entry table
---@return boolean|nil
function M.on_enter(issue, entry)
	if entry.kind == "comment" and entry.comment then
		local url = entry.comment.url
		if url and url ~= "" then
			vim.ui.open(url)
			return true
		end
	end
end

---@param issue Issue
---@param refresh fun()
function M.add_comment(issue, refresh)
	local provider = get_provider()
	if not provider or type(provider.add_comment) ~= "function" then
		return
	end

	local issue_key = tostring(issue.key or "")
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
			footer.notify("loading", "Adding comment...")
			track(provider.add_comment(issue_key, text, function(comment, err)
				if err then
					footer.notify("error", "Add comment failed: " .. err)
					return
				end
				if type(comment) == "table" and type(state.comments) == "table" then
					table.insert(state.comments, comment)
				end
				footer.notify("success", "Comment added", 1200)
				refresh()
			end))
		end,
	})
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.reply_comment(issue, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.reply_comment) ~= "function" then
		return
	end

	local comment = entry.comment
	if not comment then
		return
	end

	local issue_key = tostring(issue.key or "")
	local parent_id = find_root_id(comment)

	md_editor.open({
		key = "issue-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		completion = get_completion(),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Sending reply...")
			track(provider.reply_comment(issue_key, parent_id, text, function(reply, err)
				if err then
					footer.notify("error", "Reply failed: " .. err)
					return
				end
				if type(reply) == "table" and type(state.comments) == "table" then
					table.insert(state.comments, reply)
				end
				footer.notify("success", "Reply added", 1200)
				refresh()
			end))
		end,
	})
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.edit_comment(issue, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.edit_comment) ~= "function" then
		return
	end

	local comment = entry.comment
	if not comment or not is_own_comment(comment) then
		return
	end

	local issue_key = tostring(issue.key or "")

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
			footer.notify("loading", "Editing comment...")
			track(provider.edit_comment(issue_key, tostring(comment.id), text, function(updated, err)
				if err then
					footer.notify("error", "Edit failed: " .. err)
					return
				end
				if type(state.comments) == "table" then
					for i, c in ipairs(state.comments) do
						if tostring(c.id) == tostring(comment.id) then
							if type(updated) == "table" then
								state.comments[i] = updated
							else
								state.comments[i].body = text
							end
							break
						end
					end
				end
				footer.notify("success", "Comment updated", 1200)
				refresh()
			end))
		end,
	})
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.delete_comment(issue, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.delete_comment) ~= "function" then
		return
	end

	local comment = entry.comment
	if not comment or not is_own_comment(comment) then
		return
	end

	local issue_key = tostring(issue.key or "")

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		footer.notify("loading", "Deleting comment...")
		track(provider.delete_comment(issue_key, tostring(comment.id), function(ok, err)
			if err then
				footer.notify("error", "Delete failed: " .. err)
				return
			end
			if ok and type(state.comments) == "table" then
				for i, c in ipairs(state.comments) do
					if tostring(c.id) == tostring(comment.id) then
						table.remove(state.comments, i)
						break
					end
				end
			end
			footer.notify("success", "Comment deleted", 1200)
			refresh()
		end))
	end)
end

---@param buf integer|nil
---@param refresh fun()|nil
function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	keymaps.setup(buf, refresh)
end

---@param buf integer|nil
function M.deactivate(buf)
	if buf ~= nil then
		keymaps.teardown(buf)
	end
	cancel_all()
	if state.is_loading then
		state.is_loading = false
		footer.notify("info", "", 0)
	end
end

return M
