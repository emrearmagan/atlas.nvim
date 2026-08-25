local issue_mapper = require("atlas.issues.providers.gitea.api.mapper")
local pull_mapper = require("atlas.pulls.providers.gitea.api.mapper")

describe("Gitea issue mapping", function()
	it("keeps summary metadata separate from hydrated details", function()
		local raw = {
			number = 7,
			title = "Typed issue",
			body = "Hydrated description",
			state = "open",
			repository = { full_name = "owner/repo" },
			user = { id = 1, login = "author", full_name = "Author" },
			assignees = { { id = 2, login = "reviewer", full_name = "Reviewer" } },
			labels = { { id = 3, name = "bug", color = "ff0000" } },
			milestone = { id = 4, title = "v1", open_issues = 1, closed_issues = 1 },
			pin_order = 1,
			is_locked = true,
			content_version = 5,
		}

		local summary = assert(issue_mapper.to_issue(raw))
		local details = assert(issue_mapper.to_issue_details(raw))

		assert.equal("owner/repo", summary.repo_full_name)
		assert.equal(7, summary.number)
		assert.is_true(summary.is_pinned)
		assert.is_true(summary.is_locked)
		assert.is_nil(summary.description)
		assert.is_nil(summary._raw)
		assert.equal("Hydrated description", details.description)
		assert.equal(2, details.assignees[1].id)
		assert.equal(3, details.labels[1].id)
		assert.equal(4, details.milestone.id)
		assert.is_nil(details._raw)
	end)
end)

describe("Gitea pull request mapping", function()
	it("maps provider metadata directly onto the subtype", function()
		local raw = {
			number = 9,
			title = "Typed pull",
			body = "Description",
			state = "open",
			user = { id = 1, login = "author", full_name = "Author" },
			base = {
				ref = "main",
				sha = "base",
				repo = { full_name = "owner/repo", clone_url = "https://git.example/owner/repo.git" },
			},
			head = { ref = "feature", sha = "head", repo = { full_name = "owner/repo" } },
			additions = 12,
			deletions = 3,
			mergeable = true,
			merge_base = "merge-base",
			labels = { { id = 6, name = "feature", color = "00ff00" } },
		}

		local summary = pull_mapper.to_pull_request(raw)
		local details = pull_mapper.to_pull_request_details(raw)

		assert.equal("owner/repo", summary.repo_full_name)
		assert.equal(12, summary.lines_added)
		assert.equal(3, summary.lines_removed)
		assert.is_true(summary.mergeable)
		assert.equal("merge-base", summary.merge_base)
		assert.is_nil(summary._raw)
		assert.equal("Description", details.description)
		assert.equal(6, details.label_ids[1])
		assert.equal("feature", details.labels[1].name)
		assert.is_nil(details._raw)
	end)
end)
