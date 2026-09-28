local M = {}

local pipeline_utils = require("atlas.pulls.pipelines.utils")
local spinner = require("atlas.ui.components.spinner")
local table_tree = require("atlas.ui.components.table_tree")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas.pipelines.explorer")

---@param pipeline PullsPipeline
---@param stage PullsPipelineStage
---@param job PullsPipelineJob
---@param loading_frame string|nil
---@param selection PullsPipelinesSelection|nil
---@return table
local function job_row(pipeline, stage, job, loading_frame, selection)
	local icon, icon_hl = icons.pulls_status(tostring(job.state or "UNKNOWN"):lower())
	if loading_frame then
		icon, icon_hl = loading_frame, "AtlasTextMuted"
	end
	local row = {
		icon = icon,
		label = string.format("%s %s", icon, job.name),
		icon_hl = icon_hl,
		_item = { pipeline = pipeline, stage = stage, job = job },
	}
	if selection and selection.pipeline.id == pipeline.id and selection.job and selection.job.id == job.id then
		row.children = {}
		for index, step in ipairs(job.steps or {}) do
			local step_icon, step_hl = icons.pulls_status(step.state:lower())
			local seconds = step.duration
			row.children[#row.children + 1] = {
				icon = step_icon,
				label = string.format("%s %s", step_icon, step.name),
				icon_hl = step_hl,
				duration = seconds
					and (seconds < 60 and string.format("%ds", math.floor(seconds)) or utils.human_duration(seconds)),
				_item = { pipeline = pipeline, stage = stage, job = job, step = index },
			}
		end
	end
	return row
end

---@param pipeline PullsPipeline
---@param loading_job_id string|nil
---@param loading_frame string|nil
---@param selection PullsPipelinesSelection|nil
---@return table[], boolean
local function pipeline_children(pipeline, loading_job_id, loading_frame, selection)
	local rows = {}
	local has_steps = false
	for _, stage in ipairs(pipeline.stages) do
		local jobs = {}
		for _, job in ipairs(stage.jobs) do
			local row = job_row(pipeline, stage, job, job.id == loading_job_id and loading_frame or nil, selection)
			jobs[#jobs + 1] = row
			if row.children and #row.children > 0 then
				has_steps = true
			end
		end
		if stage.name == nil then
			vim.list_extend(rows, jobs)
		else
			local icon, icon_hl = icons.pulls_status(tostring(stage.state or "UNKNOWN"):lower())
			rows[#rows + 1] = {
				icon = icon,
				label = string.format("%s %s", icon, stage.name),
				icon_hl = icon_hl,
				_item = { pipeline = pipeline, stage = stage },
				children = jobs,
			}
		end
	end
	return rows, has_steps
end

---@param row table
---@param column table
---@param context { text: string }
---@return table[]|nil
local function cell_hl(row, column, context)
	if column.key ~= "label" or row.icon == nil then
		return nil
	end
	local icon_start, icon_end = context.text:find(row.icon, 1, true)
	if not icon_start then
		return nil
	end
	return {
		{
			start_col = icon_start - 1,
			end_col = icon_end,
			hl_group = row.icon_hl,
		},
	}
end

---@param pane PullsPipelinesExplorer
---@return string
local function loading_text(pane)
	if pane.spinner then
		return " " .. pane.spinner:text("Loading pipelines...")
	end

	return " " .. spinner.with_text("Loading pipelines...")
end

---@param pane PullsPipelinesExplorer
---@return string[], table<integer, PullsPipelinesSelection>, table[]
local function build_content(pane)
	local pipelines = pane.pipelines
	local lines, spans = {}, {}

	if pipelines == "loading" then
		utils.push(lines, spans, loading_text(pane), "AtlasTextMuted")
		return lines, {}, spans
	end

	if type(pipelines) == "string" then
		utils.push(lines, spans, " " .. pipelines:gsub("[\r\n]+", " "), "AtlasLogError")
		return lines, {}, spans
	end

	local rows = {}
	local columns = { { key = "label", name = "", can_grow = true } }
	local loading_frame = pane.spinner and pane.spinner:current_frame()
	for _, pipeline in ipairs(pipelines) do
		if #rows > 0 then
			table.insert(rows, { kind = "separator" })
		end
		local icon, icon_hl = icons.pulls_status(tostring(pipeline.state or "UNKNOWN"):lower())
		local children, has_steps = pipeline_children(pipeline, pane.loading_job_id, loading_frame, pane.selection)
		if has_steps then
			columns[2] = { key = "duration", name = "", align = "right", hl = "AtlasTextMuted", can_grow = false }
		end
		table.insert(rows, {
			icon = icon,
			label = string.format("%s %s", icon, pipeline_utils.display_name(pipeline)),
			icon_hl = icon_hl,
			_item = { pipeline = pipeline },
			children = children,
		})
	end

	if #rows == 0 then
		return { " No pipelines" }, {}, {}
	end
	return table_tree.render({
		width = vim.api.nvim_win_get_width(pane.win),
		margin = 1,
		show_header = false,
		fill = true,
		columns = columns,
		rows = rows,
		tree = {
			column_key = "label",
			default_expanded = true,
			show_indicator = false,
			leaf_prefix = "",
		},
		cell_hl = cell_hl,
	})
end

---@param buf integer
---@param lines string[]
---@param spans table[]
local function write_buffer(buf, lines, spans)
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param entry PullsPipelinesSelection
---@param selection PullsPipelinesSelection
---@return boolean
local function matches_selection(entry, selection)
	local pipeline = selection.pipeline
	if not pipeline or not entry.pipeline or entry.pipeline.id ~= pipeline.id then
		return false
	end

	if selection.job then
		return entry.job ~= nil and entry.job.id == selection.job.id and entry.step == selection.step
	end

	if selection.stage then
		return entry.stage ~= nil and entry.job == nil and entry.stage.name == selection.stage.name
	end

	return entry.stage == nil and entry.job == nil
end

---@param pane PullsPipelinesExplorer
---@param selection PullsPipelinesSelection
---@return integer|nil
function M.find_selection(pane, selection)
	for row, entry in pairs(pane.line_map) do
		if matches_selection(entry, selection) then
			return row
		end
	end
end

---@param pane PullsPipelinesExplorer
function M.render_loading(pane)
	if not pane.spinner or not utils.buffer.valid(pane.buf) or not utils.window.valid(pane.win) then
		return
	end

	local lines, line_map, spans = build_content(pane)
	pane.line_map = line_map
	write_buffer(pane.buf, lines, spans)
end

---@param pane PullsPipelinesExplorer
---@param selection PullsPipelinesSelection|nil
function M.render(pane, selection)
	if not utils.buffer.valid(pane.buf) or not utils.window.valid(pane.win) then
		return
	end

	local row = vim.api.nvim_win_get_cursor(pane.win)[1]
	selection = selection or pane.line_map[row]

	local lines, line_map, spans = build_content(pane)
	pane.line_map = line_map

	write_buffer(pane.buf, lines, spans)
	local selected_row = selection and M.find_selection(pane, selection)
	if selected_row then
		vim.api.nvim_win_set_cursor(pane.win, { selected_row, 0 })
	end
end

return M
