local config = require("atlas.config")
local resolver = require("atlas.providers.resolve")

describe("Atlas target resolver", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			pulls = {
				providers = {
					github = {},
					gitlab = { base_url = "https://gitlab.example.com" },
					bitbucket = {},
				},
			},
			issues = {
				providers = {
					github = {},
					gitlab = { base_url = "https://gitlab.example.com" },
					jira = { base_url = "https://jira.example.com" },
				},
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

	it("resolves configured Bitbucket Server URLs", function()
		config.options.pulls.providers.bitbucket = {
			api_type = "server",
			base_url = "https://bitbucket.example.com",
		}

		local target =
			assert(resolver.resolve("https://bitbucket.example.com/projects/ATLAS/repos/atlas.nvim/pull-requests/12"))
		assert.are.equal("pr", target.entity)
		assert.are.equal("ATLAS", target.workspace)
		assert.are.equal("atlas.nvim", target.repo)
		assert.are.equal(12, target.number)

		config.options.pulls.providers.bitbucket.base_url = "https://bitbucket.example.com/context"
		local repo = assert(resolver.resolve("https://bitbucket.example.com/context/projects/ATLAS/repos/atlas.nvim"))
		assert.are.equal("repo", repo.entity)
		assert.are.equal("ATLAS", repo.workspace)
		assert.are.equal("atlas.nvim", repo.repo)
	end)

	it("normalizes Bitbucket Server clone URLs and dedicated SSH ports", function()
		config.options.pulls.providers.bitbucket = {
			api_type = "server",
			base_url = "https://scm.example.com/bitbucket",
		}

		local git = require("atlas.core.git")
		local https_info = assert(git.parse_remote_url("https://scm.example.com/bitbucket/scm/ATLAS/atlas.nvim.git"))
		local https_target = resolver.target(https_info, "pulls", "pr", 12)
		assert.are.equal("bitbucket", https_info.provider)
		assert.are.equal(
			"https://scm.example.com/bitbucket/projects/ATLAS/repos/atlas.nvim/pull-requests/12",
			https_target.url
		)

		local ssh_info = assert(git.parse_remote_url("ssh://git@scm.example.com:7999/ATLAS/atlas.nvim.git"))
		local ssh_target = resolver.target(ssh_info, "pulls", "pr", 13)
		assert.are.equal("bitbucket", ssh_info.provider)
		assert.are.equal(
			"https://scm.example.com/bitbucket/projects/ATLAS/repos/atlas.nvim/pull-requests/13",
			ssh_target.url
		)
	end)

	it("discovers repositories from configured provider views", function()
		config.options.pulls.providers.github.views = { { name = "GitHub", search = "repo:owner/github is:open" } }
		config.options.pulls.providers.gitlab.views = { { name = "GitLab", project = "owner/gitlab" } }
		config.options.pulls.providers.bitbucket.views = {
			{ name = "Bitbucket", repos = { { workspace = "owner", repo = "bitbucket" } } },
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
