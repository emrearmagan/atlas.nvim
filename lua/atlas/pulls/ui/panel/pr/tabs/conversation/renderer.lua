local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local comment_box = require("atlas.ui.components.comment_box")
local emojis = require("atlas.ui.shared.emojis")
local helper = require("atlas.pulls.ui.main.helper")
local activity_component = require("atlas.pulls.ui.panel.pr.tabs.components.activity")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local CONNECTOR = "│"
local REPLY_INDENT = "    "

-- Helpers

---@param author {name: string, nickname: string|nil}|nil
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
---@return string text, table[] spans
local function format_reactions(reactions)
	if type(reactions) ~= "table" then
		return "", {}
	end
	local emoji_by_key, order = {}, {}
	for _, opt in ipairs(state.reaction_options or {}) do
		emoji_by_key[opt.key] = opt.emoji
		table.insert(order, opt.key)
	end
	for key in pairs(reactions) do
		if emoji_by_key[key] == nil then
			emoji_by_key[key] = emojis.glyph(key)
			table.insert(order, key)
		end
	end

	local parts, spans = {}, {}
	local col = 0
	for _, key in ipairs(order) do
		local count = tonumber(reactions[key]) or 0
		if count > 0 then
			if #parts > 0 then
				col = col + 2
			end
			local icon = emoji_by_key[key]
			local count_text = " " .. tostring(count)
			table.insert(spans, { start_col = col, end_col = col + #icon, hl_group = "AtlasLogInfo" })
			table.insert(
				spans,
				{ start_col = col + #icon, end_col = col + #icon + #count_text, hl_group = "AtlasTextMuted" }
			)
			col = col + #icon + #count_text
			table.insert(parts, icon .. count_text)
		end
	end
	return table.concat(parts, "  "), spans
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
local function build_comment_sections(comment, verb, width)
	local author = author_name(comment.author)
	local actions = { string.format("%s (c)", icons.general("reply")) }
	if is_own_comment(comment) then
		table.insert(actions, string.format("%s (e)", icons.general("edit")))
		table.insert(actions, string.format("%s (d)", icons.general("delete")))
	end

	local body_lines, body_hl = {}, nil
	if comment.deleted == true then
		table.insert(body_lines, "(deleted comment)")
		body_hl = "AtlasTextMutedItalic"
	else
		local raw = utils.strip_markup(comment.content_raw or "")
		if raw == "" then
			raw = "(empty comment)"
		end
		for _, line in ipairs(utils.sanitize_lines(raw)) do
			for _, chunk in ipairs(utils.wrap_line(line, width)) do
				table.insert(body_lines, chunk)
			end
		end
	end

	local rtext, rspans = format_reactions(comment.reactions)
	local reactions = nil
	if rtext ~= "" then
		reactions = { text = rtext, spans = rspans }
	end

	return comment_box.render({
		author = author,
		author_hl = helper.author_hl(author),
		icon = icons.general("user"),
		verb = verb,
		timestamp = utils.relative_time(comment.created_on),
		actions_text = table.concat(actions, "  "),
		body_lines = body_lines,
		body_hl = body_hl,
		reactions = reactions,
		width = width,
	})
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
		local header, body = build_comment_sections(reply, "replied", width - #REPLY_INDENT)
		local hl, hs = header.lines[1], header.spans
		local cl, cs = body.lines, body.spans
		local header_base = #lines
		table.insert(lines, REPLY_INDENT .. hl)
		for _, s in ipairs(hs) do
			table.insert(
				spans,
				vim.tbl_extend("force", s, {
					line = header_base,
					start_col = s.start_col + #REPLY_INDENT,
					end_col = s.end_col + #REPLY_INDENT,
				})
			)
		end
		line_to_entry[#lines] = { kind = "comment", comment = reply, thread_root = root, entity_kind = "comment" }
		local content_base = #lines
		for li, l in ipairs(cl) do
			table.insert(lines, REPLY_INDENT .. l)
			line_to_entry[#lines] = { kind = "comment", comment = reply, thread_root = root, entity_kind = "comment" }
			for _, s in ipairs(cs) do
				if s.line == li - 1 then
					table.insert(
						spans,
						vim.tbl_extend("force", s, {
							line = content_base + li - 1,
							start_col = s.start_col + #REPLY_INDENT,
							end_col = s.end_col + #REPLY_INDENT,
						})
					)
				end
			end
		end
	end
	return { lines = lines, spans = spans }, line_to_entry
end

---@param comments PullsComment[]
---@param collapsed boolean
---@param width integer
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

	local header, body = build_comment_sections(root, "commented", inner)
	push(
		{ lines = header.lines, spans = header.spans },
		{ default = { kind = "comment", comment = root, thread_root = root, entity_kind = "comment" } }
	)
	push(
		{ lines = body.lines, spans = body.spans },
		{ default = { kind = "comment", comment = root, thread_root = root, entity_kind = "comment" } }
	)

	if collapsed and #replies > 0 then
		local prefix =
			string.format("%s %d %s", icons.general("arrow_right"), #replies, #replies == 1 and "reply" or "replies")
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
			cursor = cursor + 1
		end
	end
	return block.lines, block.highlights, line_map
end

-- Timeline

---@class PullsConversationTimelineEntry
---@field type "comment"|"activity_run"
---@field timestamp string
---@field comment PullsComment|nil
---@field replies PullsComment[]|nil
---@field activities PullsActivityEntry[]|nil

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
			local pkey = tostring(c.parent_id)
			if by_id[pkey] then
				table.insert(by_id[pkey].replies, c)
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
---@return PullsConversationTimelineEntry[]
local function build_timeline(comments, activity)
	-- Build a sorted mixed list of comments and activity entries.
	local mixed = {}
	for _, t in ipairs(group_threads(comments)) do
		table.insert(mixed, {
			kind = "comment",
			timestamp = t.root.created_on or "",
			comment = t.root,
			replies = t.replies,
		})
	end
	for _, a in ipairs(activity) do
		table.insert(mixed, { kind = "activity", timestamp = a.date or "", activity = a })
	end
	table.sort(mixed, function(a, b)
		local ta, tb = tostring(a.timestamp), tostring(b.timestamp)
		if ta == tb then
			-- When activity and comment share a timestamp (review body),
			-- render the activity row first, then the comment under it.
			return a.kind == "activity" and b.kind ~= "activity"
		end
		return ta < tb
	end)

	-- Collapse consecutive activities into a single activity_run entry.
	local entries, run = {}, {}
	local function flush_run()
		if #run > 0 then
			table.insert(entries, { type = "activity_run", timestamp = run[1].date or "", activities = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		if item.kind == "activity" then
			if item.activity.always_render then
				flush_run()
				table.insert(entries, {
					type = "activity_run",
					timestamp = item.activity.date or "",
					activities = { item.activity },
				})
			else
				table.insert(run, item.activity)
			end
		else
			flush_run()
			table.insert(entries, {
				type = "comment",
				timestamp = item.timestamp,
				comment = item.comment,
				replies = item.replies,
			})
		end
	end
	flush_run()
	return entries
end

-- Render

---@param entry PullsConversationTimelineEntry
---@param width integer
local function render_entry(entry, width)
	if entry.type == "comment" then
		local key = tostring(entry.comment.id)
		if #(entry.replies or {}) > 1 and state.collapsed[key] == nil then
			state.collapsed[key] = true
		end
		local thread = { entry.comment }
		for _, r in ipairs(entry.replies or {}) do
			table.insert(thread, r)
		end
		return render_thread(thread, state.is_collapsed(entry.comment.id), width)
	elseif entry.type == "activity_run" then
		local run_id = tostring(entry.timestamp or "")
		return activity_component.render(entry.activities or {}, width, {
			padding_x = PADDING_X,
			squash = not state.is_run_expanded(run_id),
			run_id = run_id,
		})
	end
	return {}, {}, {}
end

---@param _pr PullRequest
---@param width integer
function M.render(_pr, width) ---@diagnostic disable-line: unused-local
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
	local activity = activity_ready and state.activity or {}
	---@cast comments PullsComment[]
	---@cast activity PullsActivityEntry[]
	local entries = build_timeline(comments, activity)

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
