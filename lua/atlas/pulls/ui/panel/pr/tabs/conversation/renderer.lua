local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local review_threads = require("atlas.ui.components.review_threads")
local activity_component = require("atlas.pulls.ui.panel.pr.tabs.components.activity")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local CONNECTOR = "│"

---@param lines string[]
---@param spans table[]
local function append_connector(lines, spans)
	local connector_line = PADDING .. CONNECTOR
	table.insert(lines, connector_line)
	table.insert(spans, {
		line = #lines - 1,
		start_col = PADDING_X,
		end_col = PADDING_X + #CONNECTOR,
		hl_group = "AtlasTextMuted",
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

---@param thread AtlasReviewThreadNode
---@param collapsed boolean
---@param width integer
local function render_thread(thread, collapsed, width)
	local provider = require("atlas.pulls.state").provider
	local comments = provider and provider.capabilities.comments
	local inner = math.max(1, width - (PADDING_X * 2) - 4)
	local lines, spans, line_map = review_threads.render({ thread }, inner, {
		expanded = function()
			return not collapsed
		end,
		padding_x = 0,
		reaction_options = comments and comments.reaction_options,
	})
	local result = box.render({ { lines = lines, spans = spans, line_map = line_map } }, {
		width = width,
		padding_x = PADDING_X,
	})
	return result.lines, result.highlights, result.line_map
end

-- Timeline

---@class PullsConversationTimelineEntry
---@field type "comment"|"activity_run"
---@field timestamp string
---@field thread AtlasReviewThreadNode|nil
---@field activities PullsActivityEntry[]|nil

---@param comments PullsComment[]
---@param activity PullsActivityEntry[]
---@return PullsConversationTimelineEntry[]
local function build_timeline(comments, activity)
	-- Build a sorted mixed list of comments and activity entries.
	local mixed, description = {}, nil
	for _, thread in ipairs(review_threads.group_comments(comments)) do
		local item = {
			kind = "comment",
			timestamp = thread.comment.created_on or "",
			thread = thread,
		}
		if tostring(thread.comment.id) == "__body__" then
			description = item
		else
			table.insert(mixed, item)
		end
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
	if description then
		table.insert(mixed, 1, description)
	end

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
			table.insert(run, item.activity)
		else
			flush_run()
			table.insert(entries, {
				type = "comment",
				timestamp = item.timestamp,
				thread = item.thread,
			})
		end
	end
	flush_run()
	return entries
end

-- Render

---@param entry PullsConversationTimelineEntry
---@param width integer
---@param has_next boolean
local function render_entry(entry, width, has_next)
	if entry.type == "comment" then
		local thread = entry.thread
		local root = thread.comment
		local key = tostring(root.id)
		if #thread.children > 1 and state.collapsed[key] == nil then
			state.collapsed[key] = true
		end
		return render_thread(thread, state.is_collapsed(root.id), width)
	elseif entry.type == "activity_run" then
		local run_id = tostring(entry.timestamp or "")
		return activity_component.render(entry.activities or {}, width, {
			padding_x = PADDING_X,
			squash = not state.is_run_expanded(run_id),
			run_id = run_id,
			has_next = has_next,
		})
	end
	return {}, {}, {}
end

---@param _pr PullRequest
---@param width integer
function M.render(_pr, width)
	local lines, spans, line_map = {}, {}, {}

	if state.error then
		utils.push(lines, spans, state.error, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

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

	for index, entry in ipairs(entries) do
		if #lines > 0 then
			append_connector(lines, spans)
		end
		local e_lines, e_spans, e_map = render_entry(entry, width, index < #entries)
		splice(lines, spans, line_map, e_lines, e_spans, e_map)
	end

	return lines, spans, line_map
end

return M
