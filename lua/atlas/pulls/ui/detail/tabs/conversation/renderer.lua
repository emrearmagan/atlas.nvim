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
local function render_thread(thread, collapsed, width)
	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local fold_key = fold_keys and fold_keys[1]
	local opts = {
		boxed = true,
		expanded = function()
			return not collapsed
		end,
		padding_x = PADDING_X,
		content_max_lines = fold_key and state.comment_max_lines or nil,
		content_truncated_key = fold_key,
	}
	return comment_threads.render({ thread }, width, opts)
end

-- Timeline

---@class PullsConversationTimelineEntry
---@field timestamp string
---@field thread AtlasCommentThreadNode|nil
---@field review PullsReviewHistoryEntry|nil
---@field activities PullsActivityEntry[]|nil

---@param conversation PullsConversation
---@return PullsConversationTimelineEntry[]
local function build_timeline(conversation)
	local mixed = {}
	for _, thread in ipairs(review_actions.group_comments(conversation.comments)) do
		table.insert(mixed, { timestamp = thread.comment.created_at or "", thread = thread })
	end
	for _, review in ipairs(conversation.reviews) do
		table.insert(mixed, { timestamp = review.submitted_on, review = review })
	end
	for _, activity in ipairs(conversation.activities) do
		table.insert(mixed, { timestamp = activity.date or "", activity = activity })
	end
	table.sort(mixed, function(a, b)
		if a.timestamp == b.timestamp then
			-- Keep an activity before other items created at the same time.
			return a.activity ~= nil and b.activity == nil
		end
		return a.timestamp < b.timestamp
	end)
	-- Collapse consecutive activities into a single entry.
	local entries, run = {}, {}
	if conversation.description then
		-- Not sorted by time: commits can be authored before the PR was opened.
		local description = review_actions.group_comments({ conversation.description })[1]
		table.insert(entries, { timestamp = description.comment.created_at, thread = description })
	end
	local function flush_run()
		if #run > 0 then
			table.insert(entries, { timestamp = run[1].date or "", activities = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		if item.activity then
			table.insert(run, item.activity)
		else
			flush_run()
			table.insert(entries, { timestamp = item.timestamp, thread = item.thread, review = item.review })
		end
	end
	flush_run()
	return entries
end

-- Render

---@param review PullsReviewHistoryEntry
---@return string, string, string
local function review_status(review)
	local icon, hl = icons.get("activity")
	local label = "left a review"
	if review.state == "approved" then
		icon, hl = icons.get("successful", "status")
		label = "approved"
	elseif review.state == "changes_requested" then
		icon, hl = icons.get("failed", "status")
		label = "requested changes"
	elseif review.state == "dismissed" then
		if review.previous_state == "approved" then
			icon = icons.get("successful", "status")
			hl = "AtlasTextMuted"
			label = "previously approved"
		elseif review.previous_state == "changes_requested" then
			icon = icons.get("failed", "status")
			hl = "AtlasTextMuted"
			label = "previously requested changes"
		else
			icon, hl = icons.get("stopped", "status")
			label = "dismissed"
		end
	end
	return icon, hl, label
end

---@param review PullsReviewHistoryEntry
---@param width integer
---@param has_next boolean
local function render_review(review, width, has_next)
	local icon, icon_hl, label = review_status(review)
	local timestamp = utils.relative_time(review.submitted_on)
	local additional = { { label, icon_hl } }
	if timestamp ~= "" then
		additional[#additional + 1] = { "  " .. timestamp, "AtlasTextMuted" }
	end

	local body = review.body or ""
	local lines, spans, line_map = threads.render(
		{
			{
				icon = icon,
				icon_hl = icon_hl,
				author = review.author and (review.author.username or review.author.name) or "Unknown",
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
	for _, entry in pairs(line_map) do
		entry.review_entry = review
	end
	return lines, spans, line_map
end

---@param entry PullsConversationTimelineEntry
---@param width integer
---@param has_next boolean
local function render_entry(entry, width, has_next)
	local thread, review, activities = entry.thread, entry.review, entry.activities
	if thread then
		local root = thread.comment
		if root.is_task then
			return comment_threads.render({ thread }, width, {
				padding_x = PADDING_X,
				content_prefix = has_next and "│ " or "  ",
			})
		end
		return render_thread(thread, state.is_collapsed(root.id, #thread.children > 0), width)
	elseif review then
		return render_review(review, width, has_next)
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

---@param entry PullsConversationTimelineEntry|nil
---@return boolean
local function is_activity(entry)
	if entry == nil then
		return false
	end
	local thread = entry.thread
	return thread == nil or thread.comment.is_task == true
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
		if #lines > 0 then
			if is_activity(entry) and is_activity(entries[index - 1]) then
				utils.push(lines, spans, "│", "AtlasTextMuted", PADDING_X)
			else
				lines[#lines + 1] = ""
			end
		end
		local has_next = is_activity(entry) and is_activity(entries[index + 1])
		local e_lines, e_spans, e_map = render_entry(entry, width, has_next)
		splice(lines, spans, line_map, e_lines, e_spans, e_map)
	end

	return lines, spans, line_map
end

return M
