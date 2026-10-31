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
		assert.is_nil(rawget(issue, "_raw"))
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
		assert.is_nil(rawget(details, "key"))
		assert.is_nil(rawget(details, "_raw"))
	end)

	it("maps create metadata fields to kinds and options", function()
		local function kind(schema, allowed_values)
			return mapper.to_meta_field({ schema = schema, allowedValues = allowed_values }).kind
		end

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
		assert.same(
			{ label = "Medium", value = { id = "3" } },
			mapper.to_meta_field(
				{ schema = { type = "priority" }, allowedValues = { { id = "3", name = "Medium" } } },
				{ id = "3", name = "Medium" }
			).initial
		)
		assert.same(
			{ label = "A, B", value = { { id = "1" }, { id = "2" } } },
			mapper.to_meta_field({
				schema = { type = "array", items = "option" },
				allowedValues = { { id = "1", value = "A" }, { id = "2", value = "B" } },
			}, { { id = "1", value = "A" }, { id = "2", value = "B" } }).initial
		)
		assert.same(
			{ label = "one, two", value = { "one", "two" } },
			mapper.to_meta_field({ schema = { type = "array", items = "string" } }, { "one", "two" }).initial
		)
		assert.same({ label = "5", value = 5 }, mapper.to_meta_field({ schema = { type = "number" } }, 5).initial)
		assert.same(
			{ label = "Sprint 3", value = 3 },
			mapper.to_meta_field({ schema = { custom = "com.pyxis.greenhopper.jira:gh-sprint" } }, {
				{ id = 2, name = "Sprint 2", state = "closed" },
				{ id = 3, name = "Sprint 3", state = "active" },
			}).initial
		)
		assert.is_nil(
			mapper.to_meta_field(
				{ schema = { custom = "com.pyxis.greenhopper.jira:gh-sprint" } },
				{ { id = 2, name = "Sprint 2", state = "closed" } }
			).initial
		)
		local document = {
			type = "doc",
			version = 1,
			content = { { type = "paragraph", content = { { type = "text", text = "macOS 15" } } } },
		}
		assert.same(
			{ label = "macOS 15", value = document },
			mapper.to_meta_field({ schema = { type = "string", system = "environment" } }, document).initial
		)
		assert.is_nil(mapper.to_meta_field({ schema = { type = "array", items = "string" } }, {}).initial)
		assert.is_nil(mapper.to_meta_field({ schema = { type = "user" } }, "someone").initial)
		assert.is_nil(mapper.to_meta_field({ schema = { type = "option" } }, vim.NIL).initial)
		assert.equal("multi_select", kind({ type = "array", items = "option" }, { { id = "1", value = "A" } }))
		assert.equal(
			"text",
			kind({ type = "string", custom = "com.atlassian.jira.plugin.system.customfieldtypes:textfield" })
		)
		assert.equal("number", kind({ type = "number" }))
		assert.equal("date", kind({ type = "date" }))
		assert.equal("labels", kind({ type = "array", items = "string" }))
		assert.equal(
			"sprint",
			kind({ type = "array", items = "json", custom = "com.pyxis.greenhopper.jira:gh-sprint" })
		)
		assert.equal("paragraph", kind({ type = "string", system = "environment" }))
		assert.equal(
			"paragraph",
			kind({ type = "string", custom = "com.atlassian.jira.plugin.system.customfieldtypes:textarea" })
		)
		assert.is_nil(kind({ type = "string", custom = "com.pyxis.greenhopper.jira:jsw-issue-color" }))
		assert.is_nil(kind({ type = "user" }))
	end)

	it("uses the generic icon and a dynamic color for custom issue types", function()
		local icon = assert(mapper.to_issue_type({ id = "10002", name = "Custom" }).icon)

		assert.equal(icons.get("issue"), icon.icon)
		assert.matches("^AtlasDynColor%d+$", icon.hl_group)
	end)
end)

describe("Jira comment author roles", function()
	it("marks comments by the issue reporter", function()
		local comments = mapper.to_comments_list({
			comments = {
				{ id = "1", author = { accountId = "a1", displayName = "Alice" } },
				{ id = "2", author = { accountId = "b2", displayName = "Bob" } },
			},
		}, "KAN-1", "", "a1")
		assert.same({ "Author" }, comments[1].author_roles)
		assert.is_nil(comments[2].author_roles)
	end)
end)
