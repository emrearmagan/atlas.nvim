---@class JiraIssuesOverviewTab : IssuesPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local state = require("atlas.issues.providers.jira.ui.overview.state")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

-- Render

---@param issue IssueDetails
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(issue, width)
	local lines = {}
	local spans = {}
	local line_map = {}
	local raw_description = ((issue._raw or {}).fields or {}).description

	-- Description header + mode chip on same line
	local label = "Description"
	local mode_text = state.view_mode == "raw" and "Raw (m)" or "Markdown (m)"
	local chip = " " .. mode_text .. " "
	local gap = math.max(1, width - PADDING_X - #label - #chip)
	local header_line = PADDING .. label .. string.rep(" ", gap) .. chip

	table.insert(lines, header_line)
	local hline = #lines - 1
	table.insert(
		spans,
		{ line = hline, start_col = PADDING_X, end_col = PADDING_X + #label, hl_group = "AtlasTextMuted" }
	)
	table.insert(
		spans,
		{ line = hline, start_col = #header_line - #chip, end_col = #header_line, hl_group = "AtlasChipActive" }
	)

	-- Description content
	if state.view_mode == "raw" then
		local raw_text
		if type(raw_description) == "table" then
			raw_text = vim.inspect(raw_description)
		else
			raw_text = tostring(raw_description or "")
		end
		for _, line in ipairs(vim.split(raw_text, "\n", { plain = true })) do
			table.insert(lines, PADDING .. line)
		end
	else
		local md = tostring(issue.description or "")
		if md == "" then
			utils.push(lines, spans, "No description", "AtlasTextMuted", PADDING_X)
		else
			for _, line in ipairs(utils.sanitize_lines(md)) do
				table.insert(lines, PADDING .. line)
			end
		end
	end

	return lines, spans, line_map
end

---@param buf integer
local function apply_filetype(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	if state.view_mode == "markdown" then
		vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
		vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
	else
		vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
		vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
		pcall(vim.treesitter.stop, buf)
	end
end

function M.activate(buf, refresh)
	apply_filetype(buf)
	local keys = keymaps.resolve("issues.toggle_description_mode")
	if buf and vim.api.nvim_buf_is_valid(buf) and keys then
		help.register("Panel", {
			{
				key = #keys == 1 and keys[1] or keys,
				desc = "Toggle description mode",
				opts = { silent = true, nowait = true },
				callback = function()
					state.view_mode = state.view_mode == "raw" and "markdown" or "raw"
					apply_filetype(buf)
					if refresh then
						refresh()
					end
				end,
			},
		}, { index = 212, buffer = buf })
	end
end

function M.deactivate(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		local keys = keymaps.resolve("issues.toggle_description_mode")
		if keys then
			help.remove("Panel", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
		end
		vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
		vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
		pcall(vim.treesitter.stop, buf)
	end
end

return M
