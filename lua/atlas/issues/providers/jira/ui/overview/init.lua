---@class JiraIssuesOverviewTab : IssuesPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.issues.providers.jira.ui.overview.state")
local adf = require("atlas.issues.providers.jira.converted.adf")
local issues_api = require("atlas.issues.providers.jira.api.issues")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@type { cancel: fun() }[]
local in_flight = {}

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		handle.cancel()
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
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

	cancel_all()
	state.description_loading = true
	state.raw_description = nil
	state.md_description = nil

	local issue_key = tostring(issue.key or "")
	footer.notify("loading", string.format("Loading description for %s...", issue_key))

	track(issues_api.get_issue_description(issue_key, function(raw, err)
		state.description_loading = false

		if err then
			state.raw_description = nil
			state.md_description = nil
			footer.notify("error", string.format("Failed to load description for %s", issue_key))
			refresh()
			return
		end

		state.raw_description = raw
		state.md_description = to_markdown(raw)

		footer.notify("success", string.format("Description loaded for %s", issue_key), 1200)
		refresh()
	end, { force_load = force_refresh }))
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

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
	table.insert(spans, { line = hline, start_col = PADDING_X, end_col = PADDING_X + #label, hl_group = "AtlasTextMuted" })
	table.insert(spans, { line = hline, start_col = #header_line - #chip, end_col = #header_line, hl_group = "AtlasChipActive" })

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
		pcall(vim.treesitter.stop, buf)
		vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
		vim.api.nvim_set_option_value("filetype", "", { buf = buf })
	end
end

function M.activate(buf, refresh)
	apply_filetype(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.keymap.set("n", "m", function()
			state.view_mode = state.view_mode == "raw" and "markdown" or "raw"
			apply_filetype(buf)
			if refresh then
				refresh()
			end
		end, { buffer = buf, silent = true, nowait = true })
	end
end

function M.deactivate(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.keymap.del, "n", "m", { buffer = buf })
		pcall(vim.treesitter.stop, buf)
		vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
		vim.api.nvim_set_option_value("filetype", "", { buf = buf })
	end
	cancel_all()
	if state.description_loading then
		state.description_loading = false
		footer.notify("info", "", 0)
	end
end

return M
