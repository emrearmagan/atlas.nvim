local modules = {
	"atlas.providers.azure.client",
	"atlas.providers.azure.users",
	"atlas.providers.azure.completion",
	"atlas.issues.providers.azure.api.issues",
	"atlas.issues.providers.azure.api.comments",
	"atlas.providers.azure.completion.users",
	"atlas.providers.azure.completion.issues",
	"atlas.providers.azure.completion.pulls",
	"atlas.ui.shared.icons",
}

describe("Azure mention completion", function()
	local saved, source, calls, cache, requests
	local pr = { pr = { id = 7, repo_full_name = "Team Project/api" } }
	local author = { id = "author", displayName = "Avery" }
	local reviewer = { id = "reviewer", displayName = "Robin" }
	local commenter = { id = "commenter", displayName = "Chris" }

	before_each(function()
		saved, calls, cache, requests = {}, 0, {}, {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		local build_query = require(modules[1]).build_query
		package.loaded[modules[1]] = {
			url_encode = require("atlas.core.utils").url_encode,
			build_query = build_query,
			get_cache = function(key)
				return cache[key], cache[key] ~= nil
			end,
			set_cache = function(key, value)
				cache[key] = value
			end,
			request = function(method, endpoint, payload, done)
				calls = calls + 1
				requests[#requests + 1] = { method = method, endpoint = endpoint, payload = payload }
				if endpoint:find("/_apis/wit/wiql", 1, true) then
					done({ workItems = { { id = 42 } } })
				elseif endpoint:find("pullrequests?", 1, true) then
					done({
						value = {
							{ pullRequestId = 7, title = "Fix login", status = "active", isDraft = true },
							{ pullRequestId = 8, title = "Add search", status = "completed", isDraft = false },
						},
					})
				elseif endpoint:match("/threads$") then
					done({ value = { { comments = { { author = commenter }, { author = author } } } } })
				else
					done({ createdBy = author, reviewers = { reviewer } })
				end
			end,
		}
		package.loaded[modules[4]] = {
			fetch_by_refs = function(_, _, done)
				done({
					{
						key = "42",
						title = "Login fails",
						project = "Team",
						reporter = { id = "author", name = "Avery" },
					},
				})
			end,
		}
		package.loaded["atlas.ui.shared.icons"] = {
			get = function(name)
				return name
			end,
		}
		package.loaded[modules[5]] = {
			fetch_conversation = function(_, _, done)
				done({ comments = { { author = { id = "commenter", name = "Chris" } } }, activities = {} })
			end,
		}
		source = require("atlas.providers.azure.completion").users
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("formats mentions with an identity and never falls back to an email address", function()
		assert.equal("@<author>", source.format_mention({ id = "author", username = "avery@example.com" }))
		assert.is_nil(source.format_mention({ username = "avery@example.com" }))
		assert.is_nil(source.format_mention({ id = "", username = "avery@example.com" }))
	end)

	it("deduplicates PR participants and filters cached candidates per repository", function()
		local items
		local function done(result, err)
			assert.is_nil(err)
			items = result
		end
		source.complete(pr, "", done)
		assert.same(
			{ "@<author>", "@<commenter>", "@<reviewer>" },
			vim.tbl_map(function(item)
				return item.insert_text
			end, items)
		)
		source.complete(pr, "RO", done)
		assert.equal(1, #items)
		assert.equal("@<reviewer>", items[1].insert_text)
		assert.equal(2, calls)
		source.complete({ pr = { id = 7, repo_full_name = "Team Project/other" } }, "", done)
		assert.equal(4, calls)
	end)

	it("includes work-item comment authors in filtered mention candidates", function()
		local items
		source.complete({ issue = { key = "42" } }, "ch", function(result, err)
			assert.is_nil(err)
			items = result
		end)
		assert.equal(1, #items)
		assert.equal("@<commenter>", items[1].insert_text)
	end)

	it("completes work items of the project, or of the organization without one", function()
		local issues = require("atlas.providers.azure.completion").issues
		local items
		issues.complete(pr, "", function(result, err)
			assert.is_nil(err)
			items = result
		end)
		assert.equal("POST", requests[1].method)
		assert.equal("/Team%20Project/_apis/wit/wiql?$top=50", requests[1].endpoint)
		assert.truthy(requests[1].payload.query:find("[System.TeamProject] = @project", 1, true))
		assert.same(
			{ { label = "issue #42", insert_text = "#42", filter_text = "42 Login fails", detail = "Login fails" } },
			items
		)

		issues.complete({ issue = { key = "42" } }, "", function() end)
		assert.equal("/_apis/wit/wiql?$top=50", requests[2].endpoint)
		assert.is_nil(requests[2].payload.query:find("TeamProject", 1, true))
	end)

	it("completes pull requests of the repository, or of the project without one", function()
		local pulls = require("atlas.providers.azure.completion").pulls
		local items
		pulls.complete(pr, "", function(result, err)
			assert.is_nil(err)
			items = result
		end)
		assert.truthy(requests[1].endpoint:find("^/Team%%20Project/_apis/git/repositories/api/pullrequests%?"))
		assert.same({ "draft_pr !7", "merged_pr !8" }, { items[1].label, items[2].label })
		assert.equal("!7", items[1].insert_text)

		pulls.complete({ project = "Team" }, "", function() end)
		assert.truthy(requests[2].endpoint:find("^/Team/_apis/git/pullrequests%?"))

		pulls.complete({ issue = { key = "42" } }, "", function(result, err)
			assert.is_nil(result)
			assert.equal("Azure pull request completion requires a project", err)
		end)
		assert.equal(2, #requests)
	end)
end)
