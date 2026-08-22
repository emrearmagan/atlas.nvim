---@class JiraIssuesOverviewTab : IssuesPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local statusline = require("atlas.ui.statusline")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local state = require("atlas.issues.providers.jira.ui.overview.state")
local adf = require("atlas.issues.providers.jira.converted.adf")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local request_scope = require("atlas.core.requests")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local requests = request_scope.new()

function M.reset()
	requests.cancel()
	requests = request_scope.new()
	state.reset()
end

---@param raw any
---@return string
local function to_markdown(raw)
	if raw == nil then
		return ""
	end
	if type(raw) == "table" then
		return adf.to_markdown(raw) or ""
	end
	return tostring(raw)
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	opts = opts or {}

	local force_refresh = opts.force_refresh == true
	if not force_refresh and not state.description_loading and state.raw_description ~= nil then
		return
	end

	M.reset()
	state.description_loading = true

	local issue_key = tostring(issue.key or "")
	statusline.notify("loading", string.format("Loading description for %s...", issue_key))

	requests.run(function(done)
		return issues_api.get_issue_description(issue_key, done, { force_load = force_refresh })
	end, function(raw, err)
		state.description_loading = false

		if err then
			state.raw_description = nil
			state.md_description = nil
			statusline.notify("error", string.format("Failed to load description for %s", issue_key))
			refresh()
			return
		end

		state.raw_description = raw
		state.md_description = to_markdown(raw)

		statusline.notify("success", string.format("Description loaded for %s", issue_key), 1200)
		refresh()
	end)
end

-- Render

---@param issue Issue
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(issue, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	-- Description header + mode chip on same line
	local label = state.description_loading and "Loading description..." or "Description"
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
	if state.description_loading then
		utils.push(lines, spans, spinner.with_text("Loading..."), "AtlasTextMuted", PADDING_X)
	elseif state.raw_description == nil and not state.description_loading then
	elseif state.view_mode == "raw" then
		local raw_text
		if type(state.raw_description) == "table" then
			raw_text = vim.inspect(state.raw_description)
		else
			raw_text = tostring(state.raw_description or "")
		end
		for _, line in ipairs(vim.split(raw_text, "\n", { plain = true })) do
			table.insert(lines, PADDING .. line)
		end
	else
		local md = tostring(state.md_description or "")
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

---@return boolean
function M.is_loading()
	return state.description_loading
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
	requests.cancel()
	requests = request_scope.new()
	if state.description_loading then
		state.description_loading = false
		statusline.clear_notice()
	end
end

return M
