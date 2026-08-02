local M = {}

local utils = require("atlas.ui.shared.utils")
local helper = require("atlas.pulls.ui.main.helper")

---@param pr PullRequest
---@return string[], AtlasUIHighlight[]
function M.content(pr)
	local id = tostring(pr.id or "")
	local title = tostring(pr.title or "")
	local author_name = tostring((pr.author and pr.author.name) or "Unknown")
	local repo_name = tostring(pr.repo_full_name or "")

	local lines = {
		string.format(" #%s: %s", id, title),
		"",
		string.format(" State:    %s", tostring(pr.state or "-")),
		string.format(" Author:   %s", author_name),
		string.format(" Repo:     %s", repo_name ~= "" and repo_name or "-"),
		string.format(
			" Branch:   %s -> %s",
			tostring((pr.source or {}).branch or "?"),
			tostring((pr.destination or {}).branch or "?")
		),
		string.format(" Comments: %s", tostring(pr.comments_count or 0)),
		string.format(" Tasks:    %s", tostring(pr.tasks_count or 0)),
		string.format(" Updated:  %s", utils.relative_time(pr.updated_on)),
	}

	local content_width = 1
	for _, line in ipairs(lines) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(content_width)

	local hl = {
		{ line = 1, start_col = 0, end_col = #lines[2], hl_group = "AtlasTextMuted" },
		{ line = 2, start_col = 1, end_col = 10, hl_group = "AtlasTextMuted" },
		{ line = 2, start_col = 11, end_col = #lines[3], hl_group = helper.pr_state_hl(pr.state) },
		{ line = 3, start_col = 1, end_col = 10, hl_group = "AtlasTextMuted" },
		{ line = 3, start_col = 11, end_col = #lines[4], hl_group = helper.author_hl(author_name) },
		{ line = 4, start_col = 1, end_col = 10, hl_group = "AtlasTextMuted" },
		{ line = 4, start_col = 11, end_col = #lines[5], hl_group = helper.repo_hl(repo_name) },
		{ line = 5, start_col = 1, end_col = 10, hl_group = "AtlasTextMuted" },
		{ line = 5, start_col = 11, end_col = #lines[6], hl_group = "AtlasTextMuted" },
		{ line = 6, start_col = 1, end_col = 10, hl_group = "AtlasTextMuted" },
		{ line = 7, start_col = 1, end_col = 10, hl_group = "AtlasTextMuted" },
		{ line = 8, start_col = 1, end_col = 10, hl_group = "AtlasTextMuted" },
		{ line = 8, start_col = 11, end_col = #lines[9], hl_group = "AtlasTextMuted" },
	}

	if id ~= "" then
		table.insert(hl, {
			line = 0,
			start_col = 2,
			end_col = 2 + #id,
			hl_group = "AtlasTextMuted",
		})
	end

	return lines, hl
end

return M
