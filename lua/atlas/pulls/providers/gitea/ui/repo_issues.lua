local M = {}

local issue_renderer = require("atlas.pulls.ui.panel.repo.tabs.issues.renderer")
local repo_state = require("atlas.pulls.ui.panel.repo.state")
local statusline = require("atlas.ui.statusline")

---@param repositories table
---@return PullsRepoPanelTabModule
function M.new(repositories)
	local tab = {}

	local state = { issues = nil, filter = "open", last_slug = nil }
	local in_flight
	local request_generation = 0

	local function cancel()
		request_generation = request_generation + 1
		if in_flight and in_flight.cancel then
			in_flight.cancel()
		end
		in_flight = nil
	end

	local function reset()
		cancel()
		state.issues, state.filter, state.last_slug = nil, "open", nil
	end

	---@param _repo PullsRepo
	---@param width integer
	function tab.render(_repo, width)
		return issue_renderer.render(state, width, repo_state.current_repo_details == "loading")
	end

	---@param slug string
	---@param refresh fun()
	local function fetch(slug, refresh)
		cancel()
		local generation = request_generation
		state.issues, state.last_slug = "loading", slug
		refresh()
		local finished = false
		local handle = repositories.fetch_issues(slug, state.filter, function(issues, err)
			if generation ~= request_generation or state.last_slug ~= slug then
				return
			end
			finished = true
			in_flight = nil
			if err then
				state.issues = tostring(err)
				statusline.notify("error", string.format("Failed to load issues for %s", slug))
				refresh()
				return
			end
			state.issues = issues or {}
			statusline.notify("success", string.format("Issues loaded for %s", slug), 1200)
			refresh()
		end)
		if generation == request_generation and not finished then
			in_flight = handle
		end
	end

	function tab.on_select(_, repo, refresh, opts)
		local details = repo_state.current_repo_details
		if repo == nil or (details ~= "loading" and type(details) ~= "table") then
			reset()
			refresh()
			return
		end
		if details == "loading" then
			cancel()
			state.last_slug = nil
			state.issues = "loading"
			refresh()
			return
		end
		---@cast details PullsRepoDetails
		local slug = tostring(details.full_name or "")
		if slug == "" then
			reset()
			refresh()
			return
		end
		if not ((opts and opts.force_refresh) or state.last_slug ~= slug or type(state.issues) ~= "table") then
			refresh()
			return
		end
		statusline.notify("loading", string.format("Loading issues for %s...", slug))
		fetch(slug, refresh)
	end

	function tab.is_loading()
		return state.issues == "loading"
	end

	function tab.is_selectable_line(_, entry)
		return entry.kind == "issue"
	end

	function tab.on_enter(_, entry)
		if entry and entry.kind == "issue" and tostring(entry.url or "") ~= "" then
			vim.ui.open(entry.url)
			return true
		end
	end

	function tab.activate(buf, refresh)
		if not buf or not refresh then
			return
		end
		require("atlas.ui.popups.help").register("Issues", {
			{
				key = "s",
				desc = "Toggle open/closed",
				opts = { nowait = true, silent = true },
				callback = function()
					state.filter = state.filter == "open" and "closed" or "open"
					local details = repo_state.current_repo_details
					if type(details) == "table" and tostring(details.full_name or "") ~= "" then
						fetch(details.full_name, refresh)
					end
				end,
			},
		}, { index = 212, buffer = buf })
	end

	function tab.deactivate(buf)
		cancel()
		if buf then
			require("atlas.ui.popups.help").remove("Issues", { { key = "s" } }, { buffer = buf })
		end
	end

	return tab
end

return M
