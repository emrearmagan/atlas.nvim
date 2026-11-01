local provider = require("atlas.issues.providers.jira")
local issues_api = require("atlas.issues.providers.jira.api.issues")
local projects_api = require("atlas.issues.providers.jira.api.projects")

describe("Jira issue board provider", function()
	local original_search, original_statuses
	local status_done, cancelled

	before_each(function()
		original_search = issues_api.search_issues
		original_statuses = projects_api.get_statuses
		status_done, cancelled = nil, false
		issues_api.search_issues = function(_, done)
			done({ items = { { key = "KAN-1", title = "Issue", project = { key = "KAN" } } } })
		end
		projects_api.get_statuses = function(project, done)
			assert.equal("KAN", project)
			status_done = done
			return {
				cancel = function()
					cancelled = true
				end,
			}
		end
	end)

	after_each(function()
		issues_api.search_issues = original_search
		projects_api.get_statuses = original_statuses
	end)

	it("returns workflow statuses in category order with raw names", function()
		local result
		provider.capabilities.core.fetch_issues(
			{ name = "Board", layout = "board", jql = "project = KAN" },
			{},
			function(page, err)
				assert.is_nil(err)
				result = page
			end
		)
		assert.is_nil(result)
		status_done({
			{ id = "2", name = "Done", category = "done" },
			{ id = "1", name = "Open", category = "new" },
		})
		assert.same({
			{ id = "1", name = "Open", category = "new" },
			{ id = "2", name = "Done", category = "done" },
		}, result.statuses)
		assert.equal("KAN-1", result.items[1].key)
	end)

	it("cancels the status request and ignores its late callback", function()
		local completed = false
		local handle = provider.capabilities.core.fetch_issues(
			{ name = "Board", layout = "board", jql = "project = KAN" },
			{},
			function()
				completed = true
			end
		)
		assert(handle).cancel()
		status_done({ { id = "1", name = "Open", category = "new" } })
		assert.is_true(cancelled)
		assert.is_false(completed)
	end)
end)
