---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")

---@param hex string
---@return string
local function label_hl(hex)
	local name = string.format("AtlasGHLabel_%s_1e1e2e", hex)
	if next(vim.api.nvim_get_hl(0, { name = name, create = false })) == nil then
		vim.api.nvim_set_hl(0, name, { fg = "#1e1e2e", bg = "#" .. hex, bold = true })
	end
	return name
end

-- Detail

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, loading)
	---@cast details GitHubPullRequestDetails|nil
	if details == nil then
		return loading and { header.loading_field("Assignees") } or {}
	end

	local logins = {}
	for _, assignee in ipairs(details.assignees) do
		local login = assignee.username
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	return { header.assignee_field(logins) }
end

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(_pr, details, _loading)
	---@cast details GitHubPullRequestDetails|nil
	local chips = {}

	for _, lbl in ipairs(details and details.labels or {}) do
		local name = tostring(lbl.name or "")
		if name ~= "" then
			local color = tostring(lbl.color or "")
			local hl = color ~= "" and label_hl(color) or "AtlasTabInactive"
			table.insert(chips, { label = name, hl = hl })
		end
	end

	return chips
end

-- Tabs

---@return PullsDetailTab[]
function M.tabs()
	return require("atlas.pulls.ui.detail").default_tabs()
end

return M
