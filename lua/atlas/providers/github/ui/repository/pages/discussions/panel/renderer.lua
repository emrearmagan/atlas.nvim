local chips = require("atlas.ui.components.chips")
local threads = require("atlas.ui.components.threads")
local highlights = require("atlas.ui.highlights")
local emojis = require("atlas.ui.shared.emojis")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param lines string[]
---@param spans table[]
---@param segments string[][]
local function add_line(lines, spans, segments)
	local line = ""
	for _, segment in ipairs(segments) do
		local text, hl_group = segment[1], segment[2]
		if hl_group and text ~= "" then
			table.insert(spans, { line = #lines, start_col = #line, end_col = #line + #text, hl_group = hl_group })
		end

		line = line .. text
	end

	table.insert(lines, line)
end

---@param comment GitHubDiscussionComment
---@param root GitHubDiscussionComment|nil
---@param expanded table<string, boolean>
---@return AtlasThreadItem
local function comment_item(comment, root, expanded)
	local author = comment.author or "ghost"
	local additional = { { utils.relative_time_text(comment.created_at), "AtlasTextMuted" } }
	if comment.author_roles then
		table.insert(additional, { "  " .. table.concat(comment.author_roles, " "), "AtlasTextMuted" })
	end
	if comment.answer then
		table.insert(additional, { "  " .. icons.get("check_circle") .. " Answer", "AtlasTextPositive" })
	end

	local footer_items = {}
	local children = {}
	if #comment.replies > 0 and not expanded[comment.id] then
		local count = #comment.replies
		table.insert(footer_items, {
			text = count .. (count == 1 and " reply" or " replies"),
			hl_group = "AtlasLogInfo",
		})
	else
		for _, reply in ipairs(comment.replies) do
			table.insert(children, comment_item(reply, root, expanded))
		end
	end

	local reactions = comment.reactions
	if comment.upvotes > 0 then
		local upvote = { name = "arrow_up", count = comment.upvotes, reacted = comment.upvoted }
		reactions = vim.list_extend({ upvote }, comment.reactions or {})
	end

	return {
		icon = icons.get("user"),
		icon_hl = highlights.dynamic_for(author),
		author = author,
		author_hl = highlights.dynamic_for(author),
		additional = additional,
		content = comment.deleted and "*This comment was deleted.*" or comment.body,
		markdown = true,
		reactions = reactions,
		footer_items = footer_items,
		children = children,
		line_map = { root = root, subject = not comment.deleted and comment or nil },
	}
end

---@param discussion GitHubDiscussion
---@return string[][]
local function title_line(discussion)
	local segments = {
		{ " " },
		{ icons.get("conversation") .. " Discussion", "Normal" },
		{ "  #" .. discussion.number, "AtlasTextMuted" },
	}

	if discussion.closed then
		table.insert(segments, { " · ", "AtlasTextMuted" })
		table.insert(segments, { "Closed", "Normal" })
	end

	if discussion.answered then
		table.insert(segments, { " · ", "AtlasTextMuted" })
		table.insert(segments, { "Answered", "AtlasTextPositive" })
	elseif discussion.category.answerable then
		table.insert(segments, { " · ", "AtlasTextMuted" })
		table.insert(segments, { "Unanswered", "Normal" })
	end

	return segments
end

---@param discussion GitHubDiscussionDetails|"loading"|string
---@param expanded table<string, boolean>
---@param width integer
---@return string[], table[], table<integer, AtlasThreadLineMap>
function M.render(discussion, expanded, width)
	local lines, spans, line_map = {}, {}, {}
	if discussion == "loading" then
		add_line(lines, spans, { { " " }, { "Loading discussion...", "AtlasTextMuted" } })
		return lines, spans, line_map
	elseif type(discussion) == "string" then
		add_line(lines, spans, { { " " }, { discussion, "AtlasLogError" } })
		return lines, spans, line_map
	end

	add_line(lines, spans, title_line(discussion))
	add_line(lines, spans, { { " " }, { discussion.title, "Normal" } })
	table.insert(spans, { line = 0, line_hl_group = "AtlasTabInactive" })
	table.insert(spans, { line = 1, line_hl_group = "AtlasTabInactive" })
	add_line(lines, spans, {})

	local items = {
		{
			label = emojis.get(discussion.category.emoji) .. " " .. discussion.category.name,
			hl = "AtlasRelatedChip",
		},
	}
	for _, label in ipairs(discussion.labels) do
		table.insert(items, { label = label.name, hl = highlights.label(label.color) })
	end

	local chip_lines, chip_spans = chips.render(items, { width = width })
	utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
	add_line(lines, spans, {})

	local thread_items = { comment_item(discussion.description, nil, expanded) }
	for _, comment in ipairs(discussion.thread) do
		table.insert(thread_items, comment_item(comment, comment, expanded))
	end

	local comment_lines, comment_spans, comment_map = threads.render_comments(thread_items, width, { padding_x = 1 })
	local offset = #lines
	utils.append_block(lines, spans, { lines = comment_lines, highlights = comment_spans })
	for row, entry in pairs(comment_map) do
		line_map[offset + row] = entry
	end

	if discussion.comments > #discussion.thread then
		add_line(lines, spans, {})
		add_line(lines, spans, {
			{ " " },
			{ (discussion.comments - #discussion.thread) .. " more comments on GitHub", "AtlasTextMuted" },
		})
	end

	return lines, spans, line_map
end

return M
