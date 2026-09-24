local M = {}

local help = require("atlas.ui.popups.help")
local info = require("atlas.ui.popups.info")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local detail = require("atlas.pulls.ui.detail.state")

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	local out = vim.tbl_deep_extend("force", {}, map_item)
	out.key = #keys == 1 and keys[1] or keys
	return out
end

---@param action_id AtlasKeymapActionId|string
---@return table|nil
local function remove_item(action_id)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	return { key = (#keys == 1 and keys[1] or keys) }
end

---@param commit PullsCommit
---@return string[]
function M.format_commit_lines(commit)
	local message = tostring(commit.message or ""):gsub("\r\n", "\n")
	local lines = vim.split(message, "\n", { plain = true })
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	table.insert(lines, "")

	local author = (commit.author_nickname ~= "" and commit.author_nickname) or commit.author_name or "Unknown"
	table.insert(lines, "Author: " .. tostring(author))
	table.insert(lines, "Date: " .. utils.format_date(commit.date))
	table.insert(lines, "Commit: " .. tostring(commit.hash or commit.short_hash or ""))
	return lines
end

---@param buf integer
---@param _refresh fun()
function M.setup(buf, _refresh)
	local items = {}
	utils.insert_if(
		items,
		item("ui.show_details", {
			desc = "Show full commit message (stays open while navigating)",
			opts = { nowait = true, silent = true },
			callback = function()
				if not detail.win then
					return
				end
				info.toggle({
					source_win = detail.win,
					content = function(line)
						local entry = detail.line_map[line]
						if entry and entry.commit then
							return {
								title = " Commit " .. (entry.commit.short_hash or entry.commit.hash):sub(1, 8) .. " ",
								lines = M.format_commit_lines(entry.commit),
								filetype = "markdown",
							}
						end
					end,
				})
			end,
		})
	)
	help.register("Detail", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	M.close_pin()
	local items = {}
	utils.insert_if(items, remove_item("ui.show_details"))
	help.remove("Detail", items, { buffer = buf })
end

function M.close_pin()
	if detail.win then
		info.close(detail.win)
	end
end

return M
