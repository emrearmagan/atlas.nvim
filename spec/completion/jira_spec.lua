local modules = {
	"atlas.providers.jira.client",
	"atlas.providers.jira.users",
	"atlas.providers.jira.completion",
	"atlas.ui.shared.icons",
}

describe("Jira completion", function()
	local saved, source, calls, response, failure, server
	local issue_source, request_handle
	local alice = { accountId = "account:alice", name = "alice", displayName = "Alice Smith", active = true }

	local function complete(context, query)
		local items, err
		source.complete(context, query, function(result, error)
			items, err = result, error
		end)
		return items, err
	end

	before_each(function()
		saved, calls = {}, {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		response, failure, server = { alice }, nil, false
		request_handle = { cancel = function() end }
		package.loaded["atlas.ui.shared.icons"] = {
			issues_status = function(category, name)
				return category .. "/" .. name
			end,
		}
		local cache = {}
		package.loaded["atlas.providers.jira.client"] = {
			base_url = function()
				return "https://jira.example/jira/"
			end,
			is_server = function()
				return server
			end,
			get_memory_cache = function(key)
				return cache[key]
			end,
			set_memory_cache = function(key, value)
				cache[key] = value
			end,
			request = function(method, endpoint, data, done)
				calls[#calls + 1] = { method = method, endpoint = endpoint, data = data }
				done(response, failure)
				return request_handle
			end,
		}
		source = require("atlas.providers.jira.completion").users
		issue_source = require("atlas.providers.jira.completion").issues
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	for _, api_type in ipairs({ "cloud", "server" }) do
		it("formats " .. api_type .. " mentions and searches users in the issue", function()
			server = api_type == "server"
			response[2] = { accountId = "inactive", name = "inactive", displayName = "Inactive", active = false }
			local items, err =
				complete({ provider = "jira", issue = { key = "KAN-42" }, project = "KAN" }, "Alice Smith")
			assert.is_nil(err)
			assert.same({
				{
					label = "@Alice Smith",
					insert_text = server and "[~alice]" or "[@Alice Smith](atlas-mention:account:alice)",
					filter_text = "Alice Smith alice",
					detail = "alice",
				},
			}, items)
			assert.equal(
				"/user/viewissue/search?"
					.. (server and "username" or "query")
					.. "=Alice%20Smith&issueKey=KAN-42&maxResults=1000",
				calls[1].endpoint
			)
		end)
	end

	it("caches queries separately for each issue and project", function()
		local context = { provider = "jira", issue = { key = "KAN-42" } }
		complete(context, "ali")
		complete(context, "ali")
		assert.equal(1, #calls)

		response = { { accountId = "account:bob", displayName = "Bob" } }
		complete(context, "bob")
		for _, other in ipairs({
			{ provider = "jira", issue = { key = "KAN-43" } },
			{ provider = "jira", project = "KAN" },
			{ provider = "jira", project = "OTHER" },
		}) do
			assert.equal("@Bob", complete(other, "ali")[1].label)
		end
		assert.equal("@Alice Smith", complete(context, "ali")[1].label)
		assert.equal(5, #calls)
		assert.truthy(calls[4].endpoint:find("projectKey=KAN", 1, true))
	end)

	it("caches empty results and retries failures", function()
		local context = { provider = "jira", project = "KAN" }
		response = {}
		for _ = 1, 2 do
			local items, err = complete(context, "nobody")
			assert.is_nil(err)
			assert.same({}, items)
		end
		assert.equal(1, #calls)

		response, failure = nil, "Request failed"
		for _ = 1, 2 do
			local items, err = complete(context, "alice")
			assert.is_nil(items)
			assert.equal(failure, err)
		end
		assert.equal(3, #calls)
	end)

	it("fetches recent project issues with the Cloud and Server search APIs", function()
		assert.same({ "#" }, issue_source.triggers)
		for index, case in ipairs({
			{
				server = false,
				context = { provider = "jira", issue = { key = "KAN-42" } },
				project = "KAN",
				endpoint = "/search/jql",
			},
			{
				server = true,
				context = { provider = "jira", project = "TEAM" },
				project = "TEAM",
				endpoint = "/search",
			},
		}) do
			server = case.server
			local key = case.project .. "-7"
			response = {
				issues = {
					{
						key = key,
						fields = {
							summary = "Linear issue",
							status = { name = "To Do", statusCategory = { key = "new" } },
						},
					},
				},
			}
			local handle = issue_source.complete(case.context, "Linear", function(items, err)
				assert.is_nil(err)
				assert.equal(
					server and key or "[" .. key .. "](https://jira.example/jira/browse/" .. key .. ")",
					items[1].insert_text
				)
			end)
			assert.equal(request_handle, handle)
			assert.same({
				method = "POST",
				endpoint = case.endpoint,
				data = {
					jql = 'project = "' .. case.project .. '" ORDER BY updated DESC',
					fields = { "summary", "status" },
					maxResults = 100,
				},
			}, calls[index])
		end
	end)

	it("adds status icons and caches all issue references per project across typed queries", function()
		local context = { provider = "jira", issue = { key = "KAN-42" } }
		response = {
			issues = {
				{
					key = "KAN-7",
					fields = { summary = "Linear issue", status = { name = "To Do", statusCategory = { key = "new" } } },
				},
				{
					key = "KAN-77",
					fields = {
						summary = "Completed issue",
						status = { name = "Done", statusCategory = { key = "done" } },
					},
				},
			},
		}
		local expected = {
			{
				label = "new/To Do KAN-7",
				insert_text = "[KAN-7](https://jira.example/jira/browse/KAN-7)",
				filter_text = "KAN-7 Linear issue",
				detail = "Linear issue",
			},
			{
				label = "done/Done KAN-77",
				insert_text = "[KAN-77](https://jira.example/jira/browse/KAN-77)",
				filter_text = "KAN-77 Completed issue",
				detail = "Completed issue",
			},
		}
		for _, query in ipairs({ "", "7", "77", "Lin", "Linear" }) do
			issue_source.complete(context, query, function(items, err)
				assert.is_nil(err)
				assert.same(expected, items)
			end)
		end
		issue_source.complete({ provider = "jira", project = "KAN" }, "", function(items, err)
			assert.is_nil(err)
			assert.same(expected, items)
		end)
		assert.equal(1, #calls)

		response.issues[1].key = "TEAM-7"
		response.issues[2] = nil
		issue_source.complete({ provider = "jira", project = "TEAM" }, "Linear", function(items, err)
			assert.is_nil(err)
			assert.equal("[TEAM-7](https://jira.example/jira/browse/TEAM-7)", items[1].insert_text)
		end)
		assert.equal(2, #calls)
	end)

	it("caches empty issue references and retries failed searches", function()
		response = { issues = {} }
		for _, query in ipairs({ "", "77" }) do
			issue_source.complete({ provider = "jira", project = "EMPTY" }, query, function(items, err)
				assert.is_nil(err)
				assert.same({}, items)
			end)
		end
		assert.equal(1, #calls)

		response, failure = nil, "Request failed"
		for _ = 1, 2 do
			issue_source.complete({ provider = "jira", project = "KAN" }, "Linear", function(items, err)
				assert.is_nil(items)
				assert.equal(failure, err)
			end)
		end
		assert.equal(3, #calls)
	end)
end)
