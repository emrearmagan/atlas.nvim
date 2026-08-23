local config = require("atlas.config")
local providers = require("atlas.providers")

describe("providers.resolve", function()
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
		local github = assert(providers.resolve("https://github.com/emrearmagan/atlas.nvim/pull/42"))
		local jira = assert(providers.resolve("https://jira.example.com/browse/ATLAS-123"))
		local gitlab = assert(providers.resolve("https://gitlab.example.com/emrearmagan/atlas.nvim/-/issues/8"))
		local bitbucket = assert(providers.resolve("https://bitbucket.org/emrearmagan/atlas.nvim/pull-requests/7"))

		assert.are.equal("pr", github.entity)
		assert.are.equal(42, github.number)
		assert.are.equal(42, github.id)
		assert.are.equal("emrearmagan/atlas.nvim", github.repo_full_name)
		assert.are.equal("https://github.com/emrearmagan/atlas.nvim.git", github.repository_url)
		assert.are.equal("ATLAS-123", jira.issue_key)
		assert.are.equal("emrearmagan/atlas.nvim", gitlab.project_path)
		assert.are.equal("https://gitlab.example.com/emrearmagan/atlas.nvim.git", gitlab.repository_url)
		assert.are.equal("emrearmagan", bitbucket.workspace)
		assert.are.equal(7, bitbucket.id)
	end)

	it("resolves Jira keys", function()
		local jira = assert(providers.resolve("atlas-123"))
		assert.are.equal("jira", jira.provider)
		assert.are.equal("issues", jira.domain)
		assert.are.equal("ATLAS-123", jira.issue_key)
		assert.are.equal("https://jira.example.com/browse/ATLAS-123", jira.url)
	end)

	it("resolves Git remotes as repository targets", function()
		local cases = {
			{
				"git@github.com:owner/repo.git",
				"github",
				"owner/repo",
				"https://github.com/owner/repo",
				"https://github.com/owner/repo.git",
			},
			{
				"ssh://git@gitlab.example.com/group/subgroup/repo.git",
				"gitlab",
				"group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo.git",
			},
			{
				"git://bitbucket.org/workspace/repo.git",
				"bitbucket",
				"workspace/repo",
				"https://bitbucket.org/workspace/repo",
				"https://bitbucket.org/workspace/repo.git",
			},
			{
				"https://github.com/owner/repo.git",
				"github",
				"owner/repo",
				"https://github.com/owner/repo",
				"https://github.com/owner/repo.git",
			},
		}

		for _, case in ipairs(cases) do
			local target = assert(providers.resolve(case[1]))
			assert.are.equal(case[2], target.provider)
			assert.are.equal("pulls", target.domain)
			assert.are.equal("repo", target.entity)
			assert.are.equal(case[3], target.repo_full_name)
			assert.are.equal(case[4], target.url)
			assert.are.equal(case[5], target.repository_url)
		end
	end)

	it("preserves configured base paths", function()
		config.options.providers.gitlab.base_url = "https://gitlab.example.com/gitlab"
		config.options.providers.jira.base_url = "https://jira.example.com/jira"

		local repository = assert(providers.resolve("git@gitlab.example.com:group/subgroup/repo.git"))
		local https_repository = assert(providers.resolve("https://gitlab.example.com/gitlab/group/subgroup/repo.git"))
		local merge_request =
			assert(providers.resolve("https://gitlab.example.com/gitlab/group/subgroup/repo/-/merge_requests/12"))
		local jira = assert(providers.resolve("ATLAS-123"))

		assert.are.equal("group/subgroup/repo", repository.repo_full_name)
		assert.are.equal("https://gitlab.example.com/gitlab/group/subgroup/repo", repository.url)
		assert.are.equal("https://gitlab.example.com/gitlab/group/subgroup/repo.git", repository.repository_url)
		assert.are.equal(repository.repo_full_name, https_repository.repo_full_name)
		assert.are.equal(repository.repository_url, https_repository.repository_url)
		assert.are.equal(repository.repository_url, merge_request.repository_url)
		assert.are.equal(12, merge_request.id)
		assert.are.equal("https://jira.example.com/jira/browse/ATLAS-123", jira.url)
	end)

	it("rejects unsupported URLs", function()
		local target, err = providers.resolve("https://jira.other.example.com/browse/ATLAS-123")
		assert.is_nil(target)
		assert.are.equal("Unsupported Atlas URL", err)

		target, err =
			providers.resolve("https://bitbucket.example.com/projects/ATLAS/repos/atlas.nvim/pull-requests/12")
		assert.is_nil(target)
		assert.are.equal(
			"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only",
			err
		)
	end)
end)
