local config = require("atlas.config")
local git = require("atlas.core.git")
local providers = require("atlas.providers")

describe("Azure DevOps provider registration", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			providers = {
				azure = {
					base_url = "https://dev.azure.com/acme",
					token = "test-token",
				},
			},
			pulls = {
				azure = {
					views = {
						{
							name = "Reviewing",
							key = "1",
							project = "Platform",
							repository = "api",
							scope = "assigned_to_me",
							extra_params = {
								["searchCriteria.targetRefName"] = "refs/heads/main",
							},
						},
					},
				},
			},
		}
	end)

	after_each(function()
		config.options = original_options
	end)

	it("registers an Azure DevOps provider for pulls and issues", function()
		local registered = assert(providers.azure)
		assert.equal("Azure DevOps", registered.name)
		assert.equal("function", type(registered.resolver.resolve))
		assert.is_table(registered.domains.pulls)
		assert.is_table(registered.domains.issues)

		local provider = assert(providers.load("azure", "pulls"))
		assert.equal("azure", provider.id)
		assert.equal("Azure DevOps", provider.name)
		assert.equal("", provider.icon)
		assert.equal("AtlasAzureTheme", provider.hl_group)

		local configured = providers.configured("pulls")
		assert.equal(1, #configured)
		assert.equal("azure", configured[1].id)
	end)

	it("returns configured views and renders current state filters", function()
		local provider = assert(providers.load("azure", "pulls"))
		assert.same(config.options.pulls.azure.views, provider.views())
		local view = provider.views()[1]
		local query, states = provider.resolve_search(view)
		assert.equal(
			"is:open project:Platform repository:api scope:assigned_to_me "
				.. "param.searchCriteria.targetRefName:refs/heads/main",
			query
		)
		assert.same({ "open" }, states)

		view._states = { "merged", "declined" }
		query, states = provider.resolve_search(view)
		assert.equal(
			"is:merged,declined project:Platform repository:api scope:assigned_to_me "
				.. "param.searchCriteria.targetRefName:refs/heads/main",
			query
		)
		assert.same({ "merged", "declined" }, states)
	end)

	it("resolves repositories and pull requests for the configured organization", function()
		local repo = assert(providers.resolve("https://dev.azure.com/acme/Team%20Project/_git/api%20service"))
		local pr = assert(providers.resolve("https://dev.azure.com/acme/Platform/_git/api/pullrequest/17"))

		assert.equal("Team Project/api service", repo.repo_full_name)
		assert.equal("https://dev.azure.com/acme/Team%20Project/_git/api%20service", repo.url)
		assert.equal(repo.url, repo.repository_url)
		assert.equal("acme", repo.organization)
		assert.equal("Platform/api", pr.repo_full_name)
		assert.equal("https://dev.azure.com/acme/Platform/_git/api", pr.repository_url)
		assert.equal(17, pr.id)
		assert.equal(17, pr.number)

		local provider = assert(providers.load("azure", "pulls"))
		assert.same({
			name = "Search",
			layout = "compact",
			project = "Platform",
			repository = "api",
			scope = "all",
		}, provider.view_for_target(pr))
	end)

	it("resolves modern Azure HTTPS and SSH remotes through the provider resolver", function()
		local https = assert(git.parse_remote_url("https://acme@dev.azure.com/acme/Team%20Project/_git/api%20service"))
		local ssh = assert(git.parse_remote_url("git@ssh.dev.azure.com:v3/acme/Platform/api"))

		assert.equal("azure", https.provider)
		assert.equal("Team Project/api service", https.repo_full_name)
		assert.equal("https://dev.azure.com/acme/Team%20Project/_git/api%20service", https.repository_url)
		assert.equal("azure", ssh.provider)
		assert.equal("Platform/api", ssh.repo_full_name)
		assert.equal("https://dev.azure.com/acme/Platform/_git/api", ssh.repository_url)
		assert.equal("dev.azure.com", ssh.host)

		local github = assert(git.parse_remote_url("git@github.com:owner/repository.git"))
		assert.equal("github", github.provider)
		assert.equal("owner/repository", github.repo_full_name)
	end)

	it("rejects Azure targets from another configured organization", function()
		config.options.providers.azure.base_url = "https://DEV.AZURE.COM/acme"
		local target, err = git.parse_remote_url("git@ssh.dev.azure.com:v3/other/Platform/api")

		assert.is_nil(target)
		assert.equal("Azure DevOps URL organization does not match providers.azure.base_url", err)

		target, err = providers.resolve("https://dev.azure.com/other/Platform/_git/api/pullrequest/17")
		assert.is_nil(target)
		assert.equal("Azure DevOps URL organization does not match providers.azure.base_url", err)
	end)

	it("rejects unsupported hosts and repository paths", function()
		local cases = {
			{
				value = "https://azure.evil.test/Platform/api.git",
				err = "Unsupported Atlas URL",
			},
			{
				value = "https://dev.azure.com/v3/acme/Platform/api",
				err = "Unsupported Azure DevOps URL. Expected a repository, pull request, or work item URL",
			},
			{
				value = "git@ssh.dev.azure.com:acme/Platform/_git/api",
				err = "Unsupported Azure DevOps remote. Expected v3/organization/project/repository",
			},
		}

		for _, case in ipairs(cases) do
			local target, err = providers.resolve(case.value)
			assert.is_nil(target)
			assert.equal(case.err, err)
		end
	end)
end)
