local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local utils = require("atlas.ui.shared.utils")

---@param pr PullRequest
---@return string[], AtlasUIHighlight[]
function M.content(pr)
	local id = tostring(pr.id or "")
	local marker = pr.provider == "gitlab" and "!" or "#"
	local state = tostring(pr.state or "-")
	local author = tostring((pr.author and pr.author.name) or "Unknown")
	local repo = tostring(pr.repo_full_name or "")
	local branch = tostring((pr.source or {}).branch or "?")
		.. " → "
		.. tostring((pr.destination or {}).branch or "?")
	local rows = {
		{ "State", state, helper.pr_state_hl(state) },
		{ "Author", author, helper.author_hl(author) },
		{ "Repo", repo ~= "" and repo or "-", repo ~= "" and helper.repo_hl(repo) or "AtlasTextMuted" },
		{ "Branch", branch, "AtlasTextMuted" },
		{ "Comments", tostring(pr.comments_count or 0), "AtlasTextMuted" },
		{ "Tasks", tostring(pr.tasks_count or 0), "AtlasTextMuted" },
		{ "Updated", utils.relative_time(pr.updated_on), "AtlasTextMuted" },
	}

	local lines = { string.format(" %s%s: %s", marker, id, tostring(pr.title or "")), "" }
	---@type AtlasUIHighlight[]
	local highlights = {}
	if id ~= "" then
		table.insert(highlights, { line = 0, start_col = 2, end_col = 2 + #id, hl_group = "AtlasTextMuted" })
	end

	for _, row in ipairs(rows) do
		local line = #lines
		table.insert(lines, string.format(" %-10s %s", row[1] .. ":", row[2]))
		table.insert(highlights, { line = line, start_col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
		table.insert(highlights, {
			line = line,
			start_col = 12,
			end_col = #lines[line + 1],
			hl_group = row[3],
		})
	end

	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(math.max(1, width - 1))
	table.insert(highlights, { line = 1, start_col = 0, end_col = #lines[2], hl_group = "AtlasTextMuted" })

	return lines, highlights
end

return M
