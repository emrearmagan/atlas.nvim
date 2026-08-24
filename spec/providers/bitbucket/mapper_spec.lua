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

	it("does not attach source URLs to a same-repository ref", function()
		local pr = pull("acme/repo", clone_links())

		assert.is_nil(pr.source.https_url)
		assert.is_nil(pr.source.ssh_url)
	end)

	it("does not invent missing fork URLs", function()
		local pr = pull("other/fork", {})

		assert.equal("", pr.source.https_url)
		assert.equal("", pr.source.ssh_url)
	end)
end)

describe("Bitbucket pull request details", function()
	it("keeps Bitbucket metadata on the detail type", function()
		local pr = mapper.to_pull_request_details({
			id = 42,
			state = "OPEN",
			title = "Typed details",
			description = "Description",
			task_count = 3,
			close_source_branch = true,
			links = { self = { href = "https://api.bitbucket.org/pullrequests/42" } },
			source = { branch = { name = "feature" }, commit = { hash = "head" } },
			destination = { branch = { name = "main" }, commit = { hash = "base" } },
		}, "acme", "repo")

		assert.equal("Description", pr.description)
		assert.equal(3, pr.tasks_count)
		assert.is_true(pr.close_source_branch)
		assert.equal("https://api.bitbucket.org/pullrequests/42", pr.links.self)
	end)
end)
