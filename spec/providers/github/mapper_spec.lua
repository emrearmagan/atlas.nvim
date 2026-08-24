local normalizer = require("atlas.pulls.providers.github.api.mapper")
local issue_mapper = require("atlas.issues.providers.github.api.mapper")

local function base_raw()
	return {
		number = 42,
		title = "My PR",
		body = "Description",
		state = "OPEN",
		isDraft = false,
		headRefName = "feature",
		headRefOid = "abc123",
		baseRefName = "main",
		baseRefOid = "def456",
		createdAt = "2024-01-01T00:00:00Z",
		updatedAt = "2024-01-02T00:00:00Z",
		url = "https://github.com/owner/repo/pull/42",
		repository = {
			name = "repo",
			nameWithOwner = "owner/repo",
			url = "https://github.com/owner/repo",
			sshUrl = "git@github.com:owner/repo.git",
		},
		author = { login = "octocat", name = "Octo Cat", id = "1" },
	}
end

describe("GitHub issue mapping", function()
	local function issue_raw()
		return {
			id = "I_1",
			number = 42,
			title = "My issue",
			state = "OPEN",
			repository = { nameWithOwner = "owner/repo" },
		}
	end

	it("keeps the GitHub issue identity on details", function()
		local issue = issue_mapper.to_issue_details(issue_raw())

		assert.equal("owner/repo", issue.repo_full_name)
		assert.equal(42, issue.number)
		assert.equal("I_1", issue.node_id)
	end)

	it("maps GitHub milestone progress and sub-issues", function()
		local raw = issue_raw()
		raw.milestone = {
			title = "v1",
			progressPercentage = 50,
			openIssues = { totalCount = 1 },
			closedIssues = { totalCount = 1 },
		}
		raw.subIssues = { nodes = { vim.tbl_extend("force", issue_raw(), { id = "I_2", number = 43 }) } }

		local issue = issue_mapper.to_issue_details(raw)

		assert.equal(50, issue.milestone.progress_percentage)
		assert.equal(1, issue.milestone.open_issues)
		assert.equal(1, issue.milestone.closed_issues)
		assert.equal("owner/repo#43", issue.sub_issues[1].key)
		assert.equal(43, issue.sub_issues[1].number)
	end)
end)

describe("normalize_pr author.name", function()
	it("uses author.name when it is a normal string", function()
		local raw = base_raw()
		raw.author.name = "Octo Cat"
		local pr = normalizer.to_pull_request(raw)
		assert.are.equal("Octo Cat", pr.author.name)
	end)

	it("falls back to login when author.name is missing", function()
		for _, case in ipairs({
			{ label = "nil" },
			{ label = "vim.NIL", value = vim.NIL },
			{ label = "empty string", value = "" },
		}) do
			local raw = base_raw()
			raw.author.name = case.value
			local pr = normalizer.to_pull_request(raw)
			assert.are.equal("octocat", pr.author.name, case.label)
		end
	end)
end)

describe("GitHub Git remote mapping", function()
	it("retains both URLs returned by the existing PR query", function()
		local pr = normalizer.to_pull_request(base_raw())

		assert.equal("https://github.com/owner/repo.git", pr.destination.https_url)
		assert.equal("git@github.com:owner/repo.git", pr.destination.ssh_url)
	end)
end)

describe("GitHub pull request details", function()
	it("keeps GitHub metadata and reactions on the detail type", function()
		local raw = base_raw()
		raw.id = "PR_42"
		raw.reactionGroups = { { content = "THUMBS_UP", reactors = { totalCount = 2 } } }

		local pr = normalizer.to_pull_request_details(raw)

		assert.equal("PR_42", pr.node_id)
		assert.equal(2, pr.reactions["+1"])
		assert.equal("Description", pr.description)
	end)
end)

describe("GitHub reviewer decisions", function()
	it("keeps an active review request pending after an earlier decision", function()
		local raw = base_raw()
		raw.reviews = {
			nodes = {
				{ state = "APPROVED", author = { id = "2", login = "reviewer", name = "Reviewer" } },
			},
		}
		raw.reviewRequests = {
			nodes = {
				{ requestedReviewer = { id = "2", login = "reviewer", name = "Reviewer" } },
			},
		}

		local pr = normalizer.to_pull_request(raw)

		assert.equal("pending", pr.reviewers[1].decision)
	end)

	it("keeps an approval after a later comment", function()
		local raw = base_raw()
		raw.reviews = {
			nodes = {
				{ state = "APPROVED", author = { id = "2", login = "reviewer", name = "Reviewer" } },
				{ state = "COMMENTED", author = { id = "2", login = "reviewer", name = "Reviewer" } },
			},
		}

		local pr = normalizer.to_pull_request(raw)

		assert.equal(1, #pr.reviewers)
		assert.equal("approved", pr.reviewers[1].decision)
		assert.equal("participant", pr.reviewers[1].role)
	end)

	it("removes a dismissed decision", function()
		local raw = base_raw()
		raw.reviews = {
			nodes = {
				{ state = "APPROVED", author = { id = "2", login = "reviewer", name = "Reviewer" } },
				{ state = "DISMISSED", author = { id = "2", login = "reviewer", name = "Reviewer" } },
			},
		}

		local pr = normalizer.to_pull_request(raw)

		assert.same({}, pr.reviewers)
	end)
end)

describe("review thread resolution", function()
	local function review_comment(reply_to)
		return {
			id = "PRRC_1",
			databaseId = 1,
			body = "Review comment",
			createdAt = "2024-01-01T00:00:00Z",
			author = { login = "author", databaseId = 2 },
			replyTo = reply_to,
			pullRequestReview = { state = "COMMENTED" },
		}
	end

	local function resolved_thread()
		return {
			id = "PRRT_1",
			isResolved = true,
			isOutdated = false,
			resolvedBy = { login = "resolver", databaseId = 3 },
		}
	end

	it("maps the resolver onto a resolved root comment", function()
		local comment = normalizer.to_review_comment(review_comment(nil), resolved_thread(), nil)

		assert.same({ name = "resolver", id = "3", username = "resolver", nickname = "resolver" }, comment.resolved_by)
		assert.is_nil(comment.resolved_on)
	end)

	it("does not map the resolver onto replies", function()
		local comment = normalizer.to_review_comment(review_comment({ databaseId = 1 }), resolved_thread(), 1)

		assert.is_nil(comment.resolved_by)
	end)
end)
