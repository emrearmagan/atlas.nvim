local config = require("atlas.config")

describe("issues.ui.dashboard.controller", function()
	local saved, state, controller, parent_fetches, original_relationships, focus_options
	local modules = {
		"atlas.issues.ui.dashboard.controller",
		"atlas.issues.state",
		"atlas.core.notify",
		"atlas.core.starred",
		"atlas.ui.dashboard",
		"atlas.ui.navigation",
		"atlas.ui.components.spinner",
		"atlas.ui.popups.info",
	}

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		original_relationships = config.options.issues.with_relationships
		config.options.issues.with_relationships = true
		package.loaded["atlas.core.notify"] = { loading = function() end, success = function() end }
		package.loaded["atlas.core.starred"] = {
			ref = function(issue)
				return issue.key
			end,
		}
		package.loaded["atlas.ui.dashboard"] = {
			is_active = function()
				return false
			end,
		}
		focus_options = nil
		package.loaded["atlas.ui.navigation"] = {
			focus_first_item = function(opts)
				focus_options = opts
			end,
		}
		package.loaded["atlas.ui.popups.info"] = {}
		package.loaded["atlas.ui.components.spinner"] = {
			create = function()
				return {
					start = function() end,
					stop = function() end,
					is_running = function()
						return false
					end,
					current_frame = function()
						return "*"
					end,
				}
			end,
		}
		state = require("atlas.issues.state")
		state.bookmarks = { tab = { name = "Saved" }, items = {} }
		parent_fetches = 0
		state.provider = {
			id = "jira",
			capabilities = {
				core = {
					fetch_issues = function(_, _, done)
						done({
							items = { { key = "AT-2", title = "Child", parent = { key = "AT-1" } } },
							statuses = { { id = "1", name = "Open" } },
							query = "project = AT",
						})
					end,
					fetch_by_refs = function(refs, _, done)
						parent_fetches = parent_fetches + 1
						assert.same({ { key = "AT-1" } }, refs)
						done({ { key = "AT-1", title = "Parent" } })
					end,
				},
			},
		}
		controller = require("atlas.issues.ui.dashboard.controller")
	end)

	after_each(function()
		config.options.issues.with_relationships = original_relationships
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("fetches missing parents only for plain views and preserves board status metadata", function()
		for _, layout in ipairs({ "board", "compact" }) do
			controller.switch_view({ layout = layout })
			assert.equals(0, parent_fetches)
			assert.equals(1, #state.issues)
			assert.same({ { id = "1", name = "Open" } }, state.page_history[1].statuses)
			assert.is_false(state.is_loading)
		end
		controller.switch_view({ layout = "plain" })
		assert.equals(1, parent_fetches)
		assert.equals(2, #state.issues)
		config.options.issues.with_relationships = false
		controller.switch_view({ layout = "plain" })
		assert.equals(1, parent_fetches)
		assert.equals(1, #state.issues)
	end)

	it("ignores folding in board views opened directly or from bookmarks", function()
		state.view = { layout = "board" }
		state.collapsed_issue_keys = { ["AT-1"] = true }
		state.set_issues({ { key = "AT-1" }, { key = "AT-2", parent = { key = "AT-1" } } })
		controller.toggle_current_issue_collapsed()
		controller.toggle_all_issues_collapsed()
		assert.same({ ["AT-1"] = true }, state.collapsed_issue_keys)
		state.bookmarks.selection = { kind = "bookmark", view = state.view }
		state.view = state.bookmarks.tab
		controller.toggle_current_issue_collapsed()
		controller.toggle_all_issues_collapsed()
		assert.same({ ["AT-1"] = true }, state.collapsed_issue_keys)
	end)

	it("resets selection across all columns when loading and paging", function()
		controller.switch_view({ layout = "board" })
		assert.same({ all_columns = true }, focus_options)
		focus_options = nil
		state.page_history[1].next_cursor = "next"
		controller.next_page()
		assert.same({ all_columns = true }, focus_options)
		focus_options = nil
		controller.previous_page()
		assert.same({ all_columns = true }, focus_options)
	end)

	it("keeps parent fetching and folding for unsupported board layouts", function()
		for _, provider in ipairs({ "github", "gitlab" }) do
			state.provider.id = provider
			parent_fetches = 0
			local view = { layout = "board" }
			controller.switch_view(view)
			assert.equals(1, parent_fetches)
			assert.equals(2, #state.issues)
			state.collapsed_issue_keys = {}
			controller.toggle_all_issues_collapsed()
			assert.same({ ["AT-1"] = true }, state.collapsed_issue_keys)
			state.bookmarks.selection = { kind = "bookmark", view = view }
			state.view = state.bookmarks.tab
			controller.toggle_all_issues_collapsed()
			assert.same({}, state.collapsed_issue_keys)
		end
	end)
end)
