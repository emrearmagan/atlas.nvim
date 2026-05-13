---@class GitLabPullsProviderPanel : PullsProviderPanel
local M = {}

local helper = require("atlas.pulls.ui.main.helper")

---@param pr PullRequest
---@return PullsPanelHeaderRow[]
function M.header_rows(pr)
	local raw = pr._raw or {}
	local assignees = type(raw.assignees) == "table" and raw.assignees or {}

	local logins = {}
	for _, node in ipairs(assignees) do
		local login = type(node) == "table" and tostring(node.username or node.name or "") or ""
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	local v1, v1_hl
	if #logins == 0 then
		v1 = "Unassigned"
		v1_hl = "AtlasTextMuted"
	else
		local parts = {}
		for _, login in ipairs(logins) do
			table.insert(parts, "@" .. login)
		end
		v1 = table.concat(parts, ", ")

		local spans = {}
		local cursor = 0
		for i, login in ipairs(logins) do
			local token = "@" .. login
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #token,
				hl_group = helper.author_hl(login),
			})
			cursor = cursor + #token
			if i < #logins then
				local sep = ", "
				table.insert(spans, {
					start_col = cursor,
					end_col = cursor + #sep,
					hl_group = "AtlasTextMuted",
				})
				cursor = cursor + #sep
			end
		end
		v1_hl = spans
	end

	return {
		{
			k1 = "Assignees:",
			v1 = v1,
			v1_hl = v1_hl,
			k2 = "",
			v2 = "",
			v2_hl = "AtlasTextMuted",
		},
	}
end

---@param _pr PullRequest
---@param active_tab string|nil
---@return boolean
function M.is_loading(_pr, active_tab)
	if active_tab ~= nil and active_tab ~= "overview" then
		return false
	end

	local overview_state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
	return overview_state.any_loading()
end

return M
