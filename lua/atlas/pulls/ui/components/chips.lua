local chips_component = require("atlas.ui.components.chips")
local presentation = require("atlas.pulls.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")

local M = {}

local CHECK_STATES = {
	muted = { priority = 0, label = "", icon = "unknown" },
	successful = { priority = 1, label = "Checks passed", icon = "successful" },
	inprogress = { priority = 2, label = "Checks pending", icon = "inprogress" },
	warning = { priority = 3, label = "Checks pending", icon = "inprogress" },
	failed = { priority = 4, label = "Checks failed", icon = "failed" },
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
	local icon, hl = icons.pulls_status(status.icon)
	return { label = icon .. " " .. status.label, hl = hl }
end

---@param pr PullRequest
---@param opts { width: integer, padding_x?: integer, extra_chips?: PullsDetailChip[], checks?: PullsMergeCheck[]|"loading"|string, loading?: boolean }
---@return string[], table[]
function M.render(pr, opts)
	local chips = {
		{ label = tostring(pr.state or "UNKNOWN"), hl = presentation.pr_state_hl(pr.state) },
	}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	local checks = opts.checks
	if opts.loading or checks == "loading" then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
	elseif type(checks) == "table" then
		table.insert(chips, checks_chip(checks))
	end

	return chips_component.render(chips, opts)
end

---@param repo AtlasRepositoryDetails
---@param opts { width: integer, padding_x?: integer, extra_chips?: PullsDetailChip[] }
---@return string[], table[]
function M.render_repo(repo, opts)
	local chips = {
		{
			label = string.format("%s %s", icons.pulls("file"), utils.human_size(repo.size)),
			hl = "AtlasTabInactive",
		},
		{
			label = string.format("%s %s", icons.pulls("branch"), tostring(repo.default_branch or "-")),
			hl = "AtlasPROpenChip",
		},
		repo.is_private == true and { label = "private", hl = "AtlasPRDraftChip" }
			or { label = "public", hl = "AtlasTextPositive" },
	}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	return chips_component.render(chips, opts)
end

---@param text string|nil
---@param opts { width: integer, padding_x?: integer }
---@return string[], table[]
function M.render_loading(text, opts)
	return chips_component.render({ { label = spinner.with_text(text or "Loading..."), hl = "AtlasTextMuted" } }, opts)
end

return M
