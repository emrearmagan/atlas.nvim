local M = {}

local utils = require("atlas.ui.shared.utils")
local markdown = require("atlas.formats.markdown")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local state = require("atlas.issues.providers.jira.ui.overview.state")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

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
	local line_map = {}
	local raw_description = details.raw_description

	if state.view_mode == "raw" then
		local raw_text = type(raw_description) == "table" and vim.inspect(raw_description)
			or tostring(raw_description or "")
		for _, line in ipairs(vim.split(raw_text, "\n", { plain = true })) do
			table.insert(lines, PADDING .. line)
		end
	else
		local description = details.description or ""
		if description == "" then
			utils.push(lines, spans, "No description", "AtlasTextMuted", PADDING_X)
		else
			local block = markdown.parse(description, {
				width = math.max(1, width - 2 * PADDING_X),
			})
			utils.append_block(lines, spans, block, PADDING_X)
		end
	end

	return lines, spans, line_map
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
