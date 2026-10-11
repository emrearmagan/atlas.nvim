local layouts = require("atlas.issues.ui.layouts")

describe("Issue board layout", function()
	it("preserves workflow order, empty columns and issue payloads", function()
		local issue = { key = "AT-1", title = "Work", status_id = "open", status = "Open" }
		local statuses = {
			{ id = "done", name = "Done", category = "done" },
			{ id = "open", name = "Open", category = "new" },
		}
		local lines, map = layouts.render({ layout = "board", provider_id = "jira", statuses = statuses }, { issue })
		assert.is_true(lines[1]:find("Done (0)", 1, true) < lines[1]:find("Open (1)", 1, true))
		assert.truthy(lines[2]:find("No issues", 1, true))
		assert.equals("issue_column", map[2].cells[1].kind)
		assert.equals(issue, map[2].cells[2]._issue)
		assert.equals("Open", statuses[2].name)
	end)

	it("keeps Unicode card offsets and highlights within the rendered lines", function()
		local lines, map, spans = layouts.render({ layout = "board", provider_id = "jira" }, {
			{ key = "AT-1", title = "Café", status_id = "open", status = "Open" },
			{ key = "AT-2", title = "Résumé", status_id = "done", status = "Done" },
		})
		local cell = map[2].cells[2]
		assert.is_true(cell.start_col > cell.virt_col)
		assert.truthy(lines[2]:sub(cell.start_col + 1, cell.end_col):find("AT-2", 1, true))
		for _, span in ipairs(spans) do
			assert.is_true(span.start_col >= 0 and span.end_col <= #lines[span.line + 1])
		end
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
