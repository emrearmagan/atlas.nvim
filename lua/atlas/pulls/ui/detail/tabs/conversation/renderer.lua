local M = {}

local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local icons = require("atlas.ui.shared.icons")
local threads = require("atlas.ui.components.threads")
local review_actions = require("atlas.pulls.actions.review")
local comment_threads = require("atlas.pulls.ui.components.comment_threads")
local activity_component = require("atlas.pulls.ui.detail.components.activity")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local detail = require("atlas.pulls.ui.detail.state")
local overview = require("atlas.pulls.ui.detail.tabs.overview.state")

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
	for lnum, data in pairs(src_map or {}) do
		dst_map[offset + lnum] = data
	end
end

---@param thread AtlasCommentThreadNode
---@param collapsed boolean
---@param width integer
---@param format_text (fun(text: string): string)|nil
local function render_thread(thread, collapsed, width, format_text)
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local fold_key = fold_keys and fold_keys[1]
	local opts = {
		boxed = true,
		format_text = format_text,
		expanded = function()
			return not collapsed
		end,
		padding_x = PADDING_X,
		reaction_options = comments and comments.reaction_options,
		content_max_lines = fold_key and state.comment_max_lines or nil,
		content_truncated_key = fold_key,
	}
	return comment_threads.render({ thread }, width, opts)
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
---@field thread AtlasCommentThreadNode|nil
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
	for _, thread in ipairs(review_actions.group_comments(comments)) do
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
---@param format_text (fun(text: string): string)|nil
local function render_review(item, width, has_next, format_text)
	---@type PullsReviewHistoryEntry
	local review = item.entity
	local icon, icon_hl, label = review_status(review)
	local timestamp = utils.relative_time(review.submitted_on)
	local additional = { { label, icon_hl } }
	if timestamp ~= "" then
		additional[#additional + 1] = { "  " .. timestamp, "AtlasTextMuted" }
	end

	local body = review.body or ""
	if format_text then
		body = format_text(body)
	end
	local lines, spans, line_map = threads.render(
		{
			{
				icon = icon,
				icon_hl = icon_hl,
				author = review.author and (review.author.nickname or review.author.name) or "Unknown",
				additional = additional,
				content = body ~= "" and body or nil,
				markdown = true,
			},
		},
		width,
		{
			padding_x = PADDING_X,
			content_prefix = has_next and "│ " or "  ",
		}
	)
	attach_item(line_map, item)
	return lines, spans, line_map
end

---@param entry PullsConversationTimelineEntry
---@param width integer
---@param has_next boolean
---@param by_entity table<table, PullsConversationItem>
---@param format_text (fun(text: string): string)|nil
local function render_entry(entry, width, has_next, by_entity, format_text)
	if entry.type == "comment" then
		local thread = entry.thread
		local root = thread.comment
		if root.is_task then
			local lines, spans, line_map = comment_threads.render_task_compact(thread, width, {
				padding_x = PADDING_X,
				format_text = format_text,
				content_prefix = has_next and "│ " or "  ",
			})
			attach_entities(line_map, by_entity)
			return lines, spans, line_map
		end
		local lines, spans, line_map =
			render_thread(thread, state.is_collapsed(root.id, #thread.children > 0), width, format_text)
		attach_entities(line_map, by_entity)
		return lines, spans, line_map
	elseif entry.type == "review" and entry.item then
		return render_review(entry.item, width, has_next, format_text)
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

---@param entry PullsConversationTimelineEntry|nil
---@return boolean
local function is_activity(entry)
	return entry ~= nil and (entry.type ~= "comment" or entry.thread.comment.is_task == true)
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param width integer
function M.render(pr, details, width)
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

	local reviewers = type(overview.reviewers) == "table" and overview.reviewers or nil
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	local formatter = comments and comments.comment_formatter
	local format_text = formatter
		and formatter({
			pr = pr,
			details = details,
			conversation = state.comments(),
			reviewers = reviewers,
		})

	for index, entry in ipairs(entries) do
		if #lines > 0 then
			if is_activity(entry) and is_activity(entries[index - 1]) then
				utils.push(lines, spans, "│", "AtlasTextMuted", PADDING_X)
			else
				lines[#lines + 1] = ""
			end
		end
		local has_next = is_activity(entry) and is_activity(entries[index + 1])
		local e_lines, e_spans, e_map = render_entry(entry, width, has_next, by_entity, format_text)
		splice(lines, spans, line_map, e_lines, e_spans, e_map)
	end

	return lines, spans, line_map
end

return M
