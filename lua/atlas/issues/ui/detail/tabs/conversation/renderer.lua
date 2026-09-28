local M = {}

local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local activity_component = require("atlas.issues.ui.detail.components.activity")
local detail = require("atlas.issues.ui.detail.state")
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
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local fold_key = fold_keys and fold_keys[1]
	return comment_threads.render({ thread }, width, {
		expanded = function()
			return not collapsed
		end,
		padding_x = PADDING_X,
		reaction_options = comments and comments.reaction_options,
		content_max_lines = fold_key and function(comment)
			return state.comment_max_lines(comment)
		end or nil,
		content_truncated_key = fold_key,
	})
end

---@param line_map table<integer, table>
---@param by_entity table<table, IssueConversationItem>
local function attach_entities(line_map, by_entity)
	for _, entry in pairs(line_map) do
		local item = by_entity[entry.comment or entry.activity_entry]
		if item then
			entry.conversation_item = item
		end
	end
end

---@class IssuesConversationTimelineEntry
---@field type "comment"|"activity_run"
---@field timestamp string
---@field thread IssuesCommentThreadNode|nil
---@field items IssueConversationItem[]|nil

---@param items IssueConversationItem[]
---@return IssuesConversationTimelineEntry[], table<table, IssueConversationItem>
local function build_timeline(items)
	local mixed = {}
	local comments, by_entity = {}, {}
	for _, item in ipairs(items) do
		by_entity[item.entity] = item
		if item.kind == "comment" then
			---@type IssueComment
			local comment = item.entity
			table.insert(comments, comment)
		else
			table.insert(mixed, {
				kind = "activity",
				timestamp = item.created_at,
				item = item,
			})
		end
	end
	for _, thread in ipairs(comment_threads.group_comments(comments)) do
		table.insert(mixed, {
			kind = "comment",
			timestamp = thread.comment.created or "",
			thread = thread,
		})
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
			table.insert(entries, { type = "activity_run", timestamp = run[1].created_at, items = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		if item.kind == "activity" then
			---@type IssueActivityEntry
			local activity = item.item.entity
			if activity.always_render then
				flush_run()
				table.insert(entries, {
					type = "activity_run",
					timestamp = item.timestamp,
					items = { item.item },
				})
			else
				table.insert(run, item.item)
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
	return entries, by_entity
end

---@param entry IssuesConversationTimelineEntry
---@param width integer
---@param has_next boolean
---@param by_entity table<table, IssueConversationItem>
local function render_entry(entry, width, has_next, by_entity)
	if entry.type == "comment" then
		local thread = entry.thread
		local root = thread.comment
		local key = tostring(root.id)
		if #thread.children > 0 and state.collapsed[key] == nil then
			state.collapsed[key] = true
		end
		local lines, spans, line_map = render_thread(thread, state.is_collapsed(root.id), width)
		attach_entities(line_map, by_entity)
		return lines, spans, line_map
	end
	if entry.type == "activity_run" then
		local run_id = tostring(entry.timestamp or "")
		---@type IssueActivityEntry[]
		local activities = {}
		for _, item in ipairs(entry.items or {}) do
			---@type IssueActivityEntry
			local activity = item.entity
			table.insert(activities, activity)
		end
		local lines, spans, line_map = activity_component.render(activities, width, {
			padding_x = PADDING_X,
			squash = not state.is_run_expanded(run_id),
			run_id = run_id,
			has_next = has_next,
		})
		attach_entities(line_map or {}, by_entity)
		return lines, spans, line_map
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

	if state.items == nil then
		return lines, spans, line_map
	end
	if state.items == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading conversation..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	---@cast state.items IssueConversationItem[]
	local entries, by_entity = build_timeline(state.items)

	if #entries == 0 then
		utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for index, entry in ipairs(entries) do
		local previous = entries[index - 1]
		local following = entries[index + 1]
		if #lines > 0 then
			if entry.type == "activity_run" and previous.type == "activity_run" then
				utils.push(lines, spans, "│", "AtlasTextMuted", PADDING_X)
			else
				lines[#lines + 1] = ""
			end
		end
		local has_next = entry.type == "activity_run" and following ~= nil and following.type == "activity_run"
		local entry_lines, entry_spans, entry_map = render_entry(entry, width, has_next, by_entity)
		splice(lines, spans, line_map, entry_lines, entry_spans, entry_map)
	end

	return lines, spans, line_map
end

return M
