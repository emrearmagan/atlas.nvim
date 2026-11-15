local github_client = require("spec.support.github_client_stub")

local MODULE = "atlas.pulls.providers.github.api.comments"
local pr = { id = "7", repo_full_name = "owner/repo", author = { name = "alice", username = "alice" } }

---@param response table What GitHub answers.
---@return table api, string[] mutations The comments API and the mutations it sent.
local function comments(response)
	local mutations = {}
	github_client.install({
		gh = function(args, callback)
			table.insert(mutations, table.concat(args, " "):match("(%w+)%(input:"))
			callback(response, nil)
		end,
	})
	package.loaded[MODULE] = nil
	return require(MODULE), mutations
end

describe("github review comments", function()
	after_each(function()
		github_client.uninstall()
		package.loaded[MODULE] = nil
	end)

	it("deletes review comments, pending ones too, and conversation comments with their own mutation", function()
		for _, case in ipairs({
			{ { id = "C", inline = { path = "a.lua", to = 1 } }, "deletePullRequestReviewComment" },
			{ { id = "C", file = { path = "a.lua" } }, "deletePullRequestReviewComment" },
			{ { id = "C", pending = true }, "deletePullRequestReviewComment" },
			{ { id = "C" }, "deleteIssueComment" },
		}) do
			local api, mutations = comments({ data = {} })
			local ok
			api.delete_comment(pr, case[1], function(success)
				ok = success
			end)

			assert.is_true(ok)
			assert.same({ case[2] }, mutations)
		end
	end)

	it("keeps a review comment's pending state, position and thread after an edit", function()
		local api = comments({
			data = {
				updatePullRequestReviewComment = {
					pullRequestReviewComment = { id = "C", body = "new", pullRequestReview = { state = "PENDING" } },
				},
			},
		})
		local comment =
			{ id = "C", body = "old", pending = true, inline = { path = "a.lua", to = 12 }, thread_id = "T" }

		local updated
		api.edit_comment(pr, comment, "new", function(result)
			updated = result
		end)

		assert.same(
			{ "new", true, "a.lua", 12, "T" },
			{ updated.body, updated.pending, updated.inline.path, updated.inline.to, updated.thread_id }
		)
	end)

	it("keeps a conversation comment's reactions after an edit", function()
		local api = comments({ data = { updateIssueComment = { issueComment = { id = "C", body = "new" } } } })
		local reactions = { { name = "heart", count = 1 } }

		local updated
		api.edit_comment(pr, { id = "C", body = "old", created_at = "", reactions = reactions }, "new", function(result)
			updated = result
		end)

		assert.same({ "new", reactions }, { updated.body, updated.reactions })
	end)
end)
