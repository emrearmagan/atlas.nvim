local M = {}

local icons = require("atlas.ui.shared.icons")
local providers = require("atlas.pulls.providers")
local table_tree = require("atlas.ui.components.table_tree")

---@param pipeline PullsPipeline
---@return string
local function pipeline_name(pipeline)
	local name = tostring(pipeline.name or "")
	if name == "" then
		name = tostring(pipeline.key or "")
	end
	return name ~= "" and name or "Pipeline"
end

---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@return table
local function job_row(pipeline, job)
	local icon, icon_hl = icons.pulls_status(tostring(job.state or "UNKNOWN"):lower())
	local row = {
		icon = icon,
		label = string.format("%s %s", icon, tostring(job.name or "Job")),
		icon_hl = icon_hl,
		_item = { pipeline = pipeline, job = job },
		children = {},
	}
	for _, step in ipairs(job.steps or {}) do
		local step_icon, step_icon_hl = icons.pulls_status(tostring(step.state or "UNKNOWN"):lower())
		table.insert(row.children, {
			icon = step_icon,
			label = string.format("%s %s", step_icon, tostring(step.name or "Step")),
			icon_hl = step_icon_hl,
			_item = { pipeline = pipeline, job = job, step = step },
		})
	end
	return row
end

---@param pipeline PullsPipeline
---@return table[]
local function pipeline_children(pipeline)
	local rows = {}
	local stages = {}
	local stage_order = {}
	for _, job in ipairs(pipeline.jobs or {}) do
		local stage = tostring(job.stage or "")
		if stage == "" then
			table.insert(rows, job_row(pipeline, job))
		else
			if stages[stage] == nil then
				stages[stage] = {}
				table.insert(stage_order, stage)
			end
			table.insert(stages[stage], job)
		end
	end

	for _, stage in ipairs(stage_order) do
		local jobs = stages[stage]
		local state = providers.aggregate_pipeline_state(jobs)
		local icon, icon_hl = icons.pulls_status(state:lower())
		local stage_row = {
			icon = icon,
			label = string.format("%s %s", icon, stage),
			icon_hl = icon_hl,
			_item = { pipeline = pipeline, stage = stage },
			children = {},
		}
		for _, job in ipairs(jobs) do
			table.insert(stage_row.children, job_row(pipeline, job))
		end
		table.insert(rows, stage_row)
	end
	return rows
end

---@param pipelines PullsPipeline[]
---@return table[]
local function pipeline_rows(pipelines)
	local rows = {}
	for _, pipeline in ipairs(pipelines) do
		local icon, icon_hl = icons.pulls_status(tostring(pipeline.state or "UNKNOWN"):lower())
		table.insert(rows, {
			icon = icon,
			label = string.format("%s %s", icon, pipeline_name(pipeline)),
			icon_hl = icon_hl,
			_item = { pipeline = pipeline },
			children = pipeline_children(pipeline),
		})
	end
	return rows
end

---@param row table
---@param column table
---@param context { text: string }
---@return table[]|nil
local function cell_hl(row, column, context)
	if column.key ~= "label" then
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

---@param pipelines PullsPipeline[]
---@param width integer
---@return string[], table<integer, PullsPipelineSelection>, table[]
function M.render(pipelines, width)
	local rows = pipeline_rows(pipelines)
	if #rows == 0 then
		return { " No pipelines" }, {}, {}
	end
	return table_tree.render({
		width = width,
		margin = 1,
		show_header = false,
		fill = false,
		columns = {
			{ key = "label", name = "", can_grow = false },
		},
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

return M
