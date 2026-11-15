local mapper = require("atlas.pulls.providers.github.api.mapper")

describe("GitHub pull request timeline mapper", function()
	local actor = { login = "alice", databaseId = 1 }

	it("maps GraphQL timeline items to activity entries", function()
		local commit = assert(mapper.to_activity({
			__typename = "PullRequestCommit",
			commit = {
				oid = "0123456789abcdef",
				message = "fix: thing\n\nbody",
				authoredDate = "2026-01-02T03:04:05Z",
				author = { name = "Alice" },
			},
		}))
		assert.same({ "committed", "01234567 fix: thing", "2026-01-02T03:04:05Z", "Alice" }, {
			commit.kind,
			commit.label,
			commit.date,
			commit.actor.username,
		})

		local pushed =
			assert(mapper.to_activity({ __typename = "HeadRefForcePushedEvent", actor = actor, createdAt = "d" }))
		assert.same({ "force_pushed", "force pushed", "alice" }, { pushed.kind, pushed.label, pushed.actor.username })

		local approved = assert(mapper.to_activity({
			__typename = "PullRequestReview",
			state = "APPROVED",
			author = actor,
			submittedAt = "d",
		}))
		assert.same({ "approval", "approved", "alice" }, { approved.kind, approved.label, approved.actor.username })

		local requested =
			assert(mapper.to_activity({ __typename = "ReviewRequestedEvent", requestedReviewer = { login = "bob" } }))
		assert.same({ "review_requested", "requested review from bob" }, { requested.kind, requested.label })

		assert.is_nil(mapper.to_activity({ __typename = "PullRequestReview", state = "PENDING", author = actor }))
		assert.is_nil(mapper.to_activity({ __typename = "SomeFutureEvent" }))
	end)

	it("maps GraphQL comments and reviews", function()
		local comment = mapper.to_comment({
			id = "IC_42",
			url = "https://github.com/o/r/pull/1#issuecomment-42",
			body = "hi",
			createdAt = "d",
			author = actor,
		})
		assert.same({ "IC_42", "alice", "hi" }, { comment.id, comment.author.username, comment.body })

		local review = assert(mapper.to_conversation_review({
			id = "PRR_1",
			state = "CHANGES_REQUESTED",
			body = "please fix",
			submittedAt = "d",
			commit = { oid = "abc" },
			author = actor,
		}))
		assert.same({ "PRR_1", "changes_requested", "abc" }, { review.id, review.state, review.commit_hash })
		assert.is_nil(
			mapper.to_conversation_review({ id = "PRR_2", state = "PENDING", body = "draft", author = actor })
		)
		assert.is_nil(mapper.to_conversation_review({ id = "PRR_3", state = "APPROVED", body = "", author = actor }))
	end)
end)
