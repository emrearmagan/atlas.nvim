local config = require("atlas.config")
local providers = require("atlas.providers")

describe("providers.resolve", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			providers = {
				azure = { base_url = "https://dev.azure.com/acme" },
				github = { hostname = "github.com" },
				gitlab = { base_url = "https://gitlab.example.com", token = "token" },
				bitbucket = { user = "user", token = "token" },
				jira = { base_url = "https://jira.example.com", token = "token" },
			},
			pulls = {
				azure = {},
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

	describe("GitHub", function()
		local base = "https://github.com/team/repo"

		it("resolves a repository", function()
			local target = assert(providers.resolve(base))
			assert.are.equal("github", target.provider)
			assert.are.equal("pulls", target.domain)
			assert.are.equal("repo", target.entity)
			assert.are.equal("team/repo", target.repo_full_name)
			assert.are.equal(base, target.url)
			assert.are.equal(base .. ".git", target.repository_url)
		end)

		it("resolves Git remotes as the repository", function()
			for _, remote in ipairs({ "git@github.com:team/repo.git", base .. ".git" }) do
				local target = assert(providers.resolve(remote))
				assert.are.equal("repo", target.entity)
				assert.are.equal("team/repo", target.repo_full_name)
				assert.are.equal(base, target.url)
				assert.are.equal(base .. ".git", target.repository_url)
			end
		end)

		it("resolves a pull request", function()
			local target = assert(providers.resolve(base .. "/pull/42"))
			assert.are.equal("pr", target.entity)
			assert.are.equal("pulls", target.domain)
			assert.are.equal(42, target.number)
			assert.are.equal(42, target.id)
			assert.are.equal(base .. "/pull/42", target.url)
			assert.are.equal(base .. ".git", target.repository_url)
			assert.are.equal(42, assert(providers.resolve(base .. "/pull/42/files")).number)
		end)

		it("resolves an issue", function()
			local target = assert(providers.resolve(base .. "/issues/8"))
			assert.are.equal("issue", target.entity)
			assert.are.equal("issues", target.domain)
			assert.are.equal(8, target.number)
			assert.is_nil(target.id)
		end)

		it("resolves a workflow run", function()
			local target = assert(providers.resolve(base .. "/actions/runs/99"))
			assert.are.equal("pipeline", target.entity)
			assert.are.equal(99, target.number)
			assert.are.equal(99, assert(providers.resolve(base .. "/actions/runs/99/job/5")).number)
		end)

		it("resolves repository pages", function()
			assert.are.equal("issues", assert(providers.resolve(base .. "/issues")).page)
			assert.are.equal("pulls", assert(providers.resolve(base .. "/pulls")).page)
			assert.are.equal("discussions", assert(providers.resolve(base .. "/discussions")).page)
			assert.are.equal("discussions", assert(providers.resolve(base .. "/discussions/40")).page)
			assert.are.equal("builds", assert(providers.resolve(base .. "/actions")).page)
			assert.are.equal("builds", assert(providers.resolve(base .. "/actions/workflows/ci.yml")).page)
			assert.are.equal("releases", assert(providers.resolve(base .. "/releases")).page)
			assert.are.equal("releases", assert(providers.resolve(base .. "/releases/tag/v1.0.0")).page)
			assert.are.equal("tags", assert(providers.resolve(base .. "/tags")).page)
			assert.are.equal("branches", assert(providers.resolve(base .. "/branches")).page)
			assert.are.equal("repo", assert(providers.resolve(base .. "/discussions/40")).entity)
		end)

		it("resolves Enterprise Server URLs on the active host only", function()
			config.options.providers.github.hostname = "github.company.test"
			local pull = assert(providers.resolve("https://github.company.test/team/repo/pull/42"))
			local remote = assert(providers.resolve("ssh://git@github.company.test/team/repo.git"))
			assert.are.equal("github.company.test", pull.host)
			assert.are.equal("https://github.company.test/team/repo.git", pull.repository_url)
			assert.are.equal("repo", remote.entity)
			assert.are.equal("team/repo", remote.repo_full_name)

			local target, err = providers.resolve(base .. "/pull/42")
			assert.is_nil(target)
			assert.are.equal("Unsupported Atlas URL", err)
		end)

		it("rejects unsupported URLs", function()
			assert.is_nil(providers.resolve(base .. "/wiki"))
			assert.is_nil(providers.resolve(base .. "/pull/42abc"))
			assert.is_nil(providers.resolve("https://github.com/team"))
			assert.is_nil(providers.resolve("https://github.com/orgs/team/discussions"))
			assert.is_nil(providers.resolve("git@github.com:team/repo/extra.git"))
		end)
	end)

	describe("GitLab", function()
		local base = "https://gitlab.example.com/team/repo"

		it("resolves a project", function()
			local target = assert(providers.resolve(base))
			assert.are.equal("gitlab", target.provider)
			assert.are.equal("repo", target.entity)
			assert.are.equal("team/repo", target.project_path)
			assert.are.equal("team/repo", target.repo_full_name)
			assert.are.equal(base, target.url)
			assert.are.equal(base .. ".git", target.repository_url)
		end)

		it("resolves Git remotes of nested projects", function()
			local target = assert(providers.resolve("ssh://git@gitlab.example.com/group/subgroup/repo.git"))
			assert.are.equal("repo", target.entity)
			assert.are.equal("group/subgroup/repo", target.repo_full_name)
			assert.are.equal("https://gitlab.example.com/group/subgroup/repo", target.url)
			assert.are.equal(
				"team/repo",
				assert(providers.resolve("git@gitlab.example.com:team/repo.git")).repo_full_name
			)
		end)

		it("resolves SSH remotes on a custom port", function()
			local expected = assert(providers.resolve(base))
			assert.same(expected, assert(providers.resolve("ssh://gitlab.example.com:1234/team/repo.git")))
		end)

		it("resolves a merge request", function()
			local target = assert(providers.resolve(base .. "/-/merge_requests/12"))
			assert.are.equal("pr", target.entity)
			assert.are.equal("pulls", target.domain)
			assert.are.equal(12, target.id)
			assert.are.equal(base .. ".git", target.repository_url)
			assert.are.equal(12, assert(providers.resolve(base .. "/-/merge_requests/12/diffs")).number)
		end)

		it("resolves issues and work items", function()
			local issue = assert(providers.resolve(base .. "/-/issues/8"))
			local work_item = assert(providers.resolve("https://gitlab.example.com/group/subgroup/repo/-/work_items/8"))
			assert.are.equal("issue", issue.entity)
			assert.are.equal("issues", issue.domain)
			assert.are.equal(8, issue.number)
			assert.is_nil(issue.id)
			assert.are.equal("issue", work_item.entity)
			assert.are.equal("group/subgroup/repo", work_item.repo_full_name)
		end)

		it("resolves a pipeline", function()
			local target = assert(providers.resolve(base .. "/-/pipelines/99"))
			assert.are.equal("pipeline", target.entity)
			assert.are.equal(99, target.id)
		end)

		it("resolves project pages", function()
			assert.are.equal("issues", assert(providers.resolve(base .. "/-/issues")).page)
			assert.are.equal("pulls", assert(providers.resolve(base .. "/-/merge_requests")).page)
			assert.are.equal("builds", assert(providers.resolve(base .. "/-/pipelines")).page)
			assert.are.equal("releases", assert(providers.resolve(base .. "/-/releases")).page)
			assert.are.equal("releases", assert(providers.resolve(base .. "/-/releases/v1.0.0")).page)
			assert.are.equal("tags", assert(providers.resolve(base .. "/-/tags")).page)
			assert.are.equal("branches", assert(providers.resolve(base .. "/-/branches")).page)
		end)

		it("preserves a configured base path", function()
			config.options.providers.gitlab.base_url = "https://gitlab.example.com/gitlab"
			local remote = assert(providers.resolve("git@gitlab.example.com:group/subgroup/repo.git"))
			local https = assert(providers.resolve("https://gitlab.example.com/gitlab/group/subgroup/repo.git"))
			local merge_request =
				assert(providers.resolve("https://gitlab.example.com/gitlab/group/subgroup/repo/-/merge_requests/12"))
			assert.are.equal("group/subgroup/repo", remote.repo_full_name)
			assert.are.equal("https://gitlab.example.com/gitlab/group/subgroup/repo", remote.url)
			assert.are.equal("https://gitlab.example.com/gitlab/group/subgroup/repo.git", remote.repository_url)
			assert.are.equal(remote.repository_url, https.repository_url)
			assert.are.equal(remote.repository_url, merge_request.repository_url)
			assert.are.equal(12, merge_request.id)
		end)

		it("rejects unsupported URLs and groups", function()
			assert.is_nil(providers.resolve(base .. "/-/tree/main"))
			assert.is_nil(providers.resolve(base .. "/-/issues/8abc"))
			assert.is_nil(providers.resolve("https://gitlab.example.com/team"))
			assert.is_nil(providers.resolve("https://gitlab.example.com/groups/team/-/issues"))
			assert.is_nil(providers.resolve("https://gitlab.example.com/groups/team/-/issues/8"))
			assert.is_nil(providers.resolve("https://gitlab.example.com/groups/team/-/work_items/8"))
			assert.is_nil(providers.resolve("git@gitlab.example.com:repo.git"))
		end)
	end)

	describe("Bitbucket", function()
		local base = "https://bitbucket.org/team/repo"

		it("resolves a repository", function()
			local target = assert(providers.resolve(base))
			assert.are.equal("bitbucket", target.provider)
			assert.are.equal("repo", target.entity)
			assert.are.equal("team", target.workspace)
			assert.are.equal("team/repo", target.repo_full_name)
			assert.are.equal(base, target.url)
			assert.are.equal(base .. ".git", target.repository_url)
		end)

		it("resolves Git remotes as the repository", function()
			for _, remote in ipairs({ "git@bitbucket.org:team/repo.git", "git://bitbucket.org/team/repo.git" }) do
				local target = assert(providers.resolve(remote))
				assert.are.equal("repo", target.entity)
				assert.are.equal(base, target.url)
				assert.are.equal(base .. ".git", target.repository_url)
			end
		end)

		it("resolves SSH host remotes to the canonical Cloud repository", function()
			local expected = assert(providers.resolve(base))
			for _, remote in ipairs({
				"git@ssh.bitbucket.org:team/repo.git",
				"ssh://git@ssh.bitbucket.org/team/repo.git",
			}) do
				assert.same(expected, assert(providers.resolve(remote)))
			end
		end)

		it("resolves a pull request", function()
			local target = assert(providers.resolve(base .. "/pull-requests/7"))
			assert.are.equal("pr", target.entity)
			assert.are.equal(7, target.id)
			assert.are.equal(7, assert(providers.resolve(base .. "/pull-requests/7/diff")).number)
		end)

		it("resolves a pipeline", function()
			local target = assert(providers.resolve(base .. "/pipelines/results/5"))
			assert.are.equal("pipeline", target.entity)
			assert.are.equal(5, target.id)
		end)

		it("resolves repository pages", function()
			assert.are.equal("pulls", assert(providers.resolve(base .. "/pull-requests")).page)
			assert.are.equal("branches", assert(providers.resolve(base .. "/branches")).page)
			assert.are.equal("builds", assert(providers.resolve(base .. "/pipelines")).page)
		end)

		it("rejects unsupported URLs and Bitbucket Server", function()
			assert.is_nil(providers.resolve(base .. "/src"))
			assert.is_nil(providers.resolve(base .. "/pull-requests/7abc"))
			assert.is_nil(providers.resolve("https://bitbucket.org/team"))
			assert.is_nil(providers.resolve("git@bitbucket.org:team.git"))
			assert.is_nil(providers.resolve("git@ssh.bitbucket.org:team/repo/extra.git"))
			assert.is_nil(providers.resolve("https://ssh.bitbucket.org/team/repo"))

			local target, err =
				providers.resolve("https://bitbucket.example.com/projects/ATLAS/repos/repo/pull-requests/12")
			assert.is_nil(target)
			assert.are.equal(
				"Bitbucket Server/Data Center URLs are recognized, but this Atlas provider currently supports Bitbucket Cloud only",
				err
			)
		end)
	end)

	describe("Jira", function()
		it("resolves an issue URL", function()
			assert.are.equal(
				"ATLAS-123",
				assert(providers.resolve("https://jira.example.com/browse/ATLAS-123")).issue_key
			)
		end)

		it("resolves an issue key", function()
			local target = assert(providers.resolve("atlas-123"))
			assert.are.equal("jira", target.provider)
			assert.are.equal("issues", target.domain)
			assert.are.equal("ATLAS-123", target.issue_key)
			assert.are.equal("https://jira.example.com/browse/ATLAS-123", target.url)
		end)

		it("preserves a configured base path", function()
			config.options.providers.jira.base_url = "https://jira.example.com/jira"
			assert.are.equal(
				"https://jira.example.com/jira/browse/ATLAS-123",
				assert(providers.resolve("ATLAS-123")).url
			)
		end)

		it("rejects other hosts", function()
			local target, err = providers.resolve("https://jira.other.example.com/browse/ATLAS-123")
			assert.is_nil(target)
			assert.are.equal("Unsupported Atlas URL", err)
		end)
	end)

	describe("Azure DevOps", function()
		it("resolves a pull request", function()
			local target = assert(providers.resolve("https://dev.azure.com/acme/platform/_git/api/pullrequest/17"))
			assert.are.equal("pr", target.entity)
			assert.are.equal("platform/api", target.project_path)
			assert.are.equal("platform/api", target.repo_full_name)
			assert.are.equal(17, target.id)
			assert.are.equal(17, target.number)
			assert.are.equal("https://dev.azure.com/acme/platform/_git/api", target.repository_url)
		end)

		it("keeps encoded repository names", function()
			local target = assert(providers.resolve("https://dev.azure.com/acme/platform/_git/sdk%252Fcore"))
			assert.are.equal("sdk%2Fcore", target.repo)
			assert.are.equal("https://dev.azure.com/acme/platform/_git/sdk%252Fcore", target.url)
		end)

		it("resolves Git remotes as the repository", function()
			local cases = {
				{
					"https://acme@dev.azure.com/acme/Team%20Project/_git/api%20service",
					"Team Project/api service",
					"https://dev.azure.com/acme/Team%20Project/_git/api%20service",
				},
				{
					"git@ssh.dev.azure.com:v3/acme/Platform/api",
					"Platform/api",
					"https://dev.azure.com/acme/Platform/_git/api",
				},
				{
					"ssh://git@ssh.dev.azure.com/v3/acme/Platform/api",
					"Platform/api",
					"https://dev.azure.com/acme/Platform/_git/api",
				},
			}
			for _, case in ipairs(cases) do
				local target = assert(providers.resolve(case[1]))
				assert.are.equal("azure", target.provider)
				assert.are.equal("repo", target.entity)
				assert.are.equal(case[2], target.repo_full_name)
				assert.are.equal(case[3], target.url)
				assert.are.equal(case[3], target.repository_url)
			end
		end)

		it("rejects other organizations", function()
			local target, err = providers.resolve("https://dev.azure.com/other/platform/_git/api/pullrequest/17")
			assert.is_nil(target)
			assert.are.equal("Azure DevOps URL organization does not match providers.azure.base_url", err)
		end)
	end)
end)
