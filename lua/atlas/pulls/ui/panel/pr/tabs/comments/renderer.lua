local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local threads = require("atlas.ui.components.threadsv2")
local changes_block = require("atlas.pulls.ui.components.changes_block")
local items = require("atlas.pulls.ui.panel.pr.tabs.comments.items")
local helper = require("atlas.pulls.ui.main.helper")

local PADDING_X = 1

---@param root PullsComment
---@return boolean
local function is_collapsed_state(root)
	return root.state == "DELETED" or root.state == "RESOLVED" or root.state == "OUTDATED"
end

---@param root PullsComment
---@param replies PullsComment[]
---@param current_user PullsUser|nil
---@return AtlasThreadV2Item
local function build_thread_item(root, replies, current_user)
	if #replies > 0 and is_collapsed_state(root) then
		local item = items.comment_item(root, nil, current_user, true)
		local label = string.format("%d %s", #replies, #replies == 1 and "reply" or "replies")
		item.children = { items.summary_item(label) }
		return item
	end
	return items.comment_item(root, replies, current_user, true)
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param threads_v2 AtlasThreadV2Item[]
---@param width integer
local function emit_thread_box(lines, spans, line_map, threads_v2, width)
	local inner = math.max(20, width - (PADDING_X * 2) - 2)
	local t_lines, t_spans, t_map = threads.render(threads_v2, inner, items.threads_opts(helper, PADDING_X))
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
---@param threads_by_anchor table<string, { side: string, line: integer, threads: table[] }>
local function emit_hunk_with_comments(lines, spans, line_map, width, file_path, hunk, threads_by_anchor)
	local total = 0
	for _, anchor in pairs(threads_by_anchor) do
		for _, t in ipairs(anchor.threads or {}) do
			total = total + 1 + #(t.replies or {})
		end
	end

	local cb_lines, cb_spans, cb_map = changes_block.render({
		{ path = file_path, status = "modified", hunks = { hunk } },
	}, {
		max_width = width,
		padding_x = PADDING_X,
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
			table.insert(spans, {
				line = out_line,
				start_col = s.start_col,
				end_col = s.end_col,
				hl_group = s.hl_group,
			})
		end
		local entry = cb_map and cb_map[i] or nil
		if entry then
			line_map[#lines] = entry
		end

		if entry and entry.kind == "hunk_line" and entry.path == file_path and entry.line ~= nil then
			local anchor_key = string.format("%s:%s", entry.side or "new", tostring(entry.line))
			local anchor = threads_by_anchor[anchor_key]
			if anchor then
				local thread_items = {}
				for _, t in ipairs(anchor.threads) do
					table.insert(thread_items, build_thread_item(t.root, t.replies, anchor.current_user))
				end
				emit_thread_box(lines, spans, line_map, thread_items, width)
				threads_by_anchor[anchor_key] = nil
			end
		end
	end
end

---@param pr PullRequest
---@param width integer
---@param comments PullsComment[]|"loading"|string|nil
---@return string[], table[], table<integer, table>
function M.render(pr, width, comments) ---@diagnostic disable-line: unused-local
	local lines = {}
	local spans = {}
	local line_map = {}
	local max_width = math.max(20, width)

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

	local current_user = require("atlas.pulls.state").current_user

	local by_id = {}
	for _, c in ipairs(comments) do
		by_id[tostring(c.id)] = { root = c, replies = {} }
	end
	for _, c in ipairs(comments) do
		local pid = c.parent_id and tostring(c.parent_id) or nil
		if pid and by_id[pid] then
			table.insert(by_id[pid].replies, c)
		end
	end

	---@class CommentsHunkBucket
	---@field hunk DiffHunk
	---@field threads_by_anchor table<string, { side: string, line: integer, threads: table[], current_user: PullsUser|nil }>

	local general_roots = {}
	---@type table<string, { path: string, hunks: table<string, CommentsHunkBucket>, hunk_order: string[] }>
	local file_buckets = {}
	---@type string[]
	local file_order = {}

	---@param hunk DiffHunk
	local function hunk_key(hunk)
		return string.format("%s|%s", tostring(hunk.new_start or 0), tostring(hunk.old_start or 0))
	end

	for _, c in ipairs(comments) do
		local pid = c.parent_id and tostring(c.parent_id) or nil
		if pid == nil or by_id[pid] == nil then
			local thread = by_id[tostring(c.id)]
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
					-- githubs diff_hunk is a prefix from the @@ start to the anchor
					-- line, so the longest slice in a bucket is the union of all
					hb.hunk = c.inline_hunk
				end
				local side = c.inline.to ~= nil and "new" or "old"
				local line = c.inline.to or c.inline.from
				local akey = string.format("%s:%s", side, tostring(line or ""))
				local anchor = hb.threads_by_anchor[akey]
				if anchor == nil then
					anchor = { side = side, line = line, threads = {}, current_user = current_user }
					hb.threads_by_anchor[akey] = anchor
				end
				table.insert(anchor.threads, thread)
			else
				table.insert(general_roots, thread)
			end
		end
	end

	---@param thread { root: PullsComment, replies: PullsComment[] }
	local function thread_to_item(thread)
		return build_thread_item(thread.root, thread.replies, current_user)
	end

	if #general_roots > 0 then
		utils.push(lines, spans, "Conversation", "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")
		local thread_items = {}
		for _, t in ipairs(general_roots) do
			table.insert(thread_items, thread_to_item(t))
		end
		emit_thread_box(lines, spans, line_map, thread_items, max_width)
		table.insert(lines, "")
	end

	if #file_order > 0 then
		utils.push(lines, spans, "Changes", "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")

		for _, path in ipairs(file_order) do
			local file = file_buckets[path]
			for _, hkey in ipairs(file.hunk_order) do
				local hb = file.hunks[hkey]
				emit_hunk_with_comments(lines, spans, line_map, max_width, path, hb.hunk, hb.threads_by_anchor)
				-- orphans (didnt match any rendered line)
				for _, anchor in pairs(hb.threads_by_anchor) do
					local thread_items = {}
					for _, t in ipairs(anchor.threads) do
						table.insert(thread_items, thread_to_item(t))
					end
					emit_thread_box(lines, spans, line_map, thread_items, max_width)
				end
				table.insert(lines, "")
			end
		end
	end

	return lines, spans, line_map
end

return M
