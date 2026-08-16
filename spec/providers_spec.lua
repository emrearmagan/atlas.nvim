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
		local capabilities = provider.capabilities
		assert_functions(capabilities and capabilities.core, core_functions, label .. ".core")
		assert.equal("table", type(capabilities.actions and capabilities.actions.items), label .. ".actions.items")
		assert_functions(capabilities.actions, { "is_available", "run" }, label .. ".actions")
	end
	table.sort(ids)
	assert.same(expected_ids, ids)
end

describe("provider contracts", function()
	it("loads pull request providers", function()
		assert_contract(
			"pulls",
			{ "bitbucket", "gitea", "github", "gitlab" },
			{ "resolve", "search_view", "target", "repositories" },
			{ "fetch_user", "fetch_pullrequests", "fetch_pullrequest", "update_description", "decline", "views" }
		)
	end)

	it("loads issue providers", function()
		assert_contract(
			"issues",
			{ "gitea", "github", "gitlab", "jira" },
			{ "resolve", "search_view", "issue_key" },
			{ "fetch_user", "fetch_issues", "fetch_issue", "views" }
		)
	end)

	it("exposes Bitbucket review actions", function()
		local provider = assert(providers.load("bitbucket", "pulls"))
		local reviews = assert(provider.capabilities.reviews)

		assert_functions(reviews, { "submit_review", "approve", "request_changes" }, "bitbucket.pulls.reviews")
	end)
end)
