local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local helper = require("atlas.pulls.ui.main.helper")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local CONNECTOR = "│"
local REPLY_INDENT = "    "
local ACTIVITY_COLLAPSE_KEEP = 2
local ACTIVITY_COLLAPSE_THRESHOLD = 5

local ACTIVITY_ICONS = {
	approval = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	changes_requested = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextWarning" },
	update = { icon = icons.pulls("activity"), hl = "AtlasTextMuted" },
}

-- Helpers

---@param author {name: string, nickname: string|nil}|nil
---@return string
local function author_name(author)
	if author == nil or author.name == nil or author.name == "" then
		return "Unknown"
	end
	return author.name
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

---@param reactions table|nil
---@return string
local function format_reactions(reactions)
	if type(reactions) ~= "table" then
		return ""
	end
	local parts = {}
	for _, opt in ipairs(state.reaction_options or {}) do
		local count = tonumber(reactions[opt.key]) or 0
		if count > 0 then
			table.insert(parts, string.format("%s %d", opt.emoji or opt.key, count))
		end
	end
	return table.concat(parts, "  ")
end

---@param lines string[]
---@param spans table[]
local function append_connector(lines, spans)
	local connector_line = PADDING .. CONNECTOR
	table.insert(lines, connector_line)
	table.insert(spans, {
		line = #lines - 1,
		start_col = PADDING_X,
		end_col = PADDING_X + #CONNECTOR,
		hl_group = "AtlasBorder",
	})
end

---@param dst_lines string[]
---@param dst_spans table[]
---@param dst_map table<integer, table>
---@param src_lines string[]
---@param src_spans table[]
---@param src_map table<integer, table>|nil
local function splice(dst_lines, dst_spans, dst_map, src_lines, src_spans, src_map)
	local offset = #dst_lines
	for _, l in ipairs(src_lines) do
		table.insert(dst_lines, l)
	end
	for _, s in ipairs(src_spans) do
		s.line = s.line + offset
		table.insert(dst_spans, s)
	end
	if src_map then
		for lnum, data in pairs(src_map) do
			dst_map[offset + lnum] = data
		end
	end
end

-- Comment box

