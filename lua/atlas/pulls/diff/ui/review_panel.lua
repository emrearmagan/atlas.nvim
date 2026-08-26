local M = {}

local comments = require("atlas.pulls.diff.comments")
local config = require("atlas.config")
local help = require("atlas.ui.popups.help")
local highlights = require("atlas.ui.shared.highlights")
local icons = require("atlas.ui.shared.icons")
local keymap_resolver = require("atlas.core.keymaps")
local note_renderer = require("atlas.pulls.notes.ui.renderer")
local notes = require("atlas.pulls.diff.notes")
local review = require("atlas.pulls.diff.review")
local review_actions = require("atlas.pulls.actions.review")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local utils = require("atlas.ui.shared.utils")
local namespace = vim.api.nvim_create_namespace("atlas_diff_review_panel")

---@return integer
local function panel_height()
	local diff_config = (config.options.pulls or {}).diff or {}
	local panel_config = diff_config.review_panel or {}
	local height = math.max(4, math.floor(tonumber(panel_config.height) or 10))
	return math.min(height, math.max(4, vim.o.lines - 8))
end

---@param action AtlasKeymapActionId
---@return string|nil
local function key_label(action)
	local keys = keymap_resolver.resolve(action)
	return keys and table.concat(keys, " / ") or nil
end

---@param comment PullsComment
---@return string
local function comment_location(comment)
	local position = comment.file or comment.inline
	if not position then
		return ""
	end
	local inline = comment.inline
	local path = position.path:match("([^/\\]+)$") or position.path
	local line = inline and (inline.to or inline.from) or nil
	local start_line = inline and (inline.to and inline.start_to or inline.start_from) or nil
	if line and start_line and line ~= start_line then
		return string.format("%s:%d-%d", path, start_line, line)
	end
	return line and string.format("%s:%d", path, line) or path
end

---@class AtlasDiffReviewPanelData
---@field comments PullsComment[]
---@field tasks PullsComment[]
---@field reviewers PullsReviewer[]
---@field history PullsReviewHistoryEntry[]
---@field notes AtlasNote[]
---@field note_target AtlasNoteTarget|nil

---@class AtlasDiffReviewPanel
---@field buf integer
---@field win integer|nil
---@field line_map table<integer, table>
---@field session AtlasDiffSession
---@field expanded_items table<string, boolean>
---@field expanded_sections table<string, boolean>

---@param session AtlasDiffSession
---@return AtlasDiffReviewPanelData
local function panel_data(session)
	local review_state = session.review and session.review.data
	return {
		comments = review_state and review_state.comments or {},
		tasks = review_state and review_state.tasks or {},
		reviewers = review_state and review_state.reviewers or {},
		history = review_state and review_state.history or {},
		notes = session.notes or {},
		note_target = session.note_target,
	}
end

---@param buf integer
---@param win integer|nil
---@param session AtlasDiffSession
---@return AtlasDiffReviewPanel
function M.new(buf, win, session)
	return {
		buf = buf,
		win = win,
		line_map = {},
		session = session,
		expanded_items = {},
		expanded_sections = {
			reviews = true,
			pending = true,
			comments = true,
			tasks = true,
			notes = false,
		},
	}
end

---@param author PullsAuthor
---@return string
local function reviewer_key(author)
	return author.id ~= "" and author.id or author.username:lower()
end

---@param author PullsAuthor|nil
---@return string
local function reviewer_name(author)
	return author and (author.nickname or author.name) or "Unknown"
end

---@param name string
---@return string
local function reviewer_hl(name)
	local normalized = vim.trim(name):lower()
	if normalized == "" or normalized == "unknown" or normalized == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(normalized) or "AtlasTextMuted"
end

