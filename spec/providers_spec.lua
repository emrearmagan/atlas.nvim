local providers = require("atlas.providers")
local config = require("atlas.config")

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
		assert.equal("string", type(provider.name))
		assert.is_true(provider.name ~= "")
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
	local original_options

	before_each(function()
		original_options = config.options
	end)

	after_each(function()
		config.options = original_options
	end)

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

	it("uses the configured Gitea or Forgejo identity", function()
		config.options = {
			providers = { gitea = { api_type = "forgejo" } },
			pulls = { gitea = {} },
			issues = { gitea = {} },
		}

		assert.equal("Forgejo", providers.gitea.name("pulls"))
		assert.same({ icon = "", hl_group = "AtlasForgejoTheme" }, providers.gitea.icon("pulls"))
		assert.equal("Forgejo", providers.gitea.name("issues"))

		config.options.providers.gitea.api_type = "gitea"
		assert.equal("Gitea", providers.gitea.name("issues"))
		assert.same({ icon = "", hl_group = "AtlasGiteaTheme" }, providers.gitea.icon("issues"))
	end)

	it("shares GitHub and GitLab themes across domains", function()
		assert.equal("AtlasGitHubTheme", providers.github.icon("pulls").hl_group)
		assert.equal("AtlasGitHubTheme", providers.github.icon("issues").hl_group)
		assert.equal("AtlasGitLabTheme", providers.gitlab.icon("pulls").hl_group)
		assert.equal("AtlasGitLabTheme", providers.gitlab.icon("issues").hl_group)
	end)
end)
