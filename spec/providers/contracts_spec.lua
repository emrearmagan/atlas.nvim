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
	end
	table.sort(ids)
	assert.same(expected_ids, ids)
end

describe("providers contracts", function()
	it("loads pull request providers", function()
		assert_contract(
			"pulls",
			{ "bitbucket", "github", "gitlab" },
			{ "resolve", "search_view", "target", "repositories" },
			{
				"fetch_user",
				"fetch_pullrequests",
				"fetch_pullrequest",
				"create_pr",
				"update_title",
				"set_draft",
				"decline",
				"fetch_default_reviewers",
				"fetch_description",
				"update_reviewers",
				"views",
			}
		)
	end)

	it("loads issue providers", function()
		assert_contract(
			"issues",
			{ "github", "gitlab", "jira" },
			{ "resolve", "search_view", "issue_key" },
			{ "fetch_user", "fetch_issues", "fetch_issue", "views" }
		)
	end)

	it("exposes Bitbucket review actions", function()
		local provider = assert(providers.load("bitbucket", "pulls"))
		local reviews = assert(provider.capabilities.reviews)

		assert_functions(reviews, { "fetch", "submit_review", "approve", "request_changes" }, "bitbucket.pulls.reviews")
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
