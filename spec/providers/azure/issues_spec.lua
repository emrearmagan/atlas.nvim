local client_name = "atlas.providers.azure.client"
local module_names = {
	client_name,
	"atlas.providers.azure.users",
	"atlas.issues.providers.azure.api.mapper",
	"atlas.issues.providers.azure.api.issues",
	"atlas.issues.providers.azure.api.comments",
}

describe("Azure work items", function()
	local original = {}
	local original_slice
	local client
	local calls

	before_each(function()
		original_slice = vim.list_slice
		vim.list_slice = function(items, first, last)
			local result = {}
			for index = first, last do
				result[#result + 1] = items[index]
			end
			return result
		end
		for _, name in ipairs(module_names) do
			original[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		local real_client = require(client_name)
		calls = {}
		client = {
			url_encode = real_client.url_encode,
			build_query = real_client.build_query,
			base_url = function()
				return "https://dev.azure.com/acme"
			end,
			get_cache = function()
				return nil, false
			end,
			set_cache = function() end,
			clear_cache = function() end,
			request = function(method, endpoint, payload, done)
				calls[#calls + 1] = { method = method, endpoint = endpoint, payload = payload }
				done({}, nil)
			end,
		}
		package.loaded[client_name] = client
	end)

	after_each(function()
		vim.list_slice = original_slice
		for _, name in ipairs(module_names) do
			package.loaded[name] = original[name]
		end
	end)

	it("paginates work items in WIQL order and retains the query", function()
		local query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project"
		client.request = function(method, endpoint, payload, done)
			if method == "POST" then
				assert.same({ query = query }, payload)
				done({ queryType = "flat", workItems = { { id = 1 }, { id = 3 }, { id = 2 }, { id = 4 } } })
			else
				assert.is_truthy(endpoint:find("ids=3%%2C2"))
				done({
					value = {
						{ id = 2, fields = { ["System.TeamProject"] = "Platform" } },
						{ id = 3, fields = { ["System.TeamProject"] = "Platform" } },
					},
				})
			end
		end
		local result
		require("atlas.issues.providers.azure.api.issues").list_issues(
			{ name = "Platform", project = "Platform", search = query },
			{ cursor = "1", pagelen = 2 },
			function(page, err)
				assert.is_nil(err)
				result = page
			end
		)
		assert.equal(query, result.query)
		assert.same({ "3", "2" }, { result.items[1].key, result.items[2].key })
		assert.equal("3", result.next_cursor)
		assert.equal(2, result.total_pages)
	end)

	it("resolves mentions across comment pages without changing editable text", function()
		local pages = 0
		client.request = function(_, endpoint, _, done)
			pages = pages + 1
			if pages == 1 then
				done({
					comments = { { id = 1, text = "Hi @<alice> and @<unknown>", format = "markdown" } },
					continuationToken = "next",
				})
			else
				assert.is_truthy(endpoint:find("continuationToken=next", 1, true))
				done({
					comments = {
						{
							id = 2,
							text = "Reply",
							format = "markdown",
							createdBy = { id = "alice", displayName = "Alice" },
						},
					},
				})
			end
		end
		local result
		require("atlas.issues.providers.azure.api.comments").fetch_conversation(
			{ id = 42, key = "42", title = "Title", project = "Platform" },
			{},
			function(conversation, err)
				assert.is_nil(err)
				result = conversation
			end
		)
		assert.equal(2, pages)
		assert.equal(2, #result.comments)
		assert.same({}, result.activities)
		assert.equal("Hi @<alice> and @<unknown>", result.comments[1].body)
		assert.equal("Hi @Alice and @<unknown>", result.comments[1].body_display)
	end)

	it("only switches the description format when a Markdown description is written", function()
		local api = require("atlas.issues.providers.azure.api.issues")
		local issue = { key = "42", title = "Title" }
		api.update(issue, { ["System.Title"] = "New title" }, function(ok)
			assert.is_true(ok)
		end, { format = "markdown" })
		assert.same({ { op = "add", path = "/fields/System.Title", value = "New title" } }, calls[1].payload)
		api.update(issue, { ["System.Description"] = "Body" }, function(ok)
			assert.is_true(ok)
		end, { format = "markdown" })
		assert.same({
			{ op = "add", path = "/fields/System.Description", value = "Body" },
			{ op = "add", path = "/multilineFieldsFormat/System.Description", value = "Markdown" },
		}, calls[2].payload)
	end)

	it("clears fields with replace because Azure ignores an empty add", function()
		local api = require("atlas.issues.providers.azure.api.issues")
		api.update({ key = "42", title = "Title" }, { ["System.Tags"] = "" }, function(ok)
			assert.is_true(ok)
		end)
		assert.same({ { op = "replace", path = "/fields/System.Tags", value = "" } }, calls[1].payload)
	end)
end)
