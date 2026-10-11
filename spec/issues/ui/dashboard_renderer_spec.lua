describe("issues.ui.dashboard.renderer", function()
	local saved, state, renderer
	local modules = {
		"atlas.issues.state",
		"atlas.issues.ui.dashboard.renderer",
		"atlas.ui.statusline",
		"atlas.ui.shared.bookmarks",
	}

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		package.loaded["atlas.ui.statusline"] = { set_items = function() end }
		package.loaded["atlas.ui.shared.bookmarks"] = {
			views = function(views)
				return views
			end,
			render = function(lines)
				lines[#lines + 1] = "Bookmarks"
			end,
		}
		state = require("atlas.issues.state")
		state.provider = { id = "jira", name = "Jira", capabilities = {} }
		state.view = { name = "Board", layout = "board" }
		state.views = { state.view }
		state.bookmarks = { tab = { name = "Saved" }, items = {} }
		state.page_history[1] = { statuses = { { id = "1", name = "Open" }, { id = "2", name = "Done" } } }
		renderer = require("atlas.issues.ui.dashboard.renderer")
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("renders board statuses and offsets their selectable cells below the header", function()
		local issue = { key = "AT-1", title = "Child", status_id = "1", status = "Open", parent = { key = "AT-2" } }
		state.set_issues({ issue })
		state.query = "project = AT"
		local lines, spans, map = renderer.render({ width = 100 })
		local text = table.concat(lines, "\n")
		assert.truthy(text:find("project = AT", 1, true))
		assert.truthy(text:find("Open (1)", 1, true))
		assert.truthy(text:find("Done (0)", 1, true))
		local selected_line
		for line, row in pairs(map) do
			if row.kind == "board_row" and row.cells[1]._issue then
				selected_line = line
				assert.equals(issue, row.cells[1]._issue)
				assert.truthy(lines[line]:find("Child AT-1", 1, true))
			end
		end
		assert.is_not_nil(selected_line)
		local key_span
		for _, span in ipairs(spans) do
			if span.hl_group == "AtlasJiraKey" then
				key_span = span
			end
		end
		assert.equals(selected_line - 1, key_span.line)
	end)

	it("keeps empty columns after loading and shows progress while fetching", function()
		state.is_loading = true
		local lines, _, map = renderer.render({ width = 100 })
		assert.truthy(table.concat(lines, "\n"):find("Loading...", 1, true))
		assert.same({}, map)
		state.is_loading = false
		lines, _, map = renderer.render({ width = 100 })
		assert.truthy(table.concat(lines, "\n"):find("Done (0)", 1, true))
		assert.is_not_nil(next(map))
	end)

	it("uses board layout and status metadata for a selected bookmark", function()
		state.bookmarks.selection = { kind = "bookmark", view = state.view }
		state.view = state.bookmarks.tab
		local lines = renderer.render({ width = 100 })
		local text = table.concat(lines, "\n")
		assert.truthy(text:find("Bookmarks", 1, true))
		assert.truthy(text:find("Open (0)", 1, true))
	end)

	it("renders plain and compact layouts through the shared issue list", function()
		local parent = { key = "AT-1", title = "Parent", status = "Open" }
		local child = { key = "AT-2", title = "Child", status = "Open", parent = { key = "AT-1" } }
		state.set_issues({ parent, child })
		state.collapsed_issue_keys[parent.key] = true
		for _, case in ipairs({ { "plain", 1 }, { "compact", 2 } }) do
			state.view.layout = case[1]
			local lines, _, map = renderer.render({ width = 120 })
			local issues = {}
			for line, item in pairs(map) do
				assert.is_not_nil(lines[line])
				if item.kind == "issue" then
					issues[#issues + 1] = item._issue
				end
			end
			assert.equals(case[2], #issues)
		end
	end)

	it("falls back to plain lists for non-Jira board views and bookmarks", function()
		local board_view = state.view
		local issue = {
			key = "org/repo#12",
			number = 12,
			iid = 12,
			title = "Existing board configuration",
			status_id = "open",
			status = "Open",
		}
		state.set_issues({ issue })
		for _, provider in ipairs({ "github", "gitlab" }) do
			state.provider.id = provider
			for _, bookmarked in ipairs({ false, true }) do
				state.view = bookmarked and state.bookmarks.tab or board_view
				state.bookmarks.selection = bookmarked and { kind = "bookmark", view = board_view } or nil
				local lines, _, map = renderer.render({ width = 120 })
				local found = false
				for _, item in pairs(map) do
					assert.is_not.equal("board_row", item.kind)
					found = found or item._issue == issue
				end
				assert.is_true(found)
				assert.truthy(table.concat(lines, "\n"):find(issue.title, 1, true))
			end
		end
	end)
end)
