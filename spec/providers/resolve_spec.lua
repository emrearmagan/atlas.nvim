local config = require("atlas.config")
local git = require("atlas.core.git")
local resolver = require("atlas.providers.resolve")

describe("providers.resolve", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			providers = {
				github = {},
				gitlab = { base_url = "https://gitlab.example.com" },
				bitbucket = {},
				gitea = { base_url = "http://localhost:3000" },
				forgejo = { base_url = "http://localhost:3001" },
				jira = { base_url = "https://jira.example.com" },
			},
			pulls = {
				github = {},
				gitlab = {},
				bitbucket = {},
				gitea = {},
				forgejo = {},
			},
			issues = {
				github = {},
				gitlab = {},
				gitea = {},
				forgejo = {},
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
		local gitea_pr = assert(resolver.resolve("http://localhost:3000/atlas/atlas.test/pulls/3"))
		local forgejo_issue = assert(resolver.resolve("http://localhost:3001/atlas/atlas.test/issues/4"))

		assert.are.equal("pr", github.entity)
		assert.are.equal(42, github.number)
		assert.are.equal("ATLAS-123", jira.issue_key)
		assert.are.equal("emrearmagan/atlas.nvim", gitlab.project_path)
		assert.are.equal("emrearmagan", bitbucket.workspace)
		assert.are.equal("gitea", gitea_pr.provider)
		assert.are.equal("pulls", gitea_pr.domain)
		assert.are.equal(3, gitea_pr.number)
		assert.are.equal("forgejo", forgejo_issue.provider)
		assert.are.equal("issues", forgejo_issue.domain)
		assert.are.equal(4, forgejo_issue.number)
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
		config.options.pulls.gitea.views = {
			{ name = "Gitea", repo = "owner/gitea" },
		}
		config.options.pulls.forgejo.views = {
			{ name = "Forgejo", repo = "owner/forgejo" },
		}

		local found = {}
		for _, repository in ipairs(resolver.configured_repositories()) do
			found[repository.provider] = repository.slug
		end
		assert.are.same({
			github = "owner/github",
			gitlab = "owner/gitlab",
			bitbucket = "owner/bitbucket",
			gitea = "owner/gitea",
			forgejo = "owner/forgejo",
		}, found)
	end)

	it("resolves self-hosted HTTP and SSH remotes", function()
		config.options.providers.gitea.base_url = "http://localhost:3000/git"
		config.options.providers.forgejo.base_url = "http://forgejo.localhost:3001"

		local web = assert(git.parse_remote_url("http://localhost:3000/git/owner/repo.git"))
		local ssh = assert(git.parse_remote_url("git@localhost:owner/repo.git"))
		local target = assert(resolver.resolve("http://localhost:3000/git/owner/repo/pulls/7"))

		assert.are.equal("gitea", web.provider)
		assert.are.equal("owner/repo", web.slug)
		assert.are.equal(target.provider, ssh.provider)
		assert.are.equal(target.host, ssh.host)
		assert.are.equal(target.project_path, ssh.slug)
		assert.are.equal("git@localhost:owner/repo.git", ssh.url)
	end)

	it("does not claim an HTTP remote from a different port", function()
		local remote = assert(git.parse_remote_url("http://localhost:9999/owner/repo.git"))
		assert.are.equal("unknown", remote.provider)
	end)

	it("resolves Git remotes for the requested domain", function()
		local pulls = assert(git.parse_remote_url("http://localhost:3000/owner/repo.git", "pulls"))
		local issues = assert(git.parse_remote_url("http://localhost:3000/owner/repo.git", "issues"))

		assert.are.equal("gitea", pulls.provider)
		assert.are.equal("gitea", issues.provider)
	end)

	it("resolves encoded self-hosted URL paths", function()
		config.options.providers.gitea.base_url = "http://localhost:3000/git%2Droot"

		local remote = assert(git.parse_remote_url("http://localhost:3000/git%2Droot/owner/repo.git"))
		assert.are.equal("gitea", remote.provider)
		assert.are.equal("owner/repo", remote.slug)
	end)

	it("treats default HTTP ports as the same authority", function()
		config.options.providers.gitea.base_url = "https://git.example"

		local target = assert(resolver.resolve("https://git.example:443/owner/repo/pulls/7"))
		local remote = assert(git.parse_remote_url("https://git.example:443/owner/repo.git"))
		assert.are.equal("gitea", target.provider)
		assert.are.equal("gitea", remote.provider)

		config.options.providers.gitea.base_url = "https://git.example:443"
		assert.are.equal("gitea", assert(resolver.resolve("https://git.example/owner/repo/pulls/7")).provider)
	end)

	it("uses one note target for equivalent self-hosted URLs", function()
		config.options.providers.gitea.base_url = "https://git.example/git-root"
		local notes = require("atlas.pulls.notes")
		local url = "https://git.example:443/git%2Droot/owner/repo/pulls/7"
		local from_url = assert(notes.resolve_target(url))
		local from_pull = assert(notes.target_for_pull_request({
			id = 7,
			provider = "gitea",
			repo_full_name = "owner/repo",
			link = { html = url },
		}))

		assert.are.equal(from_url.ref, from_pull.ref)
	end)
end)
