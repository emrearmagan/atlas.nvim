local board = require("atlas.issues.ui.dashboard.board")
local config = require("atlas.config")

describe("issues.ui.dashboard.board", function()
	local status_icons

	before_each(function()
		status_icons = config.options.issues.jira.project_config.status_icons
	end)

	after_each(function()
		config.options.issues.jira.project_config.status_icons = status_icons
	end)

	it("formats Jira status icons at render time without changing provider metadata", function()
		local statuses = { { id = "1", name = "Open", category = "new" } }
		config.options.issues.jira.project_config.status_icons = { new = "N", Open = "O" }
		local opts = { provider_id = "jira", statuses = statuses, issues = {} }
		local lines = board.render(opts)
		assert.truthy(lines[1]:find("O Open (0)", 1, true))
		assert.equals("Open", statuses[1].name)
		config.options.issues.jira.project_config.status_icons.Open = ""
		lines = board.render(opts)
		assert.truthy(lines[1]:find(" Open (0)", 1, true))
		assert.is_nil(lines[1]:find("O Open", 1, true))
		assert.equals("Open", statuses[1].name)
	end)

	it("keeps empty provider status columns and preserves issue payloads", function()
		local issue = { key = "org/repo#12", title = "Fix issue", status_id = "closed", status = "Closed" }
		for _, provider in ipairs({ "github", "gitlab" }) do
			local lines, map = board.render({ provider_id = provider, issues = { issue } })
			assert.truthy(lines[1]:find("Open (0)", 1, true))
			assert.truthy(lines[1]:find("Closed (1)", 1, true))
			assert.truthy(lines[2]:find("No issues", 1, true))
			assert.equals("issue_column", map[2].cells[1].kind)
			assert.equals("issue", map[2].cells[2].kind)
			assert.equals(issue, map[2].cells[2]._issue)
		end
	end)

	it("uses configured status order and adds newly encountered statuses", function()
		local issue = { key = "AT-1", title = "New status", status_id = "3", status = "Review" }
		local lines, map = board.render({
			provider_id = "jira",
			issues = { issue },
			statuses = { { id = "2", name = "Done" }, { id = "1", name = "Open" } },
		})
		assert.is_true(lines[1]:find("Done", 1, true) < lines[1]:find("Open", 1, true))
		assert.truthy(lines[1]:find("Review (1)", 1, true))
		assert.equals(issue, map[2].cells[3]._issue)
	end)

	it("groups project cards by project status and tolerates removed status options", function()
		local active = { key = "org/repo#1", title = "Active", status_id = "open", project_status_id = "doing" }
		local stale = { key = "org/repo#2", title = "Stale", status_id = "open", project_status_id = "removed" }
		local unset = { key = "org/repo#3", title = "Unset", status_id = "open" }
		local lines, map = board.render({
			provider_id = "github",
			issues = { active, stale, unset },
			statuses = { { id = "doing", name = "In progress" } },
		})
		assert.truthy(lines[1]:find("In progress (1)", 1, true))
		assert.truthy(lines[1]:find("No status (2)", 1, true))
		assert.equals(active, map[2].cells[1]._issue)
		assert.equals(stale, map[2].cells[2]._issue)
		assert.equals(unset, map[3].cells[2]._issue)
	end)

	it("keeps byte ranges and display columns aligned for Unicode cards", function()
		local lines, map, spans = board.render({
			provider_id = "jira",
			issues = {
				{ key = "AT-1", title = "Fix café\nheading", status_id = "1", status = "Open", is_starred = true },
				{ key = "AT-2", title = "Review résumé", status_id = "2", status = "Done", story_points = 3 },
			},
		})
		local row = map[2].cells
		assert.equals(38, vim.fn.strdisplaywidth(lines[2]:sub(row[1].start_col + 1, row[1].end_col)))
		assert.equals(42, row[2].virt_col)
		assert.is_true(row[2].start_col > row[2].virt_col)
		assert.truthy(lines[2]:find("Fix café heading", 1, true))
		assert.truthy(lines[2]:find("AT-2 3 pts", 1, true))
		for _, span in ipairs(spans) do
			assert.is_true(span.start_col >= 0 and span.end_col <= #lines[span.line + 1])
		end
	end)
end)
