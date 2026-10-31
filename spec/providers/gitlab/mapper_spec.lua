local issue_mapper = require("atlas.issues.providers.gitlab.api.mapper")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

describe("GitLab issue mapper", function()
	it("maps REST and GraphQL issues to the same fields", function()
		---@type table<string, any>
		local raw = {
			iid = 42,
			references = { full = "group/project#42" },
			title = "Provider types",
			state = "opened",
			issue_type = "issue",
			assignees = { { id = 8, name = "Assignee", username = "assignee" } },
			author = { id = 9, name = "Reporter", username = "reporter" },
		}
		local rest = issue_mapper.to_issue(raw)

		raw.iid = "42"
		raw.issue_type = "ISSUE"
		raw.reference = raw.references.full
		raw.references = nil
		raw.assignees[1].id = "gid://gitlab/User/8"
		raw.assignees = { nodes = raw.assignees }
		raw.author.id = "gid://gitlab/User/9"
		local graphql = assert(issue_mapper.to_issue(raw))

		assert.same(rest, graphql)
	end)

	it("maps issue details and editable milestone IDs", function()
		local details = assert(issue_mapper.to_issue_details({
			iid = 7,
			references = { full = "group/project#7" },
			title = "Details",
			description = "Hydrated description",
			state = "opened",
			milestone = { id = "gid://gitlab/Milestone/15", title = "Next" },
		}))

		assert.is_nil(rawget(details, "project_path"))
		assert.is_nil(rawget(details, "iid"))
		assert.are.equal("Hydrated description", details.description)
		assert.are.equal("Details", details.title)
		assert.same({ id = 15, title = "Next" }, details.milestone)
	end)
end)

describe("GitLab pull request details", function() end)

describe("GitLab descriptions", function()
	local alice = { name = "Alice", username = "alice" }

	it("maps a merge request description as a comment with its award emoji", function()
		local comment = assert(mapper.to_description({
			id = "gid://gitlab/MergeRequest/7",
			description = "Body",
			author = { id = "gid://gitlab/User/9", name = "Alice", username = "alice" },
			awardEmoji = { nodes = { { name = "rocket", user = alice } } },
		}, "alice"))

		assert.equal("gid://gitlab/MergeRequest/7", comment.id)
		assert.equal("Body", comment.body)
		assert.equal("alice", comment.author.username)
		assert.equal("rocket", comment.reactions[1].name)
		assert.is_true(comment.reactions[1].reacted)
	end)

	it("reads an issue's award emoji from its work item", function()
		local work_item = {
			features = { awardEmoji = { awardEmoji = { nodes = { { name = "thumbsup", user = alice } } } } },
		}

		local comment =
			assert(issue_mapper.to_description({ id = "gid://gitlab/Issue/3", description = "Body" }, work_item))

		assert.equal("gid://gitlab/Issue/3", comment.id)
		assert.equal("Body", comment.body)
		assert.equal("thumbsup", comment.reactions[1].name)
		assert.same(comment.reactions, issue_mapper.to_issue_details({ title = "Issue" }, work_item).reactions)
	end)
end)

describe("GitLab issue comments", function()
	it("maps parent and thread from the GraphQL discussion", function()
		local discussion = {
			id = "gid://gitlab/Discussion/d1",
			notes = { nodes = { { id = "gid://gitlab/Note/1" } } },
		}
		local function note(id)
			return { id = id, body = "hi", createdAt = "d", author = { username = "alice", name = "Alice" } }
		end

		local root = assert(issue_mapper.to_comment(note("gid://gitlab/Note/1"), discussion))
		local reply = assert(issue_mapper.to_comment(note("gid://gitlab/Note/2"), discussion))
		assert.same(
			{ "gid://gitlab/Note/1", "gid://gitlab/Discussion/d1", "gid://gitlab/Note/1" },
			{ root.id, root.thread_id, reply.parent_id }
		)
		assert.is_nil(root.parent_id)
		assert.is_nil(issue_mapper.to_comment({ body = "no id" }, discussion))
	end)
end)

