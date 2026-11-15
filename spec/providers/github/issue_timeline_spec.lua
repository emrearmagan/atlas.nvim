local mapper = require("atlas.issues.providers.github.api.mapper")

describe("GitHub issue timeline mapper", function()
	local function entry(node)
		node.actor = { login = "alice", name = "Alice", databaseId = 1 }
		node.createdAt = "2026-01-02T03:04:05Z"
		return assert(mapper.to_timeline_entry(node))
	end

	it("maps GraphQL timeline events to activity entries", function()
		local labeled = entry({ __typename = "LabeledEvent", label = { name = "bug" } })
		assert.same({ "labeled", "alice", "2026-01-02T03:04:05Z", "added label: bug" }, {
			labeled.kind,
			labeled.actor.username,
			labeled.date,
			labeled.label,
		})

		local sub_issue = entry({ __typename = "SubIssueAddedEvent" })
		assert.same({ "other", "added a sub-issue" }, { sub_issue.kind, sub_issue.label })

		local renamed = entry({ __typename = "RenamedTitleEvent", previousTitle = "Old", currentTitle = "New" })
		assert.same({ "renamed", "Old → New" }, { renamed.kind, renamed.body })

		local closed = entry({ __typename = "ClosedEvent", closer = { oid = "0123456789abcdef" } })
		assert.same({ "closed", "commit 01234567" }, { closed.kind, closed.body })

		local referenced = entry({ __typename = "CrossReferencedEvent", source = { title = "Fix it", url = "u" } })
		assert.same({ "referenced", "referenced", "Fix it" }, { referenced.kind, referenced.label, referenced.body })

		assert.is_nil(mapper.to_timeline_entry({ __typename = "SomeFutureEvent" }))
	end)

	it("maps GraphQL comments with node ids", function()
		local comment = assert(mapper.to_comment({
			id = "IC_42",
			url = "https://github.com/o/r/issues/1#issuecomment-42",
			body = "hi",
			createdAt = "2026-01-02T03:04:05Z",
			updatedAt = "2026-01-03T03:04:05Z",
			author = { login = "alice", name = "Alice", databaseId = 1 },
		}))
		assert.same(
			{ "IC_42", "Alice", "alice", "hi" },
			{ comment.id, comment.author.name, comment.author.username, comment.body }
		)
		assert.is_nil(mapper.to_comment({ body = "no id" }))
	end)
end)
