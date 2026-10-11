local config = require("atlas.config")
local git = require("atlas.core.git")
local checkout = require("atlas.core.git.checkout")

local function resolve(paths, repo)
	return checkout.resolve_repo_path(paths, repo, {
		require_existing = false,
	})
end

describe("core.git.checkout", function()
	it("uses the pull request snapshot commits for diffs", function()
		local base, head = checkout.pr_diff_revisions({
			destination = { commit_hash = "base123" },
			source = { commit_hash = "head456" },
		})

		assert.equal("base123", base)
		assert.equal("head456", head)
	end)

	describe("validate", function()
		it("fails when wildcard parity is wrong", function()
			local ok = checkout.validate_repo_paths({
				["ws/*"] = "~/code/no-star",
			})

			assert.is_false(ok)
		end)

		it("rejects missing or empty namespace and repository segments", function()
			for _, key in ipairs({ "bad", "/group/repo", "group//repo", "group/subgroup/", "group/subgroup//repo" }) do
				local ok = checkout.validate_repo_paths({ [key] = "~/x" })
				assert.is_false(ok)
				local path, err = resolve({}, key)
				assert.is_nil(path)
				assert.is_truthy(err:find("invalid repository identifier", 1, true))
			end
		end)
	end)

	describe("resolve", function()
		it("resolves exact mapping over wildcard", function()
			for _, namespace in ipairs({ "ws", "group/subgroup", "group/subgroup/team" }) do
				local path = resolve({
					[namespace .. "/*"] = "~/code/*",
					[namespace .. "/repo"] = "~/code/special",
				}, namespace .. "/repo")

				assert.is_string(path)
				assert.is_truthy(path:find("special"))
			end
		end)

		it("prefers more specific wildcard", function()
			for _, namespace in ipairs({ "ws", "group/subgroup" }) do
				local path = resolve({
					[namespace .. "/*"] = "~/code/*",
					[namespace .. "/proj-*"] = "~/work/proj-*",
				}, namespace .. "/proj-foo")
				assert.is_truthy(path:find("/work/proj%-foo$"))
			end
		end)

		it("substitutes multiple captures in order", function()
			for _, namespace in ipairs({ "ws", "group/subgroup" }) do
				local path = resolve({ [namespace .. "/proj-*-v*"] = "~/code/*/v*" }, namespace .. "/proj-foo-v2")
				assert.is_truthy(path:find("/code/foo/v2$"))
			end
		end)

		it("does not match across namespaces", function()
			for _, repo in ipairs({ "other/repo", "ws/subgroup/repo" }) do
				local path, err = resolve({ ["ws/*"] = "~/code/*" }, repo)
				assert.is_nil(path)
				assert.is_truthy(err:find("no repo_paths mapping", 1, true))
			end
		end)
	end)

	describe("mapped pull request workflows", function()
		local original_options, original_isdirectory, original_git
		local pending, cancelled, checked_commits, checked_out, pr
		local cases = {
			{ provider = "github", host = "github.com", repo = "owner/repo", path = "pull/1" },
			{ provider = "gitlab", host = "gitlab.com", repo = "group/subgroup/repo", path = "-/merge_requests/1" },
			{ provider = "bitbucket", host = "bitbucket.org", repo = "owner/repo", path = "pull-requests/1" },
		}
		local function use_repository(case)
			config.options.pulls.repo_config.paths = { [case.repo] = "/mapped" }
			pr = {
				provider = case.provider,
				repo_full_name = case.repo,
				link = { html = "https://" .. case.host .. "/" .. case.repo .. "/" .. case.path },
				source = { branch = "feature", commit_hash = "head" },
				destination = { commit_hash = "base" },
			}
		end

		before_each(function()
			original_options, original_isdirectory = config.options, vim.fn.isdirectory
			original_git = {}
			for _, name in ipairs({ "run", "repo_root", "check_commits", "rev_exists", "checkout_branch" }) do
				original_git[name] = git[name]
			end
			pending, cancelled, checked_commits, checked_out = nil, false, false, false
			config.options = {
				providers = {
					github = { hostname = "github.com" },
					gitlab = { base_url = "https://gitlab.com" },
					bitbucket = {},
				},
				pulls = { repo_config = {} },
			}
			vim.fn.isdirectory = function()
				return 1
			end
			-- Keep the real remote lookup and provider resolvers; finish Git asynchronously.
			git.run = function(args, _, done)
				assert.same({ "-C", "/mapped", "remote", "get-url", "origin" }, args)
				pending = done
				return {
					cancel = function()
						cancelled = true
					end,
				}
			end
			git.repo_root = function(root, done)
				done(root == "/mapped" and root or nil)
			end
			git.check_commits = function(root, revisions, done)
				assert.equal("/mapped", root)
				assert.same({ "base", "head" }, revisions)
				checked_commits = true
				done({ true, true }, nil)
			end
			git.rev_exists = function(_, _, done)
				done(true)
			end
			git.checkout_branch = function(root, branch, done)
				checked_out = { repo_path = root, local_branch = branch }
				done(true, nil)
			end
			use_repository(cases[1])
		end)

		after_each(function()
			config.options, vim.fn.isdirectory = original_options, original_isdirectory
			for name, value in pairs(original_git) do
				git[name] = value
			end
		end)

		local function complete_remote(remote)
			pending({ code = 0, stdout = remote .. "\n" })
		end

		it("opens mapped PR diffs from outside the repository for each supported provider", function()
			for _, case in ipairs(cases) do
				use_repository(case)
				local result
				checkout.prepare_diff(pr, "/outside", function() end, function(source, err)
					assert.is_nil(err)
					result = source
				end)
				local remote = case.provider == "gitlab" and ("https://" .. case.host .. "/" .. case.repo .. ".git")
					or ("git@" .. case.host .. ":" .. case.repo .. ".git")
				complete_remote(remote)
				assert.same({ root = "/mapped", base_revision = "base", head_revision = "head" }, result)
			end
		end)

		it("refuses to check out a mapped repository belonging to another provider", function()
			local result, failure
			checkout.checkout_pr(pr, function(value, err)
				result, failure = value, err
			end)
			complete_remote("https://gitlab.com/owner/repo.git")
			assert.is_nil(result)
			assert.equal("mapped repository does not match the pull request remote: /mapped", failure)
			assert.is_false(checked_out)
		end)

		it("stops a cancelled diff before fetching or opening the mapped repository", function()
			local called = false
			local request = checkout.prepare_diff(pr, "/outside", function() end, function()
				called = true
			end)
			request.cancel()
			complete_remote("https://github.com/owner/repo.git")
			assert.is_true(cancelled)
			assert.is_false(called)
			assert.is_false(checked_commits)
		end)

		it("checks out the PR branch in the mapped repository", function()
			local result
			checkout.checkout_pr(pr, function(value, err)
				assert.is_nil(err)
				result = value
			end)
			complete_remote("https://github.com/owner/repo.git")
			assert.same({ repo_path = "/mapped", local_branch = "feature" }, checked_out)
			assert.same(checked_out, result)
		end)

		it("passes mapped paths to custom actions, including configured SSH aliases", function()
			local invoked, completed
			config.options.pulls.custom_actions = {
				{
					id = "test",
					label = "Test",
					run = function(_, ctx, done)
						invoked = ctx.repo_path
						done(true)
					end,
				},
			}
			local action = require("atlas.pulls.actions.utils").find_custom_action("test")
			for _, remote in ipairs({ "https://github.com/owner/repo.git", "git@my-github-alias:owner/repo.git" }) do
				invoked, completed = nil, false
				action.run({ pr = pr, notify = function() end }, function(_, err)
					assert.is_nil(err)
					completed = true
				end)
				complete_remote(remote)
				assert.equal("/mapped", invoked)
				assert.is_true(completed)
			end
		end)
	end)
end)
