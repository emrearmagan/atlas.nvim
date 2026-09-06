local M = {}

---@class ForgeIssueSearch
---@field open fun(default: string|nil)

---@param provider_id ForgeProviderId
---@return ForgeIssueSearch
function M.new(provider_id)
	local provider_name = provider_id == "gitea" and "Gitea" or "Forgejo"
	---@type ForgeIssueSearch
	return {
		open = function(default)
			require("atlas.commands.search.prompt").open({
				name = "Atlas" .. provider_name .. "IssueSearch",
				on_submit = function(query)
					query = vim.trim(query)
					if query == "" then
						return
					end

					local view = { name = "Search", layout = "compact", search = query, state = "all" }
					if require("atlas.ui.dashboard").is_active("issues", provider_id) then
						require("atlas.issues.ui.dashboard.controller").switch_view(view)
						return
					end

					require("atlas").open("issues", provider_id, { initial_view = view })
				end,
				default = default,
			})
		end,
	}
end

return M
