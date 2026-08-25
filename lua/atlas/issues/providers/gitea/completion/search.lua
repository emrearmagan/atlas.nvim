local M = {}

---@param default string|nil
function M.open(default)
	require("atlas.commands.search.prompt").open({
		name = "AtlasGiteaIssueSearch",
		on_submit = function(query)
			query = vim.trim(query)
			if query == "" then
				return
			end

			local view = { name = "Search", layout = "compact", search = query, state = "all" }
			if require("atlas.ui.dashboard").is_active("issues", "gitea") then
				require("atlas.issues.ui.dashboard.controller").switch_view(view)
				return
			end

			require("atlas").open("issues", "gitea", { initial_view = view })
		end,
		default = default,
	})
end

return M
