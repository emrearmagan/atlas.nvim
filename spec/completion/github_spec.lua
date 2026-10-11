local modules = {
	"atlas.providers.github.client",
	"atlas.providers.github.users",
	"atlas.providers.github.completion",
	"atlas.ui.shared.icons",
}

describe("GitHub completion", function()
	local saved, source, calls, failure, repository_users, participants, reviewers
	local issue_source, pull_source, reference_response, request_handle

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		calls, failure = {}, nil
		repository_users = { { id = "U1", login = "alice", name = "Alice" } }
		participants = {}
		reviewers = {}
		reference_response = { issues = { { number = 42, title = "Fix login", state = "OPEN" } }, pulls = {} }
		request_handle = { cancel = function() end }
		package.loaded["atlas.ui.shared.icons"] = {
			get = function(name)
				return name
			end,
		}
		local cache = {}
		package.loaded["atlas.providers.github.client"] = {
			get_mem = function(key)
				return cache[key], cache[key] ~= nil
			end,
			set_mem = function(key, value)
				cache[key] = value
			end,
			gh = function(args, done)
				calls[#calls + 1] = args
				local command = table.concat(args, " ")
				if command:find("search=repo:", 1, true) then
					local kind = command:find(" is:pr ", 1, true) and "pulls" or "issues"
					done({ data = { search = { nodes = reference_response[kind] } } }, failure)
					return request_handle
				end
				done({
					data = {
						repository = {
							mentionableUsers = { nodes = repository_users },
							item = command:find("fetchParticipants=true", 1, true) and {
								participants = { nodes = vim.deepcopy(participants) },
								reviewRequests = { nodes = reviewers },
							} or nil,
						},
					},
				}, failure)
			end,
		}
		source = require("atlas.providers.github.completion").users
		issue_source = require("atlas.providers.github.completion").issues
		pull_source = require("atlas.providers.github.completion").pulls
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("fetches mentionable users for creation and canonical issue or PR refs", function()
		local items
		local queries = { "ali", "alic", "alice" }
		for index, context in ipairs({
			{ provider = "github", repository = "acme/create" },
			{ provider = "github", issue = { key = "acme/issues#42" } },
			{ provider = "github", pr = { id = 42, repo_full_name = "acme/pulls" } },
		}) do
			source.complete(context, queries[index], function(result, err)
				assert.is_nil(err)
				items = result
			end)
		end
		assert.same(
			{ { label = "@alice", insert_text = "@alice", filter_text = "alice Alice", detail = "Alice" } },
			items
		)
		assert.equal(3, #calls)
		for index, repo in ipairs({ "create", "issues", "pulls" }) do
			local args = table.concat(calls[index], " ")
			assert.truthy(args:find("mentionableUsers", 1, true))
			assert.truthy(args:find("owner=acme", 1, true))
			assert.truthy(args:find("repo=" .. repo, 1, true))
			assert.truthy(args:find("search=" .. queries[index], 1, true))
		end
	end)

	it("ranks participants before reviewers and repository users without duplicates", function()
		local pr_context = { provider = "github", pr = { id = 42, repo_full_name = "acme/repo" } }
		local dobson = { id = "U2", login = "dobsontom", name = "Tom Dobson" }
		local donna = { id = "U3", login = "donna", name = "Donna" }
		local david = { id = "U4", login = "david", name = "David" }
		local dan = { id = "U5", login = "dan", name = "Dan" }
		local items
		repository_users = { dan, david, dobson }
		participants = { dobson, donna }
		reviewers = { { requestedReviewer = donna }, { requestedReviewer = david }, { requestedReviewer = {} } }
		source.complete(pr_context, "", function(result, err)
			assert.is_nil(err)
			items = result
		end)
		assert.same(
			{ "@dobsontom", "@donna", "@david", "@dan" },
			vim.tbl_map(function(item)
				return item.insert_text
			end, items)
		)
	end)

	it("includes issue participants when the repository is already supplied", function()
		local context = { provider = "github", repository = "acme/repo", issue = { key = "acme/repo#42" } }
		participants = { { id = "U2", login = "bob", name = "Bob" } }
		source.complete(context, "", function(items, err)
			assert.is_nil(err)
			assert.equal("@bob", items[1].insert_text)
			assert.equal("@alice", items[2].insert_text)
		end)
		local command = table.concat(calls[1], " ")
		assert.truthy(command:find("number=42", 1, true))
		assert.truthy(command:find("fetchParticipants=true", 1, true))
	end)

	it("caches results including empty lists per repository, item, and query", function()
		local creation = { provider = "github", repository = "acme/repo" }
		local pr = { provider = "github", pr = { id = 42, repo_full_name = "acme/repo" } }
		local cases = {
			{ creation, "" },
			{ pr, "" },
			{ pr, "ali" },
			{ { provider = "github", pr = { id = 43, repo_full_name = "acme/repo" } }, "" },
			{ { provider = "github", pr = { id = 42, repo_full_name = "acme/other" } }, "" },
		}
		repository_users = {}
		participants = { { id = "U2", login = "bob", name = "Bob" } }
		local results = {}
		for index, case in ipairs(cases) do
			source.complete(case[1], case[2], function(items, err)
				assert.is_nil(err)
				results[index] = items
			end)
		end
		assert.equal(#cases, #calls)
		assert.same({}, results[1])
		assert.equal("@bob", results[2][1].insert_text)

		participants = {}
		for index, case in ipairs(cases) do
			local cached
			source.complete(case[1], case[2], function(items, err)
				assert.is_nil(err)
				cached = items
			end)
			assert.same(results[index], cached)
		end
		assert.equal(#cases, #calls)
	end)

	it("retries failed requests", function()
		local context = { provider = "github", repository = "acme/repo" }
		failure = "Request failed"
		for _ = 1, 2 do
			source.complete(context, "bob", function(items, err)
				assert.is_nil(items)
				assert.equal(failure, err)
			end)
		end
		assert.equal(2, #calls)
	end)

	it("fetches recent issues using repository, PR, and issue contexts", function()
		assert.same({ "#" }, issue_source.triggers)
		for _, context in ipairs({
			{ provider = "github", repository = "acme/create" },
			{ provider = "github", pr = { id = 42, repo_full_name = "acme/pulls" } },
			{ provider = "github", issue = { key = "acme/issues#42" } },
		}) do
			local handle = issue_source.complete(context, "login", function(items, err)
				assert.is_nil(err)
				assert.same({
					{
						label = "issue #42",
						insert_text = "#42",
						filter_text = "42 Fix login",
						detail = "Fix login",
					},
				}, items)
			end)
			assert.equal(request_handle, handle)
		end
		for index, repo in ipairs({ "create", "pulls", "issues" }) do
			local command = table.concat(calls[index], " ")
			assert.truthy(command:find("search=repo:acme/" .. repo .. " is:issue sort:updated-desc", 1, true))
			assert.truthy(command:find("first:%s*100"))
			assert.truthy(command:find("... on Issue", 1, true))
		end
	end)

	it("returns all cached references across typed queries and keeps repositories and kinds separate", function()
		local context = { provider = "github", repository = "acme/repo" }
		reference_response = {
			issues = {
				{ number = 77, title = "Linear issue", state = "OPEN" },
				{ number = 178, title = "Closed issue", state = "CLOSED" },
			},
			pulls = {
				{ number = 78, title = "Linear pull request", state = "OPEN", isDraft = false },
				{ number = 179, title = "Closed pull request", state = "CLOSED", isDraft = true },
				{ number = 180, title = "Merged pull request", state = "MERGED", isDraft = true },
				{ number = 181, title = "Draft pull request", state = "OPEN", isDraft = true },
			},
		}
		assert.same({ "#" }, pull_source.triggers)
		for _, case in ipairs({
			{ issue_source, { "#77", "#178" }, { "issue #77", "success #178" } },
			{
				pull_source,
				{ "#78", "#179", "#180", "#181" },
				{ "pr #78", "declined_pr #179", "merged_pr #180", "draft_pr #181" },
			},
		}) do
			for _, query in ipairs({ "", "7", "77", "Lin", "Linear" }) do
				case[1].complete(context, query, function(items, err)
					assert.is_nil(err)
					assert.same(
						case[2],
						vim.tbl_map(function(item)
							return item.insert_text
						end, items)
					)
					assert.same(
						case[3],
						vim.tbl_map(function(item)
							return item.label
						end, items)
					)
				end)
			end
		end
		assert.equal(2, #calls)
		local command = table.concat(calls[2], " ")
		assert.truthy(command:find("search=repo:acme/repo is:pr sort:updated-desc", 1, true))
		assert.truthy(command:find("... on PullRequest", 1, true))
		assert.truthy(command:find("isDraft", 1, true))

		for _, other in ipairs({
			{ provider = "github", pr = { id = 7, repo_full_name = "acme/repo" } },
			{ provider = "github", issue = { key = "acme/repo#8" } },
		}) do
			issue_source.complete(other, "77", function(items, err)
				assert.is_nil(err)
				assert.equal("#77", items[1].insert_text)
			end)
		end
		assert.equal(2, #calls)

		reference_response.issues = { { number = 999, title = "Other repository", state = "OPEN" } }
		issue_source.complete({ provider = "github", repository = "acme/other" }, "Linear", function(items, err)
			assert.is_nil(err)
			assert.equal("#999", items[1].insert_text)
		end)
		assert.equal(3, #calls)
	end)

	it("caches empty reference lists and retries failures", function()
		reference_response.issues = {}
		for _, query in ipairs({ "", "77" }) do
			issue_source.complete({ provider = "github", repository = "acme/empty" }, query, function(items, err)
				assert.is_nil(err)
				assert.same({}, items)
			end)
		end
		assert.equal(1, #calls)

		failure = "Request failed"
		for _ = 1, 2 do
			issue_source.complete({ provider = "github", repository = "acme/repo" }, "Linear", function(items, err)
				assert.is_nil(items)
				assert.equal(failure, err)
			end)
		end
		assert.equal(3, #calls)
	end)
end)
