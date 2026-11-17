local core_git = require("atlas.core.git")
local logger = require("atlas.core.logger")

local CACHE = vim.fn.stdpath("cache") .. "/atlas/worktrees"
local DEFAULT = CACHE .. "/owner-repo/abcdef012345"

local function fresh()
	package.loaded["atlas.core.git.worktree"] = nil
	return (require("atlas.core.git.worktree"))
end

---@param worktree table
---@param cfg table|nil
---@return string|nil dir
---@return string|nil err
local function claim(worktree, cfg)
	local ctx, err = worktree.claim(
		"/home/dev/code/atlas.nvim",
		"abcdef0123456789abcdef0123456789abcdef01",
		{ repo_full_name = "owner/repo" },
		cfg
	)
	return ctx and ctx.dir, err
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
	local worktree

	before_each(function()
		worktree = fresh()
	end)

	describe("claim directory", function()
		it("separates commits and pull requests under the repository slug", function()
			local root = "/home/dev/code/atlas.nvim"
			for _, case in ipairs({
				{ "abcdef0123456789abcdef0123456789abcdef01", nil, "abcdef012345" },
				{ "0123456789abcdef0123456789abcdef01234567", nil, "0123456789ab" },
				{ "abcdef0123456789abcdef0123456789abcdef01", 1234, "pr-1234" },
				{ "abcdef0123456789abcdef0123456789abcdef01", 2, "pr-2" },
			}) do
				local ctx = fresh().claim(root, case[1], { repo_full_name = "owner/repo", id = case[2] })
				assert.equal(CACHE .. "/owner-repo/" .. case[3], ctx and ctx.dir)
			end
		end)

		it("falls back to the repo root basename", function()
			for _, root in ipairs({ "/home/dev/code/atlas.nvim", "/home/dev/code/atlas.nvim/" }) do
				local ctx = fresh().claim(root, "abcdef0123456789abcdef0123456789abcdef01", nil)
				assert.equal(CACHE .. "/atlas-nvim/abcdef012345", ctx and ctx.dir)
			end
		end)

		it("uses the default when no override is configured", function()
			assert.equal(DEFAULT, claim(fresh()))
			assert.equal(DEFAULT, claim(fresh(), { link = {} }))
		end)

		it("accepts an absolute string override", function()
			for _, dir in ipairs({ "/var/tmp/review", "/var/tmp/review/" }) do
				assert.equal("/var/tmp/review", claim(fresh(), { dir = dir }))
			end
		end)

		it("rejects a relative string override", function()
			local dir, err = claim(worktree, { dir = "review" })

			assert.is_nil(dir)
			assert.is_truthy(err)
		end)

		it("calls a function override with the context and the default", function()
			local seen
			local dir = claim(worktree, {
				dir = function(ctx)
					seen = ctx
					return "/var/tmp/" .. ctx.head_sha:sub(1, 7)
				end,
			})

			assert.equal("/var/tmp/abcdef0", dir)
			assert.equal("owner/repo", seen.repo_full_name)
			assert.equal("/home/dev/code/atlas.nvim", seen.repo_root)
			assert.equal(DEFAULT, seen.dir)
		end)

		it("uses the default when the function returns nil", function()
			assert.equal(
				DEFAULT,
				claim(worktree, {
					dir = function()
						return nil
					end,
				})
			)
		end)

		it("reports an error when the function raises", function()
			local dir, err = claim(worktree, {
				dir = function()
					error("boom")
				end,
			})

			assert.is_nil(dir)
			assert.is_truthy(err and err:find("boom", 1, true))
		end)

		it("rejects a non-string return value", function()
			---@type any
			local invalid_dir = function()
				return 42
			end
			local dir, err = claim(worktree, { dir = invalid_dir })

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
				dir = "/var/tmp/review",
				link = { "node_modules", ".venv", "packages/app/node_modules" },
				on_create = function() end,
			}))
		end)

		it("rejects invalid directory and hook settings", function()
			for _, config in ipairs({ { dir = 42 }, { dir = "review" }, { on_create = "cmake" } }) do
				assert.is_false(worktree.validate(config))
			end
		end)

		it("rejects link entries that are not strings", function()
			assert.is_false(worktree.validate({ link = { 42 } } --[[@as any]]))
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

	describe("remove and ensure on existing directories", function()
		local original_run = core_git.run
		local original_fn = vim.fn
		local original_uv = vim.uv
		local original_logwarn = logger.logwarn
		local original_loginfo = logger.loginfo
		local deleted

		before_each(function()
			deleted = {}
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
			logger.logwarn = function() end
			logger.loginfo = function() end
		end)

		after_each(function()
			core_git.run = original_run
			vim.fn = original_fn
			vim.uv = original_uv
			logger.logwarn = original_logwarn
			logger.loginfo = original_loginfo
		end)

		it("isolates simultaneous sessions and reuses a directory only after discard", function()
			fake_git({ ["worktree remove"] = { code = 0 } })
			local first = assert(claim(worktree))
			local second = assert(claim(worktree))

			assert.equal(DEFAULT, first)
			assert.equal(first .. "-2", second)

			worktree.discard("/home/dev/code/atlas.nvim", first)
			assert.equal(first, claim(worktree))
			assert.equal(first .. "-3", claim(worktree))
		end)

		it("force-removes only worktrees below the cache root", function()
			local forces = {}
			core_git.run = function(args, _, on_done)
				local force_count = 0
				for _, arg in ipairs(args) do
					if arg == "--force" then
						force_count = force_count + 1
					end
				end
				forces[args[#args]] = force_count
				on_done({ code = 0, stdout = "", stderr = "" })
				return { cancel = function() end }
			end

			for _, dir in ipairs({ CACHE .. "/repo/pr-1", CACHE .. "/repo/pr-2/", CACHE, CACHE .. "/" }) do
				worktree.discard("/home/dev/code/atlas.nvim", dir)
			end
			worktree.discard("/home/dev/code/atlas.nvim", "/home/dev/reviews")
			worktree.discard("/home/dev/code/atlas.nvim", CACHE .. "-other/repo")

			assert.same({
				[CACHE .. "/repo/pr-1"] = 2,
				[CACHE .. "/repo/pr-2/"] = 2,
				[CACHE] = 1,
				[CACHE .. "/"] = 1,
				["/home/dev/reviews"] = 1,
				[CACHE .. "-other/repo"] = 1,
			}, forces)
		end)

		it("remove deletes by hand only below the cache root", function()
			local inside = CACHE .. "/repo/pr-1"
			local outside = "/home/dev/reviews"
			fake_git({
				["worktree remove"] = { code = 128, stderr = "not a working tree" },
				["worktree prune"] = { code = 0 },
			})

			worktree.discard("/home/dev/code/atlas.nvim", inside)
			worktree.discard("/home/dev/code/atlas.nvim", outside)

			assert.same({ inside }, deleted)
		end)

		it("removes locked cache worktrees through git while preserving locked custom worktrees", function()
			local inside = CACHE .. "/repo/pr-1"
			local outside = "/home/dev/reviews"
			local removed = {}
			core_git.run = function(args, _, on_done)
				local code = 0
				if args[4] == "remove" then
					local force_count = 0
					for _, arg in ipairs(args) do
						if arg == "--force" then
							force_count = force_count + 1
						end
					end
					if force_count == 2 then
						table.insert(removed, args[#args])
					else
						code = 128
					end
				end
				on_done({ code = code, stderr = code ~= 0 and "worktree is locked" or "" })
				return { cancel = function() end }
			end

			worktree.discard("/home/dev/code/atlas.nvim", inside)
			worktree.discard("/home/dev/code/atlas.nvim", outside)

			assert.same({ inside }, removed)
			assert.same({}, deleted)
		end)

		it("ensure takes over a deleted worktree path, even a locked one below the cache root", function()
			local inside = CACHE .. "/repo/pr-1"
			local outside = "/home/dev/reviews"
			local forces = {}
			vim.fn.isdirectory = function()
				return 0
			end
			core_git.run = function(args, _, on_done)
				local force_count = 0
				for _, arg in ipairs(args) do
					if arg == "--force" then
						force_count = force_count + 1
					end
				end
				forces[args[#args - 1]] = force_count
				on_done({ code = 0, stdout = "", stderr = "" })
				return { cancel = function() end }
			end

			for _, dir in ipairs({ inside, outside }) do
				worktree.ensure({
					repo_root = "/home/dev/code/atlas.nvim",
					head_sha = "abcdef0123456789abcdef0123456789abcdef01",
					dir = dir,
				}, nil, function() end)
			end

			assert.same({ [inside] = 2, [outside] = 1 }, forces)
		end)

		it("ensure refuses an existing directory that is not a worktree of the repository", function()
			local calls = fake_git({
				["worktree list"] = {
					code = 0,
					stdout = "worktree /home/dev/code/atlas.nvim\nHEAD 0123\nbranch refs/heads/main\n\n",
				},
			})
			local result, err

			worktree.ensure(
				{
					repo_root = "/home/dev/code/atlas.nvim",
					head_sha = "abcdef0123456789abcdef0123456789abcdef01",
					dir = "/home/dev/reviews",
				},
				nil,
				function(dir, ensure_err)
					result, err = dir, ensure_err
				end
			)

			assert.is_nil(result)
			assert.is_truthy(err and err:find("not a worktree", 1, true))
			assert.same({}, deleted)
			assert.is_false(ran(calls.calls, "add"))
			assert.is_false(ran(calls.calls, "remove"))
		end)

		it("ensure rebuilds an unregistered directory below the cache root", function()
			local dir = CACHE .. "/repo/pr-1"
			local calls = fake_git({
				["worktree list"] = { code = 0, stdout = "worktree /home/dev/code/atlas.nvim\n\n" },
				["worktree remove"] = { code = 128, stderr = "not a working tree" },
				["worktree prune"] = { code = 0 },
				["worktree add"] = { code = 0 },
			})
			local result

			worktree.ensure(
				{
					repo_root = "/home/dev/code/atlas.nvim",
					head_sha = "abcdef0123456789abcdef0123456789abcdef01",
					dir = dir,
				},
				nil,
				function(created)
					result = created
				end
			)

			assert.equal(dir, result)
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
			local hooked = false

			worktree.ensure({
				repo_root = "/home/dev/code/atlas.nvim",
				head_sha = "abcdef0123456789abcdef0123456789abcdef01",
				dir = dir,
			}, {
				on_create = function()
					hooked = true
				end,
			}, function(created)
				result = created
			end)

			assert.equal(dir, result)
			assert.same({}, deleted)
			assert.is_false(ran(calls.calls, "add"))
			assert.is_false(ran(calls.calls, "remove"))
			assert.is_false(hooked)
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
			local hook_ctx

			worktree.ensure({
				repo_root = "/home/dev/code/atlas.nvim",
				repo_full_name = "owner/repo",
				pr_id = 7,
				head_sha = "abcdef0123456789abcdef0123456789abcdef01",
				dir = dir,
			}, {
				on_create = function(ctx, done)
					hook_ctx = ctx
					done()
				end,
			}, function(created)
				result = created
			end)

			assert.equal(dir, result)
			assert.same({}, deleted)
			assert.is_true(ran(calls.calls, "remove"))
			assert.is_true(ran(calls.calls, "add"))
			assert.same({
				dir = dir,
				repo_root = "/home/dev/code/atlas.nvim",
				repo_full_name = "owner/repo",
				pr_id = 7,
				head_sha = "abcdef0123456789abcdef0123456789abcdef01",
			}, hook_ctx)
		end)

		it("cancels recreation during removal or fallback pruning", function()
			for _, stage in ipairs({ "remove", "prune" }) do
				local calls, pending, cancelled = {}, nil, false
				local completed = false
				core_git.run = function(args, _, on_done)
					table.insert(calls, args[4])
					if args[4] == stage then
						pending = on_done
					else
						on_done({ code = args[4] == "remove" and 128 or 0, stdout = "", stderr = "" })
					end
					return {
						cancel = function()
							assert.equal(stage, args[4])
							cancelled = true
						end,
					}
				end

				local handle = worktree.ensure(
					{
						repo_root = "/home/dev/code/atlas.nvim",
						head_sha = "abcdef0123456789abcdef0123456789abcdef01",
						dir = CACHE .. "/repo/pr-1",
					},
					nil,
					function()
						completed = true
					end
				)

				handle.cancel()
				assert.is_true(cancelled)
				assert(pending)({ code = 0, stdout = "", stderr = "" })
				assert.is_false(completed)
				assert.same(stage == "remove" and { "list", "remove" } or { "list", "remove", "prune" }, calls)
			end
		end)
	end)
end)
