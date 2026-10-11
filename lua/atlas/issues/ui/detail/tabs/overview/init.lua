local M = {}

local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local markdown = require("atlas.formats.markdown")

local view_mode = "markdown"

---@param _issue Issue
---@param details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_issue, details, width)
	if details == nil then
		return {}, {}, {}
	end

	local lines = {}
	local spans = {}
	local content_width = math.max(1, width - 2)

	local description = details.description or ""
	if description == "" then
		utils.push(lines, spans, "No description", "AtlasTextMuted")
	elseif view_mode == "raw" then
		for _, line in ipairs(vim.split(utils.normalize_newlines(description), "\n", { plain = true })) do
			utils.push(lines, spans, line)
		end
	else
		local content = markdown.render(description, { width = width, padding = 1 })
		return content.lines, content.highlights, {}
	end

	local content = utils.wrap_content({ lines = lines, highlights = spans }, content_width, " ")
	return content.lines, content.highlights, {}
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	local toggle_keys = keymaps.resolve("ui.toggle_description_mode")
	if toggle_keys then
		help.register("Detail", {
			{
				key = #toggle_keys == 1 and toggle_keys[1] or toggle_keys,
				desc = "Toggle description mode",
				index = 10,
				opts = { nowait = true, silent = true },
				callback = function()
					view_mode = view_mode == "raw" and "markdown" or "raw"
					refresh()
				end,
			},
		}, { index = 2, buffer = buf })
	end
end

---@param buf integer
function M.deactivate(buf)
	local keys = keymaps.resolve("ui.toggle_description_mode")
	if keys then
		help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
	end
end

return M