---@param comment PullsComment
---@param verb "commented"|"replied"
---@param width integer
---@return string header_line, table[] header_spans
local function build_header(comment, verb, width)
	local author = author_name(comment.author)
	local author_hl = helper.author_hl(author)
	local time_text = utils.relative_time(comment.created_on)
	local user_icon = icons.general("user")

	local left = user_icon .. "  " .. author .. "  " .. verb .. "  " .. time_text
	local spans = {}
	local col = 0
	table.insert(spans, { line = 0, start_col = col, end_col = col + #user_icon, hl_group = author_hl })
	col = col + #user_icon + 2
	table.insert(spans, { line = 0, start_col = col, end_col = col + #author, hl_group = author_hl })
	col = col + #author + 2
	local rest = verb .. "  " .. time_text
	table.insert(spans, { line = 0, start_col = col, end_col = col + #rest, hl_group = "AtlasTextMuted" })

	local actions = { string.format("%s (c)", icons.general("reply")) }
	if is_own_comment(comment) then
		table.insert(actions, string.format("%s (e)", icons.general("edit")))
		table.insert(actions, string.format("%s (d)", icons.general("delete")))
	end
	local actions_text = table.concat(actions, "  ")

	local gap = math.max(2, width - vim.api.nvim_strwidth(left) - vim.api.nvim_strwidth(actions_text))
	local line = left .. string.rep(" ", gap) .. actions_text
	local actions_start = #left + gap
	table.insert(spans, {
		line = 0,
		start_col = actions_start,
		end_col = actions_start + #actions_text,
		hl_group = "AtlasTextMuted",
	})
	return line, spans
end

---@param comment PullsComment
---@param width integer
---@return string[] lines, table[] spans
local function build_content(comment, width)
	local lines, spans = {}, {}
	if comment.deleted == true then
		local text = "(deleted comment)"
		table.insert(lines, text)
		table.insert(spans, { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMutedItalic" })
	else
		local raw = utils.strip_markup(comment.content_raw or "")
		if raw == "" then
			raw = "(empty comment)"
		end
		for _, line in ipairs(utils.sanitize_lines(raw)) do
			for _, chunk in ipairs(utils.wrap_line(line, width)) do
				table.insert(lines, chunk)
			end
		end
	end

	local reactions = format_reactions(comment.reactions)
	if reactions ~= "" then
		table.insert(lines, reactions)
		table.insert(spans, {
			line = #lines - 1,
			start_col = 0,
			end_col = #reactions,
			hl_group = "AtlasTextMuted",
		})
	end
	return lines, spans
end

---@param replies PullsComment[]
---@param root PullsComment
---@param width integer
local function build_reply_group(replies, root, width)
	local lines, spans, line_to_entry = {}, {}, {}
	for ri, reply in ipairs(replies) do
		if ri > 1 then
			table.insert(lines, "")
			line_to_entry[#lines] = { kind = "comment", comment = reply, thread_root = root, entity_kind = "comment" }
		end
		local hl, hs = build_header(reply, "replied", width - #REPLY_INDENT)
		local cl, cs = build_content(reply, width - #REPLY_INDENT)
		local header_base = #lines
		table.insert(lines, REPLY_INDENT .. hl)
		for _, s in ipairs(hs) do
			table.insert(spans, vim.tbl_extend("force", s, {
				line = header_base,
				start_col = s.start_col + #REPLY_INDENT,
				end_col = s.end_col + #REPLY_INDENT,
			}))
		end
		line_to_entry[#lines] = { kind = "comment", comment = reply, thread_root = root, entity_kind = "comment" }
		local content_base = #lines
		for li, l in ipairs(cl) do
			table.insert(lines, REPLY_INDENT .. l)
			line_to_entry[#lines] = { kind = "comment", comment = reply, thread_root = root, entity_kind = "comment" }
			for _, s in ipairs(cs) do
				if s.line == li - 1 then
					table.insert(spans, vim.tbl_extend("force", s, {
						line = content_base + li - 1,
						start_col = s.start_col + #REPLY_INDENT,
						end_col = s.end_col + #REPLY_INDENT,
					}))
				end
			end
		end
	end
	return { lines = lines, spans = spans }, line_to_entry
end

---@param comments PullsComment[]  comments[1] is root, the rest are replies
---@param collapsed boolean
---@param width integer
---@return string[], table[], table<integer, table>
local function render_thread(comments, collapsed, width)
	comments = comments or {}
	if #comments == 0 then
		return {}, {}, {}
	end
	local root = comments[1]
	local replies = {}
	for i = 2, #comments do
		table.insert(replies, comments[i])
	end
	local inner = math.max(10, width - (PADDING_X * 2) - 4) - 2

	local groups, group_entries = {}, {}
	local function push(group, meta)
		table.insert(groups, group)
		table.insert(group_entries, meta)
	end

	local hl, hs = build_header(root, "commented", inner)
	local cl, cs = build_content(root, inner)
	push({ lines = { hl }, spans = hs }, { default = { kind = "comment", comment = root, thread_root = root, entity_kind = "comment" } })
	push({ lines = cl, spans = cs }, { default = { kind = "comment", comment = root, thread_root = root, entity_kind = "comment" } })

	if collapsed and #replies > 0 then
		local prefix = string.format("%s %d %s", icons.general("arrow_right"), #replies, #replies == 1 and "reply" or "replies")
		local suffix = "  za to expand"
		local label = prefix .. suffix
		push({
			lines = { label },
			spans = {
				{ line = 0, start_col = 0, end_col = #prefix, hl_group = "AtlasLogInfo" },
				{ line = 0, start_col = #prefix, end_col = #label, hl_group = "AtlasTextMuted" },
			},
		}, { default = { kind = "thread_toggle", thread_root = root, entity_kind = "thread_toggle" } })
	elseif #replies > 0 then
		local g, line_to_entry = build_reply_group(replies, root, inner)
		push(g, { by_line = line_to_entry })
		if #replies > 1 then
			local prefix = icons.general("arrow_up")
			local suffix = "  za to collapse"
			local label = prefix .. suffix
			push({
				lines = { label },
				spans = {
					{ line = 0, start_col = 0, end_col = #prefix, hl_group = "AtlasLogInfo" },
					{ line = 0, start_col = #prefix, end_col = #label, hl_group = "AtlasTextMuted" },
				},
			}, { default = { kind = "thread_toggle", thread_root = root, entity_kind = "thread_toggle" } })
		end
	end

	local block = box.render(groups, { width = width, padding_x = PADDING_X })

	local line_map = {}
	local cursor = 2 -- after top border
	for gi, group in ipairs(groups) do
		local meta = group_entries[gi]
		for li = 1, #group.lines do
			line_map[cursor + li - 1] = (meta.by_line and meta.by_line[li]) or meta.default
		end
		cursor = cursor + #group.lines
		if gi < #groups then
			cursor = cursor + 1 -- divider
		end
	end
	return block.lines, block.highlights, line_map
end

-- Activity row

---@param entry PullsActivityEntry
local function activity_label(entry)
	local kind = entry.kind or ""
	if kind == "approval" then
		return "approved"
	elseif kind == "changes_requested" then
		return "requested changes"
	elseif kind == "review" then
		return "left a review"
	end
	return utils.strip_markup(entry.content_raw or kind)
end

---@param entry PullsActivityEntry
---@param width integer
local function render_activity(entry, width)
	local lines, spans = {}, {}
	local ai = ACTIVITY_ICONS[entry.kind or "update"] or ACTIVITY_ICONS.update
	local actor = author_name(entry.actor)
	local label = activity_label(entry)
	local time_text = utils.relative_time(entry.date)

	local icon_prefix = ai.icon .. "  "
	local icon_width = vim.api.nvim_strwidth(icon_prefix)
	local text = actor .. "  " .. label .. "  " .. time_text
	local wrapped = utils.wrap_line(text, math.max(10, width - PADDING_X - icon_width))

	local first = PADDING .. icon_prefix .. wrapped[1]
	table.insert(lines, first)
	local line_len = #first

	local col = PADDING_X
	table.insert(spans, { line = 0, start_col = col, end_col = math.min(col + #ai.icon, line_len), hl_group = ai.hl })
	col = col + #icon_prefix
	table.insert(
		spans,
		{ line = 0, start_col = col, end_col = math.min(col + #actor, line_len), hl_group = helper.author_hl(actor) }
	)
	col = col + #actor + 2
	if col < line_len then
		table.insert(
			spans,
			{ line = 0, start_col = col, end_col = math.min(col + #label, line_len), hl_group = "AtlasTextMuted" }
		)
		col = col + #label + 2
	end
	if col < line_len then
		table.insert(
			spans,
			{ line = 0, start_col = col, end_col = math.min(col + #time_text, line_len), hl_group = "AtlasTextMuted" }
		)
	end

	local continuation = string.rep(" ", PADDING_X + icon_width)
	for i = 2, #wrapped do
		local cont_line = continuation .. wrapped[i]
		table.insert(lines, cont_line)
		table.insert(spans, {
			line = #lines - 1,
			start_col = PADDING_X + icon_width,
			end_col = #cont_line,
			hl_group = "AtlasTextMuted",
		})
	end
	return lines, spans
end

---@param count integer
local function render_activity_gap(count)
	local text = string.format(
		"%s  ... %d more %s",
		icons.general("activity_more"),
		count,
		count == 1 and "activity" or "activities"
	)
	local line = PADDING .. text
	return { line }, { { line = 0, start_col = PADDING_X, end_col = PADDING_X + #text, hl_group = "AtlasTextMuted" } }
end

-- Timeline

---@class ConversationTimelineEntry
---@field type "comment"|"activity"|"activity_gap"
---@field timestamp string
---@field comment PullsComment|nil
---@field replies PullsComment[]|nil
---@field activity PullsActivityEntry|nil
---@field count integer|nil

---@param entries ConversationTimelineEntry[]
---@param run ConversationTimelineEntry[]
local function append_activity_run(entries, run)
	if #run <= ACTIVITY_COLLAPSE_THRESHOLD then
		for _, entry in ipairs(run) do
			table.insert(entries, entry)
		end
		return
	end
	for i = 1, ACTIVITY_COLLAPSE_KEEP do
		table.insert(entries, run[i])
	end
	table.insert(entries, {
		type = "activity_gap",
		timestamp = run[ACTIVITY_COLLAPSE_KEEP].timestamp,
		count = #run - (ACTIVITY_COLLAPSE_KEEP * 2),
	})
	for i = #run - ACTIVITY_COLLAPSE_KEEP + 1, #run do
		table.insert(entries, run[i])
	end
end

---@param entries ConversationTimelineEntry[]
local function collapse_activity_runs(entries)
	local collapsed, run = {}, {}
	for _, entry in ipairs(entries) do
		if entry.type == "activity" then
			table.insert(run, entry)
		else
			append_activity_run(collapsed, run)
			run = {}
			table.insert(collapsed, entry)
		end
	end
	append_activity_run(collapsed, run)
	return collapsed
end

---@param actor PullsAuthor|nil
local function author_table(actor)
	if not actor then
		return nil
	end
	return {
		name = tostring(actor.name or actor.username or ""),
		nickname = tostring(actor.nickname or actor.username or ""),
		id = tostring(actor.id or ""),
	}
end

---@param a PullsActivityEntry
---@param prefix string
local function synthetic_comment(a, prefix)
	return {
		id = prefix .. "-" .. tostring(a.date or ""),
		parent_id = nil,
		author = author_table(a.actor),
		content_raw = a.content_raw or "",
		created_on = a.date or "",
	}
end

---@param comments PullsComment[]
local function group_threads(comments)
	local by_id, order = {}, {}
	for _, c in ipairs(comments) do
		if c.parent_id == nil then
			by_id[tostring(c.id)] = { root = c, replies = {} }
			table.insert(order, tostring(c.id))
		end
	end
	for _, c in ipairs(comments) do
		if c.parent_id ~= nil then
			local pid = tostring(c.parent_id)
			if by_id[pid] then
				table.insert(by_id[pid].replies, c)
			else
				by_id[tostring(c.id)] = { root = c, replies = {} }
				table.insert(order, tostring(c.id))
			end
		end
	end
	local threads = {}
	for _, key in ipairs(order) do
		table.insert(threads, by_id[key])
	end
	return threads
end

---@param comments PullsComment[]
---@param activity PullsActivityEntry[]
---@return ConversationTimelineEntry[]
local function build_timeline(comments, activity)
	local entries = {}
	for _, t in ipairs(group_threads(comments)) do
		table.insert(entries, {
			type = "comment",
			timestamp = t.root.created_on or "",
			comment = t.root,
			replies = t.replies,
		})
	end
	for _, a in ipairs(activity) do
		if a.kind == "comment" then
			table.insert(entries, {
				type = "comment",
				timestamp = a.date or "",
				comment = synthetic_comment(a, "activity"),
			})
		else
			table.insert(entries, { type = "activity", timestamp = a.date or "", activity = a })
			local is_review = a.kind == "approval" or a.kind == "changes_requested" or a.kind == "review"
			if is_review and type(a.content_raw) == "string" and a.content_raw ~= "" then
				table.insert(entries, {
					type = "comment",
					timestamp = a.date or "",
					comment = synthetic_comment(a, "review"),
				})
			end
		end
	end
	table.sort(entries, function(a, b)
		return a.timestamp < b.timestamp
	end)
	return collapse_activity_runs(entries)
end

-- Render

---@param entry ConversationTimelineEntry
---@param width integer
local function render_entry(entry, width)
	if entry.type == "comment" then
		local key = tostring(entry.comment.id)
		if (#(entry.replies or {})) > 1 and state.collapsed[key] == nil then
			state.collapsed[key] = true
		end
		local thread = { entry.comment }
		for _, r in ipairs(entry.replies or {}) do
			table.insert(thread, r)
		end
		return render_thread(thread, state.is_collapsed(entry.comment.id), width)
	elseif entry.type == "activity" then
		local lines, spans = render_activity(entry.activity, width)
		return lines, spans, { [1] = { kind = "activity", activity = entry.activity } }
	elseif entry.type == "activity_gap" then
		local lines, spans = render_activity_gap(entry.count or 0)
		return lines, spans, {}
	end
	return {}, {}, {}
end

---@param pr PullRequest
---@param width integer
function M.render(pr, width)
	local lines, spans, line_map = {}, {}, {}

	local comments_ready = type(state.comments) == "table"
	local activity_ready = type(state.activity) == "table"
	if state.comments == nil and state.activity == nil then
		return lines, spans, line_map
	end
	if not comments_ready and not activity_ready then
		utils.push(lines, spans, spinner.with_text("Loading conversation..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local comments = comments_ready and state.comments or {}
	local entries = build_timeline(comments, activity_ready and state.activity or {})

	if #entries == 0 then
		utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for _, entry in ipairs(entries) do
		if #lines > 0 then
			append_connector(lines, spans)
		end
		local e_lines, e_spans, e_map = render_entry(entry, width)
		splice(lines, spans, line_map, e_lines, e_spans, e_map)
	end

	return lines, spans, line_map
end

return M
