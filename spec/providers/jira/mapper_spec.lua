local mapper = require("atlas.issues.providers.jira.api.mapper")

local function issue_raw()
	return {
		key = "KAN-42",
		fields = {
			summary = "My issue",
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

		assert.equal("KAN", issue.project.key)
		assert.equal("High", issue.priority)
		assert.is_nil(issue._raw)
	end)

	it("hydrates Jira detail fields without retaining the response", function()
		local raw = issue_raw()
		raw.fields.description = { type = "doc", version = 1, content = {} }
		raw.fields.customfield_10038 = { value = "Platform" }

		local issue = mapper.to_issue_details(raw, nil, {
			customfield_10038 = {
				name = "Team",
				format = function(value)
					return value.value
				end,
			},
		})

		assert.same(raw.fields.description, issue.raw_description)
		assert.same({
			{
				name = "Team",
				formatted = "Platform",
				display = "chip",
			},
		}, issue.custom_fields)
		assert.is_nil(issue._raw)
	end)
end)
