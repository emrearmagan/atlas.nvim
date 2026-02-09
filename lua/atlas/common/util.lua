---@class Bitbucket.Common.Util
local M = {}

-- Trim whitespace
function M.strim(s)
	return s:match("^%s*(.-)%s*$")
end

-- Format relative time
function M.format_relative_time(iso_date)
	if not iso_date then
		return "Unknown"
	end

	-- Parse ISO 8601 date
	local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
	local year, month, day, hour, min, sec = iso_date:match(pattern)

	if not year then
		return "Unknown"
	end

	local time = os.time({
		year = year,
		month = month,
		day = day,
		hour = hour,
		min = min,
		sec = sec,
	})

	local diff = os.difftime(os.time(), time)
	local days = math.floor(diff / 86400)
	local hours = math.floor(diff / 3600)
	local minutes = math.floor(diff / 60)

	if days > 0 then
		return days .. "d ago"
	elseif hours > 0 then
		return hours .. "h ago"
	elseif minutes > 0 then
		return minutes .. "m ago"
	else
		return "just now"
	end
end

-- Setup highlights
function M.setup_static_highlights()
	vim.api.nvim_set_hl(0, "BitbucketLine", { fg = "#6c7086" })
	vim.api.nvim_set_hl(0, "BitbucketCursorLine", { fg = "#cdd6f4", bg = "#45475a", bold = true })
	vim.api.nvim_set_hl(0, "BitbucketTitle", { fg = "#61afef", bold = true })
	vim.api.nvim_set_hl(0, "BitbucketPRNumber", { fg = "#98c379" })
	vim.api.nvim_set_hl(0, "BitbucketAuthor", { fg = "#e5c07b" })
	vim.api.nvim_set_hl(0, "BitbucketApproved", { fg = "#98c379" })
	vim.api.nvim_set_hl(0, "BitbucketNeedsWork", { fg = "#e06c75" })
	vim.api.nvim_set_hl(0, "BitbucketComments", { fg = "#61afef" })
	vim.api.nvim_set_hl(0, "BitbucketBuildSuccess", { fg = "#a6e3a1" })
	vim.api.nvim_set_hl(0, "BitbucketBuildFailed", { fg = "#f38ba8" })
	vim.api.nvim_set_hl(0, "BitbucketBuildInProgress", { fg = "#f9e2af" })
	vim.api.nvim_set_hl(0, "BitbucketDraft", { fg = "#11111b", bg = "#cba6f7", bold = true })
	vim.api.nvim_set_hl(0, "BitbucketRepo", { fg = "#c678dd" })
	vim.api.nvim_set_hl(0, "BitbucketBranch", { fg = "#56b6c2" })
	vim.api.nvim_set_hl(0, "BitbucketTime", { fg = "#abb2bf" })
	vim.api.nvim_set_hl(0, "BitbucketTabActive", { link = "CurSearch", bold = true })
	vim.api.nvim_set_hl(0, "BitbucketTabInactive", { link = "Search" })
	vim.api.nvim_set_hl(0, "BitbucketTopLevel", { link = "CursorLineNr", bold = true })
	vim.api.nvim_set_hl(0, "BitbucketPRTitle", { fg = "#f2cdcd" })
	vim.api.nvim_set_hl(0, "BitbucketHeaderLine", { fg = "#6c7086" })
	vim.api.nvim_set_hl(0, "BitbucketIconRepo", { fg = "#6c7086" })

	-- PR Details overlay highlights
	vim.api.nvim_set_hl(0, "BitbucketPRDetailsHeader", { fg = "#61afef", bold = true })
	vim.api.nvim_set_hl(0, "BitbucketPRDetailsFooter", { fg = "#abb2bf", italic = true })
	vim.api.nvim_set_hl(0, "BitbucketPRDetailsLabel", { fg = "#c678dd", bold = true })
end

return M
