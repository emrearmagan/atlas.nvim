local storage = require("atlas.core.storage")

describe("core.storage", function()
	describe("target", function()
		it("normalizes the pull request identity", function()
			local target = storage.target({
				host = "GitHub.com",
				repository = "Owner/Repo",
				id = 2,
			})

			assert.are.same({
				ref = "github.com/owner/repo/pr-2",
				host = "github.com",
				repository = "owner/repo",
				id = "2",
			}, target)
		end)

		it("rejects targets that would leave the storage folder", function()
			for _, value in ipairs({
				{ host = "github.com", repository = "owner/../repo", id = "2" },
				{ host = "github.com", repository = "owner/repo", id = "../2" },
				{ host = "example.com/x", repository = "owner/repo", id = "2" },
			}) do
				local target, err = storage.target(value)
				assert.is_nil(target)
				assert.are.equal("Invalid pull request target", err)
			end
		end)
	end)

	describe("parse", function()
		it("reads a ref back into its target", function()
			local target = storage.parse("gitlab.com/group/sub/repo/pr-1")

			assert.are.equal("gitlab.com/group/sub/repo/pr-1", target and target.ref)
			assert.is_nil(storage.parse("https://github.com/owner/repo/pull/2"))
		end)
	end)

	describe("dir", function()
		it("places a pull request under its host and repository", function()
			local target = storage.target({ host = "gitlab.com", repository = "group/sub/repo", id = "1" })
			---@cast target AtlasStorageTarget

			assert.are.equal("/tmp/atlas/gitlab.com/group/sub/repo/pr-1", storage.dir(target))
		end)
	end)
end)
