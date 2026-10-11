local mapper = require("atlas.issues.providers.jira.api.mapper")
local icons = require("atlas.ui.shared.icons")

local function issue_raw()
	return {
		id = "10042",
		key = "KAN-42",
		fields = {
			summary = "My issue",
			issuetype = { id = "10001", name = "Task" },
			project = {
				id = "10000",
				key = "KAN",
				name = "Kanban",
				self = "https://jira.example/rest/api/3/project/10000",
			},
			priority = { name = "High" },
		},
	}
end

describe("Jira issue mapping", function()
	it("maps Jira fields directly onto the provider issue", function()
		local issue = mapper.to_issue(issue_raw())

		assert.equal("10042", issue.id)
		assert.equal("KAN", issue.project.key)
		assert.equal("High", issue.priority)
		assert.same({ icon = "", hl_group = "AtlasLogInfo" }, issue.type.icon)
		assert.same(issue.type.icon, issue.icon)
		assert.is_nil(issue._raw)
	end)

	it("hydrates Jira detail fields without retaining the response", function()
		local raw = issue_raw()
		raw.fields.description = { type = "doc", version = 1, content = {} }
		raw.fields.labels = { "backend" }
		raw.fields.customfield_10038 = { value = "Platform" }

		local details = mapper.to_issue_details(raw, {
			customfield_10038 = {
				name = "Team",
				format = function(value)
					return value.value
				end,
			},
		})

		assert.same(raw.fields.description, details.raw_description)
		assert.same({ { name = "backend" } }, details.labels)
		assert.same({ icon = "", hl_group = "AtlasLogInfo" }, details.type.icon)
		assert.same({
			{
				name = "Team",
				formatted = "Platform",
				display = "chip",
			},
		}, details.custom_fields)
		assert.is_nil(details.key)
		assert.is_nil(details._raw)
	end)

	it("uses the generic icon and a dynamic color for custom issue types", function()
		local issue_type = mapper.to_issue_type({ id = "10002", name = "Custom" })

		assert.equal(icons.get("issue"), issue_type.icon.icon)
		assert.matches("^AtlasDynColor%d+$", issue_type.icon.hl_group)
	end)
end)
