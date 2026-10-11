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

		assert.equal(content.raw, comment.content_raw)
		assert.equal(
			"**Please** @Build Agent and @Alice & Bob \\[CI\\] review [this](https://example.com), @{unknown}.",
			comment.content_display
		)
	end)

	it("keeps raw text when the response has no rendered mention", function()
		for _, content in ipairs({
			{ raw = "@{unknown}" },
			{ raw = "@{unknown}", html = "<p>@{unknown}</p>" },
			{ raw = "`@{example}`", html = "<p><code>@{example}</code></p>" },
		}) do
			local comment = assert(mapper.to_comment({ id = 1, content = content }))

			assert.equal(content.raw, comment.content_raw)
			assert.is_nil(comment.content_display)
		end
	end)

	it("uses the same display conversion for tasks and activity", function()
		local content = {
			raw = "Review @{alice}",
			html = '<p>Review <span class="ap-mention" data-atlassian-id="alice">@Alice</span></p>',
		}
		local task = mapper.to_tasks_list({ values = { { id = 1, content = content } } })[1]
		local activity = mapper.to_activities_list({ values = { { comment = { content = content } } } })[1]

		assert.equal("Review @{alice}", task.content_raw)
		assert.equal("Review @Alice", task.content_display)
		assert.equal("Review @Alice", activity.body)
		assert.equal("Review @{alice}", content.raw)
	end)
end)
