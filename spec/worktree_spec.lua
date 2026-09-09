local worktree = require("atlas.core.git.worktree")
local core_git = require("atlas.core.git")
local logger = require("atlas.core.logger")

---@param overrides table|nil
---@return AtlasWorktreeContext
local function context(overrides)
	local ctx = {
		repo_root = "/home/dev/code/atlas.nvim",
		repo_full_name = "emrearmagan/atlas.nvim",
		head_sha = "abcdef0123456789abcdef0123456789abcdef01",
	}
	for key, value in pairs(overrides or {}) do
		ctx[key] = value
	end
	return ctx
end

-- Scripted git runner: answers each command from `responses`, keyed by the subcommand that follows
-- `-C <path>`. Records every invocation so specs can assert what ran and what did not.
---@param responses table<string, { code: integer, stdout: string|nil, stderr: string|nil }>
---@return { calls: string[][] }
local function fake_git(responses)
	local recorder = { calls = {} }
	core_git.run = function(args, _, on_done)
		table.insert(recorder.calls, args)
		local key = args[3] .. (args[4] and (" " .. args[4]) or "")
		local response = responses[key] or responses[args[3]] or { code = 1, stderr = "unexpected: " .. key }
		on_done({
			code = response.code,
			stdout = response.stdout or "",
			stderr = response.stderr or "",
			signal = 0,
		})
		return { cancel = function() end }
	end
	return recorder
end

---@param calls string[][]
---@param subcommand string
---@return boolean
local function ran(calls, subcommand)
	for _, args in ipairs(calls) do
		if args[3] == "worktree" and args[4] == subcommand then
			return true
		end
	end
	return false
end

