local comment_threads = require("atlas.pulls.ui.components.comment_threads")
local icons = require("atlas.ui.shared.icons")
local note_renderer = require("atlas.pulls.notes.ui.renderer")
local presentation = require("atlas.pulls.ui.presentation")
local review_actions = require("atlas.pulls.actions.review")
local utils = require("atlas.ui.shared.utils")

local M = {}

local review_states = {
	approved = { label = "Approved", icon = "successful", section = "status" },
	changes_requested = { label = "Changes requested", icon = "failed", section = "status" },
	pending = { label = "Pending", icon = "inprogress", section = "status" },
	commented = { label = "Commented", icon = "comment" },
	dismissed = { label = "Dismissed", icon = "stopped", section = "status" },
	unapproved = { label = "Approval removed", icon = "stopped", section = "status" },
	reviewed = { label = "Reviewed", icon = "review" },
}

---@class AtlasDiffReviewPanelRow
---@field key string
---@field tree_key string|nil
---@field comment PullsComment|nil
---@field thread_root PullsComment|nil
---@field note AtlasNote|nil
---@field review_entry PullsReviewHistoryEntry|nil

---@class AtlasDiffReviewPanelItem
---@field key string
---@field thread AtlasCommentThreadNode|nil
---@field authors table<string, boolean>|nil
---@field note AtlasNote|nil
---@field author AtlasUser|nil
---@field decision PullsReviewHistoryState|nil
---@field history PullsReviewHistoryEntry[]|nil
---@field path string|nil
---@field line integer|nil
---@field timestamp string|nil

---@alias AtlasDiffReviewPanelFilter "all"|"unresolved"|"mine"

---@param node AtlasCommentThreadNode
---@return PullsComment[]
local function thread_comments(node)
	local comments = { node.comment }
	for _, child in ipairs(node.children) do
		vim.list_extend(comments, thread_comments(child))
	end
	return comments
end

---@param user AtlasUser|nil
---@return string[]
local function user_keys(user)
	local keys = {}
	if user and (user.id or "") ~= "" then
		table.insert(keys, "id:" .. user.id)
	end
	if user and (user.username or "") ~= "" then
		table.insert(keys, "username:" .. user.username)
	end
	return keys
end

---@param item AtlasDiffReviewPanelItem
---@param filter AtlasDiffReviewPanelFilter
---@param user AtlasUser|nil
---@return boolean
local function matches(item, filter, user)
	if filter == "all" then
		return true
	end
	if item.thread then
		if filter == "unresolved" then
			return item.thread.comment.state ~= "RESOLVED"
		end
		for _, key in ipairs(user_keys(user)) do
			if item.authors[key] then
				return true
			end
		end
		return false
	end
	if item.note then
		return filter == "mine" or not item.note.resolved
	end
	return false
end

---@param comment PullsComment
---@return string
local function comment_location(comment)
	local position = comment.file or comment.inline
	if not position then
		return ""
	end
	local path = vim.fs.basename(position.path)
	local inline = comment.inline
	local line = inline and (inline.to or inline.from)
	local first = inline and (inline.to and inline.start_to or inline.start_from)
	if first and line and first ~= line then
		return string.format("%s:%d-%d", path, first, line)
	end
	return line and string.format("%s:%d", path, line) or path
end

