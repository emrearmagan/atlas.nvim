local modules = {
	"atlas.providers.gitlab.client",
	"atlas.providers.gitlab.users",
	"atlas.providers.gitlab.completion",
	"atlas.issues.providers.gitlab.api.mapper",
	"atlas.ui.shared.icons",
}

describe("GitLab completion", function()
	local saved, source, cache, calls, participants, reviewers, failure
	local issue_source, pull_source, reference_nodes, request_handle
	local member = { username = "alice", name = "Alice" }
	local commenter = { username = "external", name = "External commenter" }
	local reviewer = { username = "reviewer", name = "Reviewer" }

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		cache, calls = {}, { members = 0, participants = {}, references = {} }
		failure = nil
		participants, reviewers = { commenter }, { reviewer, commenter }
		reference_nodes = { issues = { { iid = "42", title = "Fix login", state = "opened" } }, pulls = {} }
		request_handle = { cancel = function() end }
		package.loaded["atlas.ui.shared.icons"] = {
			issues = function(name)
				return "issues." .. name
			end,
			pulls = function(name)
				return "pulls." .. name
			end,
		}
		package.loaded["atlas.providers.gitlab.client"] = {
			get_memory_cache = function(key)
				return cache[key], cache[key] ~= nil
			end,
			set_memory_cache = function(key, value)
				cache[key] = value
			end,
			graphql = function(query, variables, done)
				local field = query:find("mergeRequests(", 1, true) and "mergeRequests"
					or query:find("issues(", 1, true) and "issues"
				if field then
					calls.references[#calls.references + 1] = { query = query, variables = variables }
					local kind = field == "mergeRequests" and "pulls" or "issues"
					done({ project = { [field] = { nodes = reference_nodes[kind] } } }, failure)
					return request_handle
				end
				calls.participants[#calls.participants + 1] = variables
				local item = { participants = { nodes = vim.deepcopy(participants) } }
				if variables.isMergeRequest then
					item.reviewers = { nodes = vim.deepcopy(reviewers) }
				end
				done({ project = { [variables.isMergeRequest and "mergeRequest" or "issue"] = item } }, nil)
			end,
		}
		package.loaded["atlas.providers.gitlab.users"] = {
			list_members = function(project, query, done)
				calls.members = calls.members + 1
				calls.member_args = { project, query }
				done({ member, reviewer }, failure)
			end,
		}
		source = require("atlas.providers.gitlab.completion").users
		issue_source = require("atlas.providers.gitlab.completion").issues
		pull_source = require("atlas.providers.gitlab.completion").pulls
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("puts participants and reviewers first and caches suggestions per MR and project", function()
		local items
		local function done(result, err)
			assert.is_nil(err)
			items = result
		end
		local context = { provider = "gitlab", pr = { id = 42, repo_full_name = "group/subgroup/project" } }
		source.complete(context, "", done)
		assert.same({ "@external", "@reviewer", "@alice" }, {
			items[1].insert_text,
			items[2].insert_text,
			items[3].insert_text,
		})
		assert.equal(3, #items)
		assert.same({ path = "group/subgroup/project", iid = "42", isMergeRequest = true }, calls.participants[1])

		participants, reviewers = {}, {}
		source.complete(context, "", done)
		assert.equal("@external", items[1].insert_text)
		assert.equal(3, #items)
		assert.equal(1, calls.members)
		assert.equal(1, #calls.participants)

		source.complete({ provider = "gitlab", pr = { id = 43, repo_full_name = context.pr.repo_full_name } }, "", done)
		assert.equal("@alice", items[1].insert_text)
		assert.equal(2, calls.members)
		assert.equal(2, #calls.participants)

		for _, project in ipairs({ context.pr.repo_full_name, "group/other" }) do
			source.complete({ provider = "gitlab", repository = project }, "", done)
			assert.equal("@alice", items[1].insert_text)
		end
		assert.equal(4, calls.members)
	end)

	it("keeps issue and MR suggestions separate when their numbers match", function()
		source.complete(
			{ provider = "gitlab", pr = { id = 42, repo_full_name = "group/subgroup/project" } },
			"Alice Smith",
			function() end
		)
		source.complete(
			{ provider = "gitlab", issue = { key = "group/subgroup/project#42" } },
			"Alice Smith",
			function(items, err)
				assert.is_nil(err)
				assert.equal("@external", items[1].insert_text)
				assert.equal("@alice", items[2].insert_text)
			end
		)
		assert.same({ path = "group/subgroup/project", iid = "42", isMergeRequest = false }, calls.participants[2])
		assert.same({ "group/subgroup/project", "Alice Smith" }, calls.member_args)
		assert.equal(2, calls.members)
	end)

	it("caches each query and retries failed requests", function()
		local context = { provider = "gitlab", repository = "group/project" }
		for _, query in ipairs({ "ali", "alice", "ali", "alice" }) do
			source.complete(context, query, function(items, err)
				assert.is_nil(err)
				assert.equal("@alice", items[1].insert_text)
			end)
		end
		assert.equal(2, calls.members)

		failure = "Request failed"
		for _ = 1, 2 do
			source.complete(context, "bob", function(items, err)
				assert.is_nil(items)
				assert.equal(failure, err)
			end)
		end
		assert.equal(4, calls.members)
	end)

	it("fetches recent issue references using repository, project, MR, and issue contexts", function()
		assert.same({ "#" }, issue_source.triggers)
		for _, context in ipairs({
			{ provider = "gitlab", repository = "group/subgroup/repository" },
			{ provider = "gitlab", project = "group/subgroup/project" },
			{ provider = "gitlab", pr = { id = 42, repo_full_name = "group/subgroup/pulls" } },
			{ provider = "gitlab", issue = { key = "group/subgroup/issues#42" } },
		}) do
			local handle = issue_source.complete(context, "login", function(items, err)
				assert.is_nil(err)
				assert.same({
					{
						label = "issues.issue #42",
						insert_text = "#42",
						filter_text = "42 Fix login",
						detail = "Fix login",
					},
				}, items)
			end)
			assert.equal(request_handle, handle)
		end
		for index, project in ipairs({ "repository", "project", "pulls", "issues" }) do
			local call = calls.references[index]
			assert.same({ path = "group/subgroup/" .. project }, call.variables)
			assert.truthy(call.query:find("issues(", 1, true))
			assert.truthy(call.query:find("first:%s*100"))
			assert.truthy(call.query:find("sort: UPDATED_DESC", 1, true))
		end
	end)

	it("keeps state icons and plain references while caching all candidates per project and kind", function()
		local context = { provider = "gitlab", repository = "group/project" }
		reference_nodes = {
			issues = {
				{ iid = "77", title = "Linear issue", state = "opened" },
				{ iid = "178", title = "Closed issue", state = "closed" },
			},
			pulls = {
				{ iid = "78", title = "Linear MR", state = "opened", draft = false },
				{ iid = "179", title = "Closed MR", state = "closed", draft = true },
				{ iid = "180", title = "Merged MR", state = "merged", draft = true },
				{ iid = "181", title = "Draft MR", state = "opened", draft = true },
			},
		}
		assert.same({ "!" }, pull_source.triggers)
		for _, case in ipairs({
			{ issue_source, { "#77", "#178" }, { "issues.issue #77", "issues.success #178" } },
			{
				pull_source,
				{ "!78", "!179", "!180", "!181" },
				{ "pulls.pr !78", "pulls.declined_pr !179", "pulls.merged_pr !180", "pulls.draft_pr !181" },
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
		assert.equal(2, #calls.references)
		assert.truthy(calls.references[2].query:find("mergeRequests(", 1, true))
		assert.truthy(calls.references[2].query:find("draft", 1, true))

		issue_source.complete({ provider = "gitlab", issue = { key = "group/project#9" } }, "77", function(items, err)
			assert.is_nil(err)
			assert.equal("#77", items[1].insert_text)
		end)
		assert.equal(2, #calls.references)

		reference_nodes.issues = { { iid = "999", title = "Other project", state = "opened" } }
		issue_source.complete({ provider = "gitlab", repository = "group/other" }, "Linear", function(items, err)
			assert.is_nil(err)
			assert.equal("#999", items[1].insert_text)
		end)
		assert.equal(3, #calls.references)
	end)

	it("caches empty reference lists and retries failures", function()
		reference_nodes.issues = {}
		for _, query in ipairs({ "", "77" }) do
			issue_source.complete({ provider = "gitlab", repository = "group/empty" }, query, function(items, err)
				assert.is_nil(err)
				assert.same({}, items)
			end)
		end
		assert.equal(1, #calls.references)

		failure = "Request failed"
		for _ = 1, 2 do
			issue_source.complete({ provider = "gitlab", repository = "group/project" }, "Linear", function(items, err)
				assert.is_nil(items)
				assert.equal(failure, err)
			end)
		end
		assert.equal(3, #calls.references)
	end)
end)
