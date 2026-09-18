local pipeline_utils = require("atlas.pulls.pipelines.utils")
local picker = require("atlas.ui.picker")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param pipeline PullsPipeline
---@return string, string
local function format_run(pipeline)
	local icon, hl = icons.pulls_status(pipeline.state:lower())
	local parts = { icon, "#" .. (pipeline.number or pipeline.id) }
	if pipeline.commit then
		parts[#parts + 1] = pipeline.commit:sub(1, 7)
	end
	if pipeline.started_at then
		parts[#parts + 1] = utils.relative_time_text(pipeline.started_at)
	end
	if pipeline.title then
		parts[#parts + 1] = pipeline.title:gsub("[\r\n]+", " ")
	end
	return table.concat(parts, "  "), hl
end

---@param runs PullsPipeline[]
---@param query string
---@return PullsPipeline[]
local function filter(runs, query)
	return vim.tbl_filter(function(run)
		return format_run(run):lower():find(query:lower(), 1, true) ~= nil
	end, runs)
end

---@param context PullsPipelineContext
---@param backend PullsPipelineBackend
---@param pipeline PullsPipeline
---@param on_select fun(pipeline: PullsPipeline)
function M.open(context, backend, pipeline, on_select)
	---@type PullsPipeline[]|nil
	local runs
	picker.search({
		title = "Recent builds: " .. pipeline.name,
		debounce_ms = 0,
		fetch_on_open = true,
		format_item = function(run)
			local text, hl = format_run(run)
			return text .. (run.id == pipeline.id and " (selected)" or ""), hl
		end,
		fetch = function(query, done)
			if runs then
				done(filter(runs, query), nil)
				return
			end
			return backend.fetch_history(context, pipeline, function(items, err)
				if err then
					done(nil, err)
					return
				end
				runs = items or {}
				done(filter(runs, query), nil)
			end)
		end,
		preview_item = function(run, done)
			local lines = { pipeline_utils.display_name(run), pipeline_utils.state_label(run.state), "" }
			if run.title then
				vim.list_extend(lines, vim.split(run.title, "\n", { plain = true }))
				lines[#lines + 1] = ""
			end
			for _, field in ipairs({
				{ "Branch", run.branch },
				{ "Commit", run.commit },
				{ "Started", run.started_at },
			}) do
				if field[2] then
					lines[#lines + 1] = field[1] .. ": " .. field[2]
				end
			end
			done({ title = "Build", lines = lines })
		end,
		on_select = on_select,
	})
end

return M
