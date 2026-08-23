---@class PullsOverviewTab : PullsPRPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local table_tree = require("atlas.ui.components.table_tree")
local statusline = require("atlas.ui.statusline")
local state = require("atlas.pulls.ui.panel.pr.tabs.overview.state")
local panel_state = require("atlas.pulls.ui.panel.pr.state")
local keymaps = require("atlas.pulls.ui.panel.pr.tabs.overview.keymaps")
local helper = require("atlas.pulls.ui.main.helper")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local MAX_DESCRIPTION_LINES = 15

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

function M.reset()
	cancel_all()
	state.reset()
end

---@param pr PullRequest
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	opts = opts or {}

	local provider = get_provider()
	if not provider then
		return
	end
	local core = provider.capabilities.core

	local force_refresh = opts.force_refresh == true
	local can_fetch_reviewers = core.fetch_reviewers ~= nil
	local can_fetch_merge_checks = core.fetch_merge_checks ~= nil
	local should_fetch_reviewers = can_fetch_reviewers
		and (force_refresh or state.reviewers == nil or state.reviewers == "loading")
	local should_fetch_merge_checks = can_fetch_merge_checks
		and (force_refresh or state.merge_checks == nil or state.merge_checks == "loading")

	if should_fetch_reviewers or should_fetch_merge_checks then
		cancel_all()
	end

	if should_fetch_reviewers then
		state.reviewers = "loading"
	end
	if should_fetch_merge_checks then
		state.merge_checks = "loading"
	end

	if should_fetch_reviewers then
		track(core.fetch_reviewers(pr, opts, function(reviewers, err)
			if err then
				state.reviewers = err
			else
				state.reviewers = reviewers or {}
			end
			refresh()
		end))
	end

	if should_fetch_merge_checks then
		track(core.fetch_merge_checks(pr, opts, function(checks, err)
			if err then
				state.merge_checks = err
			else
				state.merge_checks = checks or {}
			end
			refresh()
		end))
	end
end

-- Reviewers

local DECISION_GROUPS = { "approved", "changes_requested", "reviewed", "pending" }
local OTHER_DECISION_GROUPS = { "approved", "changes_requested" }

local DECISION_ICONS = {
	approved = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	changes_requested = { icon = icons.pulls_status("failed"), hl = "AtlasLogError" },
	reviewed = { icon = icons.pulls("review"), hl = "AtlasTextMuted" },
	pending = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
}

---@param decisions PullsReviewer[]
---@param groups string[]
---@param width integer
---@return BoxContentGroup
local function decision_content(decisions, groups, width)
	local box_lines = {}
	local box_spans = {}
	local grouped = { approved = {}, changes_requested = {}, reviewed = {}, pending = {} }
	for _, decision in ipairs(decisions) do
		local decision_state = decision.decision or "pending"
		if grouped[decision_state] == nil then
			decision_state = "pending"
		end
		table.insert(grouped[decision_state], helper.user_handle(decision))
	end

	local box_inner = math.max(10, width - (PADDING_X * 2) - 4)
	for _, decision_state in ipairs(groups) do
		local names = grouped[decision_state]
		if #names > 0 then
			table.sort(names)
			local display = DECISION_ICONS[decision_state] or DECISION_ICONS.pending
			local label = table.concat(names, ", ")
			local icon_prefix = display.icon .. " "
			local icon_prefix_width = vim.api.nvim_strwidth(icon_prefix)
			local label_width = math.max(1, box_inner - icon_prefix_width)
			local wrapped = utils.wrap_line(label, label_width)

			local line_text = icon_prefix .. wrapped[1]
			table.insert(box_lines, line_text)
			table.insert(box_spans, {
				line = #box_lines - 1,
				start_col = 0,
				end_col = #display.icon,
				hl_group = display.hl,
			})

			local continuation_prefix = string.rep(" ", icon_prefix_width)
			for i = 2, #wrapped do
				table.insert(box_lines, continuation_prefix .. wrapped[i])
			end
		end
	end

	return { lines = box_lines, spans = box_spans }
