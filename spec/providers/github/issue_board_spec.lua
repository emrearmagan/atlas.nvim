local provider = require("atlas.issues.providers.github")
local issues_api = require("atlas.issues.providers.github.api.issues")
local mapper = require("atlas.issues.providers.github.api.mapper")
local git = require("atlas.core.git")

describe("GitHub issue board provider", function()
	local original_search, original_project_search, original_repository, original_getcwd
	local repository_done, search_done, request, cancelled

	before_each(function()
		original_search = issues_api.search_issues
		original_project_search = issues_api.search_project_issues
		original_repository = git.local_repository
		original_getcwd = vim.fn.getcwd
		repository_done, search_done, request, cancelled = nil, nil, nil, {}
		vim.fn.getcwd = function()
			return "/repo"
		end
		git.local_repository = function(_, done)
			repository_done = done
			return {
				cancel = function()
					cancelled.repository = true
				end,
			}
		end
		issues_api.search_project_issues = function(project, query, done, opts)
			request = { project = project, query = query, opts = opts }
			search_done = done
			return {
				cancel = function()
					cancelled.search = true
				end,
			}
		end
		issues_api.search_issues = function(query, done, opts)
			request = { query = query, opts = opts }
			search_done = done
		end
	end)

	after_each(function()
		issues_api.search_issues = original_search
		issues_api.search_project_issues = original_project_search
		git.local_repository = original_repository
		vim.fn.getcwd = original_getcwd
	end)

	it("resolves the current repository before fetching project columns and retains their order", function()
		local project = { owner = "team", number = 3, status_field = "Workflow" }
		local view = { layout = "board", project = project, current_repo = true, search = "is:open" }
		local result
		provider.capabilities.core.fetch_issues(
			view,
			{ pagelen = 25, cursor = "next", force_refresh = true },
			function(page, err)
				assert.is_nil(err)
				result = page
			end
		)
		assert.is_nil(request)
		repository_done({ provider = "github", repo_full_name = "team/repo" })
		assert.same({
			project = project,
			query = "repo:team/repo is:open is:issue",
			opts = { pagelen = 25, cursor = "next", force_refresh = true },
		}, request)
		local items = { { key = "team/repo#1" }, { key = "team/repo#2", is_pinned = true } }
		local statuses = { { id = "doing", name = "Doing" } }
		search_done({ items = items, statuses = statuses, next_cursor = "after", total_pages = 4 })
		assert.same(items, result.items)
		assert.same(statuses, result.statuses)
		assert.equal(request.query, result.query)
		assert.equal("after", result.next_cursor)
		assert.equal(4, result.total_pages)
		assert.equal("is:open", view.search)
	end)

	it("keeps regular search boards sorted with pinned issues first", function()
		local result
		provider.capabilities.core.fetch_issues(
			{ layout = "board", search = "repo:team/repo" },
			{ pagelen = 50 },
			function(page)
				result = page
			end
		)
		assert.is_nil(request.project)
		search_done({ items = { { key = "1" }, { key = "2", is_pinned = true } } })
		assert.equal("2", result.items[1].key)
		assert.equal("repo:team/repo is:issue", result.query)
	end)

	it("cancels repository resolution without starting a project request", function()
		local completed = false
		local handle = provider.capabilities.core.fetch_issues({
			layout = "board",
			project = { owner = "team", number = 3 },
			current_repo = true,
		}, {}, function()
			completed = true
		end)
		handle.cancel()
		repository_done({ provider = "github", repo_full_name = "team/repo" })
		assert.is_true(cancelled.repository)
		assert.is_nil(request)
		assert.is_false(completed)
	end)

	it("cancels the active project request and ignores its late result", function()
		local completed = false
		local handle = provider.capabilities.core.fetch_issues({
			layout = "board",
			project = { owner = "team", number = 3 },
		}, {}, function()
			completed = true
		end)
		handle.cancel()
		search_done({ items = {} })
		assert.is_true(cancelled.search)
		assert.is_false(completed)
	end)

	it("returns the resolved query with project errors", function()
		local result, failure
		provider.capabilities.core.fetch_issues({
			layout = "board",
			project = { owner = "team", number = 3 },
			search = "is:open",
		}, {}, function(page, err)
			result, failure = page, err
		end)
		search_done({ items = {} }, "Project unavailable")
		assert.same({ items = {}, query = "is:open is:issue" }, result)
		assert.equal("Project unavailable", failure)
	end)
end)

describe("GitHub project issue mapping", function()
	it("ignores JSON null nodes without indexing them", function()
		local original_null = vim.NIL
		-- Match Neovim's userdata sentinel: indexing JSON null must raise an error.
		vim.NIL = setmetatable({}, {
			__index = function()
				error("Cannot index JSON null")
			end,
		})
		local ok, page = pcall(mapper.to_project_page, {
			field = { options = {} },
			items = { nodes = { vim.NIL, { content = vim.NIL } } },
		}, 50)
		vim.NIL = original_null
		assert.is_true(ok, page)
		assert.same({}, page.items)
		assert.same({ { id = "no_status", name = "No status" } }, page.statuses)
	end)

	it("retains project options, issue status IDs and cursor pagination", function()
		local function issue(number)
			return { number = number, title = "Issue", state = "OPEN", repository = { nameWithOwner = "team/repo" } }
		end
		local options = { { id = "doing", name = "Doing" }, { id = "done", name = "Done" } }
		local page = mapper.to_project_page({
			field = { options = options },
			items = {
				totalCount = 30,
				pageInfo = { hasNextPage = true, endCursor = "next" },
				nodes = {
					{ content = issue(1), status = { optionId = "doing" } },
					{ content = issue(2), status = vim.NIL },
					{ content = vim.NIL },
				},
			},
		}, 20)
		assert.equal(2, #page.items)
		assert.equal("doing", page.items[1].project_status_id)
		assert.equal("no_status", page.items[2].project_status_id)
		assert.equal("next", page.next_cursor)
		assert.equal(2, page.total_pages)
		assert.same({ options[1], options[2], { id = "no_status", name = "No status" } }, page.statuses)
		assert.equal(2, #options)
	end)
end)
