local M = {}
local notify = require("atlas.core.notify")

---@class ForgePullSearch
---@field open fun(default: string|nil)
---@field open_global fun(default: string|nil)

---@param provider_id "gitea"|"forgejo"
---@return ForgePullSearch
function M.new(provider_id)
	local provider_name = provider_id == "gitea" and "Gitea" or "Forgejo"
	---@type ForgePullSearch
	local search = {}

	---@param default string|nil
	---@param global boolean
	local function open(default, global)
		local state = require("atlas.pulls.state")
		local view = state.search_view()
		---@cast view AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig|nil
		local repo = (view and view.repo) or ""
		if not global and repo == "" then
			notify.warn("Select a " .. provider_name .. " repository first")
			return
		end
		require("atlas.commands.search.prompt").open({
			name = "Atlas" .. provider_name .. "PullSearch",
			default = default or state.query,
			on_submit = function(query)
				query = vim.trim(query)
				local target_view = {
					name = "Search",
					layout = (view and view.layout) or "compact",
					search = query,
				}
				if not global then
					target_view.repo = repo
				end
				if require("atlas.ui.dashboard").is_active("pulls", provider_id) then
					require("atlas.pulls.ui.dashboard.controller").switch_view(target_view)
					return
				end
				require("atlas").open("pulls", provider_id, { initial_view = target_view })
			end,
		})
	end

	---@param default string|nil
	function search.open(default)
		open(default, false)
	end

	---@param default string|nil
	function search.open_global(default)
		open(default, true)
	end

	return search
end

return M
