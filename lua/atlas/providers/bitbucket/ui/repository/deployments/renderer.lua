local pipeline_utils = require("atlas.pulls.pipelines.utils")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local M = {}

---@param text string
---@param right string
---@param width integer
---@return string
local function align_right(text, right, width)
	local right_width = vim.fn.strdisplaywidth(right)
	text = utils.truncate(text, math.max(0, width - right_width - 2))
	local padding = math.max(2, width - vim.fn.strdisplaywidth(text) - right_width)
	return text .. string.rep(" ", padding) .. right
end

---@param environments BitbucketDeploymentEnvironment[]
---@param width integer
---@param expanded table<string, boolean>
---@return string[] lines
---@return table<integer, { environment: BitbucketDeploymentEnvironment, deployment?: BitbucketDeployment }> line_map
---@return AtlasUIHighlight[] spans
function M.render(environments, width, expanded)
	local lines = {}
	local line_map = {}
	local spans = {}
	local content_width = math.max(1, width - 1)

	for group_index, environment in ipairs(environments) do
		---@param text string
		---@param hl string
		---@param deployment BitbucketDeployment|nil
		local function add(text, hl, deployment)
			utils.push(lines, spans, utils.truncate(text:gsub("%c", " "), content_width), hl)
			line_map[#lines] = { environment = environment, deployment = deployment }
		end

		if group_index > 1 then
			lines[#lines + 1] = ""
		end

		local count = #environment.deployments
		add(environment.name, "AtlasColumnHeader")
		if #environment.deployments == 0 then
			add("   No deployment in loaded history", "AtlasTextMuted")
		end

		if not expanded[environment.id] then
			count = math.min(3, count)
		end

		for index = 1, count do
			local deployment = environment.deployments[index]

			local icon, hl = icons.pulls_status(deployment.state:lower())
			local label = pipeline_utils.state_label(deployment.state)
			if deployment.state == "UNDEPLOYED" then
				icon, hl = icons.general("progress")
				label = "Not deployed"
			end

			local time = ""
			if content_width >= 60 and deployment.started_at then
				time = utils.relative_time_text(deployment.started_at)
			end

			local prefix = icon .. "  "
			local title = prefix .. "Deployment #" .. deployment.number
			if time ~= "" then
				title = align_right(title, time, content_width)
			end
			add(title, "Normal", deployment)

			if content_width >= vim.fn.strdisplaywidth(prefix) then
				spans[#spans + 1] = {
					line = #lines - 1,
					start_col = 0,
					end_col = #icon,
					hl_group = hl,
				}
			end

			if time ~= "" then
				local line = lines[#lines]
				spans[#spans + 1] = {
					line = #lines - 1,
					start_col = #line - #time,
					end_col = #line,
					hl_group = "AtlasTextMuted",
				}
			end

			local details = {}
			if deployment.pipeline_name and deployment.pipeline_name ~= "" then
				details[#details + 1] = deployment.pipeline_name
			end
			details[#details + 1] = label
			if deployment.branch then
				details[#details + 1] = icons.pulls("branch") .. " " .. deployment.branch
			end

			if deployment.commit and deployment.commit ~= "" then
				details[#details + 1] = deployment.commit:sub(1, 8)
			end

			if deployment.duration then
				if deployment.duration < 60 then
					details[#details + 1] = string.format("%ds", math.floor(deployment.duration))
				else
					details[#details + 1] = utils.human_duration(deployment.duration)
				end
			end
			local text = "   " .. table.concat(details, "  ")
			if deployment.deployer then
				text = align_right(text, "Deployed by " .. deployment.deployer, content_width)
			end
			add(text, "AtlasTextMuted", deployment)
		end
		if count < #environment.deployments then
			add((#environment.deployments - count) .. " more", "AtlasTextMuted")
		end
	end

	return lines, line_map, spans
end

return M