describe("worktree", function()
	describe("default_dir", function()
		it("slugifies the repo name and truncates the sha", function()
			local dir = worktree.default_dir(context())

			assert.equals(worktree.cache_root() .. "/emrearmagan-atlas-nvim/abcdef012345", dir)
		end)

		it("prefers the pull request number over the sha", function()
			local dir = worktree.default_dir(context({ pr_id = 1234 }))

			assert.equals(worktree.cache_root() .. "/emrearmagan-atlas-nvim/pr-1234", dir)
		end)

		it("falls back to the repo root basename", function()
			local dir = worktree.default_dir(context({ repo_full_name = nil }))

			assert.is_truthy(dir:find("atlas-nvim/abcdef012345", 1, true))
		end)

		it("ignores trailing separators on the repo root", function()
			local dir = worktree.default_dir(context({ repo_full_name = "", repo_root = "/home/dev/code/atlas.nvim/" }))

			assert.is_truthy(dir:find("atlas-nvim/abcdef012345", 1, true))
		end)

		it("gives different commits different directories", function()
			local first = worktree.default_dir(context())
			local second = worktree.default_dir(context({ head_sha = "0123456789abcdef0123456789abcdef01234567" }))

			assert.are_not.equals(first, second)
		end)

		it("gives different pull requests different directories", function()
			local first = worktree.default_dir(context({ pr_id = 1 }))
			local second = worktree.default_dir(context({ pr_id = 2 }))

			assert.are_not.equals(first, second)
		end)
	end)

	describe("resolve_dir", function()
		it("returns the default when no override is configured", function()
			local ctx = context()

			assert.equals(worktree.default_dir(ctx), worktree.resolve_dir(ctx, nil))
			assert.equals(worktree.default_dir(ctx), worktree.resolve_dir(ctx, { enabled = true }))
		end)

		it("accepts an absolute string override", function()
			local dir = worktree.resolve_dir(context(), { dir = "/var/tmp/review" })

			assert.equals("/var/tmp/review", dir)
		end)

		it("strips trailing separators from an override", function()
			local dir = worktree.resolve_dir(context(), { dir = "/var/tmp/review/" })

			assert.equals("/var/tmp/review", dir)
		end)

		it("rejects a relative string override", function()
			local dir, err = worktree.resolve_dir(context(), { dir = "review" })

			assert.is_nil(dir)
			assert.is_truthy(err)
		end)

		it("calls a function override with the context and the default", function()
			local seen
			local dir = worktree.resolve_dir(context(), {
				dir = function(ctx)
					seen = ctx
					return "/var/tmp/" .. ctx.head_sha:sub(1, 7)
				end,
			})

			assert.equals("/var/tmp/abcdef0", dir)
			assert.equals("emrearmagan/atlas.nvim", seen.repo_full_name)
			assert.equals("/home/dev/code/atlas.nvim", seen.repo_root)
			assert.equals(worktree.default_dir(context()), seen.default)
		end)

		it("falls back to the default when the function returns nil or empty", function()
			local ctx = context()

			assert.equals(
				worktree.default_dir(ctx),
				worktree.resolve_dir(ctx, {
					dir = function()
						return nil
					end,
				})
			)
			assert.equals(
				worktree.default_dir(ctx),
				worktree.resolve_dir(ctx, {
					dir = function()
						return ""
					end,
				})
			)
		end)

		it("reports an error when the function raises", function()
			local dir, err = worktree.resolve_dir(context(), {
				dir = function()
					error("boom")
				end,
			})

			assert.is_nil(dir)
			assert.is_truthy(err and err:find("boom", 1, true))
		end)

		it("rejects a non-string return value", function()
			local dir, err = worktree.resolve_dir(context(), {
				dir = function()
					return 42
				end,
			})

			assert.is_nil(dir)
			assert.is_truthy(err)
		end)
	end)

	describe("validate", function()
		it("accepts an absent or empty config", function()
			assert.is_true(worktree.validate(nil))
			assert.is_true(worktree.validate({}))
		end)

		it("accepts a well formed config", function()
			assert.is_true(worktree.validate({
				enabled = true,
				dir = "/var/tmp/review",
				link = { "node_modules", ".venv", "packages/app/node_modules" },
			}))
		end)

		it("rejects a non-boolean enabled", function()
			assert.is_false(worktree.validate({ enabled = "yes" }))
		end)

		it("rejects a dir that is neither string nor function", function()
			assert.is_false(worktree.validate({ dir = 42 }))
		end)

		it("rejects a relative dir string", function()
			assert.is_false(worktree.validate({ dir = "review" }))
		end)

		it("rejects link entries that are not strings", function()
			assert.is_false(worktree.validate({ link = { 42 } }))
			assert.is_false(worktree.validate({ link = { "" } }))
		end)

		it("rejects absolute link entries", function()
			assert.is_false(worktree.validate({ link = { "/etc" } }))
		end)

		it("rejects link entries that escape the repository", function()
			assert.is_false(worktree.validate({ link = { ".." } }))
			assert.is_false(worktree.validate({ link = { "../secrets" } }))
			assert.is_false(worktree.validate({ link = { "packages/../../secrets" } }))
			assert.is_false(worktree.validate({ link = { "packages/.." } }))
		end)

		it("rejects linking the git directory", function()
			assert.is_false(worktree.validate({ link = { ".git" } }))
			assert.is_false(worktree.validate({ link = { ".git/hooks" } }))
		end)
	end)

	describe("claim", function()
		before_each(function()
			for _, dir in ipairs(worktree.claimed_dirs()) do
				worktree.release(dir)
			end
		end)

		it("hands out the resolved directory when it is free", function()
			local ctx = context()
			local dir = worktree.claim(ctx, nil)

			assert.equals(worktree.default_dir(ctx), dir)
			assert.is_true(worktree.is_claimed(dir))
		end)

		it("suffixes the directory while another session holds it", function()
			local ctx = context()
			local first = worktree.claim(ctx, nil)
			local second = worktree.claim(ctx, nil)

			assert.are_not.equals(first, second)
			assert.equals(first .. "-2", second)
		end)

		it("reuses a released directory", function()
			local ctx = context()
			local first = worktree.claim(ctx, nil)
			worktree.release(first)
			local second = worktree.claim(ctx, nil)

			assert.equals(first, second)
			assert.is_false(worktree.is_claimed(first .. "-2"))
		end)

		it("propagates resolution errors", function()
			local dir, err = worktree.claim(context(), { dir = "relative" })

			assert.is_nil(dir)
			assert.is_truthy(err)
		end)
	end)

	describe("is_cache_path", function()
		it("accepts directories below the cache root", function()
			assert.is_true(worktree.is_cache_path(worktree.cache_root() .. "/repo/pr-1"))
			assert.is_true(worktree.is_cache_path(worktree.cache_root() .. "/repo/pr-1/"))
		end)

		it("rejects the cache root itself", function()
			assert.is_false(worktree.is_cache_path(worktree.cache_root()))
			assert.is_false(worktree.is_cache_path(worktree.cache_root() .. "/"))
		end)

		it("rejects paths outside the cache root", function()
			assert.is_false(worktree.is_cache_path("/home/dev/reviews"))
			assert.is_false(worktree.is_cache_path(worktree.cache_root() .. "-other/repo"))
			assert.is_false(worktree.is_cache_path(""))
		end)
	end)

	describe("parse_worktree_list", function()
		it("returns every worktree path from porcelain output", function()
			local paths = worktree.parse_worktree_list(table.concat({
				"worktree /home/dev/code/atlas.nvim",
				"HEAD 0123456789abcdef0123456789abcdef01234567",
				"branch refs/heads/main",
				"",
				"worktree /tmp/atlas/worktrees/repo/pr-1",
				"HEAD abcdef0123456789abcdef0123456789abcdef01",
				"detached",
				"",
			}, "\n"))

			assert.same({ "/home/dev/code/atlas.nvim", "/tmp/atlas/worktrees/repo/pr-1" }, paths)
		end)

		it("handles empty output", function()
			assert.same({}, worktree.parse_worktree_list(""))
			assert.same({}, worktree.parse_worktree_list(nil))
		end)
	end)

	describe("remove and ensure on existing directories", function()
		local original_run = core_git.run
		local original_fn = vim.fn
		local original_uv = vim.uv
		local original_logwarn = logger.logwarn
		local original_loginfo = logger.loginfo
		local deleted
		local warnings

		before_each(function()
			deleted = {}
			warnings = {}
			vim.fn = setmetatable({
				isdirectory = function()
					return 1
				end,
				mkdir = function() end,
				delete = function(path)
					table.insert(deleted, path)
					return 0
				end,
			}, { __index = original_fn })
			vim.uv = setmetatable({
				fs_realpath = function(path)
					return path
				end,
			}, { __index = original_uv or {} })
			logger.logwarn = function(message)
				table.insert(warnings, message)
			end
			logger.loginfo = function() end
		end)

		after_each(function()
			core_git.run = original_run
			vim.fn = original_fn
			vim.uv = original_uv
			logger.logwarn = original_logwarn
			logger.loginfo = original_loginfo
		end)

		it("remove deletes by hand only below the cache root", function()
			local inside = worktree.cache_root() .. "/repo/pr-1"
			local outside = "/home/dev/reviews"
			fake_git({
				["worktree remove"] = { code = 128, stderr = "not a working tree" },
				["worktree prune"] = { code = 0 },
			})

			worktree.remove("/home/dev/code/atlas.nvim", inside)
			worktree.remove("/home/dev/code/atlas.nvim", outside)

			assert.same({ inside }, deleted)
		end)

		it("ensure refuses an existing directory that is not a worktree of the repository", function()
			local calls = fake_git({
				["worktree list"] = {
					code = 0,
					stdout = "worktree /home/dev/code/atlas.nvim\nHEAD 0123\nbranch refs/heads/main\n\n",
				},
			})
			local result, err

			worktree.ensure({
				repo_root = "/home/dev/code/atlas.nvim",
				head_sha = "abcdef0123456789abcdef0123456789abcdef01",
				dir = "/home/dev/reviews",
			}, function(dir, ensure_err)
				result, err = dir, ensure_err
			end)

			assert.is_nil(result)
			assert.is_truthy(err and err:find("not a worktree", 1, true))
			assert.same({}, deleted)
			assert.is_false(ran(calls.calls, "add"))
			assert.is_false(ran(calls.calls, "remove"))
		end)

		it("ensure rebuilds an unregistered directory below the cache root", function()
			local dir = worktree.cache_root() .. "/repo/pr-1"
			local calls = fake_git({
				["worktree list"] = { code = 0, stdout = "worktree /home/dev/code/atlas.nvim\n\n" },
				["worktree remove"] = { code = 128, stderr = "not a working tree" },
				["worktree prune"] = { code = 0 },
				["worktree add"] = { code = 0 },
			})
			local result

			worktree.ensure({
				repo_root = "/home/dev/code/atlas.nvim",
				head_sha = "abcdef0123456789abcdef0123456789abcdef01",
				dir = dir,
			}, function(created)
				result = created
			end)

			assert.equals(dir, result)
			assert.same({ dir }, deleted)
			assert.is_true(ran(calls.calls, "add"))
		end)

		it("ensure reuses a registered worktree at the same head", function()
			local dir = "/home/dev/reviews"
			local calls = fake_git({
				["worktree list"] = {
					code = 0,
					stdout = "worktree /home/dev/code/atlas.nvim\n\nworktree " .. dir .. "\ndetached\n\n",
				},
				["rev-parse"] = { code = 0, stdout = "abcdef0123456789abcdef0123456789abcdef01\n" },
			})
			local result

			worktree.ensure({
				repo_root = "/home/dev/code/atlas.nvim",
				head_sha = "abcdef0123456789abcdef0123456789abcdef01",
				dir = dir,
			}, function(created)
				result = created
			end)

			assert.equals(dir, result)
			assert.same({}, deleted)
			assert.is_false(ran(calls.calls, "add"))
			assert.is_false(ran(calls.calls, "remove"))
		end)

		it("ensure recreates a registered worktree at a different head", function()
			local dir = "/home/dev/reviews"
			local calls = fake_git({
				["worktree list"] = { code = 0, stdout = "worktree " .. dir .. "\ndetached\n\n" },
				["rev-parse"] = { code = 0, stdout = "0123456789abcdef0123456789abcdef01234567\n" },
				["worktree remove"] = { code = 0 },
				["worktree add"] = { code = 0 },
			})
			local result

			worktree.ensure({
				repo_root = "/home/dev/code/atlas.nvim",
				head_sha = "abcdef0123456789abcdef0123456789abcdef01",
				dir = dir,
			}, function(created)
				result = created
			end)

			assert.equals(dir, result)
			assert.same({}, deleted)
			assert.is_true(ran(calls.calls, "remove"))
			assert.is_true(ran(calls.calls, "add"))
		end)
	end)
end)