---@param state PullsReviewHistoryState|"pending"
---@return string icon, string label, string hl_group
local function review_state(state)
	if state == "approved" then
		local icon, hl = icons.pulls_status("successful")
		return icon, "Approved", hl
	end
	if state == "changes_requested" then
		local icon, hl = icons.pulls_status("failed")
		return icon, "Changes requested", hl
	end
	if state == "pending" then
		local icon, hl = icons.pulls_status("inprogress")
		return icon, "Pending", hl
	end
	if state == "commented" then
		local icon, hl = icons.general("comment")
		return icon, "Commented", hl
	end
	if state == "dismissed" then
		local icon, hl = icons.pulls_status("stopped")
		return icon, "Dismissed", hl
	end
	if state == "unapproved" then
		local icon, hl = icons.pulls_status("stopped")
		return icon, "Approval removed", hl
	end
	local icon, hl = icons.pulls("review")
	return icon, "Reviewed", hl
end

---@param data AtlasDiffReviewPanelData
---@return table[]
local function reviewer_items(data)
	local items, by_author = {}, {}
	for _, reviewer in ipairs(data.reviewers) do
		local key = reviewer_key(reviewer)
		local item = {
			kind = "reviewer",
			key = "reviewer:" .. key,
			author = reviewer,
			reviewer = reviewer,
			history = {},
		}
		by_author[key] = item
		table.insert(items, item)
	end
	for index, entry in ipairs(data.history) do
		local key = entry.author and reviewer_key(entry.author) or "unknown:" .. tostring(entry.id or index)
		local item = by_author[key]
		if item == nil then
			item = {
				kind = "reviewer",
				key = "reviewer:" .. key,
				author = entry.author,
				history = {},
			}
			by_author[key] = item
			table.insert(items, item)
		end
		table.insert(item.history, entry)
	end
	local pending, visible, awaiting = {}, {}, {}
	for _, item in ipairs(items) do
		if item.reviewer and item.reviewer.decision == "pending" and #item.history == 0 then
			table.insert(awaiting, item)
		elseif item.reviewer and item.reviewer.decision == "pending" then
			table.insert(pending, item)
		else
			table.insert(visible, item)
		end
	end
	if #awaiting == 1 then
		table.insert(pending, 1, awaiting[1])
	elseif #awaiting > 1 then
		table.insert(pending, 1, {
			kind = "awaiting_reviewers",
			key = "reviewers:awaiting",
			reviewers = awaiting,
			history = {},
		})
	end
	vim.list_extend(pending, visible)
	return pending
end

