local actions = require("atlas.pulls.actions")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local bitbucket_query = require("atlas.providers.bitbucket.query")
local bitbucket_search = require("atlas.providers.bitbucket.completion.search")
local picker = require("atlas.ui.picker")
local state = require("atlas.pulls.state")
local workspaces_api = require("atlas.providers.bitbucket.workspaces")

---@type AtlasPullAction[]
local ACTIONS = {}

---@param action AtlasPullAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param on_select fun(repo: AtlasRepository)
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function select_repository(on_select, done)
	notify.loading("Loading workspaces...")
	workspaces_api.fetch_workspaces(function(workspaces, err)
		if err ~= nil then
			notify.error(string.format("Failed loading workspaces: %s", tostring(err)))
			done(nil, tostring(err))
			return
		end

		local ws = workspaces or {}
		if #ws == 0 then
			notify.warn("No workspaces found")
			done({ changed_pr = false }, nil)
			return
		end

		notify.info(string.format("Loaded %d workspaces", #ws), { timeout = 1200 })

		---@param selected_ws BitbucketWorkspace
		local function continue_with_workspace(selected_ws)
			if selected_ws.slug == "" then
				notify.warn("Invalid workspace selection")
				done({ changed_pr = false }, nil)
				return
			end

			picker.search({
				title = string.format("Repositories in %s", selected_ws.slug),
				format_item = function(repo)
					return repo.full_name ~= "" and repo.full_name or repo.name
				end,
				fetch = function(query, fetch_done)
					return workspaces_api.fetch_workspace_repositories(selected_ws.slug, vim.trim(query), fetch_done)
				end,
				on_select = on_select,
				on_cancel = function()
					done({ changed_pr = false }, nil)
				end,
			})
		end

		if #ws == 1 then
			continue_with_workspace(ws[1])
			return
		end

		picker.select({
			title = "Select workspace",
			items = ws,
			format_item = function(item)
				return item.slug
			end,
			on_select = function(selected)
				if selected == nil then
					done({ changed_pr = false }, nil)
					return
				end
				continue_with_workspace(selected)
			end,
		})
	end)
end

register(actions.approve)
register(actions.request_changes)
register(actions.merge)
register(actions.decline)

register(actions.edit_pr)
register(actions.ready_for_review)
register(actions.convert_to_draft)
register(actions.edit_reviewers)

register({
	id = "search",
	label = "Search repositories",
	icon = icons.get("search", "actions"),
	run = function(_, done)
		select_repository(function(repo)
			---@type AtlasBitbucketViewConfig
			local search_view = {
				name = "Search",
				layout = "compact",
				search = bitbucket_query.for_repo(repo.owner, repo.repo_name),
			}
			notify.success(string.format("Search view -> %s", repo.full_name))
			require("atlas").open("pulls", "bitbucket", { initial_view = search_view })
			done({ changed_pr = false }, nil)
		end, done)
	end,
})

register(actions.browse_repository)
register({
	id = "browse_repositories",
	label = "Browse Repository",
	icon = icons.get("overview"),
	run = function(ctx, done)
		select_repository(function(repo)
			require("atlas.ui.repository").open(repo.full_name, ctx.provider, { page = ctx.page })
			done(nil, nil)
		end, done)
	end,
})

register({
	id = "search_pull_requests",
	label = "New Search",
	icon = icons.get("search", "actions"),
	run = function(_, done)
		bitbucket_search.open({ name = "Search", search = state.query })
		done(nil, nil)
	end,
})

register({
	id = "edit_search",
	label = "Edit Current Search",
	icon = icons.get("search", "actions"),
	run = function(_, done)
		bitbucket_search.edit({ name = "Search", search = state.query }, function(query)
			local view = state.search_view()
			if view then
				view.search = query
				view._states = nil
				require("atlas.pulls.ui.dashboard.controller").refresh_view()
			end
		end)
		done(nil, nil)
	end,
})

register(actions.open_pipelines)
register(actions.open_diff)
register(actions.checkout)

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

return ACTIONS
