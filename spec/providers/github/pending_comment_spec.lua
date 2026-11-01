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
	return { id = "7", repo_full_name = "owner/repo", author = { name = "alice", username = "alice" } }
end

local function pending_comment(overrides)
	return vim.tbl_extend("force", {
		id = "PRRC_node",
		body = "updated body",
		pending = true,
		inline = { path = "lua/init.lua", to = 12 },
		thread_id = "PRRT_node",
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
				api.edit_comment(pull_request(), comment, "updated body", function(result, e)
					updated, err = result, e
				end)

				assert.is_nil(err)
				assert.equal("graphql", gh_calls[index][2])
				local flags = gh_flags(gh_calls[index])
				assert.equal("PRRC_node", flags.commentId)
				assert.equal("updated body", flags.body)
				assert.is_truthy(flags.query:find("updatePullRequestReviewComment", 1, true))
				assert.equal("PRRC_node", updated.id)
				assert.equal("updated body", updated.body)
				assert.equal(comment.pending, updated.pending)
				assert.equal("lua/init.lua", updated.inline.path)
				assert.equal(12, updated.inline.to)
				assert.equal("PRRT_node", updated.thread_id)
			end
			assert.equal(0, #api_calls)
			assert.equal(2, #gh_calls)
		end)

		it("updates conversation comments over GraphQL and keeps their reactions", function()
			github_client.install({
				gh = function(args, callback)
					table.insert(gh_calls, args)
					callback({
						data = { updateIssueComment = { issueComment = { id = "IC_node", body = "updated body" } } },
					}, nil)
				end,
			})
			local api = fresh_module()
			local reactions = { { name = "heart", count = 1 } }

			local updated
			api.edit_comment(
				pull_request(),
				{ id = "IC_node", body = "old body", created_at = "", reactions = reactions },
				"updated body",
				function(result)
					updated = result
				end
			)

			local flags = gh_flags(gh_calls[1])
			assert.equal("IC_node", flags.commentId)
			assert.is_truthy(flags.query:find("updateIssueComment", 1, true))
			assert.same({ "IC_node", "updated body", reactions }, { updated.id, updated.body, updated.reactions })
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

		it("deletes conversation comments over GraphQL", function()
			github_client.install({
				gh = function(args, callback)
					table.insert(gh_calls, args)
					callback({ data = { deleteIssueComment = {} } }, nil)
				end,
			})
			local api = fresh_module()

			local ok
			api.delete_comment(pull_request(), { id = "IC_node", body = "", created_at = "" }, function(success)
				ok = success
			end)

			assert.is_true(ok)
			local flags = gh_flags(gh_calls[1])
			assert.equal("IC_node", flags.commentId)
			assert.is_truthy(flags.query:find("deleteIssueComment", 1, true))
		end)
	end)
end)
