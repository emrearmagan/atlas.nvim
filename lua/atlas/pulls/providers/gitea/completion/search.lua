local M = {}

---@param default string|nil
---@param global boolean
local function open(default, global)
	local state = require("atlas.pulls.state")
	---@type AtlasGiteaForgejoPullsViewConfig
	local view = state.active_view or state.current_view or {}
	local repo = tostring(view.repo or "")
	if not global and repo == "" then
		require("atlas.ui.statusline").notify("warn", "Select a Gitea/Forgejo repository first")
		return
	end
	require("atlas.commands.search.prompt").open({
		name = "AtlasGiteaPullSearch",
		default = default or tostring(view.search or ""),
		on_submit = function(query)
			query = vim.trim(tostring(query or ""))
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
