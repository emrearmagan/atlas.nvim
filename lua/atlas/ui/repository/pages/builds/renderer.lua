local pipeline_utils = require("atlas.pulls.pipelines.utils")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param value string
---@return string
local function clean(value)
	return (value:gsub("%c", " "))
end

---@param state RepositoryBuilds
---@param width integer
---@return string[], table<integer, PullsPipeline>, AtlasUIHighlight[]
function M.render(state, width)
	local lines, line_map, spans = {}, {}, {}
	local runs = state.runs
	---@cast runs PullsPipeline[]
	local content_width = math.max(1, width - 1)
	---@param text string
	---@param hl string|nil
	---@param run PullsPipeline|nil
	local function add(text, hl, run)
		utils.push(lines, spans, utils.truncate(clean(text), content_width), hl)
		line_map[#lines] = run
	end

	add(icons.pulls("branch") .. " " .. state.branch .. "  " .. #runs .. " runs", "AtlasTextMuted")
	add("")
	for _, run in ipairs(runs) do
		local name = pipeline_utils.display_name(run)
		local title = run.title and run.title ~= "" and run.title or name
		local icon, hl = icons.pulls_status(run.state:lower())
		local leading = icon .. "  "
		local time = content_width >= 60 and run.started_at and utils.relative_time_text(run.started_at) or ""
		local available = content_width - vim.fn.strdisplaywidth(leading) - (time ~= "" and #time + 2 or 0)
		local left = leading .. utils.truncate(clean(title), math.max(0, available))
		local gap = time ~= "" and math.max(2, content_width - vim.fn.strdisplaywidth(left) - #time) or 0
		add(left .. string.rep(" ", gap) .. time, "Normal", run)
		local line = lines[#lines]
		if content_width >= vim.fn.strdisplaywidth(leading) then
			spans[#spans + 1] = { line = #lines - 1, start_col = 0, end_col = #icon, hl_group = hl }
		end
		if time ~= "" then
			spans[#spans + 1] =
				{ line = #lines - 1, start_col = #line - #time, end_col = #line, hl_group = "AtlasTextMuted" }
		end

		local parts = { name, pipeline_utils.state_label(run.state) }
		if run.commit then
			parts[#parts + 1] = run.commit:sub(1, 8)
		end
		add("   " .. table.concat(parts, "  "), "AtlasTextMuted", run)
		add("")
	end
	return lines, line_map, spans
end

return M
