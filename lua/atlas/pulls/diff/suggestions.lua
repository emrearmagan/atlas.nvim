local diff_hunks = require("atlas.ui.components.diff_hunks")
local diff_parser = require("atlas.core.git.diff_parser")
local notify = require("atlas.core.notify")

-- Use vim.diff on Neovim < 0.12.
---@diagnostic disable-next-line: deprecated
local vim_diff = vim.text and vim.text.diff or vim.diff

local M = {}

---@class AtlasDiffSuggestion
---@field comment PullsComment
---@field path string
---@field first integer
---@field last integer
---@field lines string[]

-- Returns the lines fenced as a suggestion for a review comment.
---@param lines string[]
---@param provider string
---@return string
function M.format(lines, provider)
	local fence = "suggestion"
	if provider == "gitlab" then
		-- GitLab comments sit on the last line, so reach up to the first.
		fence = string.format("suggestion:-%d+0", #lines - 1)
	end
	return string.format("```%s\n%s\n```", fence, table.concat(lines, "\n"))
end

---@param comment PullsComment
---@return AtlasDiffSuggestion|nil
local function parse(comment)
	local inline = comment.inline
	local range, code = comment.body:gsub("\r\n", "\n"):match("```suggestion(%S*)[ \t]*\n(.-)```")
	if not inline or not inline.to or not range then
		return nil
	end

	-- The newline before the closing fence leaves an empty last line.
	local lines = vim.split(code, "\n", { plain = true })
	table.remove(lines)

	-- GitLab puts the range in the fence: suggestion:-2+0 is 2 lines above, 0 below.
	local above, below = range:match("^:%-(%d+)%+(%d+)$")
	return {
		comment = comment,
		path = inline.path,
		first = above and inline.to - tonumber(above) or inline.start_to or inline.to,
		last = below and inline.to + tonumber(below) or inline.to,
		lines = lines,
	}
end

---@param session AtlasDiffSessionInternal
---@return AtlasDiffSuggestion[]
function M.list(session)
	local suggestions = {}
	for _, comment in ipairs(session.review and session.review.comments or {}) do
		local open = not comment.deleted and not comment.outdated and comment.state == nil
		local suggestion = open and parse(comment)
		if suggestion then
			suggestions[#suggestions + 1] = suggestion
		end
	end
	return suggestions
end

---@param lines string[]
---@param suggestion AtlasDiffSuggestion
---@return string[]
local function replace(lines, suggestion)
	return vim.list_extend(
		vim.list_extend(vim.list_slice(lines, 1, suggestion.first - 1), suggestion.lines),
		vim.list_slice(lines, suggestion.last + 1)
	)
end

---@param root string
---@param suggestions AtlasDiffSuggestion[]
function M.apply(root, suggestions)
	local by_path = {}
	for _, suggestion in ipairs(suggestions) do
		by_path[suggestion.path] = by_path[suggestion.path] or {}
		table.insert(by_path[suggestion.path], suggestion)
	end

	local skipped = 0
	for path, list in pairs(by_path) do
		-- Bottom up, so the line numbers of the ones above stay valid.
		table.sort(list, function(a, b)
			return a.first > b.first
		end)
		local file = vim.fs.joinpath(root, path)
		local lines = vim.fn.readfile(file, "b")
		local applied_from = math.huge
		for _, suggestion in ipairs(list) do
			if suggestion.last >= applied_from or suggestion.last > #lines then
				skipped = skipped + 1
			else
				lines = replace(lines, suggestion)
				applied_from = suggestion.first
			end
		end
		vim.fn.writefile(lines, file, "b")
	end

	if skipped > 0 then
		notify.warn(string.format("Skipped %d overlapping suggestions", skipped))
	end
end

---@param suggestion AtlasDiffSuggestion
---@param content string The commented file.
---@param width integer
---@return AtlasPickerPreview
function M.preview(suggestion, content, width)
	local new = replace(vim.split(content, "\n", { plain = true }), suggestion)
	local patch = vim_diff(content, table.concat(new, "\n"), { ctxlen = 3 })
	---@cast patch string
	local file = { path = suggestion.path, status = "modified", hunks = { diff_parser.parse_hunk(patch) } }
	local lines, highlights = diff_hunks.hunks({ file }, { max_width = width, show_file_header = false })
	return { title = suggestion.path, lines = lines, highlights = highlights }
end

return M
