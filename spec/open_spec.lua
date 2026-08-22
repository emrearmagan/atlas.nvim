local config = require("atlas.config")
local resolver = require("atlas.providers.resolve")

describe("Atlas target resolver", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			providers = {
				github = {},
				gitlab = { base_url = "https://gitlab.example.com" },
				bitbucket = {},
				jira = { base_url = "https://jira.example.com" },
			},
			pulls = {
				github = {},
				gitlab = {},
				bitbucket = {},
			},
			issues = {
				github = {},
				gitlab = {},
				jira = {},
			},
		}
	end)

	after_each(function()
		config.options = original_options
	end)

	it("parses supported provider URLs", function()
		local github = assert(resolver.resolve("https://github.com/emrearmagan/atlas.nvim/pull/42"))
		local jira = assert(resolver.resolve("https://jira.example.com/browse/ATLAS-123"))
		local gitlab = assert(resolver.resolve("https://gitlab.example.com/emrearmagan/atlas.nvim/-/issues/8"))
		local bitbucket = assert(resolver.resolve("https://bitbucket.org/emrearmagan/atlas.nvim/pull-requests/7"))

		assert.are.equal("pr", github.entity)
		assert.are.equal(42, github.number)
		assert.are.equal("ATLAS-123", jira.issue_key)
		assert.are.equal("emrearmagan/atlas.nvim", gitlab.project_path)
		assert.are.equal("emrearmagan", bitbucket.workspace)
	end)

	it("resolves keys and numbers", function()
		local jira = assert(resolver.resolve("atlas-123"))
		assert.are.equal("jira", jira.provider)
		assert.are.equal("issues", jira.domain)
		assert.are.equal("ATLAS-123", jira.issue_key)
		assert.are.equal("https://jira.example.com/browse/ATLAS-123", jira.url)

		assert.are.equal(42, assert(resolver.resolve("#42")).number)
		local repo = assert(resolver.resolve("emrearmagan/atlas.nvim#42"))
		assert.are.equal("emrearmagan/atlas.nvim", repo.repo_slug)
		assert.are.equal(42, repo.number)
	end)

	it("rejects unsupported URLs", function()
		local target, err = resolver.resolve("https://jira.other.example.com/browse/ATLAS-123")
		assert.is_nil(target)
		assert.are.equal("Unsupported Atlas URL", err)

		target, err = resolver.resolve("https://bitbucket.example.com/projects/ATLAS/repos/atlas.nvim/pull-requests/12")
		assert.is_nil(target)
		assert.are.equal(
			"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only",
			err
		)
	end)

	it("discovers repositories from configured provider views", function()
		config.options.pulls.github.views = { { name = "GitHub", search = "repo:owner/github is:open" } }
		config.options.pulls.gitlab.views = { { name = "GitLab", project = "owner/gitlab" } }
		config.options.pulls.bitbucket.views = {
			{ name = "Bitbucket", targets = { { workspace = "owner", repo = "bitbucket" } } },
		}

		local found = {}
		for _, repository in ipairs(resolver.configured_repositories()) do
			found[repository.provider] = repository.slug
		end
		assert.are.same({
			github = "owner/github",
			gitlab = "owner/gitlab",
			bitbucket = "owner/bitbucket",
		}, found)
	end)
end)
