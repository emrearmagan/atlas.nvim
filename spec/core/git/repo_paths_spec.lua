local repo_paths = require("atlas.core.git.repo_paths")

describe("core.git.repo_paths", function()
	it("fails when wildcard parity is wrong", function()
		local path, err = repo_paths.resolve({ ["ws/*"] = "~/code/no-star" }, "ws/repo")
		assert.is_nil(path)
		assert.matches("wildcard parity mismatch", assert(err), 1, true)
	end)

	it("rejects missing or empty namespace and repository segments", function()
		for _, key in ipairs({ "bad", "/group/repo", "group//repo", "group/subgroup/", "group/subgroup//repo" }) do
			local mapped_path, mapped_err = repo_paths.resolve({ [key] = "~/x" }, "ws/repo")
			assert.is_nil(mapped_path)
			assert.matches("invalid key", assert(mapped_err), 1, true)
			local path, err = repo_paths.resolve({}, key)
			assert.is_nil(path)
			assert.matches("invalid repository identifier", assert(err), 1, true)
		end
	end)

	it("resolves exact mapping over wildcard", function()
		for _, namespace in ipairs({ "ws", "group/subgroup", "group/subgroup/team" }) do
			local path = repo_paths.resolve({
				[namespace .. "/*"] = "~/code/*",
				[namespace .. "/repo"] = "~/code/special",
			}, namespace .. "/repo")
			assert.matches("special", assert(path))
		end
	end)

	it("prefers more specific wildcard", function()
		for _, namespace in ipairs({ "ws", "group/subgroup" }) do
			local path = repo_paths.resolve({
				[namespace .. "/*"] = "~/code/*",
				[namespace .. "/proj-*"] = "~/work/proj-*",
			}, namespace .. "/proj-foo")
			assert.matches("/work/proj%-foo$", assert(path))
		end
	end)

	it("substitutes multiple captures in order", function()
		for _, namespace in ipairs({ "ws", "group/subgroup" }) do
			local path =
				repo_paths.resolve({ [namespace .. "/proj-*-v*"] = "~/code/*/v*" }, namespace .. "/proj-foo-v2")
			assert.matches("/code/foo/v2$", assert(path))
		end
	end)

	it("does not match across namespaces", function()
		for _, repo in ipairs({ "other/repo", "ws/subgroup/repo" }) do
			local path, err = repo_paths.resolve({ ["ws/*"] = "~/code/*" }, repo)
			assert.is_nil(path)
			assert.matches("no repo_paths mapping", assert(err), 1, true)
		end
	end)
end)
