local provider = require("atlas.issues.providers.jira")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local projects_api = require("atlas.issues.providers.jira.api.projects")
local notify = require("atlas.core.notify")

describe("Jira issue board provider", function()
	local original_search, original_statuses, original_warn, original_values
	local search_done, status_done, request, cancelled, warnings

	before_each(function()
		original_search = issues_api.search_issues
		original_statuses = projects_api.get_statuses
		original_warn = notify.warn
		original_values = vim.tbl_values
		vim.tbl_values = function(values)
			local result = {}
			for _, value in pairs(values) do
				result[#result + 1] = value
			end
			return result
		end
		search_done, status_done, request, cancelled, warnings = nil, {}, nil, {}, {}
		issues_api.search_issues = function(query, done, opts)
			request = { query = query, opts = opts }
			search_done = done
			return {
				cancel = function()
					cancelled.search = true
				end,
			}
		end
		projects_api.get_statuses = function(project, done)
			assert.is_nil(status_done[project])
			status_done[project] = done
			return {
				cancel = function()
					cancelled[project] = true
				end,
			}
		end
		notify.warn = function(message)
			warnings[#warnings + 1] = message
		end
	end)

	after_each(function()
		issues_api.search_issues = original_search
		projects_api.get_statuses = original_statuses
		notify.warn = original_warn
		vim.tbl_values = original_values
	end)

	it("adds ordered project statuses while preserving the query and pagination", function()
		local result
		provider.capabilities.core.fetch_issues({ layout = "board", jql = "project = KAN" }, {
			pagelen = 25,
			cursor = "25",
			force_refresh = true,
		}, function(page, err)
			assert.is_nil(err)
			result = page
		end)
		assert.same({ query = "project = KAN", opts = { pagelen = 25, cursor = "25", force_refresh = true } }, request)
		local items = { { project = { id = "100" } }, { project = { id = "100" } }, { project = { key = "OTHER" } } }
		search_done({ items = items, next_cursor = "50", total_pages = 3 })
		assert.is_nil(result)
		status_done["100"]({
			{ id = "3", name = "Done", category = "done" },
			{ id = "1", name = "Open", category = "new" },
		})
		assert.is_nil(result)
		status_done.OTHER({ { id = "2", name = "Doing", category = "indeterminate" } })
		assert.same(items, result.items)
		assert.equal("project = KAN", result.query)
		assert.equal("50", result.next_cursor)
		assert.equal(3, result.total_pages)
		assert.same({
			{ id = "1", name = "Open", category = "new" },
			{ id = "2", name = "Doing", category = "indeterminate" },
			{ id = "3", name = "Done", category = "done" },
		}, result.statuses)
	end)

	it("still returns issues and query when project metadata fails", function()
		local result
		provider.capabilities.core.fetch_issues({ layout = "board", jql = "project = KAN" }, {}, function(page, err)
			assert.is_nil(err)
			result = page
		end)
		local items = { { project = { key = "KAN" } } }
		search_done({ items = items })
		status_done.KAN(nil, "Permission denied")
		assert.same({ items = items, statuses = {}, query = "project = KAN" }, result)
		assert.same({ "Failed to load board statuses: Permission denied" }, warnings)
	end)

	it("cancels all pending project metadata requests and ignores late results", function()
		local completed = false
		local handle = provider.capabilities.core.fetch_issues(
			{ layout = "board", jql = "assignee = currentUser()" },
			{},
			function()
				completed = true
			end
		)
		search_done({ items = { { project = { key = "ONE" } }, { project = { key = "TWO" } } } })
		handle.cancel()
		status_done.ONE({})
		status_done.TWO({})
		assert.is_true(cancelled.ONE)
		assert.is_true(cancelled.TWO)
		assert.is_false(completed)
	end)

	it("returns queries for non-board views without requesting project statuses", function()
		local result
		provider.capabilities.core.fetch_issues({ layout = "compact", jql = "project = KAN" }, {}, function(page)
			result = page
		end)
		search_done({ items = { { project = { key = "KAN" } } } })
		assert.equal("project = KAN", result.query)
		assert.is_nil(result.statuses)
		assert.same({}, status_done)
	end)
end)
