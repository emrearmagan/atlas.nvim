local storage = require("atlas.core.storage")

describe("core.storage", function()
	describe("target", function()
		it("normalizes the pull request identity", function()
			local target = storage.target({
				provider = "GitHub",
				host = "GitHub.com",
				repository = "Owner/Repo",
				id = 2,
				url = "https://github.com/owner/repo/pull/2",
			})

			assert.are.same({
				ref = "github.com/owner/repo/pr-2",
				provider = "github",
				host = "github.com",
				repository = "owner/repo",
				id = "2",
				url = "https://github.com/owner/repo/pull/2",
			}, target)
		end)

		it("rejects targets that would leave the storage folder", function()
			for _, value in ipairs({
				{ provider = "github", host = "github.com", repository = "owner/../repo", id = "2" },
				{ provider = "github", host = "github.com", repository = "owner/repo", id = "../2" },
				{ provider = "github", host = "example.com/x", repository = "owner/repo", id = "2" },
			}) do
				local target, err = storage.target(value)
				assert.is_nil(target)
				assert.are.equal("Invalid pull request target", err)
			end
		end)
	end)

	describe("dir", function()
		it("places a pull request under its host and repository", function()
			local target =
				storage.target({ provider = "gitlab", host = "gitlab.com", repository = "group/sub/repo", id = "1" })
			---@cast target AtlasStorageTarget

			assert.are.equal("/tmp/atlas/gitlab.com/group/sub/repo/pr-1", storage.dir(target))
		end)
	end)
end)
