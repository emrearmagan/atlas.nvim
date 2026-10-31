local chips_component = require("atlas.ui.components.chips")
local presentation = require("atlas.pulls.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")

local M = {}

local CHECK_STATES = {
	muted = { priority = 0, label = "", icon = "unknown" },
	successful = { priority = 1, label = "Checks passed", icon = "successful", hl = "AtlasTextPositive" },
	inprogress = { priority = 2, label = "Checks pending", icon = "inprogress", hl = "AtlasTextMuted" },
	warning = { priority = 3, label = "Checks blocked", icon = "inprogress", hl = "AtlasTextWarning" },
	failed = { priority = 4, label = "Checks failed", icon = "failed", hl = "AtlasLogError" },
}

---@param checks PullsMergeCheck[]
---@return PullsDetailChip|nil
local function checks_chip(checks)
	local status = CHECK_STATES.muted
	for _, check in ipairs(checks) do
		local current = CHECK_STATES[check.state]
		if current.priority > status.priority then
			status = current
		end
	end

	if status == CHECK_STATES.muted then
		return nil
	end

	return { label = icons.get(status.icon, "status") .. " " .. status.label, hl = status.hl }
end

---@param pr PullRequest
---@param opts { width: integer, padding_x?: integer, extra_chips?: PullsDetailChip[], checks?: PullsMergeCheck[]|"loading"|string }
---@return string[], table[]
function M.render(pr, opts)
	local chips = {
		{ label = tostring(pr.state or "UNKNOWN"), hl = presentation.pr_state_hl(pr.state) },
	}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	local checks = opts.checks
	if checks == "loading" then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
	elseif type(checks) == "table" then
		table.insert(chips, checks_chip(checks))
	elseif type(checks) == "string" then
		table.insert(
			chips,
			{ label = icons.get("inprogress", "status") .. " Checks unavailable", hl = "AtlasTextWarning" }
		)
	end

	return chips_component.render(chips, opts)
end

return M
