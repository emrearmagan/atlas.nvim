---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")
local highlights = require("atlas.ui.highlights")
local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local stack = require("atlas.pulls.providers.github.stack")
local state = require("atlas.pulls.ui.detail.state")

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

	local logins = vim.tbl_map(function(assignee)
		return assignee.username
	end, details.assignees)

	return { header.assignee_field(logins) }
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param _loading boolean
---@return PullsDetailChip[]
function M.chips(pr, details, _loading)
	---@cast pr GitHubPullRequest
	---@cast details GitHubPullRequestDetails|nil
	local chips = {}

	local indicator = stack.indicator(pr.stack)
	if indicator then
		table.insert(chips, { label = indicator, hl = "AtlasRelatedChip" })
	end

	for _, lbl in ipairs(details and details.labels or {}) do
		table.insert(chips, { label = lbl.name, hl = highlights.label(lbl.color) })
	end

	return chips
end

-- Tabs

---@return PullsDetailTab[]
function M.tabs()
	return require("atlas.pulls.ui.detail").default_tabs()
end

-- Keymaps

---@param direction 1|-1
local function navigate_stack(direction)
	local pr = state.current_pr
	if pr == nil then
		return
	end
	---@cast pr GitHubPullRequest
	if not stack.is_stacked(pr.stack) then
		notify.info("PR is not part of a stack")
		return
	end

	local details = state.current_details
	---@cast details GitHubPullRequestDetails|nil
	if details == nil or details.stack == nil then
		return
	end

	local entry = stack.neighbor(details.stack, direction)
	if entry == nil then
		if direction > 0 then
			notify.info("Top of stack")
		else
			notify.info("Bottom of stack")
		end
		return
	end

	if entry.number == nil then
		notify.warn("Stack PR is not accessible")
		return
	end

	require("atlas.pulls.ui.detail").open({ id = entry.number, repo_full_name = pr.repo_full_name }, {
		provider = state.provider,
		on_update = state.on_update,
		back = state.back,
	})
end

---@return PullsDetailKeymap[]
function M.keymaps()
	local keymaps = {}

	local prev_keys = resolver.resolve("pulls.stack.prev")
	if prev_keys then
		table.insert(keymaps, {
			key = prev_keys,
			desc = "Previous PR in stack",
			callback = function()
				navigate_stack(-1)
			end,
		})
	end

	local next_keys = resolver.resolve("pulls.stack.next")
	if next_keys then
		table.insert(keymaps, {
			key = next_keys,
			desc = "Next PR in stack",
			callback = function()
				navigate_stack(1)
			end,
		})
	end

	return keymaps
end

return M
