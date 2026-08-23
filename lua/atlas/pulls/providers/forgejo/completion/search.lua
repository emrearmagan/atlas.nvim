local M = {}
local notify = require("atlas.core.notify")

---@param default string|nil
---@param global boolean
local function open(default, global)
	local state = require("atlas.pulls.state")
	---@type AtlasForgejoPullsViewConfig
	local view = state.active_view
	local repo = view.repo or ""
	if not global and repo == "" then
		notify.warn("Select a Forgejo repository first")
		return
	end
	require("atlas.commands.search.prompt").open({
		name = "AtlasForgejoPullSearch",
		default = default or view.search or "",
		on_submit = function(query)
			query = vim.trim(query)
			local search_view = { name = "Search", layout = view.layout or "compact", search = query }
			if not global then
				search_view.repo = repo
			end
			require("atlas.pulls.ui.main.controller").switch_view(search_view)
		end,
	})
end

---@param default string|nil
function M.open(default)
	open(default, false)
end

---@param default string|nil
function M.open_global(default)
	open(default, true)
end

return M
