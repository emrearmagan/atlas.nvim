local mapper = require("atlas.issues.providers.shortcut.api.mapper")

describe("Shortcut Story mapper", function()
	it("maps owners, workflow and parent types without dropping unknown states", function()
		local owner = { id = "owner", name = "Ada Owner" }
		local issues = mapper.to_issues({
			{ id = 123, story_type = "bug", workflow_state_id = 42, owner_ids = { "owner" }, parent_story_id = 99 },
			{ id = 124, story_type = "bug", workflow_state_id = 99 },
		}, { owner }, { { id = 42, name = "Ready" } })
		assert.equal("123", issues[1].key)
		assert.equal(owner, issues[1].assignee)
		assert.equal("Ready", issues[1].status)
		assert.same({ key = "99" }, issues[1].parent)
		assert.is_true(issues[1].type.subtask)
		assert.same({ icon = "", hl_group = "AtlasLogError" }, issues[1].icon)
		assert.equal(issues[1].type.icon, issues[1].icon)
		assert.is_false(issues[2].type.subtask)
		assert.equal("Unknown", issues[2].status)
		assert.equal("99", issues[2].status_id)
	end)

	it("keeps fresh editor metadata and sorts checklist tasks by position", function()
		local details = mapper.to_issue_details({
			name = "Updated title",
			story_type = "feature",
			workflow_state_id = 42,
			description = "",
			tasks = {
				{ id = 2, description = "Second", complete = false, position = 2 },
				{ id = 1, description = "First", complete = true, position = 1 },
			},
		}, {})
		assert.equal("Updated title", details.title)
		assert.equal("feature", details.story_type)
		assert.equal(42, details.workflow_state_id)
		assert.equal("", details.description)
		assert.equal(1, details.tasks[1].id)
		assert.is_true(details.tasks[1].complete)
		assert.equal(2, details.tasks[2].id)
	end)

	it("resolves comment authors and counts Shortcut reaction participants", function()
		local author = { id = "author", name = "Ada Author" }
		local comment = mapper.to_comment({
			id = 456,
			author_id = "author",
			text = "Looks good",
			parent_id = 123,
			reactions = { { emoji = ":thumbsup:", permission_ids = { "author", "two" } } },
		}, { author })
		assert.equal("456", comment.id)
		assert.equal(author, comment.author)
		assert.equal("Looks good", comment.body)
		assert.equal(123, comment.parent_id)
		assert.same({ { name = "thumbsup", count = 2, users = { author } } }, comment.reactions)
	end)

	it("maps activity actors and readable change descriptions", function()
		local entries = mapper.to_history({
			{
				member_id = "owner",
				actor_name = "Ada Owner",
				actions = { { action = "update", entity_type = "story", changes = { owner_ids = {} } } },
			},
		})
		assert.same({ id = "owner", name = "Ada Owner" }, entries[1].actor)
		assert.equal("owners", entries[1].body)
	end)
end)
