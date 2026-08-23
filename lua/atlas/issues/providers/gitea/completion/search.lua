local M = {}

---@param query string
local function run(query)
	query = vim.trim(query)
	if query == "" then
		return
	end

	local view = { name = "Search", layout = "compact", search = query, state = "all" }
	local layout = require("atlas.ui.layout")
	local state = require("atlas.issues.state")
	if layout.is_open() and state.provider and state.provider.id == "gitea" then
		require("atlas.issues.ui.main.controller").switch_view(view)
		return
	end

	require("atlas").open("issues", "gitea", { initial_view = view })
end

---@param default string|nil
function M.open(default)
	require("atlas.commands.search.prompt").open({
		name = "AtlasGiteaIssueSearch",
		on_submit = run,
		default = default,
	})
end

return M
