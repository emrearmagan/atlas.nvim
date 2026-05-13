local M = {}

local helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")

---@param chips PullsPanelChip[]
---@param opts { padding_x?: integer }|nil
---@return string, table[]
local function render_chips(chips, opts)
	opts = opts or {}
	local pad = math.max(0, opts.padding_x or 1)
	local line = string.rep(" ", pad)
	local spans = {}
	local col = pad

	for _, chip in ipairs(chips) do
		if chip ~= nil then
			local label = string.format(" %s ", chip.label)
			line = line .. label .. " "
			if chip.hl ~= nil then
				table.insert(spans, {
					start_col = col,
					end_col = col + #label,
					hl_group = chip.hl,
				})
			end
			col = col + #label + 1
		end
	end

	return line, spans
end

---@param pr PullRequest
---@param opts { padding_x?: integer, extra_chips?: PullsPanelChip[] }|nil
---@return string, table[]
function M.render(pr, opts)
	opts = opts or {}
	local chips = {
		{ label = tostring(pr.state or "UNKNOWN"), hl = helper.pr_state_hl(pr.state) },
	}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	return render_chips(chips, opts)
end

---@param repo PullsRepoDetails
---@param opts { padding_x?: integer, extra_chips?: PullsPanelChip[] }|nil
---@return string, table[]
function M.render_repo(repo, opts)
	opts = opts or {}
	local raw = repo._raw or {}
	local chips = {
		{
			label = string.format("%s %s", icons.pulls("file"), utils.human_size(repo.size or raw.size)),
			hl = "AtlasTabInactive",
		},
		{
			label = string.format("%s %s", icons.pulls("branch"), tostring(repo.default_branch or "-")),
			hl = "AtlasBitbucketPRMerged",
		},
		(repo.is_private == true or raw.is_private == true)
			and { label = "private", hl = "AtlasBitbucketPRDraft" }
			or { label = "public", hl = "AtlasTextPositive" },
	}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	return render_chips(chips, opts)
end

---@param text string|nil
---@param opts { padding_x?: integer }|nil
---@return string, table[]
function M.render_loading(text, opts)
	return render_chips({ { label = spinner.with_text(text or "Loading..."), hl = "AtlasTextMuted" } }, opts)
end

return M
