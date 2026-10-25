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
		author = { login = "alice", name = "Alice Example", id = "1" },
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

	it("maps editable issue details without issue identity fields", function()
		local details = assert(issue_mapper.to_issue_details(vim.tbl_extend("force", issue_raw(), {
			body = "Description",
		})))

		assert.equal("My issue", details.title)
		assert.equal("Description", details.description)
		assert.is_nil(rawget(details, "repo_full_name"))
		assert.is_nil(rawget(details, "number"))
		assert.is_nil(rawget(details, "node_id"))
	end)

	it("maps GitHub milestone progress and sub-issues", function()
		local raw = issue_raw()
		raw.milestone = {
			number = 7,
			title = "v1",
			progressPercentage = 50,
			openIssues = { totalCount = 1 },
			closedIssues = { totalCount = 1 },
		}
		raw.subIssues = { nodes = { vim.tbl_extend("force", issue_raw(), { id = "I_2", number = 43 }) } }

		local details = assert(issue_mapper.to_issue_details(raw))

		assert.equal(7, details.milestone.number)
		assert.equal(50, details.milestone.progress_percentage)
		assert.equal(1, details.milestone.open_issues)
		assert.equal(1, details.milestone.closed_issues)
		assert.equal("owner/repo#43", details.sub_issues[1].key)
		assert.equal(43, details.sub_issues[1].number)
	end)
end)

describe("normalize_pr author.name", function()
	it("uses author.name and falls back to login when it is missing", function()
		for _, case in ipairs({
			{ label = "set", value = "Alice Example", expected = "Alice Example" },
			{ label = "nil", expected = "alice" },
			{ label = "vim.NIL", value = vim.NIL, expected = "alice" },
			{ label = "empty string", value = "", expected = "alice" },
		}) do
			local raw = base_raw()
			raw.author.name = case.value
			local pr = normalizer.to_pull_request(raw)
			assert.are.equal(case.expected, pr.author.name, case.label)
		end
	end)
end)

describe("GitHub descriptions", function()
	local groups = {
		{ content = "HOORAY", viewerHasReacted = true, reactors = { totalCount = 1, nodes = { { login = "bob" } } } },
	}

	it("maps a pull request description as a comment with its reactions", function()
		local raw = vim.tbl_extend("force", base_raw(), { id = "PR_1", reactionGroups = groups })

		local comment = assert(normalizer.to_description(raw))

		assert.equal("PR_1", comment.id)
		assert.equal("Description", comment.body)
		assert.equal("tada", comment.reactions[1].name)
		assert.is_true(comment.reactions[1].reacted)
		assert.same(comment.reactions, normalizer.to_pull_request_details(raw).reactions)
	end)

	it("maps an issue description as a comment", function()
		local comment = assert(issue_mapper.to_comment({ id = "I_1", body = "Body", reactionGroups = groups }))

		assert.equal("I_1", comment.id)
		assert.equal("Body", comment.body)
		assert.equal("tada", comment.reactions[1].name)
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

		assert.same({ name = "resolver", id = "3", username = "resolver" }, comment.resolved_by)
		assert.is_nil(comment.resolved_at)
	end)

	it("does not map the resolver onto replies", function()
		local comment = normalizer.to_review_comment(review_comment({ id = "PRRC_1" }), resolved_thread(), "PRRC_1")

		assert.is_nil(comment.resolved_by)
	end)
end)

describe("GitHub comment author roles", function()
	local function roles(association, author)
		return issue_mapper.to_comment({ id = "IC_1", authorAssociation = association, author = author }, "alice").author_roles
	end

	it("maps the association and marks the issue author", function()
		assert.same({ "Author", "Owner" }, roles("OWNER", { login = "alice" }))
		assert.same({ "Member" }, roles("MEMBER", { login = "bob" }))
		assert.same({ "First-time contributor" }, roles("FIRST_TIMER", { login = "bob" }))
	end)

	it("marks bots and skips associations GitHub does not show", function()
		assert.same({ "Bot" }, roles("NONE", { __typename = "Bot", login = "ci-bot" }))
		assert.is_nil(roles("MANNEQUIN", { login = "imported-user" }))
		assert.is_nil(roles(nil, vim.NIL))
	end)

	it("maps review comments against the pull request author", function()
		local node = { id = "RC_1", authorAssociation = "COLLABORATOR", author = { login = "alice" } }
		assert.same({ "Author", "Collaborator" }, normalizer.to_review_comment(node, {}, nil, "alice").author_roles)
	end)
end)

describe("GitHub pull request stacks", function()
	it("maps a stack summary onto the pull request", function()
		local raw = base_raw()
		raw.stackEntry = { position = 2, stack = { number = 530, size = 5, baseRefName = "main" } }

		local pr = normalizer.to_pull_request(raw)

		assert.same({ position = 2, number = 530, size = 5, base_ref_name = "main" }, pr.stack)
	end)

	it("maps stack entries onto pull request details", function()
		local raw = base_raw()
		raw.stackEntry = {
			position = 2,
			stack = {
				number = 530,
				size = 3,
				baseRefName = "main",
				entries = {
					nodes = {
						{
							position = 1,
							pullRequest = { number = 10, title = "Base", state = "OPEN", isDraft = false },
						},
						{
							position = 2,
							pullRequest = { number = 11, title = "Middle", state = "OPEN", isDraft = true },
						},
						{ position = 3, pullRequest = vim.NIL },
					},
				},
			},
		}

		local details = normalizer.to_pull_request_details(raw)

		assert.equal(2, details.stack.position)
		assert.equal(3, details.stack.size)
		assert.same({ position = 1, number = 10, title = "Base", state = "open" }, details.stack.entries[1])
		assert.equal("draft", details.stack.entries[2].state)
		assert.same({ position = 3 }, details.stack.entries[3])
	end)

	it("leaves stack nil when the pull request is not stacked", function()
		local raw = base_raw()
		raw.stackEntry = vim.NIL

		assert.is_nil(normalizer.to_pull_request(raw).stack)
		assert.is_nil(normalizer.to_pull_request_details(raw).stack)
	end)
end)