describe("GitLab comment resolution metadata", function()
	local function resolved_note()
		return {
			id = 101,
			body = "Please update this",
			created_at = "2026-08-16T12:00:00Z",
			author = { id = 1, username = "author", name = "Author" },
			resolved = true,
			resolved_at = "2026-08-17T09:30:00Z",
			resolved_by = { id = 2, username = "reviewer", name = "Reviewer" },
		}
	end

	local function discussion(root)
		return { id = "abc", notes = { root } }
	end

	it("maps resolver and timestamp onto resolved thread roots", function()
		local note = resolved_note()
		local comment = mapper.to_discussion_note(note, discussion(note), "https://gitlab.com/o/r/-/merge_requests/1")

		assert.same(
			{ "gid://gitlab/Note/101", "gid://gitlab/Discussion/abc", "RESOLVED", "2026-08-17T09:30:00Z" },
			{ comment.id, comment.thread_id, comment.state, comment.resolved_at }
		)
		assert.same({
			id = "2",
			name = "Reviewer",
			username = "reviewer",
		}, comment.resolved_by)
		assert.equal("https://gitlab.com/o/r/-/merge_requests/1#note_101", comment.url)
	end)

	it("does not attach thread resolution metadata to replies", function()
		local note = resolved_note()
		note.id = 102
		local comment = mapper.to_discussion_note(note, discussion(resolved_note()), "")

		assert.are.equal("RESOLVED", comment.state)
		assert.are.equal("gid://gitlab/Note/101", comment.parent_id)
		assert.is_nil(comment.resolved_at)
		assert.is_nil(comment.resolved_by)
	end)

	it("does not retain resolution metadata on unresolved roots", function()
		local note = resolved_note()
		note.resolved = false
		local comment = mapper.to_discussion_note(note, discussion(note), "")

		assert.is_nil(comment.state)
		assert.is_nil(comment.resolved_at)
		assert.is_nil(comment.resolved_by)
	end)

	it("keeps the original multiline location of outdated comments", function()
		local note = resolved_note()
		note.resolved = false
		note.original_position = {
			position_type = "text",
			old_path = "old.lua",
			new_path = "new.lua",
			new_line = 15,
			line_range = { start = { new_line = 13 } },
		}
		local comment = mapper.to_discussion_note(note, discussion(note), "")

		assert.are.equal("OUTDATED", comment.state)
		assert.are.equal("new.lua", comment.inline.path)
		assert.are.equal(13, comment.inline.start_to)
		assert.are.equal(15, comment.inline.to)
	end)
end)

describe("GitLab GraphQL notes", function()
	local function note(id)
		return {
			id = id,
			body = "Looks good",
			createdAt = "2026-08-16T12:00:00Z",
			url = "https://gitlab.com/o/r/-/merge_requests/1#note_1",
			author = { id = "gid://gitlab/User/7", username = "alice", name = "Alice" },
			position = {
				positionType = "text",
				oldPath = "a.lua",
				newPath = "a.lua",
				newLine = 12,
				diffRefs = { headSha = "abc" },
			},
			discussion = {
				id = "gid://gitlab/Discussion/d1",
				resolved = true,
				resolvedAt = "2026-08-17T09:30:00Z",
				resolvedBy = { id = "gid://gitlab/User/8", username = "bob", name = "Bob" },
				notes = { nodes = { { id = "gid://gitlab/DiscussionNote/1" } } },
			},
		}
	end

	it("maps thread, position and resolution from the note's discussion", function()
		local root = mapper.to_comment(note("gid://gitlab/DiffNote/1"))
		assert.same({
			"gid://gitlab/Note/1",
			"gid://gitlab/Discussion/d1",
			"RESOLVED",
			"bob",
			"7",
			{ path = "a.lua", old_path = "a.lua", to = 12, commit_hash = "abc" },
		}, { root.id, root.thread_id, root.state, root.resolved_by.username, root.author.id, root.inline })
		assert.is_nil(root.parent_id)

		local reply = mapper.to_comment(note("gid://gitlab/DiffNote/2"))
		assert.equal("gid://gitlab/Note/1", reply.parent_id)
		assert.is_nil(reply.resolved_by)
	end)

	it("maps draft notes with their own id", function()
		local draft = mapper.to_draft_comment({
			id = 5,
			note = "draft",
			author_id = 7,
			discussion_id = "d1",
			position = { position_type = "file", new_path = "a.lua", head_sha = "abc" },
		})
		assert.same(
			{ "5", true, "gid://gitlab/Discussion/d1", "draft", { path = "a.lua", commit_hash = "abc" } },
			{ draft.id, draft.pending, draft.thread_id, draft.body, draft.file }
		)
	end)
end)

describe("GitLab comment author roles", function()
	local function roles(note)
		note.id = "gid://gitlab/Note/1"
		return issue_mapper.to_comment(note, {}, nil, "alice").author_roles
	end

	it("maps the access level, contributors, bots and the issue author", function()
		assert.same(
			{ "Author", "Maintainer" },
			roles({ author = { username = "alice" }, maxAccessLevelOfAuthor = "Maintainer" })
		)
		assert.same({ "Contributor" }, roles({ author = { username = "bob" }, authorIsContributor = true }))
		assert.same(
			{ "Bot", "Developer" },
			roles({ author = { username = "ci", bot = true }, maxAccessLevelOfAuthor = "Developer" })
		)
		assert.is_nil(roles({ author = { username = "bob" }, maxAccessLevelOfAuthor = vim.NIL }))
	end)

	it("marks the merge request author on REST discussion notes", function()
		local note = { id = 1, author = { username = "alice" } }
		local comment =
			mapper.to_discussion_note(note, { id = "d1", notes = { note } }, "https://gitlab.com/mr", "alice")
		assert.same({ "Author" }, comment.author_roles)
	end)
end)