---@param item table
---@param width integer
---@param expanded boolean
---@return string[], table[], table<integer, table>
local function render_awaiting_reviewers(item, width, expanded)
	local lines, spans, line_map = {}, {}, {}
	local expander, expander_hl = icons.general(expanded and "fold_open" or "fold_closed")
	local label = string.format("%d awaiting review", #item.reviewers)
	table.insert(lines, expander .. " " .. label)
	table.insert(spans, {
		line = 0,
		start_col = 0,
		end_col = #expander,
		hl_group = expander_hl,
	})
	table.insert(spans, {
		line = 0,
		start_col = #expander + 1,
		end_col = #lines[1],
		hl_group = "AtlasTextMuted",
	})
	line_map[1] = { reviewer_group = item, tree_key = item.key }
	if expanded then
		local user_icon, user_hl = icons.general("user")
		for _, reviewer in ipairs(item.reviewers) do
			local prefix = "  " .. user_icon .. " "
			local full_name = reviewer_name(reviewer.author)
			local name = utils.truncate(full_name, math.max(1, width - vim.api.nvim_strwidth(prefix)))
			table.insert(lines, prefix .. name)
			table.insert(spans, {
				line = #lines - 1,
				start_col = 2,
				end_col = 2 + #user_icon,
				hl_group = user_hl,
			})
			table.insert(spans, {
				line = #lines - 1,
				start_col = #prefix,
				end_col = #lines[#lines],
				hl_group = reviewer_hl(full_name),
			})
			line_map[#lines] = { reviewer_group = item, tree_key = item.key }
		end
	end
	return lines, spans, line_map
end

---@param items table[]
---@return integer
local function reviewer_count(items)
	local count = 0
	for _, item in ipairs(items) do
		count = count + (item.kind == "awaiting_reviewers" and #item.reviewers or 1)
	end
	return count
end

---@param item table
---@param width integer
---@param expanded boolean
---@param history_expanded boolean
---@param head_revision string|nil
---@return string[], table[], table<integer, table>
local function render_reviewer(item, width, expanded, history_expanded, head_revision, edit_key)
	local lines, spans, line_map = {}, {}, {}
	local history = item.history
	local expander, expander_hl = " ", nil
	if #history > 0 then
		expander, expander_hl = icons.general(expanded and "fold_open" or "fold_closed")
	end
	local user_icon, user_hl = icons.general("user")
	local state_icon, state_label, state_hl
	if item.reviewer then
		state_icon, state_label, state_hl = review_state(item.reviewer.decision)
	else
		state_icon, state_label, state_hl = review_state(history[#history].state)
	end
	local is_previous = false
	if item.reviewer and item.reviewer.decision ~= "pending" then
		for index = #history, 1, -1 do
			local entry = history[index]
			if entry.state == item.reviewer.decision then
				is_previous = entry.commit_hash and head_revision and entry.commit_hash ~= head_revision
				break
			end
		end
	end
	local previous_text = is_previous and "  previous commit" or ""
	local reviewer_prefix = expander .. " " .. user_icon .. " "
	local suffix = state_icon .. " " .. state_label .. previous_text
	local name_width = math.max(1, width - vim.api.nvim_strwidth(reviewer_prefix) - vim.api.nvim_strwidth(suffix) - 2)
	local name = utils.truncate(reviewer_name(item.author), name_width)
	local line = ""
	local marks = {}
	local function add(text, hl)
		local start_col = #line
		line = line .. text
		if hl then
			table.insert(marks, { start_col, #line, hl })
		end
	end
	add(expander, expander_hl)
	add(" ")
	add(user_icon, user_hl)
	add(" ")
	add(name, reviewer_hl(reviewer_name(item.author)))
	add("  ")
	add(state_icon .. " " .. state_label, state_hl)
	add(previous_text, "AtlasTextMuted")
	table.insert(lines, line)
	for _, mark in ipairs(marks) do
		table.insert(spans, { line = 0, start_col = mark[1], end_col = mark[2], hl_group = mark[3] })
	end
	line_map[1] = {
		reviewer = item,
		tree_key = #history > 0 and item.key or nil,
	}

	local function render_history_entry(entry, key, show_status, full_body)
		local icon, _, hl = review_state(entry.state)
		local status = show_status and icon or ""
		local details = utils.relative_time(entry.submitted_on)
		local is_previous_entry = show_status
			and entry.commit_hash
			and head_revision
			and entry.commit_hash ~= head_revision
		if is_previous_entry then
			details = details ~= "" and details .. "  previous commit" or "previous commit"
		end
		local body = entry.body and vim.trim(entry.body:gsub("%s+", " ")) or ""
		if full_body and body ~= "" then
			local body_prefix = status ~= "" and (status .. "  ") or ""
			local continuation = string.rep(" ", vim.api.nvim_strwidth(body_prefix))
			for index, row in ipairs(utils.wrap_line(body, math.max(1, width - vim.api.nvim_strwidth(body_prefix)))) do
				local text = (index == 1 and body_prefix or continuation) .. row
				table.insert(lines, text)
				line_map[#lines] = { reviewer = item, review_history = entry, tree_key = key }
				if index == 1 and status ~= "" then
					table.insert(spans, {
						line = #lines - 1,
						start_col = 0,
						end_col = #status,
						hl_group = hl,
					})
				end
			end
			if details ~= "" then
				if vim.api.nvim_strwidth(lines[#lines]) + vim.api.nvim_strwidth(details) + 2 <= width then
					local start_col = #lines[#lines] + 2
					lines[#lines] = lines[#lines] .. "  " .. details
					table.insert(spans, {
						line = #lines - 1,
						start_col = start_col,
						end_col = #lines[#lines],
						hl_group = "AtlasTextMuted",
					})
				else
					table.insert(lines, continuation .. details)
					line_map[#lines] = { reviewer = item, review_history = entry, tree_key = key }
					table.insert(spans, {
						line = #lines - 1,
						start_col = #continuation,
						end_col = #lines[#lines],
						hl_group = "AtlasTextMuted",
					})
				end
			end
			return
		end
		local separators = (status ~= "" and body ~= "" and 2 or 0)
			+ (details ~= "" and (status ~= "" or body ~= "") and 2 or 0)
		local body_width =
			math.max(0, width - vim.api.nvim_strwidth(status) - vim.api.nvim_strwidth(details) - separators)
		body = utils.truncate(body, body_width)
		local text = status
		if body ~= "" then
			text = text .. (status ~= "" and "  " or "") .. body
		end
		if details ~= "" then
			text = text .. ((status ~= "" or body ~= "") and "  " or "") .. details
		end
		table.insert(lines, text)
		line_map[#lines] = { reviewer = item, review_history = entry, tree_key = key }
		if status ~= "" then
			table.insert(spans, {
				line = #lines - 1,
				start_col = 0,
				end_col = #status,
				hl_group = hl,
			})
		end
		if details ~= "" then
			table.insert(spans, {
				line = #lines - 1,
				start_col = #text - #details,
				end_col = #text,
				hl_group = "AtlasTextMuted",
			})
		end
	end

	if expanded and #history > 0 then
		local latest = history[#history]
		local has_body = vim.trim(latest.body or "") ~= ""
		local show_status = not item.reviewer or latest.state ~= item.reviewer.decision or not has_body
		render_history_entry(latest, item.key, show_status, true)
		if edit_key and latest.id and has_body then
			local footer = edit_key .. " edit"
			table.insert(lines, footer)
			line_map[#lines] = { reviewer = item, review_history = latest, tree_key = item.key }
			table.insert(spans, {
				line = #lines - 1,
				start_col = 0,
				end_col = #footer,
				hl_group = "AtlasTextMuted",
			})
		end
		if #history > 1 then
			local history_key = item.key .. ":history"
			local history_icon, history_hl = icons.general(history_expanded and "fold_open" or "fold_closed")
			local older = #history - 1
			local history_label = string.format("%d earlier %s", older, older == 1 and "review" or "reviews")
			local history_line = history_icon .. " " .. history_label
			table.insert(lines, history_line)
			line_map[#lines] = { reviewer = item, tree_key = history_key }
			table.insert(spans, {
				line = #lines - 1,
				start_col = 0,
				end_col = #history_icon,
				hl_group = history_hl,
			})
			table.insert(spans, {
				line = #lines - 1,
				start_col = #history_icon + 1,
				end_col = #history_line,
				hl_group = "AtlasTextMuted",
			})
			if history_expanded then
				for index = #history - 1, 1, -1 do
					render_history_entry(history[index], history_key, true)
				end
			end
		end
	end

	return lines, spans, line_map
end

---@param name string
---@param session AtlasDiffSession
---@return AtlasDiffReviewPanel
function M.create(name, session)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, name)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].buflisted = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	return M.new(buf, nil, session)
end

---@param panel AtlasDiffReviewPanel|nil
---@return boolean
local function active(panel)
	return panel ~= nil
		and panel.win ~= nil
		and vim.api.nvim_buf_is_valid(panel.buf)
		and vim.api.nvim_win_is_valid(panel.win)
end

---@param panel AtlasDiffReviewPanel|nil
function M.configure(panel)
	if not active(panel) then
		return
	end
	vim.bo[panel.buf].filetype = "atlas.review"
	vim.bo[panel.buf].syntax = "OFF"
	pcall(vim.treesitter.stop, panel.buf)
	vim.wo[panel.win].cursorline = true
	vim.wo[panel.win].list = false
	vim.wo[panel.win].number = false
	vim.wo[panel.win].relativenumber = false
	vim.wo[panel.win].signcolumn = "no"
	vim.wo[panel.win].statuscolumn = ""
	vim.wo[panel.win].spell = false
	vim.wo[panel.win].wrap = false
	vim.wo[panel.win].foldenable = false
	vim.wo[panel.win].winfixheight = true
	vim.wo[panel.win].winbar = " Atlas Review"
	vim.api.nvim_win_call(panel.win, function()
		vim.cmd("wincmd J")
	end)
	vim.api.nvim_win_set_height(panel.win, panel_height())
end

---@param panel AtlasDiffReviewPanel
---@param anchor integer
---@param focus boolean
---@return integer|nil
function M.open(panel, anchor, focus)
	if active(panel) then
		if focus then
			vim.api.nvim_set_current_win(panel.win)
		end
		return panel.win
	end
	if not vim.api.nvim_win_is_valid(anchor) then
		return nil
	end
	panel.win = vim.api.nvim_open_win(panel.buf, false, { split = "below", win = anchor, height = panel_height() })
	M.configure(panel)
	M.render(panel)
	if focus then
		vim.api.nvim_set_current_win(panel.win)
	end
	return panel.win
end

---@param panel AtlasDiffReviewPanel|nil
function M.close(panel)
	if not panel then
		return
	end
	local win = panel.win
	panel.win = nil
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

---@param panel AtlasDiffReviewPanel|nil
function M.delete(panel)
	if not panel then
		return
	end
	M.close(panel)
	if vim.api.nvim_buf_is_valid(panel.buf) then
		vim.api.nvim_buf_delete(panel.buf, { force = true })
	end
end

---@param panel AtlasDiffReviewPanel
---@return table|nil
local function selected_entry(panel)
	if not active(panel) then
		return nil
	end
	return panel.line_map[vim.api.nvim_win_get_cursor(panel.win)[1]]
end

---@param entry table|nil
---@return string|nil
local function tree_key(entry)
	if not entry then
		return nil
	end
	local root = entry.thread_root or entry.comment
	return entry.tree_key or (root and review_threads.comment_key(root)) or nil
end

---@param thread AtlasReviewThreadNode
---@return boolean
local function has_pending(thread)
	if thread.comment.state == "PENDING" then
		return true
	end
	for _, child in ipairs(thread.children) do
		if has_pending(child) then
			return true
		end
	end
	return false
end

---@param data AtlasDiffReviewPanelData
---@return table[], table[], table[], table[], table[]
local function panel_items(data)
	local pending, published_comments, standalone_tasks, rendered_notes = {}, {}, {}, {}
	for _, thread in ipairs(review_threads.group_comments(data.comments, data.tasks)) do
		local position = thread.comment.file or thread.comment.inline
		table.insert(has_pending(thread) and pending or published_comments, {
			kind = "comment",
			thread = thread,
			key = review_threads.comment_key(thread.comment),
			path = position and position.path or "",
			line = thread.comment.inline and (thread.comment.inline.to or thread.comment.inline.from) or 0,
			timestamp = tostring(thread.comment.created_on or ""),
		})
	end
	local comment_ids = {}
	for _, comment in ipairs(data.comments) do
		comment_ids[tostring(comment.id)] = true
	end
	for _, task in ipairs(data.tasks) do
		if not task.parent_id or not comment_ids[tostring(task.parent_id)] then
			local position = task.file or task.inline
			table.insert(standalone_tasks, {
				kind = "task",
				thread = { comment = task, children = {} },
				key = review_threads.comment_key(task),
				path = position and position.path or "",
				line = task.inline and (task.inline.to or task.inline.from) or 0,
				timestamp = tostring(task.created_on or ""),
			})
		end
	end
	if data.note_target then
		for _, note in ipairs(data.notes) do
			table.insert(rendered_notes, {
				kind = "note",
				note = note,
				key = note_renderer.note_key(data.note_target, note),
				path = note.file_path,
				line = note.line,
				timestamp = tostring(note.updated_at or note.created_at or ""),
			})
		end
	end
	local function sort_items(left, right)
		if left.path ~= right.path then
			return left.path < right.path
		end
		if left.line ~= right.line then
			return left.line < right.line
		end
		if left.timestamp ~= right.timestamp then
			return left.timestamp < right.timestamp
		end
		return left.key < right.key
	end
	table.sort(pending, sort_items)
	table.sort(published_comments, sort_items)
	table.sort(standalone_tasks, sort_items)
	table.sort(rendered_notes, sort_items)
	return reviewer_items(data), pending, published_comments, standalone_tasks, rendered_notes
end

---@param panel AtlasDiffReviewPanel|nil
---@param session AtlasDiffSession|nil
function M.render(panel, session)
	if not panel then
		return
	end
	if session then
		panel.session = session
	end
	if not active(panel) or not panel.session then
		return
	end

	local data = panel_data(panel.session)
	local selected = tree_key(selected_entry(panel))
	local cursor = vim.api.nvim_win_get_cursor(panel.win)
	local width = math.max(6, vim.api.nvim_win_get_width(panel.win))
	local lines, spans, line_map = {}, {}, {}
	local reviewers, pending_comments, published_comments, standalone_tasks, rendered_notes = panel_items(data)
	local published, pending = 0, 0
	for _, items in ipairs({ data.comments, data.tasks }) do
		for _, item in ipairs(items) do
			if item.state == "PENDING" then
				pending = pending + 1
			elseif not item.is_task then
				published = published + 1
			end
		end
	end
	local comment_icon = icons.general("comment")
	local task_icon = icons.pulls("tasks")
	local note_icon = icons.general("pin")
	local pending_icon = icons.pulls_status("inprogress")
	local comment_action_keys = {
		reply = key_label("pulls.review.diff.add_comment"),
		edit = key_label("ui.comments.edit"),
		delete = key_label("ui.delete"),
		toggle_resolved = key_label("pulls.review.diff.toggle_resolved"),
	}
	local task_capability = panel.session.review and panel.session.review.provider.capabilities.tasks
	local task_action_keys = {
		edit = task_capability and task_capability.edit_task and comment_action_keys.edit or nil,
		delete = task_capability and task_capability.delete_task and comment_action_keys.delete or nil,
		toggle_resolved = task_capability and task_capability.edit_task and comment_action_keys.toggle_resolved or nil,
	}
	local review_capability = panel.session.review and panel.session.review.provider.capabilities.reviews
	local review_edit_key = review_capability and review_capability.edit_review and comment_action_keys.edit or nil
	local note_action_keys = {
		edit = key_label("ui.comments.edit"),
		delete = key_label("ui.delete"),
	}
	local winbar = string.format(
		" Atlas Review %%=%s Comments: %d   %s Tasks: %d   %s Notes: %d",
		comment_icon,
		published,
		task_icon,
		#data.tasks,
		note_icon,
		#data.notes
	)
	if pending > 0 then
		winbar = winbar .. string.format("   %s Pending: %d", pending_icon, pending)
	end
	vim.wo[panel.win].winbar = winbar .. " "
	local sections = {
		{ id = "pending", title = "Pending", item_name = "comment", items = pending_comments },
		{
			id = "reviews",
			title = "Reviews",
			item_name = "reviewer",
			items = reviewers,
			count = reviewer_count(reviewers),
		},
		{ id = "tasks", title = "Tasks", item_name = "task", items = standalone_tasks },
		{ id = "comments", title = "Comments", item_name = "comment", items = published_comments },
		{ id = "notes", title = "Notes", item_name = "note", items = rendered_notes },
	}
	for _, section in ipairs(sections) do
		if #section.items > 0 then
			if #lines > 0 then
				table.insert(lines, "")
			end
			local expanded = panel.expanded_sections[section.id] == true
			local expander, expander_hl = icons.general(expanded and "fold_open" or "fold_closed")
			local header = string.format("%s %s", expander, section.title)
			local count_start = #header + 2
			local count = section.count or #section.items
			local item_name = count == 1 and section.item_name or section.item_name .. "s"
			header = string.format("%s  %d %s", header, count, item_name)
			table.insert(lines, header)
			line_map[#lines] = { section = section.id, tree_key = "section:" .. section.id }
			table.insert(spans, {
				line = #lines - 1,
				start_col = 0,
				end_col = #expander,
				hl_group = expander_hl,
			})
			table.insert(spans, {
				line = #lines - 1,
				start_col = count_start,
				end_col = #header,
				hl_group = "AtlasTextMuted",
			})
			if expanded then
				for index, item in ipairs(section.items) do
					if section.id == "pending" and panel.expanded_items[item.key] == nil then
						panel.expanded_items[item.key] = true
					end
					local item_expanded = panel.expanded_items[item.key] == true
					local block_lines, block_spans, block_map = {}, {}, {}
					if item.kind == "awaiting_reviewers" then
						block_lines, block_spans, block_map = render_awaiting_reviewers(item, width, item_expanded)
					elseif item.kind == "reviewer" then
						block_lines, block_spans, block_map = render_reviewer(
							item,
							width,
							item_expanded,
							panel.expanded_items[item.key .. ":history"] == true,
							panel.session.source.head_revision,
							review_edit_key
						)
					elseif item.kind ~= "note" then
						block_lines, block_spans, block_map = review_threads.render_compact(
							item.thread,
							width,
							item_expanded,
							comment_location(item.thread.comment),
							{
								action_keys = item.kind == "task" and task_action_keys or comment_action_keys,
								toggle_resolved_key = item.kind == "task" and task_action_keys.toggle_resolved or nil,
							}
						)
					else
						block_lines, block_spans, block_map = note_renderer.render_list({
							{
								target = data.note_target,
								note = item.note,
								expanded = item_expanded,
							},
						}, width, { action_keys = note_action_keys })
					end
					local offset = #lines
					utils.append_block(lines, spans, { lines = block_lines, highlights = block_spans })
					for line, entry in pairs(block_map) do
						line_map[offset + line] = entry
					end
					if item_expanded and index < #section.items then
						table.insert(lines, "")
					end
				end
			end
		end
	end
	if #lines == 0 then
		lines = { "No review items." }
	end

	vim.bo[panel.buf].modifiable = true
	vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
	vim.bo[panel.buf].modifiable = false
	panel.line_map = line_map
	vim.api.nvim_buf_clear_namespace(panel.buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(panel.buf, namespace, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	if selected then
		for line = 1, #lines do
			if tree_key(line_map[line]) == selected then
				vim.api.nvim_win_set_cursor(panel.win, { line, 0 })
				return
			end
		end
	end
	vim.api.nvim_win_set_cursor(panel.win, { math.min(cursor[1], #lines), 0 })
end

---@param entries table[]
---@param action AtlasKeymapActionId|AtlasKeymapActionId[]
---@param desc string
---@param index integer
---@param callback fun()
local function add_mapping(entries, action, desc, index, callback)
	local keys = {}
	for _, action_id in ipairs(type(action) == "table" and action or { action }) do
		vim.list_extend(keys, keymap_resolver.resolve(action_id) or {})
	end
	if #keys > 0 then
		table.insert(entries, {
			key = #keys == 1 and keys[1] or keys,
			desc = desc,
			index = index,
			callback = callback,
			opts = { nowait = true, silent = true },
		})
	end
end

---@param panel AtlasDiffReviewPanel|nil
---@return AtlasDiffSession|nil
local function active_session(panel)
	local session = panel and panel.session or nil
	return session and not session.closed and session or nil
end

---@param panel AtlasDiffReviewPanel
---@param buffers integer[]
function M.register_toggle(panel, buffers)
	local entries = {}
	add_mapping(entries, "pulls.review.diff.toggle_review_panel", "Toggle review panel", 5, function()
		local session = active_session(panel)
		if session and session.toggle_review_panel then
			session.toggle_review_panel(true)
		end
	end)
	for _, buf in ipairs(buffers) do
		if vim.api.nvim_buf_is_valid(buf) then
			help.register("General", entries, { buffer = buf, index = 90 })
		end
	end
end

---@param panel AtlasDiffReviewPanel|nil
function M.register_keymaps(panel)
	if not panel then
		return
	end
	local function toggle_selected()
		local entry = selected_entry(panel)
		if entry and entry.section then
			panel.expanded_sections[entry.section] = not panel.expanded_sections[entry.section]
			M.render(panel)
			return
		end
		local key = tree_key(entry)
		if key then
			panel.expanded_items[key] = not panel.expanded_items[key]
			if panel.expanded_items[key] ~= true and entry.reviewer and key == entry.reviewer.key then
				panel.expanded_items[key .. ":history"] = false
			end
			M.render(panel)
		end
	end
	local function show_selected(focus_diff)
		local session = active_session(panel)
		if not session then
			return
		end
		local entry = selected_entry(panel)
		if entry and (entry.reviewer or entry.reviewer_group) then
			toggle_selected()
		elseif not session.focus_item then
			return
		elseif entry and entry.note then
			session.focus_item({ kind = "note", note = entry.note }, focus_diff)
		elseif entry and (entry.thread_root or entry.comment) then
			local comment = entry.thread_root or entry.comment
			if not comment.is_task then
				session.focus_item({ kind = "comment", comment = comment }, focus_diff)
			end
		end
	end
	local function run_action(action)
		local session = active_session(panel)
		if not session then
			return
		end
		local entry = selected_entry(panel)
		if entry and entry.review_history then
			if action ~= "edit" then
				return
			end
			local context = review.action_context(session, nil)
			if context then
				review_actions.edit_review(context, entry.review_history, function(result, err)
					if result and not err then
						session:render()
					end
				end)
			end
			return
		end
		if entry and entry.note then
			if action == "edit" then
				notes.edit(session, entry.note)
			elseif action == "delete" then
				notes.delete(session, entry.note)
			end
			return
		end
		local comment = entry and entry.comment or nil
		if action == "toggle_resolved" and entry then
			comment = entry.thread_root or comment
		end
		if comment then
			if action == "add_comment" and comment.is_task then
				return
			end
			if action == "toggle_resolved" and comment.is_task then
				action = "toggle_task"
			end
			comments.run_action(session, action, comment)
		end
	end
	local entries = {}
	add_mapping(entries, { "ui.select", "ui.show_details" }, "Show item in diff", 1, function()
		show_selected(false)
	end)
	add_mapping(entries, "pulls.review.focus_item", "Focus item in diff", 2, function()
		show_selected(true)
	end)
	add_mapping(entries, "ui.open_in_browser", "Open item in browser", 3, function()
		local entry = selected_entry(panel)
		local target = entry and (entry.review_history or entry.comment or entry.thread_root)
		local url = target and tostring(target.html_url or target.url or "") or ""
		if url ~= "" then
			vim.ui.open(url)
		end
	end)
	add_mapping(entries, "pulls.review.diff.add_comment", "Reply to comment", 4, function()
		run_action("add_comment")
	end)
	add_mapping(entries, "ui.comments.edit", "Edit review item", 5, function()
		run_action("edit")
	end)
	add_mapping(entries, "ui.delete", "Delete review item", 6, function()
		run_action("delete")
	end)
	add_mapping(entries, "pulls.review.diff.toggle_resolved", "Toggle resolved / completed", 7, function()
		run_action("toggle_resolved")
	end)
	add_mapping(entries, "ui.toggle_fold", "Expand / collapse", 8, toggle_selected)
	add_mapping(entries, "ui.toggle_all_folds", "Expand / collapse all", 9, function()
		local session = active_session(panel)
		if not session then
			return
		end
		local reviewers, pending, published_comments, standalone_tasks, rendered_notes =
			panel_items(panel_data(session))
		local keys, history_keys = {}, {}
		for _, reviewer in ipairs(reviewers) do
			if reviewer.kind == "awaiting_reviewers" or #reviewer.history > 0 then
				table.insert(keys, reviewer.key)
			end
			if #reviewer.history > 1 then
				table.insert(history_keys, reviewer.key .. ":history")
			end
		end
		for _, items in ipairs({ pending, published_comments, standalone_tasks, rendered_notes }) do
			for _, item in ipairs(items) do
				table.insert(keys, item.key)
			end
		end
		local expand = false
		for _, key in ipairs(keys) do
			if panel.expanded_items[key] ~= true then
				expand = true
				break
			end
		end
		for _, key in ipairs(keys) do
			panel.expanded_items[key] = expand
		end
		if not expand then
			for _, key in ipairs(history_keys) do
				panel.expanded_items[key] = false
			end
		end
		M.render(panel)
	end)
	add_mapping(entries, "ui.refresh", "Refresh review", 10, function()
		local session = active_session(panel)
		if not session then
			return
		end
		review.reload(session)
		notes.reload(session)
	end)
	add_mapping(entries, "ui.close", "Close panel", 11, function()
		local session = active_session(panel)
		if session and session.toggle_review_panel then
			session.toggle_review_panel()
		end
	end)
	add_mapping(entries, "ui.help", "Toggle help", 0, function()
		help.toggle({ buffer = panel.buf })
	end)
	help.register("Review", entries, { index = 110, buffer = panel.buf })
end

return M
