local M = {}

local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local markdown = require("atlas.formats.markdown")
local reactions = require("atlas.ui.shared.reactions")

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
	local content
	if description == "" then
		utils.push(lines, spans, "No description", "AtlasTextMuted")
	elseif view_mode == "raw" then
		for _, line in ipairs(vim.split(utils.normalize_newlines(description), "\n", { plain = true })) do
			utils.push(lines, spans, line)
		end
	else
		content = markdown.render(description, { width = width, padding = 1 })
	end
	content = content or utils.wrap_content({ lines = lines, highlights = spans }, content_width, " ")

	local reaction_text, reaction_spans = reactions.format(details.reactions)
	if reaction_text ~= "" then
		table.insert(content.lines, "")
		utils.append_block(
			content.lines,
			content.highlights,
			{ lines = { reaction_text }, highlights = reaction_spans },
			1
		)
	end
	return content.lines, content.highlights, {}
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	local toggle = keymaps.resolve("ui.toggle_description_mode")
	if toggle then
		help.register("Detail", {
			{
				key = toggle.key,
				desc = toggle.desc,
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
	local toggle = keymaps.resolve("ui.toggle_description_mode")
	if toggle then
		help.remove("Detail", { { key = toggle.key } }, { buffer = buf })
	end
end

return M
