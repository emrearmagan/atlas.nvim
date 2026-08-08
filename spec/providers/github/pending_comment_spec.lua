local github_client = require("spec.support.github_client_stub")

local function fresh_module()
	package.loaded["atlas.pulls.providers.github.api.comments"] = nil
	return require("atlas.pulls.providers.github.api.comments")
end

---@param args string[]
---@return table<string, string>
local function gh_flags(args)
	local flags = {}
	for index, value in ipairs(args) do
		if value == "-f" or value == "-F" then
			local key, rest = tostring(args[index + 1]):match("^([^=]+)=(.*)$")
			flags[key] = rest
		end
	end
	return flags
end

---@param raw table|nil overrides for the PR's `_raw` (e.g. a cached pending review)
local function pull_request(raw)
	return { id = "7", repo_full_name = "octo/repo", _raw = raw or {} }
end

local function pending_comment(overrides)
	return vim.tbl_extend("force", {
		id = 4242,
		content_raw = "updated body",
		state = "PENDING",
		inline = { path = "lua/init.lua", to = 12 },
		_raw = {
			comment_id = "PRRC_node",
			thread_id = "PRRT_node",
			review_id = "PRR_node",
		},
	}, overrides or {})
end

describe("github pending review comments", function()
	local gh_calls, api_calls

	before_each(function()
		gh_calls, api_calls = {}, {}
	end)

	after_each(function()
		github_client.uninstall()
		package.loaded["atlas.pulls.providers.github.api.comments"] = nil
	end)

	describe("edit_comment", function()
		it("updates a pending comment over GraphQL instead of REST", function()
			github_client.install({
				gh = function(args, callback)
					table.insert(gh_calls, args)
					callback({
						data = {
							updatePullRequestReviewComment = {
								pullRequestReviewComment = {
									id = "PRRC_node",
									databaseId = 4242,
									body = "updated body",
									url = "https://github.test/c/4242",
									createdAt = "2026-08-07T10:00:00Z",
									author = { login = "octocat", databaseId = 1 },
									pullRequestReview = { id = "PRR_node", state = "PENDING" },
								},
							},
						},
					}, nil)
				end,
				api = function(_, _, _, callback)
					table.insert(api_calls, true)
					callback(nil, "REST should not be used")
				end,
			})
			local api = fresh_module()

			local updated, err
			api.edit_comment(pull_request(), pending_comment(), function(result, e)
				updated, err = result, e
			end)

			assert.is_nil(err)
			assert.equal(0, #api_calls)
			assert.equal(1, #gh_calls)
			assert.equal("graphql", gh_calls[1][2])

			local flags = gh_flags(gh_calls[1])
			assert.equal("PRRC_node", flags.commentId)
			assert.equal("updated body", flags.body)
			assert.is_truthy(flags.query:find("updatePullRequestReviewComment", 1, true))

			assert.equal(4242, updated.id)
			assert.equal("updated body", updated.content_raw)
			assert.equal("PENDING", updated.state)
			assert.equal("lua/init.lua", updated.inline.path)
			assert.equal(12, updated.inline.to)
			assert.equal("PRRT_node", updated._raw.thread_id)
			assert.equal("PRRC_node", updated._raw.comment_id)
		end)

		it("keeps using REST for published comments", function()
			local endpoint
			github_client.install({
				gh = function(args)
					table.insert(gh_calls, args)
				end,
				api = function(_, path, _, callback)
					endpoint = path
					callback({ id = 4242, body = "updated body", user = { login = "octocat" } }, nil)
				end,
			})
			local api = fresh_module()

			local published = pending_comment()
			published.state = nil

			local err
			api.edit_comment(pull_request(), published, function(_, e)
				err = e
			end)

			assert.is_nil(err)
			assert.equal(0, #gh_calls)
			assert.equal("repos/octo/repo/pulls/comments/4242", endpoint)
		end)

		it("fails when the pending comment has no node id", function()
			github_client.install({
				gh = function(args)
					table.insert(gh_calls, args)
				end,
			})
			local api = fresh_module()

			local updated, err
			api.edit_comment(pull_request(), pending_comment({ _raw = {} }), function(result, e)
				updated, err = result, e
			end)

			assert.is_nil(updated)
			assert.equal("Missing review comment id", err)
			assert.equal(0, #gh_calls)
		end)

		it("propagates GraphQL errors", function()
			github_client.install({
				gh = function(args, callback)
					table.insert(gh_calls, args)
					callback(nil, "boom")
				end,
			})
			local api = fresh_module()

			local updated, err
			api.edit_comment(pull_request(), pending_comment(), function(result, e)
				updated, err = result, e
			end)

			assert.is_nil(updated)
			assert.equal("boom", err)
		end)
	end)

	describe("delete_comment", function()
		it("deletes a pending comment over GraphQL instead of REST", function()
			github_client.install({
				gh = function(args, callback)
					table.insert(gh_calls, args)
					callback({ data = { deletePullRequestReviewComment = {} } }, nil)
				end,
				api = function(_, _, _, callback)
					table.insert(api_calls, true)
					callback(nil, "REST should not be used")
				end,
			})
			local api = fresh_module()

			local ok, err
			api.delete_comment(pull_request(), pending_comment(), function(success, e)
				ok, err = success, e
			end)

			assert.is_true(ok)
			assert.is_nil(err)
			assert.equal(0, #api_calls)
			assert.equal(1, #gh_calls)

			local flags = gh_flags(gh_calls[1])
			assert.equal("PRRC_node", flags.commentId)
			assert.is_truthy(flags.query:find("deletePullRequestReviewComment", 1, true))
		end)

		it("forgets the pending review when the last draft comment is gone", function()
			github_client.install({
				gh = function(args, callback)
					table.insert(gh_calls, args)
					callback({ data = { deletePullRequestReviewComment = { pullRequestReview = vim.NIL } } }, nil)
				end,
			})
			local api = fresh_module()

			local pr = pull_request({ reviews = { nodes = { { id = "PRR_node" } } } })
			api.delete_comment(pr, pending_comment(), function() end)

			assert.is_nil(pr._raw.reviews)
		end)

		it("keeps the pending review when other draft comments remain", function()
			github_client.install({
				gh = function(args, callback)
					table.insert(gh_calls, args)
					callback({
						data = {
							deletePullRequestReviewComment = {
								pullRequestReview = { id = "PRR_node", state = "PENDING", commit = { oid = "abc123" } },
							},
						},
					}, nil)
				end,
			})
			local api = fresh_module()

			local pr = pull_request()
			api.delete_comment(pr, pending_comment(), function() end)

			assert.same(
				{ nodes = { { id = "PRR_node", state = "PENDING", commit = { oid = "abc123" } } } },
				pr._raw.reviews
			)
		end)

		it("keeps using REST for published comments", function()
			local endpoint
			github_client.install({
				gh = function(args)
					table.insert(gh_calls, args)
				end,
				api = function(_, path, _, callback)
					endpoint = path
					callback(nil, nil)
				end,
			})
			local api = fresh_module()

			local published = pending_comment()
			published.state = nil

			local ok = false
			api.delete_comment(pull_request(), published, function(success)
				ok = success
			end)

			assert.is_true(ok)
			assert.equal(0, #gh_calls)
			assert.equal("repos/octo/repo/pulls/comments/4242", endpoint)
		end)

		it("fails when the pending comment has no node id", function()
			github_client.install({
				gh = function(args)
					table.insert(gh_calls, args)
				end,
			})
			local api = fresh_module()

			local ok, err
			api.delete_comment(pull_request(), pending_comment({ _raw = {} }), function(success, e)
				ok, err = success, e
			end)

			assert.is_false(ok)
			assert.equal("Missing review comment id", err)
			assert.equal(0, #gh_calls)
		end)
	end)
end)
