local M = {}

local overview = require("atlas.issues.ui.detail.tabs.overview")
local utils = require("atlas.ui.shared.utils")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@param issue Issue
---@param details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(issue, details, width)
	local lines, spans, line_map = overview.render(issue, details, width)
	if details == nil then
		return lines, spans, line_map
	end
	---@cast details ShortcutIssueDetails
	if #details.tasks == 0 then
		return lines, spans, line_map
	end

	table.insert(lines, "")
	utils.push(lines, spans, "Checklist", "AtlasColumnHeader", PADDING_X)
	for _, task in ipairs(details.tasks) do
		local rows = utils.sanitize_lines(task.description)
		local marker = task.complete and "- [x] " or "- [ ] "
		table.insert(lines, PADDING .. marker .. (rows[1] or ""))
		for index = 2, #rows do
			table.insert(lines, PADDING .. "      " .. rows[index])
		end
	end

	return lines, spans, line_map
end

M.activate = overview.activate
M.deactivate = overview.deactivate

return M
