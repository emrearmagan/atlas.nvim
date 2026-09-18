local providers = require("atlas.providers")

local function assert_functions(value, names, label)
	assert.equal("table", type(value), label)
	for _, name in ipairs(names) do
		assert.equal("function", type(value[name]), label .. "." .. name)
	end
end

local function assert_contract(domain, expected_ids, provider_functions, core_functions)
	local ids = {}
	for _, registered in ipairs(providers.list(domain)) do
		ids[#ids + 1] = registered.id
		local provider = assert(providers.load(registered.id, domain))
		local label = registered.id .. "." .. domain

		assert.equal(registered.id, provider.id)
		assert.equal(registered.name, provider.name)
		assert_functions(provider, provider_functions, label)
		assert_functions(provider.capabilities and provider.capabilities.core, core_functions, label .. ".core")
		if domain == "pulls" then
			local pipelines = provider.capabilities and provider.capabilities.pipelines
			assert_functions(pipelines, { "fetch" }, label .. ".pipelines")
			assert.equal("table", type(pipelines.actions), label .. ".pipelines.actions")
		end
	end
	table.sort(ids)
	assert.same(expected_ids, ids)
end

describe("providers contracts", function()
	it("loads pull request providers", function()
		assert_contract(
			"pulls",
			{ "bitbucket", "github", "gitlab" },
			{ "resolve_search", "view_for_target", "views" },
			{
				"fetch_user",
				"fetch_pullrequests",
				"fetch_by_refs",
				"fetch_pullrequest",
				"create_pr",
				"update_title",
				"set_draft",
				"decline",
				"fetch_default_reviewers",
				"fetch_description",
				"update_reviewers",
			}
		)
	end)

	it("loads issue providers", function()
		assert_contract(
			"issues",
			{ "github", "gitlab", "jira" },
			{ "resolve_search", "view_for_target", "issue_ref", "views" },
			{ "fetch_user", "fetch_issues", "fetch_by_refs", "fetch_issue" }
		)
	end)

	it("exposes Bitbucket review actions", function()
		local provider = assert(providers.load("bitbucket", "pulls"))
		local reviews = assert(provider.capabilities.reviews)

		assert_functions(reviews, { "fetch", "submit_review", "approve", "request_changes" }, "bitbucket.pulls.reviews")
	end)

	describe("native GitLab pipelines", function()
		local client
		local original_fetch

		before_each(function()
			client = require("atlas.providers.gitlab.client")
			original_fetch = client.fetch_all_pages
		end)

		after_each(function()
			client.fetch_all_pages = original_fetch
		end)

		it("loads jobs through the pipeline capability", function()
			local requested
			client.fetch_all_pages = function(endpoint, done)
				requested = endpoint
				done({ { id = 7, name = "Compile", stage = "Build", status = "success" } }, nil)
			end
			local provider = assert(providers.load("gitlab", "pulls"))
			local pipeline = { id = "42", name = "Pipeline", state = "SUCCESSFUL", stages = {} }
			local result
			provider.capabilities.pipelines.fetch_details(
				{ repo_full_name = "team/repo" },
				pipeline,
				nil,
				function(item)
					result = item
				end
			)
			assert.matches("/pipelines/42/jobs", requested, 1, true)
			assert.equal("Build", result.stages[1].name)
			assert.equal("Compile", result.stages[1].jobs[1].name)
			assert.equal("SUCCESSFUL", result.stages[1].jobs[1].state)
		end)
	end)

	it("exposes notifications for GitHub and GitLab", function()
		for _, id in ipairs({ "github", "gitlab" }) do
			for _, domain in ipairs({ "pulls", "issues" }) do
				local provider = assert(providers.load(id, domain))
				assert_functions(
					provider.capabilities.notifications,
					{ "fetch", "mark_read", "mark_done" },
					id .. "." .. domain .. ".notifications"
				)
			end
		end
	end)
end)
