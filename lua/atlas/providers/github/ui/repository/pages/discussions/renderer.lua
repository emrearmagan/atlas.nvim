local highlights = require("atlas.ui.highlights")
local emojis = require("atlas.ui.shared.emojis")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param segments string[][]
---@return integer
local function width_of(segments)
	local width = 0
	for _, segment in ipairs(segments) do
		width = width + vim.api.nvim_strwidth(segment[1])
	end

	return width
end

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

---@param discussion GitHubDiscussion
---@return string[][]
local function leading(discussion)
	if discussion.pinned then
		local icon, hl = icons.get("pin")
		return { { " " }, { icon, hl }, { "  " } }
	end

	return { { " " }, { emojis.get(discussion.category.emoji), "Normal" }, { "  " } }
end

---@param discussion GitHubDiscussion
---@return string[][]
local function stats(discussion)
	local comment_icon, comment_hl = icons.get("comment")
	if discussion.answered then
		comment_icon, comment_hl = icons.get("check_circle")
	end

	return {
		{ icons.get("upvote") .. " " .. discussion.upvotes .. "  ", "AtlasTextMuted" },
		{ comment_icon, comment_hl },
		{ " " .. discussion.comments, "AtlasTextMuted" },
	}
end

---@param discussion GitHubDiscussion
---@param width integer
---@return string[][]
local function title_line(discussion, width)
	local segments = leading(discussion)
	local right = stats(discussion)
	local available = width - width_of(segments) - width_of(right) - 3
	local title = utils.truncate(discussion.title, available)
	table.insert(segments, { title, "Normal" })

	local used = vim.api.nvim_strwidth(title)
	for _, label in ipairs(discussion.labels) do
		local chip = " " .. label.name .. " "
		local chip_width = vim.api.nvim_strwidth(chip) + 1
		if used + chip_width > available then
			break
		end

		table.insert(segments, { " " })
		table.insert(segments, { chip, highlights.label(label.color) })
		used = used + chip_width
	end

	local gap = width - width_of(segments) - width_of(right) - 1
	table.insert(segments, { string.rep(" ", math.max(2, gap)) })

	return vim.list_extend(segments, right)
end

---@param discussion GitHubDiscussion
---@return string[][]
local function detail_line(discussion)
	local author = discussion.author or "ghost"
	local verb = discussion.category.answerable and " asked " or " started "
	local segments = {
		{ string.rep(" ", width_of(leading(discussion))) },
		{ "#" .. discussion.number .. "  ", "AtlasTextMuted" },
		{ author, highlights.dynamic_for(author) },
		{
			verb .. utils.relative_time_text(discussion.created_at) .. " in " .. discussion.category.name,
			"AtlasTextMuted",
		},
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

---@param state RepositoryDiscussions
---@param width integer
---@return string[][]
local function header(state, width)
	local page = ""
	if state.page > 1 or state.next_cursor then
		page = "Page " .. state.page
	end

	local prefix = " " .. icons.get("search") .. " "
	local query = vim.trim((state.query:gsub("%s+", " ")))
	query = utils.truncate(query, math.max(1, width - vim.api.nvim_strwidth(prefix) - #page - 3))
	local segments = { { prefix .. query, "AtlasTextMuted" } }
	if page ~= "" then
		table.insert(segments, { string.rep(" ", math.max(2, width - width_of(segments) - #page - 1)) })
		table.insert(segments, { page, "AtlasTextMuted" })
	end

	return segments
end

---@param state RepositoryDiscussions
---@param width integer
---@return string[], table[], table<integer, GitHubDiscussion>
function M.render(state, width)
	local lines, line_map, spans = {}, {}, {}
	add_line(lines, spans, header(state, width))
	add_line(lines, spans, {})

	local discussions = state.discussions
	---@cast discussions GitHubDiscussion[]
	for index, discussion in ipairs(discussions) do
		add_line(lines, spans, title_line(discussion, width))
		line_map[#lines] = discussion

		add_line(lines, spans, detail_line(discussion))
		line_map[#lines] = discussion

		if index < #discussions then
			add_line(lines, spans, { { " " }, { string.rep("─", math.max(1, width - 2)), "AtlasBorder" } })
		end
	end

	return lines, spans, line_map
end

return M
