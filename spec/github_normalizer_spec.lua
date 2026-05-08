local normalizer = require("atlas.pulls.providers.github.api.normalizer")

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
		repository = { name = "repo", nameWithOwner = "owner/repo" },
		author = { login = "octocat", name = "Octo Cat", id = "1" },
	}
end

describe("normalize_pr author.name", function()
	it("uses author.name when it is a normal string", function()
		local raw = base_raw()
		raw.author.name = "Octo Cat"
		local pr = normalizer.normalize_pr(raw)
		assert.are.equal("Octo Cat", pr.author.name)
	end)

	it("falls back to login when author.name is nil", function()
		local raw = base_raw()
		raw.author.name = nil
		local pr = normalizer.normalize_pr(raw)
		assert.are.equal("octocat", pr.author.name)
	end)

	it("falls back to login when author.name is vim.NIL", function()
		local raw = base_raw()
		raw.author.name = vim.NIL
		local pr = normalizer.normalize_pr(raw)
		assert.are.equal("octocat", pr.author.name)
	end)

	it("falls back to login when author.name is an empty string", function()
		local raw = base_raw()
		raw.author.name = ""
		local pr = normalizer.normalize_pr(raw)
		assert.are.equal("octocat", pr.author.name)
	end)
end)
