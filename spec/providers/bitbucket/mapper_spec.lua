local mapper = require("atlas.pulls.providers.bitbucket.api.mapper")

local function repository(full_name, clone_links)
	return {
		full_name = full_name,
		links = { clone = clone_links },
	}
end

local function clone_links()
	return {
		{ name = "ssh", href = "ssh://git@ssh.bitbucket.example/acme/repo.git" },
		{ name = "https", href = "https://bitbucket.example/acme/repo.git" },
	}
end

local function pull(source_name, links)
	return mapper.to_pull_requests_list({
		values = {
			{
				id = 42,
				state = "OPEN",
				source = {
					branch = { name = "feature" },
					commit = { hash = "head" },
					repository = repository(source_name, links),
				},
				destination = {
					branch = { name = "main" },
					commit = { hash = "base" },
					repository = repository("acme/repo", links),
				},
			},
		},
	}, "acme", "repo")[1]
end

describe("Bitbucket Git remote mapping", function()
	it("preserves both API-provided URLs regardless of list order", function()
		local links = clone_links()
		for _, ordered in ipairs({ links, { links[2], links[1] } }) do
			local pr = pull("other/fork", ordered)
			assert.equal("https://bitbucket.example/acme/repo.git", pr.source.https_url)
			assert.equal("ssh://git@ssh.bitbucket.example/acme/repo.git", pr.source.ssh_url)
			assert.equal("https://bitbucket.example/acme/repo.git", pr.destination.https_url)
			assert.equal("ssh://git@ssh.bitbucket.example/acme/repo.git", pr.destination.ssh_url)
		end
	end)

	it("recognizes same-repository refs when requested by UUID", function()
		local pr = mapper.to_pull_request({
			source = { repository = repository("acme/repo", {}) },
			destination = { repository = repository("acme/repo", {}) },
		}, "{workspace-id}", "{repo-id}")

		assert.is_nil(pr.source.https_url)
		assert.is_nil(pr.source.ssh_url)
	end)

	it("does not invent missing fork URLs", function()
		local pr = pull("other/fork", {})

		assert.equal("", pr.source.https_url)
		assert.equal("", pr.source.ssh_url)
	end)
end)

describe("Bitbucket comment display", function()
	it("uses rendered mention names while preserving raw Markdown", function()
		local content = {
			raw = "**Please** @{557057:build-agent} and @{alice} review [this](https://example.com), @{unknown}.",
			html = '<p><strong>Please</strong> <span class="ap-mention" data-atlassian-id="557057:build-agent">@Build Agent</span>'
				.. ' and <span class="ap-mention" data-atlassian-id="alice">@Alice &amp; Bob [CI]</span>'
				.. ' review <a href="https://example.com">this</a>, @{unknown}.</p>',
		}
		local comment = assert(mapper.to_comment({ id = 1, content = content }))

		assert.equal(content.raw, comment.body)
		assert.equal(
			"**Please** @Build Agent and @Alice & Bob \\[CI\\] review [this](https://example.com), @{unknown}.",
			comment.body_display
		)
	end)

	it("keeps raw text when the response has no rendered mention", function()
		for _, content in ipairs({
			{ raw = "@{unknown}" },
			{ raw = "@{unknown}", html = "<p>@{unknown}</p>" },
			{ raw = "`@{example}`", html = "<p><code>@{example}</code></p>" },
		}) do
			local comment = assert(mapper.to_comment({ id = 1, content = content }))

			assert.equal(content.raw, comment.body)
			assert.is_nil(comment.body_display)
		end
	end)

	it("uses the same display conversion for tasks and activity", function()
		local content = {
			raw = "Review @{alice}",
			html = '<p>Review <span class="ap-mention" data-atlassian-id="alice">@Alice</span></p>',
		}
		local task = mapper.to_tasks_list({ values = { { id = 1, content = content } } })[1]
		local activity = mapper.to_activities_list({ values = { { comment = { content = content } } } })[1]

		assert.equal("Review @{alice}", task.body)
		assert.equal("Review @Alice", task.body_display)
		assert.equal("Review @Alice", activity.body)
		assert.equal("Review @{alice}", content.raw)
	end)
end)

describe("Bitbucket comment author roles", function()
	it("marks comments by the pull request author", function()
		local comments = mapper.to_comments_list({
			values = {
				{ id = 1, user = { account_id = "a1", display_name = "Alice" } },
				{ id = 2, user = { account_id = "b2", display_name = "Bob" } },
			},
		}, "a1")
		assert.same({ "Author" }, comments[1].author_roles)
		assert.is_nil(comments[2].author_roles)
	end)
end)
