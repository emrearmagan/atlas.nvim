local layouts = require("atlas.issues.ui.layouts")

describe("Issue board layout", function()
	it("wraps readable columns in workflow order with one line per issue", function()
		local issues = {
			{ key = "AT-1", title = "Keep board cards easy to read", status_id = "open", status = "Open" },
			{ key = "AT-2", title = "Finished", status_id = "done", status = "Done" },
			{ key = "AT-3", title = "Review", status_id = "review", status = "Review" },
		}
		local statuses = {
			{ id = "done", name = "Done", category = "done" },
			{ id = "waiting", name = "Waiting", category = "new" },
			{ id = "open", name = "Open", category = "new" },
			{ id = "review", name = "Review", category = "indeterminate" },
		}
		local opts = { layout = "board", provider_id = "jira", width = 80, statuses = statuses }
		local lines, map = layouts.render(opts, issues)
		assert.is_true(lines[1]:find("Done (1)", 1, true) < lines[1]:find("Open (1)", 1, true))
		assert.is_nil(lines[1]:find("Waiting", 1, true))
		assert.equals(2, #map[2].cells)
		assert.equals(issues[1], map[2].cells[2]._issue)
		assert.equals(6, #lines)
		assert.equals("", lines[3])
		assert.equals("", lines[4])
		assert.truthy(lines[5]:find("Review (1)", 1, true))
		assert.equals(issues[3], map[6].cells[1]._issue)
		assert.equals(3, map[6].cells[1].column)
		assert.equals("Open", statuses[3].name)
		assert.truthy(lines[2]:find(issues[1].title, 1, true))
		for _, line in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= opts.width)
		end

		opts.width = 120
		lines, map = layouts.render(opts, issues)
		assert.equals(2, #lines)
		assert.equals(3, #map[2].cells)
		assert.same({ " No issues found." }, layouts.render(opts, {}))
	end)

	it("keeps issue keys before titles and highlights them correctly with Unicode and wrapping", function()
		local lines, map, spans = layouts.render({ layout = "board", provider_id = "jira", width = 80 }, {
			{ key = "AT-1", title = "Café", status_id = "open", status = "Open" },
			{ key = "AT-2", title = "Résumé", status_id = "done", status = "Done" },
			{ key = "AT-3", title = "Überprüfung", status_id = "review", status = "Review" },
		})
		local cell = map[2].cells[2]
		local text = "AT-2 Résumé"
		assert.equals(text, lines[2]:sub(cell.start_col + 1, cell.start_col + #text))

		local highlighted = {}
		for _, span in ipairs(spans) do
			if span.hl_group ~= "AtlasColumnHeader" then
				table.insert(highlighted, lines[span.line + 1]:sub(span.start_col + 1, span.end_col))
			end
		end
		assert.same({ "AT-1", "AT-2", "AT-3" }, highlighted)
	end)

	it("falls back to plain for unsupported providers", function()
		local plain = require("atlas.issues.ui.layouts.plain")
		local issues = { { key = "AT-1", number = 1, title = "Work" } }
		local opts = { layout = "board", provider_id = "github", width = 80 }
		assert.same({ plain.github(opts, issues) }, { layouts.render(opts, issues) })
		opts.provider_id = "unknown"
		assert.same({ plain.default(opts, issues) }, { layouts.render(opts, issues) })
	end)
end)
