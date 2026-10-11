local modules = {
	"atlas.providers.bitbucket.client",
	"atlas.providers.bitbucket.completion",
	"atlas.ui.shared.icons",
}

describe("Bitbucket completion", function()
	local saved, source, calls, pull_request
	local pull_source, reference_calls, references, failure, request_handle
	local author = { account_id = "author", display_name = "Author", nickname = "author" }
	local commenter =
		{ account_id = "commenter", uuid = "{commenter}", display_name = "Commenter", nickname = "commenter" }
	local reviewer = { account_id = "reviewer", uuid = "{reviewer}", display_name = "Reviewer", nickname = "reviewer" }
	local default_reviewer = { uuid = "{default}", display_name = "Default", nickname = "default" }
	local context = { provider = "bitbucket", pr = { id = 42, repo_full_name = "acme/repo" } }

	before_each(function()
		saved, calls = {}, { defaults = 0, pr = 0 }
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		reference_calls, failure = {}, nil
		references = { { id = 42, title = "Fix login", state = "OPEN", draft = false } }
		request_handle = { cancel = function() end }
		package.loaded["atlas.ui.shared.icons"] = {
			pulls = function(name)
				return "pulls." .. name
			end,
		}
		pull_request = {
			author = author,
			participants = {
				{ role = "REVIEWER", user = reviewer, participated_on = vim.NIL },
				{ role = "REVIEWER", user = commenter, participated_on = "2026-10-01T12:00:00Z" },
				{ role = "PARTICIPANT", user = author },
				{ role = "PARTICIPANT", user = { uuid = "{commenter}", display_name = "Commenter" } },
				{ role = "REVIEWER", user = { account_id = "former", display_name = "Former" } },
			},
			reviewers = { reviewer, commenter },
		}
		local cache = {}
		package.loaded["atlas.providers.bitbucket.client"] = {
			get_cache = function(key)
				return cache[key]
			end,
			set_cache = function(key, value)
				cache[key] = value
			end,
			fetch_all_values = function(endpoint, done)
				assert.truthy(endpoint:match("^/repositories/acme/[^/]+/effective%-default%-reviewers%?"))
				calls.defaults = calls.defaults + 1
				done({ values = { { user = default_reviewer } } }, nil)
			end,
			request = function(method, endpoint, _, _, done)
				assert.equal("GET", method)
				if endpoint:find("/pullrequests?", 1, true) then
					reference_calls[#reference_calls + 1] = endpoint
					done({ values = references }, failure)
					return request_handle
				end
				assert.truthy(endpoint:match("^/repositories/acme/[^/]+/pullrequests/%d+%?"))
				calls.pr = calls.pr + 1
				done(pull_request, nil)
			end,
		}
		source = require("atlas.providers.bitbucket.completion").users
		pull_source = require("atlas.providers.bitbucket.completion").pulls
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("ranks author and participants before reviewers without duplicates", function()
		source.complete(context, "", function(items, err)
			assert.is_nil(err)
			assert.same(
				{ "@{author}", "@{commenter}", "@{reviewer}", "@{former}" },
				vim.tbl_map(function(item)
					return item.insert_text
				end, items)
			)
		end)
		assert.same({ defaults = 0, pr = 1 }, calls)
	end)

	it("caches candidates by repository and PR separately from creation defaults", function()
		local items
		local function done(result, err)
			assert.is_nil(err)
			items = result
		end
		local creation = { provider = "bitbucket", repository = "acme/repo" }
		source.complete(creation, "", done)
		assert.equal("@{default}", items[1].insert_text)
		source.complete(creation, "DEFAULT", done)
		assert.equal("@{default}", items[1].insert_text)
		assert.same({ defaults = 1, pr = 0 }, calls)

		source.complete({ provider = "bitbucket", repository = "acme/other" }, "comment", done)
		assert.same({}, items)
		assert.same({ defaults = 2, pr = 0 }, calls)

		source.complete(context, "default", done)
		assert.same({}, items)
		source.complete(context, "comment", done)
		assert.equal("@{commenter}", items[1].insert_text)
		assert.same({ defaults = 2, pr = 1 }, calls)

		pull_request = { author = author, participants = {}, reviewers = {} }
		source.complete({ provider = "bitbucket", pr = { id = 43, repo_full_name = "acme/repo" } }, "comment", done)
		assert.same({}, items)
		source.complete({ provider = "bitbucket", pr = { id = 42, repo_full_name = "acme/other" } }, "comment", done)
		assert.same({}, items)

		source.complete(creation, "comment", done)
		assert.same({}, items)
		assert.same({ defaults = 2, pr = 3 }, calls)
	end)

	it("fetches recent PR references using repository and PR contexts", function()
		assert.same({ "#" }, pull_source.triggers)
		for _, reference_context in ipairs({
			{ provider = "bitbucket", repository = "acme/create" },
			{ provider = "bitbucket", pr = { id = 7, repo_full_name = "acme/pulls" } },
		}) do
			local handle = pull_source.complete(reference_context, "login", function(items, err)
				assert.is_nil(err)
				assert.same({
					{
						label = "pulls.pr #42",
						insert_text = "pull request #42",
						filter_text = "42 Fix login",
						detail = "Fix login",
					},
				}, items)
			end)
			assert.equal(request_handle, handle)
		end
		for index, repo in ipairs({ "create", "pulls" }) do
			local endpoint = reference_calls[index]
			assert.truthy(endpoint:find("/repositories/acme/" .. repo .. "/pullrequests?", 1, true))
			for _, parameter in ipairs({
				"pagelen=50",
				"sort=-updated_on",
				"state=OPEN",
				"state=MERGED",
				"state=DECLINED",
				"state=SUPERSEDED",
			}) do
				assert.truthy(endpoint:find(parameter, 1, true))
			end
		end
	end)

	it("preserves state icons and caches every reference across queries within its repository", function()
		references = {
			{ id = 42, title = "Open PR", state = "OPEN", draft = false },
			{ id = 43, title = "Draft PR", state = "OPEN", draft = true },
			{ id = 44, title = "Merged PR", state = "MERGED", draft = true },
			{ id = 45, title = "Declined PR", state = "DECLINED", draft = true },
			{ id = 46, title = "Superseded PR", state = "SUPERSEDED", draft = true },
		}
		for _, query in ipairs({ "", "4", "42", "Open" }) do
			pull_source.complete(context, query, function(items, err)
				assert.is_nil(err)
				assert.same(
					{
						"pulls.pr #42",
						"pulls.draft_pr #43",
						"pulls.merged_pr #44",
						"pulls.declined_pr #45",
						"pulls.declined_pr #46",
					},
					vim.tbl_map(function(item)
						return item.label
					end, items)
				)
			end)
		end
		assert.equal(1, #reference_calls)

		references = { { id = 99, title = "Other repository", state = "OPEN" } }
		pull_source.complete({ provider = "bitbucket", repository = "acme/other" }, "", function(items, err)
			assert.is_nil(err)
			assert.equal("pull request #99", items[1].insert_text)
		end)
		assert.equal(2, #reference_calls)
	end)

	it("caches empty PR lists and retries failed requests", function()
		references = {}
		for _, query in ipairs({ "", "42" }) do
			pull_source.complete(context, query, function(items, err)
				assert.is_nil(err)
				assert.same({}, items)
			end)
		end
		assert.equal(1, #reference_calls)

		failure = "Request failed"
		for _ = 1, 2 do
			pull_source.complete({ provider = "bitbucket", repository = "acme/other" }, "", function(items, err)
				assert.is_nil(items)
				assert.equal(failure, err)
			end)
		end
		assert.equal(3, #reference_calls)
	end)
end)
