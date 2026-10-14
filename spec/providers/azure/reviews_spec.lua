local modules = {
	"atlas.providers.azure.client",
	"atlas.providers.azure.repositories",
	"atlas.pulls.providers.azure.api.mapper",
	"atlas.pulls.providers.azure.api.reviews",
	"atlas.pulls.providers.azure.api.changes",
	"atlas.pulls.providers.azure.api.comments",
}
local pr = {
	id = 1,
	repo_full_name = "Platform/api",
	repo = { owner = "Platform", repo_name = "api" },
	source = { commit_hash = "head" },
	link = { html = "https://example.com/pr/1" },
}

local function comment(id, parent)
	return { id = id, parentCommentId = parent or 0, commentType = "text", content = "Review", author = {} }
end

describe("Azure review mapping", function()
	local saved, threads, reviewers, files

	before_each(function()
		saved, threads, reviewers, files = {}, {}, {}, {}
		for _, name in ipairs(modules) do
			saved[name], package.loaded[name] = package.loaded[name], nil
		end
		local client = require(modules[1])
		package.loaded[modules[1]] = {
			url_encode = client.url_encode,
			build_query = client.build_query,
			get_cache = function() end,
			set_cache = function() end,
			request = function(_, endpoint, _, done)
				if endpoint:match("/reviewers$") then
					done({ value = reviewers }, nil)
				else
					assert.matches("/threads?$baseIteration=0&$iteration=2", endpoint, 1, true)
					done({ value = threads }, nil)
				end
			end,
		}
		package.loaded["atlas.pulls.providers.azure.api.changes"] = {
			fetch_iteration = function(_, commit, done)
				assert.equal("head", commit)
				done(2, nil)
			end,
			fetch_file_diffs = function(_, iteration, _, done)
				assert.equal(2, iteration)
				done(files, nil)
			end,
		}
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("uses fresh reviewer votes and preserves raw mention tokens", function()
		reviewers = { { id = "reviewer", displayName = "Reviewer", vote = 10 } }
		local raw = comment(1)
		raw.content = "Ask @<reviewer>"
		threads =
			{ { id = 7, threadContext = { filePath = "/main.lua", rightFileEnd = { line = 12 } }, comments = { raw } } }
		local result
		require("atlas.pulls.providers.azure.api.reviews").fetch(
			vim.tbl_extend("force", {}, pr, {
				reviewers = { { id = "reviewer", name = "Reviewer", decision = "pending" } },
			}),
			{ force_refresh = true },
			function(data, err)
				assert.is_nil(err)
				result = data
			end
		)
		assert.equal("approved", result.reviewers[1].decision)
		assert.equal("Ask @<reviewer>", result.comments[1].body)
		assert.equal("Ask @Reviewer", result.comments[1].body_display)
	end)

	it("matches renamed-file hunks on both sides, excluding replies and unmatched positions", function()
		local first = { old_start = 1, old_count = 1, new_start = 1, new_count = 1 }
		local hunk = { old_start = 10, old_count = 2, new_start = 20, new_count = 2 }
		files = { { path = "main.lua", old_path = "old.lua", hunks = { first, hunk } } }
		threads = {
			{
				id = 1,
				threadContext = { filePath = "/main.lua", rightFileEnd = { line = 21 } },
				comments = { comment(1), comment(2, 1) },
			},
			{
				id = 2,
				threadContext = { filePath = "/old.lua", leftFileEnd = { line = 11 } },
				comments = { comment(1) },
			},
			{
				id = 3,
				threadContext = { filePath = "/missing.lua", rightFileEnd = { line = 21 } },
				comments = { comment(1) },
			},
			{
				id = 4,
				threadContext = { filePath = "/main.lua", rightFileEnd = { line = 22 } },
				comments = { comment(1) },
			},
			{ id = 5, threadContext = { filePath = "/main.lua" }, comments = { comment(1) } },
		}
		local result
		require("atlas.pulls.providers.azure.api.reviews").fetch_threads(pr, {}, function(data, err)
			assert.is_nil(err)
			result = data.comments
		end)
		assert.equal(6, #result)
		assert.equal(hunk, result[1].hunk)
		assert.equal(hunk, result[3].hunk)
		for _, index in ipairs({ 2, 4, 5, 6 }) do
			assert.is_nil(result[index].hunk)
		end
	end)
end)
