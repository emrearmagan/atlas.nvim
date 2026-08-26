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
		---@type AtlasGiteaPullsViewConfig|AtlasForgejoPullsViewConfig
		local view = state.active_view
		local repo = view.repo or ""
		if not global and repo == "" then
			notify.warn("Select a " .. provider_name .. " repository first")
			return
		end
		require("atlas.commands.search.prompt").open({
			name = "Atlas" .. provider_name .. "PullSearch",
			default = default or view.search or "",
			on_submit = function(query)
				query = vim.trim(query)
				local search_view = { name = "Search", layout = view.layout or "compact", search = query }
				if not global then
					search_view.repo = repo
				end
				if require("atlas.ui.dashboard").is_active("pulls", provider_id) then
					require("atlas.pulls.ui.dashboard.controller").switch_view(search_view)
					return
				end
				require("atlas").open("pulls", provider_id, { initial_view = search_view })
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
