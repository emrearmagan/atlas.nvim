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

local function pull_request()
	return { id = "7", repo_full_name = "octo/repo" }
end

local function pending_comment(overrides)
	return vim.tbl_extend("force", {
		id = 4242,
		content_raw = "updated body",
		pending = true,
		inline = { path = "lua/init.lua", to = 12 },
		thread_id = "PRRT_node",
		_raw = {
			comment_id = "PRRC_node",
		},
	}, overrides or {})
end

describe("github review comments", function()
	local gh_calls, api_calls

	before_each(function()
		gh_calls, api_calls = {}, {}
	end)

	after_each(function()
		github_client.uninstall()
		package.loaded["atlas.pulls.providers.github.api.comments"] = nil
	end)

	describe("edit_comment", function()
		it("updates pending and published review comments over GraphQL", function()
			local review_state
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
									pullRequestReview = { id = "PRR_node", state = review_state },
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

			for index, state in ipairs({ "PENDING", "COMMENTED" }) do
				review_state = state
				local comment = pending_comment()
				comment.pending = state == "PENDING"
				local updated, err
				api.edit_comment(pull_request(), comment, function(result, e)
					updated, err = result, e
				end)

				assert.is_nil(err)
				assert.equal("graphql", gh_calls[index][2])
				local flags = gh_flags(gh_calls[index])
				assert.equal("PRRC_node", flags.commentId)
				assert.equal("updated body", flags.body)
				assert.is_truthy(flags.query:find("updatePullRequestReviewComment", 1, true))
				assert.equal(4242, updated.id)
				assert.equal("updated body", updated.content_raw)
				assert.equal(comment.pending, updated.pending)
				assert.equal("lua/init.lua", updated.inline.path)
				assert.equal(12, updated.inline.to)
				assert.equal("PRRT_node", updated.thread_id)
				assert.equal("PRRC_node", updated._raw.comment_id)
			end
			assert.equal(0, #api_calls)
			assert.equal(2, #gh_calls)
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
		it("deletes pending and published review comments over GraphQL", function()
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

			for index, state in ipairs({ "PENDING", "COMMENTED" }) do
				local comment = pending_comment()
				comment.pending = state == "PENDING"
				local ok, err
				api.delete_comment(pull_request(), comment, function(success, e)
					ok, err = success, e
				end)

				assert.is_true(ok)
				assert.is_nil(err)
				local flags = gh_flags(gh_calls[index])
				assert.equal("PRRC_node", flags.commentId)
				assert.is_truthy(flags.query:find("deletePullRequestReviewComment", 1, true))
			end
			assert.equal(0, #api_calls)
			assert.equal(2, #gh_calls)
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
