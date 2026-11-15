local config = require("atlas.config")
local git = require("atlas.core.git")
local description = require("atlas.pulls.create.description")

describe("pulls.create.description", function()
	local original_options, diff_revisions, commits_for_range, diff_stat

	---@param options AtlasPullsDescriptionConfig
	---@param repository { provider: string, url: string }
	---@param commits { hash: string, subject: string }[]
	---@param diffstat string[]
	---@return PullsCreateDescription
	local function build(options, repository, commits, diffstat)
		config.options = {
			pulls = {
				description = options,
				repo_config = { settings = { ["owner/repo"] = { pr_template = "" } } },
			},
			providers = { jira = { base_url = "https://jira.example.com", token = "token" } },
		}
		---@diagnostic disable-next-line: duplicate-set-field
		git.diff_revisions = function(_, _, _, done)
			done("base", "head")
		end
		---@diagnostic disable-next-line: duplicate-set-field
		git.commits_for_range = function(_, _, done)
			done(commits)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		git.diff_stat = function(_, _, _, done)
			done(diffstat)
		end

		local result
		description.build("/repo", "owner/repo", "main", "feature/KAN-3-search", repository, function(value)
			result = value
		end)
		return result
	end

	before_each(function()
		original_options = config.options
		diff_revisions, commits_for_range, diff_stat = git.diff_revisions, git.commits_for_range, git.diff_stat
	end)

	after_each(function()
		config.options = original_options
		git.diff_revisions, git.commits_for_range, git.diff_stat = diff_revisions, commits_for_range, diff_stat
	end)

	it("groups conventional commits into sections and links issues and Jira keys", function()
		local result = build(
			{ include_summary = false, include_commit_hashes = false, include_related = true, include_diffstat = true },
			{ provider = "github", url = "https://github.com/owner/repo" },
			{
				{ hash = "a1", subject = "feat(api): add search" },
				{ hash = "b2", subject = "fix(KAN-1): handle empty results #12" },
				{ hash = "c3", subject = "[KAN-2] feat!: drop v1 endpoints" },
			},
			{ " a.lua | 2 +-" }
		)

		local jira = "https://jira.example.com/browse/"
		assert.equal("[KAN-2] feat!: drop v1 endpoints", result.title)
		assert.equal(
			table.concat({
				"## Changes",
				"",
				"**Breaking changes**",
				"- [KAN-2](" .. jira .. "KAN-2) drop v1 endpoints",
				"",
				"**Features**",
				"- (api) add search",
				"",
				"**Fixes**",
				"- [KAN-1](" .. jira .. "KAN-1) handle empty results [#12](https://github.com/owner/repo/issues/12)",
				"",
				"## Related",
				"",
				"- [KAN-3](" .. jira .. "KAN-3)",
				"- [KAN-1](" .. jira .. "KAN-1)",
				"- [#12](https://github.com/owner/repo/issues/12)",
				"- [KAN-2](" .. jira .. "KAN-2)",
				"",
				"**Diffstat**",
				"",
				"```text",
				" a.lua | 2 +-",
				"```",
			}, "\n"),
			result.body
		)
	end)

	it("lists other commits with links to the commit on the provider", function()
		local result = build(
			{ include_summary = false, include_commit_hashes = true, include_related = false, include_diffstat = false },
			{ provider = "gitlab", url = "https://gitlab.com/group/repo" },
			{ { hash = "a1b2", subject = "Update readme" }, { hash = "c3d4", subject = "Bump deps" } },
			{}
		)

		assert.equal(
			"- [`a1b2`](https://gitlab.com/group/repo/-/commit/a1b2) Update readme\n"
				.. "- [`c3d4`](https://gitlab.com/group/repo/-/commit/c3d4) Bump deps",
			result.body
		)
	end)
end)
