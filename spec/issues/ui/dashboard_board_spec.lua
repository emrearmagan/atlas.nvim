local layouts = require("atlas.issues.ui.layouts")

describe("Issue board layout", function()
	it("draws the visible columns left to right in workflow order", function()
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
		assert.equal(2, #lines)
		assert.is_true(lines[1]:find("Done (1)", 1, true) < lines[1]:find("Open (1)", 1, true))
		assert.is_nil(lines[1]:find("Waiting", 1, true))
		assert.is_nil(lines[1]:find("Review", 1, true))
		assert.equal(3, map[2].column_count)
		assert.equal(issues[2], map[2].cells[1].issue)
		assert.equal(issues[1], map[2].cells[2].issue)
		assert.equal("Open", statuses[3].name)
		assert.truthy(lines[2]:find(issues[1].title, 1, true))
		assert.is_true(vim.fn.strdisplaywidth(lines[2]) <= opts.width)
		assert.same({ " No issues found." }, layouts.render(opts, {}))

		opts.first_column = 2
		lines, map = layouts.render(opts, issues)
		assert.is_nil(lines[1]:find("Done", 1, true))
		assert.equal(issues[1], map[2].cells[1].issue)
		assert.equal(issues[3], map[2].cells[2].issue)
		assert.equal(3, map[2].cells[2].column)
	end)

	it("fits as many full columns as the window allows", function()
		local issues = {}
		for index, status in ipairs({ "A", "B", "C", "D", "E", "F" }) do
			issues[index] = { key = "AT-" .. index, title = "Card", status_id = status, status = status }
		end
		local function visible(width, first_column)
			local _, map = layouts.render(
				{ layout = "board", provider_id = "jira", width = width, first_column = first_column },
				issues
			)
			for _, cell in ipairs(map[2].cells) do
				assert.is_true(cell.end_col <= width)
			end
			return #map[2].cells, map[2].cells[1].column
		end
		assert.equal(5, visible(200))
		assert.equal(4, visible(158))
		assert.equal(2, visible(80))
		assert.equal(1, visible(40))
		assert.same({ 2, 5 }, { visible(80, 10) })
	end)
end)
