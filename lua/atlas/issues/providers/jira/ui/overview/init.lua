local M = {}

local utils = require("atlas.ui.shared.utils")
local markdown = require("atlas.formats.markdown")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local state = require("atlas.issues.providers.jira.ui.overview.state")

---@param _issue Issue
---@param details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_issue, details, width)
	if details == nil then
		return {}, {}, {}
	end
	---@cast details JiraIssueDetails
	local lines = {}
	local spans = {}
	local content_width = math.max(1, width - 2)
	local raw_description = details.raw_description

	if state.view_mode == "raw" then
		local raw_text = type(raw_description) == "table" and vim.inspect(raw_description)
			or tostring(raw_description or "")
		for _, line in ipairs(vim.split(raw_text, "\n", { plain = true })) do
			table.insert(lines, line)
		end
	else
		local description = details.description or ""
		if description == "" then
			utils.push(lines, spans, "No description", "AtlasTextMuted")
		else
			local content = markdown.render(description, { width = width, padding = 1 })
			return content.lines, content.highlights, {}
		end
	end

	local content = utils.wrap_content({ lines = lines, highlights = spans }, content_width, " ")
	return content.lines, content.highlights, {}
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	local keys = keymaps.resolve("ui.toggle_description_mode")
	if keys then
		help.register("Panel", {
			{
				key = #keys == 1 and keys[1] or keys,
				desc = "Toggle description mode",
				opts = { silent = true, nowait = true },
				callback = function()
					state.view_mode = state.view_mode == "raw" and "markdown" or "raw"
					refresh()
				end,
			},
		}, { index = 212, buffer = buf })
	end
end

---@param buf integer
function M.deactivate(buf)
	local keys = keymaps.resolve("ui.toggle_description_mode")
	if keys then
		help.remove("Panel", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
	end
end

return M
