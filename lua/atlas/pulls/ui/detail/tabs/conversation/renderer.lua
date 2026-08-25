local M = {}

local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local icons = require("atlas.ui.shared.icons")
local threads = require("atlas.ui.components.threadsv2")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local activity_component = require("atlas.pulls.ui.detail.components.activity")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local detail = require("atlas.pulls.ui.detail.state")

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
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	local inner = math.max(1, width - (PADDING_X * 2) - 4)
	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local fold_key = fold_keys and fold_keys[1]
	local lines, spans, line_map = review_threads.render({ thread }, inner, {
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

---@param line_map table<integer, table>
---@param item PullsConversationItem
local function attach_item(line_map, item)
	for _, entry in pairs(line_map) do
		entry.conversation_item = item
		entry.entity_kind = item.kind
	end
end

---@param line_map table<integer, table>
---@param by_entity table<table, PullsConversationItem>
local function attach_entities(line_map, by_entity)
	for _, entry in pairs(line_map) do
		local item = by_entity[entry.comment or entry.activity_entry]
		if item then
			entry.conversation_item = item
		end
	end
end

-- Timeline

---@class PullsConversationTimelineEntry
---@field type "comment"|"review"|"activity_run"
---@field timestamp string
---@field thread AtlasReviewThreadNode|nil
---@field item PullsConversationItem|nil
---@field items PullsConversationItem[]|nil

---@param items PullsConversationItem[]
---@return PullsConversationTimelineEntry[], table<table, PullsConversationItem>
local function build_timeline(items)
	local mixed = {}
	local comments, by_entity = {}, {}
	for _, item in ipairs(items) do
		by_entity[item.entity] = item
		if item.kind == "comment" then
			---@type PullsComment
			local comment = item.entity
			table.insert(comments, comment)
		else
			table.insert(mixed, {
				kind = item.kind,
				timestamp = item.created_on,
				item = item,
			})
		end
	end
	for _, thread in ipairs(review_threads.group_comments(comments)) do
		table.insert(mixed, {
			kind = "comment",
			timestamp = thread.comment.created_on or "",
			thread = thread,
		})
	end
	table.sort(mixed, function(a, b)
		local ta, tb = tostring(a.timestamp), tostring(b.timestamp)
		if ta == tb then
			-- Keep an activity before other items created at the same time.
			return a.kind == "activity" and b.kind ~= "activity"
		end
		return ta < tb
	end)
	-- Collapse consecutive activities into a single activity_run entry.
	local entries, run = {}, {}
	local function flush_run()
		if #run > 0 then
			table.insert(entries, { type = "activity_run", timestamp = run[1].created_on, items = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		if item.kind == "activity" then
			table.insert(run, item.item)
		else
			flush_run()
			if item.kind == "review" then
				table.insert(entries, { type = item.kind, timestamp = item.timestamp, item = item.item })
			else
				table.insert(entries, {
					type = "comment",
					timestamp = item.timestamp,
					thread = item.thread,
				})
			end
		end
	end
	flush_run()
	return entries, by_entity
end

-- Render

---@param review PullsReviewHistoryEntry
---@return string, string, string
local function review_status(review)
	local icon, hl = icons.pulls("activity")
	local label = "left a review"
	if review.state == "approved" then
		icon, hl = icons.pulls_status("successful")
		label = "approved"
	elseif review.state == "changes_requested" then
		icon, hl = icons.pulls_status("failed")
		label = "requested changes"
	elseif review.state == "dismissed" then
		if review.previous_state == "approved" then
			icon = icons.pulls_status("successful")
			hl = "AtlasTextMuted"
			label = "previously approved"
		elseif review.previous_state == "changes_requested" then
			icon = icons.pulls_status("failed")
			hl = "AtlasTextMuted"
			label = "previously requested changes"
		else
			icon, hl = icons.pulls_status("stopped")
			label = "dismissed"
		end
	end
	return icon, hl, label
end

---@param item PullsConversationItem
---@param width integer
---@param has_next boolean
local function render_review(item, width, has_next)
	---@type PullsReviewHistoryEntry
	local review = item.entity
	local icon, icon_hl, label = review_status(review)
	local timestamp = utils.relative_time(review.submitted_on)
	local additional = timestamp ~= "" and (label .. "  " .. timestamp) or label
	local body = utils.strip_markup(review.body)
	local lines, spans, line_map = threads.render(
		{
			{
				icon = icon,
				icon_hl = icon_hl,
				author = review.author and (review.author.nickname or review.author.name) or "Unknown",
				additional = additional,
				content = body ~= "" and body or nil,
			},
		},
		width,
		{
			padding_x = PADDING_X,
			content_prefix = has_next and "│ " or "  ",
			additional_hl = function(_, text)
				local highlights = {
					{ start_col = 0, end_col = math.min(#label, #text), hl_group = icon_hl },
				}
				local time_start = #label + 2
				if time_start < #text then
					table.insert(highlights, {
						start_col = time_start,
						end_col = #text,
						hl_group = "AtlasTextMuted",
					})
				end
				return highlights
			end,
		}
	)
	attach_item(line_map, item)
	return lines, spans, line_map
end

---@param entry PullsConversationTimelineEntry
---@param width integer
---@param has_next boolean
---@param by_entity table<table, PullsConversationItem>
local function render_entry(entry, width, has_next, by_entity)
	if entry.type == "comment" then
		local thread = entry.thread
		local root = thread.comment
		if root.is_task then
			local lines, spans, line_map = review_threads.render_task_compact(thread, width, {
				padding_x = PADDING_X,
				content_prefix = has_next and "│ " or "  ",
			})
			attach_entities(line_map, by_entity)
			return lines, spans, line_map
		end
		local key = tostring(root.id)
		if #thread.children > 0 and state.collapsed[key] == nil then
			state.collapsed[key] = true
		end
		local lines, spans, line_map = render_thread(thread, state.is_collapsed(root.id), width)
		attach_entities(line_map, by_entity)
		return lines, spans, line_map
	elseif entry.type == "review" and entry.item then
		return render_review(entry.item, width, has_next)
	elseif entry.type == "activity_run" then
		local run_id = tostring(entry.timestamp or "")
		local activities = {}
		for _, item in ipairs(entry.items or {}) do
			---@type PullsActivityEntry
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

---@param _pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
function M.render(_pr, _details, width)
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

	---@cast state.items PullsConversationItem[]
	local items = state.items
	local entries, by_entity = build_timeline(items)

	if #entries == 0 then
		utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for index, entry in ipairs(entries) do
		if #lines > 0 then
			append_connector(lines, spans)
		end
		local e_lines, e_spans, e_map = render_entry(entry, width, index < #entries, by_entity)
		splice(lines, spans, line_map, e_lines, e_spans, e_map)
	end

	return lines, spans, line_map
end

return M
