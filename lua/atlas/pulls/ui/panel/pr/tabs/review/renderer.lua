local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local diff = require("atlas.ui.components.diff_hunks")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local keymaps = require("atlas.core.keymaps")
local review_actions = require("atlas.pulls.actions.review")
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
---@param current_user PullsUser|nil
local function emit_tasks(lines, spans, line_map, tasks, width, current_user)
	local toggle_keys = keymaps.resolve("pulls.review.toggle_resolved")
	local provider = require("atlas.pulls.state").provider
	local padding = string.rep(" ", PADDING_X)

	for _, task in ipairs(tasks) do
		local resolved = task.state == "RESOLVED"
		local actions = {}
		if toggle_keys and review_actions.is_available("toggle_task", task, current_user, provider) then
			table.insert(
				actions,
				string.format(
					"%s (%s)",
					resolved and icons.general("refresh") or icons.general("success"),
					table.concat(toggle_keys, " / ")
				)
			)
		end
		if review_actions.is_available("edit", task, current_user, provider) then
			table.insert(actions, string.format("%s (e)", icons.general("edit")))
		end
		if review_actions.is_available("delete", task, current_user, provider) then
			table.insert(actions, string.format("%s (d)", icons.general("delete")))
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
		local action_text = table.concat(actions, "  ")
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
---@param current_user PullsUser|nil
local function emit_thread_box(lines, spans, line_map, nodes, width, current_user)
	local inner = math.max(1, width - (PADDING_X * 2) - 4)
	local toggle_keys = keymaps.resolve("pulls.review.toggle_resolved")
	local provider = require("atlas.pulls.state").provider
	local comments = provider and provider.capabilities.comments
	local t_lines, t_spans, t_map = review_threads.render(nodes, inner, {
		expanded = function(root)
			return state.is_thread_expanded(root)
		end,
		can_action = function(action, comment)
			return review_actions.is_available(action, comment, current_user, provider)
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

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param width integer
---@param file_path string
---@param hunk DiffHunk
---@param threads_by_anchor table<string, { threads: AtlasReviewThreadNode[], current_user: PullsUser|nil }>
---@return boolean collapsed
local function emit_hunk_with_comments(lines, spans, line_map, width, file_path, hunk, threads_by_anchor)
	local collapsed = state.collapsed_hunks[diff.hunk_key({ path = file_path }, hunk)] == true
	local function count(node)
		local total = 1
		for _, child in ipairs(node.children or {}) do
			total = total + count(child)
		end
		return total
	end
	local total = 0
	for _, anchor in pairs(threads_by_anchor) do
		for _, node in ipairs(anchor.threads or {}) do
			total = total + count(node)
		end
	end

	local cb_lines, cb_spans, cb_map = diff.hunks({
		{ path = file_path, status = "modified", hunks = { hunk } },
	}, {
		max_width = width,
		padding_x = PADDING_X,
		collapsed_hunks = state.collapsed_hunks,
		hunk_footer = function()
			if total == 0 then
				return nil
			end
			return string.format("%d %s", total, total == 1 and "comment" or "comments")
		end,
	})

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

		if entry and entry.kind == "hunk_line" and entry.path == file_path and entry.line ~= nil then
			local anchor_key = string.format("%s:%s", entry.side or "new", tostring(entry.line))
			local anchor = threads_by_anchor[anchor_key]
			if anchor then
				entry.thread_roots = {}
				for _, thread in ipairs(anchor.threads) do
					table.insert(entry.thread_roots, thread.comment)
				end
				emit_thread_box(lines, spans, line_map, anchor.threads, width, anchor.current_user)
				threads_by_anchor[anchor_key] = nil
			end
		end
	end
	return collapsed
end

---@param _pr PullRequest
---@param width integer
---@param comments PullsComment[]|"loading"|string|nil
---@param tasks PullsComment[]|"loading"|string|nil
---@return string[], table[], table<integer, table>
function M.render(_pr, width, comments, tasks)
	local lines = {}
	local spans = {}
	local line_map = {}
	local max_width = math.max(1, width)
	local current_user = require("atlas.pulls.state").current_user

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
		emit_tasks(lines, spans, line_map, sorted_tasks, max_width, current_user)
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

	---@class CommentsHunkBucket
	---@field hunk DiffHunk
	---@field threads_by_anchor table<string, { threads: AtlasReviewThreadNode[], current_user: PullsUser|nil }>

	local general_roots = {}
	---@type table<string, { path: string, hunks: table<string, CommentsHunkBucket>, hunk_order: string[] }>
	local file_buckets = {}
	---@type string[]
	local file_order = {}

	---@param hunk DiffHunk
	local function hunk_key(hunk)
		return string.format("%s|%s", tostring(hunk.new_start or 0), tostring(hunk.old_start or 0))
	end

	for _, thread in ipairs(roots) do
		local c = thread.comment
		if c.inline and c.inline.path and c.inline_hunk then
			local file = file_buckets[c.inline.path]
			if file == nil then
				file = { path = c.inline.path, hunks = {}, hunk_order = {} }
				file_buckets[c.inline.path] = file
				table.insert(file_order, c.inline.path)
			end
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
			local line = c.inline.to or c.inline.from
			local akey = string.format("%s:%s", side, tostring(line or ""))
			local anchor = hb.threads_by_anchor[akey]
			if anchor == nil then
				anchor = { threads = {}, current_user = current_user }
				hb.threads_by_anchor[akey] = anchor
			end
			table.insert(anchor.threads, thread)
		else
			table.insert(general_roots, thread)
		end
	end

	if #general_roots > 0 then
		utils.push(lines, spans, "Conversation", "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")
		emit_thread_box(lines, spans, line_map, general_roots, max_width, current_user)
		table.insert(lines, "")
	end

	if #file_order > 0 then
		utils.push(lines, spans, "Changes", "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")

		for _, path in ipairs(file_order) do
			local file = file_buckets[path]
			for _, hkey in ipairs(file.hunk_order) do
				local hb = file.hunks[hkey]
				local collapsed =
					emit_hunk_with_comments(lines, spans, line_map, max_width, path, hb.hunk, hb.threads_by_anchor)
				if not collapsed then
					-- orphans (didnt match any rendered line)
					for _, anchor in pairs(hb.threads_by_anchor) do
						emit_thread_box(lines, spans, line_map, anchor.threads, max_width, current_user)
					end
				end
				table.insert(lines, "")
			end
		end
	end

	return lines, spans, line_map
end

return M
