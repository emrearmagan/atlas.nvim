local M = {}

local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local activity_component = require("atlas.issues.ui.detail.components.activity")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")

local PADDING_X = 1

---@param dst_lines string[]
---@param dst_spans table[]
---@param dst_map table<integer, table>
---@param src_lines string[]
---@param src_spans table[]
---@param src_map table<integer, table>|nil
local function splice(dst_lines, dst_spans, dst_map, src_lines, src_spans, src_map)
	local offset = #dst_lines
	utils.append_block(dst_lines, dst_spans, { lines = src_lines, highlights = src_spans })
	for lnum, entry in pairs(src_map or {}) do
		dst_map[offset + lnum] = entry
	end
end

---@param thread IssuesCommentThreadNode
---@param collapsed boolean
---@param width integer
local function render_thread(thread, collapsed, width)
	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local fold_key = fold_keys and fold_keys[1]
	return comment_threads.render({ thread }, width, {
		expanded = function()
			return not collapsed
		end,
		padding_x = PADDING_X,
		content_max_lines = fold_key and function(comment)
			return state.comment_max_lines(comment)
		end or nil,
		content_truncated_key = fold_key,
	})
end

---@class IssuesConversationTimelineEntry
---@field timestamp string
---@field thread IssuesCommentThreadNode|nil
---@field activities IssueActivityEntry[]|nil

---@param conversation IssueConversation
---@return IssuesConversationTimelineEntry[]
local function build_timeline(conversation)
	local mixed = {}
	for _, thread in ipairs(comment_threads.group_comments(conversation.comments)) do
		table.insert(mixed, { timestamp = thread.comment.created_at or "", thread = thread })
	end
	for _, activity in ipairs(conversation.activities) do
		table.insert(mixed, { timestamp = activity.date or "", activity = activity })
	end
	table.sort(mixed, function(left, right)
		if left.timestamp == right.timestamp then
			return left.activity ~= nil and right.activity == nil
		end
		return left.timestamp < right.timestamp
	end)

	local entries = {}
	local run = {}
	if conversation.description then
		local description = comment_threads.group_comments({ conversation.description })[1]
		table.insert(entries, { timestamp = description.comment.created_at or "", thread = description })
	end
	local function flush_run()
		if #run > 0 then
			table.insert(entries, { timestamp = run[1].date or "", activities = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		local activity = item.activity
		if activity and activity.always_render then
			flush_run()
			table.insert(entries, { timestamp = item.timestamp, activities = { activity } })
		elseif activity then
			table.insert(run, activity)
		else
			flush_run()
			table.insert(entries, { timestamp = item.timestamp, thread = item.thread })
		end
	end
	flush_run()
	return entries
end

---@param entry IssuesConversationTimelineEntry
---@param width integer
---@param has_next boolean
local function render_entry(entry, width, has_next)
	local thread, activities = entry.thread, entry.activities
	if thread then
		local root = thread.comment
		return render_thread(thread, state.is_collapsed(root.id, #thread.children > 0), width)
	elseif activities then
		local run_id = entry.timestamp
		return activity_component.render(activities, width, {
			padding_x = PADDING_X,
			squash = not state.is_run_expanded(run_id),
			run_id = run_id,
			has_next = has_next,
		})
	end
	return {}, {}, {}
end

---@param _issue Issue
---@param _details IssueDetails|nil
---@param width integer
function M.render(_issue, _details, width)
	local lines, spans, line_map = {}, {}, {}

	if state.error then
		utils.push(lines, spans, state.error, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local conversation = state.conversation
	if conversation == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading conversation..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end
	if type(conversation) ~= "table" then
		return lines, spans, line_map
	end

	local entries = build_timeline(conversation)

	if #entries == 0 then
		utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for index, entry in ipairs(entries) do
		local previous = entries[index - 1]
		local following = entries[index + 1]
		if #lines > 0 then
			if entry.activities and previous.activities then
				utils.push(lines, spans, "│", "AtlasTextMuted", PADDING_X)
			else
				lines[#lines + 1] = ""
			end
		end
		local has_next = entry.activities ~= nil and following ~= nil and following.activities ~= nil
		local entry_lines, entry_spans, entry_map = render_entry(entry, width, has_next)
		splice(lines, spans, line_map, entry_lines, entry_spans, entry_map)
	end

	return lines, spans, line_map
end

return M
