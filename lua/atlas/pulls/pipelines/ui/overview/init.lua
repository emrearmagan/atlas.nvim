local pipeline_utils = require("atlas.pulls.pipelines.utils")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@class PullsPipelinesOverview
---@field buf integer
---@field win integer
---@field selection PullsPipelinesSelection|nil
---@field line_map table<integer, PullsPipelinesSelection>

local M = {}

local namespace = vim.api.nvim_create_namespace("atlas.pipelines.overview")

---@param lines string[]
---@param spans table[]
---@param segments { [1]: string, [2]: string|nil }[]
local function add(lines, spans, segments)
	local text = " "
	for _, segment in ipairs(segments) do
		if segment[2] then
			spans[#spans + 1] = {
				line = #lines,
				start_col = #text,
				end_col = #text + #segment[1],
				hl_group = segment[2],
			}
		end
		text = text .. segment[1]
	end
	lines[#lines + 1] = text
end

---@param text string
---@param width integer
---@return string
local function pad(text, width)
	return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
end

---@param pipeline PullsPipeline
---@param path string[] Trigger jobs leading to this pipeline.
---@param jobs { state: PullsPipelineState, selection: PullsPipelinesSelection, location: string }[]
local function collect_jobs(pipeline, path, jobs)
	for _, stage in ipairs(pipeline.stages) do
		for _, job in ipairs(stage.jobs) do
			if job.downstream then
				local downstream_path = vim.list_extend({}, path)
				downstream_path[#downstream_path + 1] = job.name
				collect_jobs(job.downstream, downstream_path, jobs)
			else
				local location = vim.list_extend({}, path)
				if stage.name and stage.name ~= job.name then
					location[#location + 1] = stage.name
				end
				jobs[#jobs + 1] = {
					state = job.state,
					selection = { pipeline = pipeline, stage = stage, job = job },
					location = table.concat(location, " › "),
				}
			end
		end
	end
end

---@param pipeline PullsPipeline
---@return string[] lines, table[] spans, table<integer, PullsPipelinesSelection> line_map
local function build(pipeline)
	local lines, spans, line_map = {}, {}, {}
	local name = pipeline_utils.display_name(pipeline)
	local title = pipeline.title and pipeline.title:gsub("[\r\n].*", "")
	local state_icon, state_hl = icons.get(tostring(pipeline.state or "UNKNOWN"), "status")
	add(lines, spans, { { state_icon, state_hl }, { " " .. (title or name), "AtlasColumnHeader" } })
	if title then
		add(lines, spans, { { "  " .. name, "AtlasTextMuted" } })
	end
	local source = {}
	if pipeline.branch then
		source[#source + 1] = icons.get("branch") .. " " .. pipeline.branch
	end
	if pipeline.commit then
		source[#source + 1] = pipeline.commit:sub(1, 8)
	end
	if #source > 0 then
		add(lines, spans, { { "  " .. table.concat(source, "   "), "AtlasTextMuted" } })
	end

	lines[#lines + 1] = ""
	local grid = {
		{ "Status", pipeline_utils.state_label(pipeline.state), state_hl },
		{ "Trigger", pipeline.trigger or "-" },
		{ "Started", utils.relative_time_text(pipeline.started_at) },
		{ "Duration", pipeline.duration and pipeline_utils.format_duration(pipeline.duration) or "-" },
	}
	local titles, values = { { "  " } }, { { "  " } }
	for index, cell in ipairs(grid) do
		local title_text, value = cell[1], cell[2]
		if index < #grid then
			local width = math.max(vim.fn.strdisplaywidth(title_text), vim.fn.strdisplaywidth(value)) + 3
			title_text, value = pad(title_text, width), pad(value, width)
		end
		titles[#titles + 1] = { title_text, "AtlasTextMuted" }
		values[#values + 1] = { value, cell[3] }
	end
	add(lines, spans, titles)
	add(lines, spans, values)

	lines[#lines + 1] = ""
	add(lines, spans, { { "  " }, { "Jobs", "AtlasColumnHeader" } })
	local jobs = {}
	collect_jobs(pipeline, {}, jobs)
	local name_width, location_width, duration_width = 0, 0, 0
	for _, entry in ipairs(jobs) do
		local duration = entry.selection.job.duration
		entry.duration = duration and pipeline_utils.format_duration(duration) or ""
		name_width = math.max(name_width, vim.fn.strdisplaywidth(entry.selection.job.name))
		location_width = math.max(location_width, vim.fn.strdisplaywidth(entry.location))
		duration_width = math.max(duration_width, #entry.duration)
	end
	for _, entry in ipairs(pipeline_utils.sort_by_state(jobs)) do
		local job = entry.selection.job
		local icon, hl = icons.get(tostring(job.state or "UNKNOWN"), "status")
		local segments = { { "  " }, { icon, hl }, { " " .. pad(job.name, name_width) } }
		if location_width > 0 then
			segments[#segments + 1] = { "   " .. pad(entry.location, location_width), "AtlasTextMuted" }
		end
		if duration_width > 0 then
			local duration = string.rep(" ", duration_width - #entry.duration) .. entry.duration
			segments[#segments + 1] = { "   " .. duration, "AtlasTextMuted" }
		end
		line_map[#lines + 1] = entry.selection
		add(lines, spans, segments)
	end
	if #jobs == 0 then
		add(lines, spans, { { "  No jobs", "AtlasTextMuted" } })
	end
	return lines, spans, line_map
end

---@param pane PullsPipelinesOverview
function M.render(pane)
	local pipeline = pane.selection and pane.selection.pipeline
	if not pipeline or not utils.window.has_buffer(pane.win, pane.buf) then
		return
	end

	local lines, spans, line_map = build(pipeline)
	pane.line_map = line_map
	vim.bo[pane.buf].modifiable = true
	vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
	utils.apply_spans(pane.buf, namespace, spans)
	vim.bo[pane.buf].modifiable = false
	vim.wo[pane.win].winbar = " " .. pipeline_utils.display_name(pipeline):gsub("%%", "%%%%") .. " "
end

---@param pane PullsPipelinesOverview
---@param selection PullsPipelinesSelection
function M.show(pane, selection)
	local previous = pane.selection and pane.selection.pipeline
	pane.selection = selection
	M.render(pane)
	if not (previous and previous.id == selection.pipeline.id) and utils.window.has_buffer(pane.win, pane.buf) then
		vim.api.nvim_win_set_cursor(pane.win, { 1, 0 })
	end
end

---@param pane PullsPipelinesOverview
---@return PullsPipelinesSelection|nil
function M.current_selection(pane)
	if not utils.window.has_buffer(pane.win, pane.buf) then
		return nil
	end
	return pane.line_map[vim.api.nvim_win_get_cursor(pane.win)[1]]
end

return M
