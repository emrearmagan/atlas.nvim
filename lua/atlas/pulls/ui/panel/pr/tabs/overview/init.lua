---@class PullsOverviewTab : PullsPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
local keymaps = require("atlas.pulls.ui.panel.pr.tabs.overview.keymaps")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local MAX_DESCRIPTION_LINES = 8

---@type { cancel: fun() }[]
local in_flight = {}

---@return PullsProvider|nil
local function get_provider()
	local pulls_state = require("atlas.pulls.state")
	return pulls_state.provider
end

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

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, repo, refresh, opts)
	opts = opts or {}

	local provider = get_provider()
	if not provider then
		return
	end

	local force_refresh = opts.force_refresh == true
	local pr_id = tostring(pr.id or "")

	local can_fetch_reviewers = type(provider.fetch_reviewers) == "function"
	local can_fetch_description = type(provider.fetch_description) == "function"
	local can_fetch_merge_checks = type(provider.fetch_merge_checks) == "function"
	local should_fetch_reviewers = can_fetch_reviewers
		and (force_refresh or state.reviewers == nil or state.reviewers == "loading")
	local should_fetch_description = can_fetch_description
		and (force_refresh or state.description == nil or state.description == "loading")
	local should_fetch_merge_checks = can_fetch_merge_checks
		and (force_refresh or state.merge_checks == nil or state.merge_checks == "loading")

	if should_fetch_reviewers or should_fetch_description or should_fetch_merge_checks then
		cancel_all()
	end

	local pending = 0
	local errors = 0
	if should_fetch_description then
		pending = pending + 1
	end
	if should_fetch_reviewers then
		pending = pending + 1
	end
	if should_fetch_merge_checks then
		pending = pending + 1
	end

	if pending > 0 then
		footer.notify("loading", string.format("Loading overview for #%s...", pr_id))
	end

	local function complete(err)
		if err then
			errors = errors + 1
		end
		pending = pending - 1
		if pending == 0 then
			if errors > 0 then
				footer.notify("error", string.format("Failed to load overview for #%s", pr_id))
			else
				footer.notify("success", string.format("Overview loaded for #%s", pr_id), 1200)
			end
		end
	end

	if should_fetch_description then
		state.description = "loading"
		track(provider.fetch_description(pr, opts, function(desc, err)
			if err then
				state.description = nil
			else
				state.description = desc or ""
			end
			complete(err)
			refresh()
		end))
	end

	if should_fetch_reviewers then
		state.reviewers = "loading"
		track(provider.fetch_reviewers(pr, opts, function(reviewers, err)
			if err then
				state.reviewers = err
			else
				state.reviewers = reviewers or {}
			end
			complete(err)
			refresh()
		end))
	end

	if should_fetch_merge_checks then
		state.merge_checks = "loading"
		track(provider.fetch_merge_checks(pr, opts, function(checks, err)
			if err then
				state.merge_checks = err
			else
				state.merge_checks = checks or {}
			end
			complete(err)
			refresh()
		end))
	end
end

--------------------------------------------------------------------------------
-- Reviewers
--------------------------------------------------------------------------------

local DECISION_GROUPS = { "approved", "changes_requested", "pending" }

