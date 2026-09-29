---@type PullsProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(_pr, details, _loading)
	---@cast details BitbucketPullRequestDetails|nil
	local fields = {}

	if details and details.close_source_branch ~= nil then
		local state_icon, state_icon_hl
		if details.close_source_branch then
			state_icon, state_icon_hl = icons.general("success")
		else
			state_icon, state_icon_hl = icons.general("error")
		end
		table.insert(fields, {
			label = "Close source",
			value = state_icon,
			hl = state_icon_hl,
		})
	end

	return fields
end

---@return PullsDetailTab[]
function M.tabs()
	return require("atlas.pulls.ui.detail").default_tabs()
end

return M
