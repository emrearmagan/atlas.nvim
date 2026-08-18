local M = {}

local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local activity_component = require("atlas.issues.ui.panel.issue.tabs.components.activity")
local state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")

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
	for _, line in ipairs(src_lines) do
		table.insert(dst_lines, line)
	end
	for _, span in ipairs(src_spans) do
		span.line = span.line + offset
		table.insert(dst_spans, span)
	end
	for lnum, entry in pairs(src_map or {}) do
		dst_map[offset + lnum] = entry
	end
end

---@param thread IssuesCommentThreadNode
---@param collapsed boolean
---@param width integer
local function render_thread(thread, collapsed, width)
	local provider = require("atlas.issues.state").provider
	local comments = provider and provider.capabilities.comments
	local inner = math.max(1, width - (PADDING_X * 2) - 4)
	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local fold_key = fold_keys and fold_keys[1]
	local lines, spans, line_map = comment_threads.render({ thread }, inner, {
		expanded = function()
			return not collapsed
		end,
		padding_x = 0,
		reaction_options = comments and comments.reaction_options,
		content_max_lines = fold_key and state.comment_max_lines or nil,
		content_truncated_key = fold_key,
	})
	local result = box.render({ { lines = lines, spans = spans, line_map = line_map } }, {
		width = width,
		padding_x = PADDING_X,
	})
	return result.lines, result.highlights, result.line_map
end

---@class IssuesConversationTimelineEntry
---@field type "comment"|"activity_run"
---@field timestamp string
---@field thread IssuesCommentThreadNode|nil
---@field activities IssueActivityEntry[]|nil

---@param comments IssueComment[]
---@param activity IssueActivityEntry[]
---@return IssuesConversationTimelineEntry[]
local function build_timeline(comments, activity)
	local mixed = {}
	for _, thread in ipairs(comment_threads.group_comments(comments)) do
		table.insert(mixed, {
			kind = "comment",
			timestamp = thread.comment.created or "",
			thread = thread,
		})
	end
	for _, entry in ipairs(activity) do
		table.insert(mixed, { kind = "activity", timestamp = entry.date or "", activity = entry })
	end
	table.sort(mixed, function(left, right)
		local left_time = tostring(left.timestamp)
		local right_time = tostring(right.timestamp)
		if left_time == right_time then
			return left.kind == "activity" and right.kind ~= "activity"
		end
		return left_time < right_time
	end)

	local entries = {}
	local run = {}
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
				thread = item.thread,
			})
		end
	end
	flush_run()
	return entries
end

---@param entry IssuesConversationTimelineEntry
---@param width integer
local function render_entry(entry, width)
	if entry.type == "comment" then
		local thread = entry.thread
		local root = thread.comment
		local key = tostring(root.id)
		if #thread.children > 0 and state.collapsed[key] == nil then
			state.collapsed[key] = true
		end
		return render_thread(thread, state.is_collapsed(root.id), width)
	end
	if entry.type == "activity_run" then
		local run_id = tostring(entry.timestamp or "")
		return activity_component.render(entry.activities or {}, width, {
			padding_x = PADDING_X,
			squash = not state.is_run_expanded(run_id),
			run_id = run_id,
		})
	end
	return {}, {}, {}
end

---@param _issue Issue
---@param width integer
function M.render(_issue, width)
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
	---@cast comments IssueComment[]
	---@cast activity IssueActivityEntry[]
	local entries = build_timeline(comments, activity)

	if #entries == 0 then
		utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for _, entry in ipairs(entries) do
		if #lines > 0 then
			append_connector(lines, spans)
		end
		local entry_lines, entry_spans, entry_map = render_entry(entry, width)
		splice(lines, spans, line_map, entry_lines, entry_spans, entry_map)
	end

	return lines, spans, line_map
end

M.render_comment = comment_threads.render_comment

return M
