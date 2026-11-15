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
	it("hydrates Jira detail fields", function()
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
		assert.same({
			{
				name = "Team",
				formatted = "Platform",
				display = "chip",
			},
		}, details.custom_fields)
	end)

	it("maps create metadata fields to kinds and options", function()
		assert.same(
			{
				name = "Team",
				required = true,
				kind = "select",
				options = { { id = "1", name = "Platform" }, { id = "2", name = "High" } },
			},
			mapper.to_meta_field({
				name = "Team",
				required = true,
				schema = { type = "option" },
				allowedValues = { { id = "1", value = "Platform" }, { id = 2, name = "High" }, { name = "No id" } },
			})
		)
		for _, case in ipairs({
			{ { type = "array", items = "option" }, "multi_select", { { id = "1", value = "A" } } },
			{ { type = "string", custom = "com.atlassian.jira.plugin.system.customfieldtypes:textfield" }, "text" },
			{ { type = "number" }, "number" },
			{ { type = "date" }, "date" },
			{ { type = "array", items = "string" }, "labels" },
			{ { type = "array", items = "json", custom = "com.pyxis.greenhopper.jira:gh-sprint" }, "sprint" },
			{ { type = "string", system = "environment" }, "paragraph" },
			{ { type = "string", custom = "com.atlassian.jira.plugin.system.customfieldtypes:textarea" }, "paragraph" },
			{ { type = "string", custom = "com.pyxis.greenhopper.jira:jsw-issue-color" } },
			{ { type = "user" } },
		}) do
			assert.equal(case[2], mapper.to_meta_field({ schema = case[1], allowedValues = case[3] }).kind)
		end
	end)

	it("maps current values to initial create field values", function()
		local document = {
			type = "doc",
			version = 1,
			content = { { type = "paragraph", content = { { type = "text", text = "macOS 15" } } } },
		}
		for _, case in ipairs({
			{
				field = { schema = { type = "priority" }, allowedValues = { { id = "3", name = "Medium" } } },
				value = { id = "3", name = "Medium" },
				expected = { label = "Medium", value = { id = "3" } },
			},
			{
				field = {
					schema = { type = "array", items = "option" },
					allowedValues = { { id = "1", value = "A" }, { id = "2", value = "B" } },
				},
				value = { { id = "1", value = "A" }, { id = "2", value = "B" } },
				expected = { label = "A, B", value = { { id = "1" }, { id = "2" } } },
			},
			{
				field = { schema = { type = "array", items = "string" } },
				value = { "one", "two" },
				expected = { label = "one, two", value = { "one", "two" } },
			},
			{ field = { schema = { type = "number" } }, value = 5, expected = { label = "5", value = 5 } },
			{
				field = { schema = { custom = "com.pyxis.greenhopper.jira:gh-sprint" } },
				value = {
					{ id = 2, name = "Sprint 2", state = "closed" },
					{ id = 3, name = "Sprint 3", state = "active" },
				},
				expected = { label = "Sprint 3", value = 3 },
			},
			{
				field = { schema = { custom = "com.pyxis.greenhopper.jira:gh-sprint" } },
				value = { { id = 2, name = "Sprint 2", state = "closed" } },
			},
			{
				field = { schema = { type = "string", system = "environment" } },
				value = document,
				expected = { label = "macOS 15", value = document },
			},
			{ field = { schema = { type = "array", items = "string" } }, value = {} },
			{ field = { schema = { type = "user" } }, value = "someone" },
			{ field = { schema = { type = "option" } }, value = vim.NIL },
		}) do
			assert.same(case.expected, mapper.to_meta_field(case.field, case.value).initial)
		end
	end)

	it("uses the generic icon and a dynamic color for custom issue types", function()
		local icon = assert(mapper.to_issue_type({ id = "10002", name = "Custom" }).icon)

		assert.equal(icons.get("issue"), icon.icon)
		assert.matches("^AtlasDynColor%d+$", icon.hl_group)
	end)
end)