local DECISION_ICONS = {
	approved = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	changes_requested = { icon = icons.pulls_status("failed"), hl = "AtlasTextWarning" },
	pending = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
}

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_reviewers(pr, width, lines, spans)
	if state.reviewers == nil then
		return
	end

	if state.reviewers == "loading" then
		utils.push(lines, spans, "Reviewers (...)", "AtlasColumnHeader", PADDING_X)
		local header_text = "Reviewers (...)"
		local count_text = "(...)"
		table.insert(spans, {
			line = #lines - 1,
			start_col = PADDING_X + #header_text - #count_text,
			end_col = PADDING_X + #header_text,
			hl_group = "AtlasTextMuted",
		})
		local loading_text = spinner.with_text("Loading reviewers...")
		utils.append_block(
			lines,
			spans,
			box.render(
				{
					{
						lines = { loading_text },
						spans = { { line = 0, start_col = 0, end_col = #loading_text, hl_group = "AtlasTextMuted" } },
					},
				},
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	if type(state.reviewers) == "string" then
		utils.push(lines, spans, "Reviewers", "AtlasColumnHeader", PADDING_X)
		local err_text = state.reviewers
		utils.append_block(
			lines,
			spans,
			box.render(
				{
					{
						lines = { err_text },
						spans = { { line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" } },
					},
				},
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	local decisions = state.reviewers
	local approved_count = 0
	for _, r in ipairs(decisions) do
		if r.decision == "approved" then
			approved_count = approved_count + 1
		end
	end

	local header_text = string.format("Reviewers (%d/%d)", approved_count, #decisions)
	utils.push(lines, spans, header_text, "AtlasColumnHeader", PADDING_X)
	local count_text = string.format("(%d/%d)", approved_count, #decisions)
	table.insert(spans, {
		line = #lines - 1,
		start_col = PADDING_X + #header_text - #count_text,
		end_col = PADDING_X + #header_text,
		hl_group = "AtlasTextMuted",
	})

	if #decisions == 0 then
		local empty_text = "no reviewers yet"
		utils.append_block(
			lines,
			spans,
			box.render(
				{
					{
						lines = { empty_text },
						spans = { { line = 0, start_col = 0, end_col = #empty_text, hl_group = "AtlasTextMuted" } },
					},
				},
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	local box_lines = {}
	local box_spans = {}
	local grouped = { approved = {}, changes_requested = {}, pending = {} }
	for _, d in ipairs(decisions) do
		local s = d.decision or "pending"
		if grouped[s] == nil then
			s = "pending"
		end
		local name = (d.name and d.name ~= "") and d.name
			or (d.nickname and d.nickname ~= "") and d.nickname
			or "Unknown"
		table.insert(grouped[s], name)
	end

	local box_inner = math.max(10, width - (PADDING_X * 2) - 4)
	for _, s in ipairs(DECISION_GROUPS) do
		local names = grouped[s]
		if #names > 0 then
			table.sort(names)
			local d = DECISION_ICONS[s] or DECISION_ICONS.pending
			local label = table.concat(names, ", ")
			local icon_prefix = d.icon .. " "
			local icon_prefix_width = vim.api.nvim_strwidth(icon_prefix)
			local label_width = math.max(1, box_inner - icon_prefix_width)
			local wrapped = utils.wrap_line(label, label_width)

			local line_text = icon_prefix .. wrapped[1]
			table.insert(box_lines, line_text)
			table.insert(box_spans, {
				line = #box_lines - 1,
				start_col = 0,
				end_col = #d.icon,
				hl_group = d.hl,
			})

			local continuation_prefix = string.rep(" ", icon_prefix_width)
			for i = 2, #wrapped do
				table.insert(box_lines, continuation_prefix .. wrapped[i])
			end
		end
	end

	utils.append_block(
		lines,
		spans,
		box.render({ { lines = box_lines, spans = box_spans } }, {
			width = width,
			padding_x = PADDING_X,
		})
	)
	table.insert(lines, "")
end

--------------------------------------------------------------------------------
-- Builds
--------------------------------------------------------------------------------

local BUILD_HL = {
	SUCCESSFUL = "AtlasBuildLinkSuccess",
	FAILED = "AtlasBuildLinkFailed",
	INPROGRESS = "AtlasBuildLinkInProgress",
	STOPPED = "AtlasBuildLinkMuted",
}

---@param status string
---@return string
local function status_label(status)
	local s = tostring(status or ""):lower()
	if s == "" then
		return "Unknown"
	end
	return s:sub(1, 1):upper() .. s:sub(2)
end

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_builds(pr, width, lines, spans, line_map)
	if state.builds == nil then
		return
	end

	if state.builds == "loading" then
		utils.push(lines, spans, "Builds", "AtlasColumnHeader", PADDING_X)
		local loading_text = spinner.with_text("Loading builds...")
		utils.append_block(
			lines,
			spans,
			box.render(
				{
					{
						lines = { loading_text },
						spans = { { line = 0, start_col = 0, end_col = #loading_text, hl_group = "AtlasTextMuted" } },
					},
				},
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	if type(state.builds) == "string" then
		utils.push(lines, spans, "Builds", "AtlasColumnHeader", PADDING_X)
		local err_text = state.builds
		utils.append_block(
			lines,
			spans,
			box.render(
				{
					{
						lines = { err_text },
						spans = { { line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" } },
					},
				},
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	local entries = state.builds

	if #entries == 0 then
		return
	end

	utils.push(lines, spans, "Builds", "AtlasColumnHeader", PADDING_X)

	local box_inner = math.max(10, width - (PADDING_X * 2) - 4)
	local box_lines = {}
	local box_spans = {}
	local box_lmap = {}

	for _, entry in ipairs(entries) do
		local s = tostring(entry.state or "UNKNOWN")
		local icon = icons.pulls_status(s:lower())
		local name = tostring(entry.name or entry.key or "Build")
		local text = string.format("%s %s (%s)", icon, name, status_label(s))
		local wrapped = utils.wrap_line(text, box_inner)

		for i, chunk in ipairs(wrapped) do
			table.insert(box_lines, chunk)
			box_lmap[#box_lines - 1] = { kind = "build", build = entry, url = tostring(entry.url or "") }
			local hl = i == 1 and (BUILD_HL[s] or "AtlasBuildLinkMuted") or "AtlasBuildLinkMuted"
			table.insert(box_spans, {
				line = #box_lines - 1,
				start_col = 0,
				end_col = #chunk,
				hl_group = hl,
			})
		end
	end

	utils.append_block(
		lines,
		spans,
		box.render({ { lines = box_lines, spans = box_spans, line_map = box_lmap } }, {
			width = width,
			padding_x = PADDING_X,
			line_map = line_map,
			line_offset = #lines,
		})
	)
	table.insert(lines, "")
end

--------------------------------------------------------------------------------
-- Description
--------------------------------------------------------------------------------

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_description(pr, width, lines, spans)
	local content_width = math.max(10, width - (PADDING_X * 2))

	utils.push(lines, spans, "Description", "AtlasColumnHeader", PADDING_X)

	if state.description == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading description..."), "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
		return
	end

	local desc_text = utils.strip_markup(state.description or pr.description or "")
	if desc_text == "" then
		utils.push(lines, spans, "No description provided.", "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
		return
	end

	local desc_lines = utils.sanitize_lines(desc_text)
	while #desc_lines > 0 and vim.trim(desc_lines[#desc_lines]) == "" do
		table.remove(desc_lines)
	end

	local truncated = false
	if not state.description_expanded and #desc_lines > MAX_DESCRIPTION_LINES then
		desc_lines = vim.list_slice(desc_lines, 1, MAX_DESCRIPTION_LINES)
		truncated = true
	end

	for _, line in ipairs(desc_lines) do
		table.insert(lines, PADDING .. line)
	end

	if truncated then
		local keys = require("atlas.core.keymaps").resolve("ui.toggle_fold") or {}
		local key = keys[1] or "za"
		local prefix = "Press "
		local suffix = " to expand"
		local hint = prefix .. key .. suffix
		local pad = math.max(0, math.floor((width - #hint) / 2))
		local hint_line = string.rep(" ", pad) .. hint
		table.insert(lines, "")
		table.insert(lines, hint_line)
		local line_idx = #lines - 1
		local prefix_start = pad
		local key_start = prefix_start + #prefix
		local suffix_start = key_start + #key
		local hint_end = suffix_start + #suffix
		table.insert(
			spans,
			{ line = line_idx, start_col = prefix_start, end_col = key_start, hl_group = "AtlasTextMuted" }
		)
		table.insert(spans, { line = line_idx, start_col = key_start, end_col = suffix_start, hl_group = "Normal" })
		table.insert(
			spans,
			{ line = line_idx, start_col = suffix_start, end_col = hint_end, hl_group = "AtlasTextMuted" }
		)
	end

	table.insert(lines, "")
end

--------------------------------------------------------------------------------
-- Merge checks
--------------------------------------------------------------------------------

local MERGE_CHECK_STATE = {
	successful = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	failed = { icon = icons.pulls_status("failed"), hl = "AtlasLogError" },
	inprogress = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
	warning = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextWarning" },
	muted = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
}

---@param check PullsMergeCheck
---@return BoxContentGroup
local function render_merge_check_group(check)
	local pair = MERGE_CHECK_STATE[check.state] or MERGE_CHECK_STATE.muted
	local lines = {}
	local spans = {}

	local heading = string.format("%s %s", pair.icon, check.label)
	table.insert(lines, heading)
	table.insert(spans, { line = 0, start_col = 0, end_col = #pair.icon, hl_group = pair.hl })

	for _, detail in ipairs(check.details or {}) do
		local indent = "  "
		local text = indent .. detail
		table.insert(lines, text)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" })
	end

	return { lines = lines, spans = spans }
end

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_merge_checks(pr, width, lines, spans) ---@diagnostic disable-line: unused-local
	if state.merge_checks == nil then
		return
	end

	utils.push(lines, spans, "Merge Checks", "AtlasColumnHeader", PADDING_X)

	if state.merge_checks == "loading" then
		local loading_text = spinner.with_text("Loading merge checks...")
		utils.append_block(
			lines,
			spans,
			box.render(
				{
					{
						lines = { loading_text },
						spans = { { line = 0, start_col = 0, end_col = #loading_text, hl_group = "AtlasTextMuted" } },
					},
				},
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	if type(state.merge_checks) == "string" then
		local err_text = state.merge_checks --[[@as string]]
		utils.append_block(
			lines,
			spans,
			box.render(
				{
					{
						lines = { err_text },
						spans = { { line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" } },
					},
				},
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	local checks = state.merge_checks --[[@as PullsMergeCheck[] ]]
	if #checks == 0 then
		table.insert(lines, "")
		return
	end

	local groups = {}
	for _, check in ipairs(checks) do
		table.insert(groups, render_merge_check_group(check))
	end

	utils.append_block(lines, spans, box.render(groups, { width = width, padding_x = PADDING_X }))
	table.insert(lines, "")
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	render_description(pr, width, lines, spans)
	render_reviewers(pr, width, lines, spans)
	render_merge_checks(pr, width, lines, spans)
	render_builds(pr, width, lines, spans, line_map)

	return lines, spans, line_map
end

---@param _lnum integer
---@param _entry table
---@return boolean
function M.is_selectable_line(_lnum, _entry)
	return false
end

---@param _pr PullRequest
---@param entry table
---@return boolean|nil
function M.on_enter(_pr, entry)
	if entry.kind == "build" and entry.url and entry.url ~= "" then
		vim.ui.open(entry.url)
		return true
	end
end

function M.activate(buf, refresh)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
	if refresh ~= nil then
		keymaps.setup(buf, refresh)
	end
end

function M.deactivate(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	keymaps.teardown(buf)
	pcall(vim.treesitter.stop, buf)
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	vim.api.nvim_set_option_value("filetype", "", { buf = buf })
	cancel_all()
end

return M