---@param session AtlasDiffSession
---@param filter AtlasDiffReviewPanelFilter
---@return table[]
local function sections(session, filter)
	local pending, reviews, tasks, comments, notes = {}, {}, {}, {}, {}
	local data = session.review
	if data then
		for _, thread in ipairs(review_actions.group_comments(data.comments, data.tasks)) do
			local comment = thread.comment
			local position = comment.file or comment.inline
			local authors, has_pending = {}, false
			for _, thread_comment in ipairs(thread_comments(thread)) do
				has_pending = has_pending or thread_comment.pending == true
				for _, key in ipairs(user_keys(thread_comment.author)) do
					authors[key] = true
				end
			end
			local items = comment.is_task and tasks or (has_pending and pending or comments)
			items[#items + 1] = {
				key = comment_threads.comment_key(comment),
				thread = thread,
				authors = authors,
				path = position and position.path or "",
				line = comment.inline and (comment.inline.to or comment.inline.from) or 0,
				timestamp = comment.created_at,
			}
		end

		local by_author = {}
		---@param author AtlasUser|nil
		---@param fallback string
		local function reviewer(author, fallback)
			local key = author and ((author.id or "") ~= "" and author.id or (author.username or ""):lower()) or ""
			key = key ~= "" and key or fallback
			if not by_author[key] then
				by_author[key] = { key = "reviewer:" .. key, author = author, history = {} }
				reviews[#reviews + 1] = by_author[key]
			end
			return by_author[key]
		end
		for index, author in ipairs(data.reviewers) do
			reviewer(author, "reviewer:" .. index).decision = author.decision
		end
		for index, entry in ipairs(data.history) do
			local item = reviewer(entry.author, "unknown:" .. (entry.id or index))
			item.history[#item.history + 1] = entry
		end
	end
	if session.notes then
		for _, note in ipairs(session.notes.items) do
			local position = session.notes.positions[note.id]
			notes[#notes + 1] = {
				key = note_renderer.note_key(session.notes.target, note),
				note = vim.tbl_extend("force", note, position),
				path = note.file_path,
				line = position.end_line,
				timestamp = note.updated_at or note.created_at,
			}
		end
	end
	for _, items in ipairs({ pending, tasks, comments, notes }) do
		table.sort(items, function(a, b)
			if a.path ~= b.path then
				return a.path < b.path
			end
			if a.line ~= b.line then
				return a.line < b.line
			end
			if a.timestamp ~= b.timestamp then
				return a.timestamp < b.timestamp
			end
			return a.key < b.key
		end)
	end
	---@param id string
	---@param title string
	---@param item_name string
	---@param items AtlasDiffReviewPanelItem[]
	---@return table
	local function section(id, title, item_name, items)
		return {
			id = id,
			title = title,
			item_name = item_name,
			total = #items,
			items = vim.tbl_filter(function(item)
				return matches(item, filter, session.current_user)
			end, items),
		}
	end

	return {
		section("pending", "Pending", "comment", pending),
		section("reviews", "Reviews", "reviewer", reviews),
		section("tasks", "Tasks", "task", tasks),
		section("comments", "Comments", "comment", comments),
		section("notes", "Notes", "note", notes),
	}
end

---@param entry PullsReviewHistoryEntry
---@param pr_head string|nil
---@return boolean
local function on_older_commit(entry, pr_head)
	return pr_head ~= nil and entry.commit_hash ~= nil and entry.commit_hash ~= pr_head
end

---@param item AtlasDiffReviewPanelItem
---@param width integer
---@param expanded boolean
---@param history_expanded boolean
---@param pr_head string|nil
---@param edit_key string|nil
---@return string[], table[], table<integer, AtlasDiffReviewPanelRow>
local function render_review(item, width, expanded, history_expanded, pr_head, edit_key)
	local lines, spans, line_map = {}, {}, {}
	local history = item.history or {}
	local decision = item.decision or history[#history].state
	local status = review_states[decision]
	local status_icon, status_hl = icons.get(status.icon, status.section)
	local author = item.author and (item.author.username or item.author.name) or "Unknown"

	local function add_line(chunks, entry)
		local text = ""
		for _, chunk in ipairs(chunks) do
			local start_col = #text
			text = text .. chunk[1]
			if chunk[2] and #text > start_col then
				spans[#spans + 1] = {
					line = #lines,
					start_col = start_col,
					end_col = #text,
					hl_group = chunk[2],
				}
			end
		end
		lines[#lines + 1] = text
		line_map[#lines] = entry
	end

	local previous = ""
	for index = #history, 1, -1 do
		if history[index].state == decision then
			previous = on_older_commit(history[index], pr_head) and "  previous commit" or ""
			break
		end
	end

	local fold, fold_hl = " ", nil
	if #history > 0 then
		fold, fold_hl = icons.get(expanded and "fold_open" or "fold_closed")
	end
	local user, user_hl = icons.get("user")
	local label = status_icon .. " " .. status.label
	local name_width = math.max(1, width - vim.fn.strdisplaywidth(fold .. " " .. user .. "   " .. label .. previous))
	add_line({
		{ fold, fold_hl },
		{ " " .. user .. " ", user_hl },
		{ utils.truncate(author, name_width), presentation.author_hl(author) },
		{ "  " .. label, status_hl },
		{ previous, "AtlasTextMuted" },
	}, { key = item.key, tree_key = #history > 0 and item.key or nil })

	if not expanded or #history == 0 then
		return lines, spans, line_map
	end

	local history_key = item.key .. ":history"
	local function add_review(index)
		local entry = history[index]
		local latest = index == #history
		local body = vim.trim((entry.body or ""):gsub("%s+", " "))
		local show_status = not latest or entry.state ~= item.decision or body == ""
		local entry_status = review_states[entry.state]
		local entry_icon, entry_hl = icons.get(entry_status.icon, entry_status.section)
		local prefix = show_status and entry_icon or ""
		if prefix ~= "" and body ~= "" then
			prefix = prefix .. "  "
		end
		local details = utils.relative_time(entry.submitted_on)
		if show_status and on_older_commit(entry, pr_head) then
			details = details .. "  previous commit"
		end

		local target = {
			key = "review:" .. (entry.id or item.key .. ":" .. index),
			tree_key = latest and item.key or history_key,
			review_entry = entry,
		}
		if not latest then
			local body_width = math.max(0, width - vim.fn.strdisplaywidth(prefix .. details) - 2)
			add_line({
				{ prefix, entry_hl },
				{ utils.truncate(body, body_width), "Normal" },
				{ "  " .. details, "AtlasTextMuted" },
			}, target)
			return
		end

		local indent = string.rep(" ", vim.fn.strdisplaywidth(prefix))
		for row, text in ipairs(utils.wrap_line(body, math.max(1, width - #indent))) do
			add_line({ { row == 1 and prefix or indent, entry_hl }, { text, "Normal" } }, target)
		end
		if vim.fn.strdisplaywidth(lines[#lines] .. "  " .. details) <= width then
			local start_col = #lines[#lines] + 2
			lines[#lines] = lines[#lines] .. "  " .. details
			spans[#spans + 1] = {
				line = #lines - 1,
				start_col = start_col,
				end_col = #lines[#lines],
				hl_group = "AtlasTextMuted",
			}
		else
			add_line({ { indent .. details, "AtlasTextMuted" } }, target)
		end
		if edit_key and entry.id and body ~= "" then
			add_line({ { edit_key .. " edit", "AtlasTextMuted" } }, target)
		end
	end

	add_review(#history)
	if #history > 1 then
		local icon, hl = icons.get(history_expanded and "fold_open" or "fold_closed")
		local count = #history - 1
		local history_label = string.format("%d earlier %s", count, count == 1 and "review" or "reviews")
		add_line({ { icon .. " ", hl }, { history_label, "AtlasTextMuted" } }, {
			key = history_key,
			tree_key = history_key,
		})
		if history_expanded then
			for index = #history - 1, 1, -1 do
				add_review(index)
			end
		end
	end

	return lines, spans, line_map
end

---@param session AtlasDiffSession
---@param filter AtlasDiffReviewPanelFilter
---@param width integer
---@param action_keys table<string, string|nil>
---@param expanded fun(key: string): boolean
---@return string[], table[], table<integer, AtlasDiffReviewPanelRow>
function M.render(session, filter, width, action_keys, expanded)
	local pr = session.source.pr
	local lines, spans, line_map = {}, {}, {}
	for _, section in ipairs(sections(session, filter)) do
		if #section.items > 0 then
			if #lines > 0 then
				lines[#lines + 1] = ""
			end
			local count = #section.items
			local name = section.total == 1 and section.item_name or section.item_name .. "s"
			local summary = count == section.total and string.format("%d %s", count, name)
				or string.format("%d of %d %s", count, section.total, name)
			lines[#lines + 1] = section.title .. "  " .. summary
			spans[#spans + 1] = {
				line = #lines - 1,
				start_col = #section.title + 2,
				end_col = #lines[#lines],
				hl_group = "AtlasTextMuted",
			}
			for index, item in ipairs(section.items) do
				local item_open = false
				if not item.history or #item.history > 0 then
					item_open = expanded(item.key)
				end
				local history_open = false
				if item.history and #item.history > 1 then
					history_open = expanded(item.key .. ":history")
				end
				local content, highlights, entries
				if item.thread then
					content, highlights, entries = comment_threads.render_compact(
						item.thread,
						width,
						item_open,
						comment_location(item.thread.comment),
						{
							action_keys = action_keys,
						}
					)
				elseif item.note then
					content, highlights, entries = note_renderer.render_list({
						{ target = session.notes.target, note = item.note, expanded = item_open },
					}, width, { action_keys = action_keys })
				else
					content, highlights, entries = render_review(
						item,
						width,
						item_open,
						history_open,
						pr and pr.source.commit_hash,
						action_keys.edit
					)
				end
				local offset = #lines
				utils.append_block(lines, spans, { lines = content, highlights = highlights })
				for row, entry in pairs(entries) do
					entry.key = entry.key or (entry.comment and comment_threads.comment_key(entry.comment)) or item.key
					entry.tree_key = entry.tree_key or (item.thread and item.key)
					line_map[offset + row] = entry
				end
				if item_open and index < #section.items then
					lines[#lines + 1] = ""
				end
			end
		end
	end
	if #lines == 0 then
		lines = { "No review items." }
	end
	return lines, spans, line_map
end

return M
