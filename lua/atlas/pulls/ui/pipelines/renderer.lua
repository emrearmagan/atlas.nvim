local M = {}

local icons = require("atlas.ui.shared.icons")
local table_tree = require("atlas.ui.components.table_tree")

---@param pipeline PullsPipeline
---@param stage PullsPipelineStage
---@param job PullsPipelineJob
---@return table
local function job_row(pipeline, stage, job)
	local icon, icon_hl = icons.pulls_status(tostring(job.state or "UNKNOWN"):lower())
	return {
		icon = icon,
		label = string.format("%s %s", icon, job.name),
		icon_hl = icon_hl,
		_item = { pipeline = pipeline, stage = stage, job = job },
	}
end

---@param pipeline PullsPipeline
---@return table[]
local function pipeline_children(pipeline)
	local rows = {}
	for _, stage in ipairs(pipeline.stages) do
		if stage.name == nil then
			for _, job in ipairs(stage.jobs) do
				table.insert(rows, job_row(pipeline, stage, job))
			end
		else
			local icon, icon_hl = icons.pulls_status(tostring(stage.state or "UNKNOWN"):lower())
			local stage_row = {
				icon = icon,
				label = string.format("%s %s", icon, stage.name),
				icon_hl = icon_hl,
				_item = { pipeline = pipeline, stage = stage },
				children = {},
			}
			for _, job in ipairs(stage.jobs) do
				table.insert(stage_row.children, job_row(pipeline, stage, job))
			end
			table.insert(rows, stage_row)
		end
	end
	return rows
end

---@param pipelines PullsPipeline[]
---@return table[]
local function pipeline_rows(pipelines)
	local rows = {}
	for _, pipeline in ipairs(pipelines) do
		if #rows > 0 then
			table.insert(rows, { kind = "separator" })
		end
		local icon, icon_hl = icons.pulls_status(tostring(pipeline.state or "UNKNOWN"):lower())
		table.insert(rows, {
			icon = icon,
			label = string.format("%s %s", icon, pipeline.name),
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