end

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_reviewers(pr, width, lines, spans)
	if state.reviewers == nil then
		return
	end

	if state.reviewers == "loading" then
		local approved_count = 0
		local reviewer_count = 0
		for _, reviewer in ipairs(pr.reviewers or {}) do
			if reviewer.role ~= "participant" then
				reviewer_count = reviewer_count + 1
				if reviewer.decision == "approved" then
					approved_count = approved_count + 1
				end
			end
		end
		local count_text = pr.reviewers and string.format("(%d/%d)", approved_count, reviewer_count) or "(...)"
		local header_text = "Reviewers " .. count_text
		utils.push(lines, spans, header_text, "AtlasColumnHeader", PADDING_X)
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
			box.render({
				{
					lines = { loading_text },
					spans = { { line = 0, start_col = 0, end_col = #loading_text, hl_group = "AtlasTextMuted" } },
				},
			}, { width = width, padding_x = PADDING_X })
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
			box.render({
				{
					lines = { err_text },
					spans = { { line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" } },
				},
			}, { width = width, padding_x = PADDING_X })
		)
		table.insert(lines, "")
		return
	end

	local decisions = {}
	local others = {}
	for _, reviewer in ipairs(state.reviewers) do
		table.insert(reviewer.role == "participant" and others or decisions, reviewer)
	end
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

	local content
	if #decisions == 0 then
		local empty_text = "no reviewers yet"
		content = {
			lines = { empty_text },
			spans = { { line = 0, start_col = 0, end_col = #empty_text, hl_group = "AtlasTextMuted" } },
		}
	else
		content = decision_content(decisions, DECISION_GROUPS, width)
	end

	if #others > 0 then
		table.insert(content.lines, "")
		local label = "Other decisions"
		table.insert(content.lines, label)
		table.insert(content.spans, {
			line = #content.lines - 1,
			start_col = 0,
			end_col = #label,
			hl_group = "AtlasColumnHeader",
		})

		local other_content = decision_content(others, OTHER_DECISION_GROUPS, width)
		local line_offset = #content.lines
		for _, line in ipairs(other_content.lines) do
			table.insert(content.lines, line)
		end
		for _, span in ipairs(other_content.spans) do
			table.insert(content.spans, {
				line = line_offset + span.line,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end

	utils.append_block(lines, spans, box.render({ content }, { width = width, padding_x = PADDING_X }))
	table.insert(lines, "")
end

-- Pipelines

local PIPELINE_HL = {
	SUCCESSFUL = "AtlasPipelineLinkSuccess",
	FAILED = "AtlasPipelineLinkFailed",
	INPROGRESS = "AtlasPipelineLinkInProgress",
	STOPPED = "AtlasPipelineLinkMuted",
}

local PIPELINE_STATUS_LABEL = {
	SUCCESSFUL = "Passed",
	FAILED = "Failed",
	INPROGRESS = "Running",
	STOPPED = "Stopped",
}

---@param status string
---@return string
local function status_label(status)
	return PIPELINE_STATUS_LABEL[tostring(status or ""):upper()] or "Unknown"
end

---@param _pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_pipelines(_pr, width, lines, spans, line_map)
	if panel_state.pipelines == nil then
		return
	end

	if panel_state.pipelines == "loading" then
		utils.push(lines, spans, "Pipelines", "AtlasColumnHeader", PADDING_X)
		local loading_text = spinner.with_text("Loading pipelines...")
		utils.append_block(
			lines,
			spans,
			box.render({
				{
					lines = { loading_text },
					spans = { { line = 0, start_col = 0, end_col = #loading_text, hl_group = "AtlasTextMuted" } },
				},
			}, { width = width, padding_x = PADDING_X })
		)
		table.insert(lines, "")
		return
	end

	if type(panel_state.pipelines) == "string" then
		utils.push(lines, spans, "Pipelines", "AtlasColumnHeader", PADDING_X)
		local err_text = panel_state.pipelines
		utils.append_block(
			lines,
			spans,
			box.render({
				{
					lines = { err_text },
					spans = { { line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" } },
				},
			}, { width = width, padding_x = PADDING_X })
		)
		table.insert(lines, "")
		return
	end

	local entries = panel_state.pipelines

	if #entries == 0 then
		return
	end

	utils.push(lines, spans, "Pipelines", "AtlasColumnHeader", PADDING_X)

	local rows = {}
	for _, pipeline in ipairs(entries) do
		if #rows > 0 then
			table.insert(rows, { kind = "separator" })
		end
		local state_value = tostring(pipeline.state or "UNKNOWN"):upper()
		local icon = icons.pulls_status(state_value:lower())
		local jobs = pipeline.jobs or {}
		local job_count = string.format("%d %s", #jobs, #jobs == 1 and "job" or "jobs")
		local row = {
			label = string.format("%s  %s", tostring(pipeline.name or pipeline.key or "Pipeline"), job_count),
			status = string.format("%s %s", icon, status_label(state_value)),
			status_hl = PIPELINE_HL[state_value] or "AtlasPipelineLinkMuted",
			kind = "pipeline",
			pipeline = pipeline,
			url = tostring(pipeline.url or ""),
			children = {},
		}
		for _, job in ipairs(jobs) do
			local job_state = tostring(job.state or "UNKNOWN"):upper()
			local job_icon = icons.pulls_status(job_state:lower())
			table.insert(row.children, {
				label = string.format("%s %s", job_icon, tostring(job.name or "Job")),
				status = "",
				status_icon = job_icon,
				status_hl = PIPELINE_HL[job_state] or "AtlasPipelineLinkMuted",
				kind = "pipeline",
				pipeline = pipeline,
				job = job,
				url = tostring(job.url or pipeline.url or ""),
			})
		end
		table.insert(rows, row)
	end

	local box_lines, box_lmap, box_spans = table_tree.render({
		width = math.max(10, width - (PADDING_X * 2) - 4),
		margin = 0,
		show_header = false,
		column_gap = 1,
		columns = {
			{ key = "label", name = "", can_grow = true },
			{ key = "status", name = "", can_grow = false },
		},
		rows = rows,
		tree = {
			column_key = "label",
			leaf_prefix = "",
			show_indicator = false,
			is_expanded = function(row)
				return state.is_pipeline_expanded(row.pipeline)
			end,
		},
		cell_hl = function(row, column, context)
			if row.kind == "separator" then
				return nil
			end
			if column.key == "label" and row.status_icon then
				local start_col = context.text:find(row.status_icon, 1, true)
				if start_col then
					return {
						{
							start_col = start_col - 1,
							end_col = start_col - 1 + #row.status_icon,
							hl_group = row.status_hl,
						},
					}
				end
			end
			if column.key == "status" then
				return row.status_hl
			end
			return nil
		end,
	})

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

-- Description

---@param pr PullRequestDetails
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_description(pr, width, lines, spans, line_map)
	local start_line = #lines + 1
	local function map_lines()
		for lnum = start_line, #lines do
			line_map[lnum] = { kind = "description" }
		end
	end

	utils.push(lines, spans, "Description", "AtlasColumnHeader", PADDING_X)

	local desc_text = utils.strip_markup(pr.description)
	if desc_text == "" then
		utils.push(lines, spans, "No description provided.", "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
		map_lines()
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
	map_lines()
end

-- Merge checks

local MERGE_CHECK_STATE = {
	successful = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	failed = { icon = icons.pulls_status("failed"), hl = "AtlasLogError" },
	inprogress = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
	warning = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextWarning" },
	muted = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
}

local MERGE_CHECK_PRIORITY = {
	failed = 1,
	warning = 2,
	inprogress = 3,
	successful = 4,
	muted = 5,
}

---@param check PullsMergeCheck
---@param width integer
---@return BoxContentGroup
local function render_merge_check_group(check, width)
	local pair = MERGE_CHECK_STATE[check.state] or MERGE_CHECK_STATE.muted
	local lines = {}
	local spans = {}
	local content_width = math.max(2, width - (PADDING_X * 2) - 3)

	local icon_prefix = pair.icon .. " "
	local icon_width = vim.api.nvim_strwidth(icon_prefix)
	local title_width = math.max(2, content_width - icon_width)
	local title_lines = utils.wrap_line(check.label, title_width)
	for index, title in ipairs(title_lines) do
		local prefix = index == 1 and icon_prefix or string.rep(" ", icon_width)
		table.insert(lines, prefix .. title)
		if index == 1 then
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #pair.icon, hl_group = pair.hl })
		end
	end

	for _, detail in ipairs(check.details or {}) do
		local indent = "  "
		local detail_width = math.max(2, content_width - vim.api.nvim_strwidth(indent))
		for _, detail_line in ipairs(utils.wrap_line(detail, detail_width)) do
			local text = indent .. detail_line
			table.insert(lines, text)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" })
		end
	end

	return { lines = lines, spans = spans }
end

---@param text string
---@param hl_group string
---@param width integer
---@return BoxContentGroup
local function render_merge_check_message_group(text, hl_group, width)
	local content_width = math.max(2, width - (PADDING_X * 2) - 3)
	local lines = utils.wrap_line(text, content_width)
	local spans = {}
	for index, line in ipairs(lines) do
		table.insert(spans, { line = index - 1, start_col = 0, end_col = #line, hl_group = hl_group })
	end
	return { lines = lines, spans = spans }
end

---@param _pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_merge_checks(_pr, width, lines, spans)
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
				{ render_merge_check_message_group(loading_text, "AtlasTextMuted", width) },
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
				{ render_merge_check_message_group(err_text, "AtlasLogError", width) },
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	local checks = vim.list_slice(state.merge_checks --[[@as PullsMergeCheck[] ]])
	if #checks == 0 then
		table.insert(lines, "")
		return
	end

	table.sort(checks, function(a, b)
		return (MERGE_CHECK_PRIORITY[a.state] or math.huge) < (MERGE_CHECK_PRIORITY[b.state] or math.huge)
	end)

	local groups = {}
	for _, check in ipairs(checks) do
		table.insert(groups, render_merge_check_group(check, width))
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

	if panel_state.current_details then
		render_description(panel_state.current_details, width, lines, spans, line_map)
	end
	render_reviewers(pr, width, lines, spans)
	render_merge_checks(pr, width, lines, spans)
	render_pipelines(pr, width, lines, spans, line_map)

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "pipeline"
end

---@param _pr PullRequest
---@param entry table
---@return boolean|nil
function M.on_enter(_pr, entry)
	if entry.kind == "pipeline" and entry.url and entry.url ~= "" then
		vim.ui.open(entry.url)
		return true
	end
end

---@return boolean
function M.is_loading()
	return state.any_loading()
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
	vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)
	cancel_all()
end

return M
