---@type PullsProviderDetail
local M = {}

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(_pr, details, _loading)
	local chips = {}
	for _, label in ipairs(details and details.labels or {}) do
		table.insert(chips, { label = label.name, hl = "AtlasTabInactive" })
	end
	return chips
end

return M
