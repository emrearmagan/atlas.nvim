local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local diff = require("atlas.ui.components.diff_hunks")
local highlights = require("atlas.ui.shared.highlights")
local keymaps = require("atlas.core.keymaps")
local review_threads = require("atlas.ui.components.review_threads")
local state = require("atlas.pulls.ui.panel.pr.tabs.review.state")

local PADDING_X = 1

---@param author { name: string, nickname: string|nil }|nil
---@return string
local function author_name(author)
	if author == nil then
		return "Unknown"
	end
	if author.nickname and author.nickname ~= "" then
		return author.nickname
	end
	if author.name and author.name ~= "" then
		return author.name
	end
	return "Unknown"
end

---@param tasks PullsComment[]
---@return string
local function task_heading(tasks)
	local label = vim.trim(tostring(tasks[1] and tasks[1].task_label or "Task"))
	if label == "" then
		label = "Task"
	end
	return label:sub(-1):lower() == "s" and label or (label .. "s")
end

---@param prefix string
---@param text string
---@param suffix string
---@param width integer
---@return string line, string text
local function task_row(prefix, text, suffix, width)
	local gap_width = suffix ~= "" and 2 or 0
	local text_width = width - vim.api.nvim_strwidth(prefix) - vim.api.nvim_strwidth(suffix) - PADDING_X - gap_width
	if text_width > 0 then
		text = utils.truncate(text, text_width)
	else
		text = ""
	end

	if suffix == "" then
		return prefix .. text, text
	end

	local gap = math.max(
		2,
		width - vim.api.nvim_strwidth(prefix) - vim.api.nvim_strwidth(text) - vim.api.nvim_strwidth(suffix) - PADDING_X
	)
	return prefix .. text .. string.rep(" ", gap) .. suffix, text
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param tasks PullsComment[]
---@param width integer
local function emit_tasks(lines, spans, line_map, tasks, width)
	local toggle_keys = keymaps.resolve("pulls.review.diff.toggle_resolved")
	local edit_keys = keymaps.resolve("pulls.review.diff.edit_comment")
	local delete_keys = keymaps.resolve("pulls.review.diff.delete")
	local padding = string.rep(" ", PADDING_X)

	for _, task in ipairs(tasks) do
		local resolved = task.state == "RESOLVED"
		local footer = {}
		if edit_keys then
			table.insert(footer, table.concat(edit_keys, " / ") .. " edit")
		end
		if delete_keys then
			table.insert(footer, table.concat(delete_keys, " / ") .. " delete")
		end
		if toggle_keys then
			table.insert(footer, table.concat(toggle_keys, " / ") .. (resolved and " reopen" or " complete"))
		end

		local title = utils.task_text(task.content_display or task.content_raw)
		local newline = title:find("\n", 1, true)
		title = newline and title:sub(1, newline - 1) or title
		if title == "" then
			title = string.format("(empty %s)", (task.task_label or "task"):lower())
		end

		local checkbox = resolved and "[x]" or "[ ]"
		local timestamp = utils.relative_time(task.created_on)
		local marker, marker_hl = review_threads.status_marker(task)
		local title_suffix = timestamp
		if marker ~= "" then
			title_suffix = title_suffix ~= "" and (title_suffix .. "  " .. marker) or marker
		end
		local title_prefix = padding .. checkbox .. " "
		local title_line = task_row(title_prefix, title, title_suffix, width)
		table.insert(lines, title_line)
		line_map[#lines] = { kind = "header", comment = task, entity_kind = "task" }
		table.insert(spans, {
			line = #lines - 1,
			start_col = #padding,
			end_col = #padding + #checkbox,
			hl_group = resolved and "AtlasTextPositive" or "AtlasTextMuted",
		})
		if title_suffix ~= "" then
			table.insert(spans, {
				line = #lines - 1,
				start_col = #title_line - #title_suffix,
				end_col = #title_line,
				hl_group = "AtlasTextMuted",
			})
			if marker ~= "" then
				table.insert(spans, {
					line = #lines - 1,
					start_col = #title_line - #marker,
					end_col = #title_line,
					hl_group = marker_hl,
				})
			end
		end

		local creator = author_name(task.author)
		local author = "by @" .. creator
		local action_text = table.concat(footer, "  ")
		local meta_prefix = padding .. string.rep(" ", #checkbox + 1)
		local meta_line, visible_author = task_row(meta_prefix, author, action_text, width)
		table.insert(lines, meta_line)
		line_map[#lines] = { kind = "task_meta", comment = task, entity_kind = "task" }
		if visible_author ~= "" then
			local normalized_author = vim.trim(creator):lower()
			local author_highlight
			if normalized_author == "" or normalized_author == "unknown" then
				author_highlight = "AtlasTextMutedItalic"
			else
				author_highlight = highlights.dynamic_for(normalized_author) or "AtlasTextMuted"
			end
			table.insert(spans, {
				line = #lines - 1,
				start_col = #meta_prefix,
				end_col = #meta_prefix + #visible_author,
				hl_group = author_highlight,
			})
		end
		if action_text ~= "" then
			table.insert(spans, {
				line = #lines - 1,
				start_col = #meta_line - #action_text,
				end_col = #meta_line,
				hl_group = "AtlasTextMuted",
			})
		end
	end
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param nodes AtlasReviewThreadNode[]
---@param width integer
local function emit_thread_box(lines, spans, line_map, nodes, width)
	local inner = math.max(1, width - (PADDING_X * 2) - 4)
	local toggle_keys = keymaps.resolve("pulls.review.diff.toggle_resolved")
	local provider = require("atlas.pulls.state").provider
	local comments = provider and provider.capabilities.comments
	local t_lines, t_spans, t_map = review_threads.render(nodes, inner, {
		expanded = function(root)
			return state.is_thread_expanded(root)
		end,
		padding_x = 0,
		toggle_resolved_key = toggle_keys and table.concat(toggle_keys, " / ") or nil,
		reaction_options = comments and comments.reaction_options,
	})
	local mark_line = #lines
	local result = box.render({ { lines = t_lines, spans = t_spans, line_map = t_map } }, {
		width = width,
		padding_x = PADDING_X,
		line_map = line_map,
		line_offset = mark_line,
	})
	utils.append_block(lines, spans, { lines = result.lines, highlights = result.highlights })
end

---@class CommentsHunkBucket
---@field hunk DiffHunk
---@field threads_by_anchor table<string, { threads: AtlasReviewThreadNode[] }>

---@class CommentsFileBucket
---@field path string
---@field threads AtlasReviewThreadNode[]
---@field hunks table<string, CommentsHunkBucket>
---@field hunk_order string[]

---@param hunk DiffHunk
---@return string
local function hunk_key(hunk)
	return string.format("%s|%s", tostring(hunk.new_start or 0), tostring(hunk.old_start or 0))
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param width integer
---@param file_path string
---@param file_threads AtlasReviewThreadNode[]
---@param buckets CommentsHunkBucket[]
local function emit_file_with_comments(lines, spans, line_map, width, file_path, file_threads, buckets)
	local function count(node)
		local total = 1
		for _, child in ipairs(node.children or {}) do
			total = total + count(child)
		end
		return total
	end

	local file = { path = file_path, status = "modified", hunks = {} }
	local totals = {}
	local buckets_by_key = {}
	for _, bucket in ipairs(buckets) do
		table.insert(file.hunks, bucket.hunk)
		buckets_by_key[diff.hunk_key(file, bucket.hunk)] = bucket
		local total = 0
		for _, anchor in pairs(bucket.threads_by_anchor) do
			for _, node in ipairs(anchor.threads or {}) do
				total = total + count(node)
			end
		end
		totals[hunk_key(bucket.hunk)] = total
	end

	local cb_lines, cb_spans, cb_map = diff.hunks({ file }, {
		max_width = width,
		padding_x = PADDING_X,
		collapsed_hunks = state.collapsed_hunks,
		hunk_footer = function(_, hunk)
			local total = totals[hunk_key(hunk)] or 0
			if total == 0 then
				return nil
			end
			return string.format("%d %s", total, total == 1 and "comment" or "comments")
		end,
	})
	if #cb_lines == 0 then
		utils.push(lines, spans, file_path, "Normal", PADDING_X)
		table.insert(lines, "")
		emit_thread_box(lines, spans, line_map, file_threads, width)
		return
	end

	---@type table<integer, table[]>
	local spans_by_cb_line = {}
	for _, s in ipairs(cb_spans) do
		local list = spans_by_cb_line[s.line]
		if list == nil then
			list = {}
			spans_by_cb_line[s.line] = list
		end
		table.insert(list, s)
	end

	local current_bucket
	for i, text in ipairs(cb_lines) do
		table.insert(lines, text)
		local out_line = #lines - 1
		for _, s in ipairs(spans_by_cb_line[i - 1] or {}) do
			s.line = out_line
			table.insert(spans, s)
		end
		local entry = cb_map and cb_map[i] or nil
		if entry then
			line_map[#lines] = entry
		end

		if entry and entry.kind == "hunk_header" then
			current_bucket = buckets_by_key[entry.hunk_key]
		elseif entry and entry.kind == "hunk_line" and entry.path == file_path and entry.line ~= nil then
			local anchor_key = string.format("%s:%s", entry.side or "new", tostring(entry.line))
			local anchor = current_bucket and current_bucket.threads_by_anchor[anchor_key]
			if anchor then
				entry.thread_roots = {}
				for _, thread in ipairs(anchor.threads) do
					table.insert(entry.thread_roots, thread.comment)
				end
				emit_thread_box(lines, spans, line_map, anchor.threads, width)
				current_bucket.threads_by_anchor[anchor_key] = nil
			end
		end
		if i == 2 and #file_threads > 0 then
			emit_thread_box(lines, spans, line_map, file_threads, width)
			table.insert(lines, "")
		end
	end

	for _, bucket in ipairs(buckets) do
		if state.collapsed_hunks[diff.hunk_key(file, bucket.hunk)] ~= true then
			for _, anchor in pairs(bucket.threads_by_anchor) do
				emit_thread_box(lines, spans, line_map, anchor.threads, width)
			end
		end
	end
end

---@param width integer
---@param comments PullsComment[]|"loading"|string|nil
---@param tasks PullsComment[]|"loading"|string|nil
---@return string[], table[], table<integer, table>
function M.render(width, comments, tasks)
	local lines = {}
	local spans = {}
	local line_map = {}
	local max_width = math.max(1, width)

	if tasks == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading tasks..."), "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
	elseif type(tasks) == "string" then
		utils.push(lines, spans, tasks, "AtlasLogError", PADDING_X)
		table.insert(lines, "")
	elseif type(tasks) == "table" and #tasks > 0 then
		---@cast tasks PullsComment[]
		local sorted_tasks = vim.list_extend({}, tasks)
		table.sort(sorted_tasks, function(left, right)
			local left_date = tostring(left.created_on or "")
			local right_date = tostring(right.created_on or "")
			return left_date == right_date and tostring(left.id) < tostring(right.id) or left_date < right_date
		end)
		utils.push(lines, spans, task_heading(sorted_tasks), "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")
		emit_tasks(lines, spans, line_map, sorted_tasks, max_width)
		table.insert(lines, "")
	end

	if comments == nil then
		return lines, spans, line_map
	end

	if comments == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading comments..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(comments) == "string" then
		utils.push(lines, spans, comments, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	---@cast comments PullsComment[]
	if #comments == 0 then
		utils.push(lines, spans, "No comments yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local roots = review_threads.group_comments(comments, type(tasks) == "table" and tasks or nil)

	local general_roots = {}
	---@type table<string, CommentsFileBucket>
	local file_buckets = {}
	---@type string[]
	local file_order = {}

	for _, thread in ipairs(roots) do
		local c = thread.comment
		local path = c.file and c.file.path or (c.inline and c.inline.path)
		if path and (c.file or c.inline_hunk) then
			local file = file_buckets[path]
			if file == nil then
				file = { path = path, threads = {}, hunks = {}, hunk_order = {} }
				file_buckets[path] = file
				table.insert(file_order, path)
			end
			if c.file then
				table.insert(file.threads, thread)
			else
				local hkey = hunk_key(c.inline_hunk)
				local hb = file.hunks[hkey]
				if hb == nil then
					hb = { hunk = c.inline_hunk, threads_by_anchor = {} }
					file.hunks[hkey] = hb
					table.insert(file.hunk_order, hkey)
				elseif #(c.inline_hunk.lines or {}) > #(hb.hunk.lines or {}) then
					-- GitHub's diff hunk ends at the comment anchor, so the longest
					-- snippet contains every anchor seen for this hunk.
					hb.hunk = c.inline_hunk
				end
				local side = c.inline.to ~= nil and "new" or "old"
				local line = c.inline_hunk_anchor or c.inline.to or c.inline.from
				local akey = string.format("%s:%s", side, tostring(line or ""))
				local anchor = hb.threads_by_anchor[akey]
				if anchor == nil then
					anchor = { threads = {} }
					hb.threads_by_anchor[akey] = anchor
				end
				table.insert(anchor.threads, thread)
			end
		else
			table.insert(general_roots, thread)
		end
	end

	if #general_roots > 0 then
		utils.push(lines, spans, "Conversation", "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")
		emit_thread_box(lines, spans, line_map, general_roots, max_width)
		table.insert(lines, "")
	end

	if #file_order > 0 then
		utils.push(lines, spans, "Changes", "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")

		for _, path in ipairs(file_order) do
			local file = file_buckets[path]
			local buckets = {}
			for _, hkey in ipairs(file.hunk_order) do
				table.insert(buckets, file.hunks[hkey])
			end
			emit_file_with_comments(lines, spans, line_map, max_width, path, file.threads, buckets)
			table.insert(lines, "")
		end
	end

	return lines, spans, line_map
end

return M
