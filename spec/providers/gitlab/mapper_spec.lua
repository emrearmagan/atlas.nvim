local issue_mapper = require("atlas.issues.providers.gitlab.api.mapper")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

describe("GitLab issue mapper", function()
	it("maps provider fields directly onto issues", function()
		local issue = issue_mapper.to_issue({
			iid = 42,
			references = { full = "group/project#42" },
			title = "Provider types",
			state = "opened",
		})

		assert.are.equal("group/project", issue.project_path)
		assert.are.equal(42, issue.iid)
	end)

	it("maps only supplemental issue details", function()
		local details = issue_mapper.to_issue_details({
			iid = 7,
			references = { full = "group/project#7" },
			title = "Details",
			description = "Hydrated description",
			state = "opened",
		})

		assert.is_nil(details.project_path)
		assert.is_nil(details.iid)
		assert.are.equal("Hydrated description", details.description)
	end)
end)

describe("GitLab pull request details", function()
	it("maps only supplemental detail fields", function()
		local details = mapper.to_pull_request_details({
			description = "Description",
			subscribed = true,
			assignees = { { id = 8, name = "Assignee", username = "assignee" } },
			labels = { { name = "backend", color = "#ffffff", text_color = "#000000" } },
		})

		assert.equal("Description", details.description)
		assert.is_true(details.is_subscribed)
		assert.equal("assignee", details.assignees[1].username)
		assert.equal("backend", details.labels[1].name)
		assert.equal("#000000", details.labels[1].text_color)
		assert.is_nil(details.repo_full_name)
	end)
end)

describe("GitLab comment resolution metadata", function()
	local function resolved_note()
		return {
			id = 101,
			body = "Please update this",
			created_at = "2026-08-16T12:00:00Z",
			author = { id = 1, username = "author", name = "Author" },
			resolved_at = "2026-08-17T09:30:00Z",
			resolved_by = { id = 2, username = "reviewer", name = "Reviewer" },
		}
	end

	it("maps resolver and timestamp onto resolved thread roots", function()
		local comment = mapper.to_comment(resolved_note(), 101, "discussion-1", true)

		assert.are.equal("RESOLVED", comment.state)
		assert.are.equal("2026-08-17T09:30:00Z", comment.resolved_on)
		assert.same({
			id = "2",
			name = "Reviewer",
			username = "reviewer",
			nickname = "reviewer",
		}, comment.resolved_by)
	end)

	it("does not attach thread resolution metadata to replies", function()
		local note = resolved_note()
		note.id = 102
		local comment = mapper.to_comment(note, 101, "discussion-1", true)

		assert.are.equal("RESOLVED", comment.state)
		assert.is_nil(comment.resolved_on)
		assert.is_nil(comment.resolved_by)
	end)

	it("does not retain resolution metadata on unresolved roots", function()
		local comment = mapper.to_comment(resolved_note(), 101, "discussion-1", false)

		assert.is_nil(comment.state)
		assert.is_nil(comment.resolved_on)
		assert.is_nil(comment.resolved_by)
	end)

	it("keeps the original multiline location of outdated comments", function()
		local note = resolved_note()
		note.original_position = {
			position_type = "text",
			old_path = "old.lua",
			new_path = "new.lua",
			new_line = 15,
			line_range = { start = { new_line = 13 } },
		}
		local comment = mapper.to_comment(note, 101, "discussion-1", false)

		assert.are.equal("OUTDATED", comment.state)
		assert.are.equal("new.lua", comment.inline.path)
		assert.are.equal(13, comment.inline.start_to)
		assert.are.equal(15, comment.inline.to)
	end)
end)
