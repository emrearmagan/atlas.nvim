local mapper = require("atlas.issues.providers.shortcut.api.mapper")

describe("Shortcut Story mapper", function()
	it("maps a Story to an Atlas issue", function()
		local users = {
			{ account_id = "owner", display_name = "Ada Owner" },
		}
		local issue = assert(mapper.to_issue({
			id = 123,
			name = "Ship Shortcut support",
			story_type = "bug",
			workflow_state_id = 42,
			started = true,
			parent_story_id = 99,
			owner_ids = { "owner", "other" },
			labels = { { name = "api", color = "#123456" } },
			comment_ids = { 1, 2 },
			updated_at = "2026-08-23T10:00:00Z",
			app_url = "https://app.shortcut.com/acme/story/123/ship-shortcut-support",
		}, users))

		assert.same({
			id = 123,
			key = "123",
			title = "Ship Shortcut support",
			status = "Started",
			status_id = "started",
			type = "bug",
			assignee = { account_id = "owner", display_name = "Ada Owner" },
			owner_count = 2,
			labels = { { name = "api", color = "#123456" } },
			comment_count = 2,
			updated_at = "2026-08-23T10:00:00Z",
			url = "https://app.shortcut.com/acme/story/123/ship-shortcut-support",
		}, {
			id = issue.id,
			key = issue.key,
			title = issue.title,
			status = issue.status,
			status_id = issue.status_id,
			type = issue.type and issue.type.name,
			assignee = issue.assignee,
			owner_count = issue.owner_count,
			labels = issue.labels,
			comment_count = issue.comment_count,
			updated_at = issue.updated_at,
			url = issue.url,
		})
		assert.is_nil(issue.parent)
	end)

	it("maps Story details", function()
		local details = mapper.to_issue_details({
			id = 123,
			name = "Ship Shortcut support",
			story_type = "feature",
			workflow_state_id = 1,
			description = "Full description",
			parent_story_id = 122,
			owner_ids = {},
			sub_task_story_ids = { 124, 125 },
			tasks = {
				{ id = 2, description = "Second", complete = false, position = 2 },
				{ id = 1, description = "First", complete = true, position = 1 },
			},
		}, {})

		assert.equal("Full description", details.description)
		assert.same({ key = "122" }, details.parent)
		assert.same({ { key = "124" }, { key = "125" } }, details.sub_issues)
		assert.same({
			{ id = 1, description = "First", complete = true, position = 1 },
			{ id = 2, description = "Second", complete = false, position = 2 },
		}, details.tasks)
	end)

	it("maps Story comments", function()
		local author = { account_id = "author", display_name = "Ada Author", mention_name = "ada" }
		local comment = mapper.to_comment({
			id = 456,
			author_id = "author",
			text = "Looks good",
			parent_id = 123,
			created_at = "2026-08-23T10:00:00Z",
		}, { author })

		assert.same({
			id = "456",
			author = author,
			body = "Looks good",
			parent_id = 123,
			created = "2026-08-23T10:00:00Z",
			deleted = false,
		}, comment)
	end)
end)
