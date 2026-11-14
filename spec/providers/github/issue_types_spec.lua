local github_client = require("spec.support.github_client_stub")

local MODULES = { "atlas.issues.providers.github.api.issues" }

local function fresh_module()
	for _, name in ipairs(MODULES) do
		package.loaded[name] = nil
	end
	return require("atlas.issues.providers.github.api.issues")
end

describe("github issue types", function()
	local calls

	before_each(function()
		calls = {}
	end)

	after_each(function()
		github_client.uninstall()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = nil
		end
	end)

	---@param result any
	local function install(result)
		github_client.install({
			gh = function(args, callback)
				table.insert(calls, args)
				callback(result, nil)
			end,
		})
	end

	it("lists only enabled repository issue types", function()
		install({
			data = {
				repository = {
					issueTypes = {
						nodes = {
							{ id = "IT_1", name = "Task", color = "YELLOW", isEnabled = true },
							{ id = "IT_2", name = "Epic", color = "PURPLE", isEnabled = false },
							{ id = "IT_3", name = "Bug", color = "RED", isEnabled = true },
						},
					},
				},
			},
		})
		local api = fresh_module()

		local types
		api.list_issue_types("owner/repo", function(result)
			types = result
		end)

		assert.same(
			{ "Task", "Bug" },
			vim.tbl_map(function(item)
				return item.name
			end, types)
		)
		assert.equal("owner=owner", calls[1][6])
		assert.equal("repo=repo", calls[1][8])
	end)

	it("returns no types when the owner deleted all of them", function()
		install({ data = { repository = { issueTypes = { nodes = {} } } } })
		local api = fresh_module()

		local types
		api.list_issue_types("owner/repo", function(result)
			types = result
		end)

		assert.same({}, types)
	end)

	it("sets and removes the issue type with gh issue edit", function()
		install(nil)
		local api = fresh_module()

		api.set_issue_type("owner/repo#42", "Bug", function() end)
		api.set_issue_type("owner/repo#42", nil, function() end)

		assert.same({
			{ "issue", "edit", "42", "--repo", "owner/repo", "--type", "Bug" },
			{ "issue", "edit", "42", "--repo", "owner/repo", "--remove-type" },
		}, calls)
	end)

	it("creates an issue with its type", function()
		install("https://github.com/owner/repo/issues/42\n")
		local api = fresh_module()

		api.create_issue({ repo_slug = "owner/repo", title = "Title", issue_type = "Feature" }, function() end)

		assert.same(
			{ "issue", "create", "--repo", "owner/repo", "--title", "Title", "--body", "", "--type", "Feature" },
			calls[1]
		)
	end)

	it("updates the issue type by name and clears it with null", function()
		install({ html_url = "https://github.com/owner/repo/issues/42" })
		local api = fresh_module()

		api.update_issue("owner/repo#42", { issue_type = "Bug" }, function() end)
		api.update_issue("owner/repo#42", { issue_type = false }, function() end)
		api.update_issue("owner/repo#42", { title = "Title" }, function() end)

		assert.same({
			{ "api", "-X", "PATCH", "repos/owner/repo/issues/42", "-f", "type=Bug" },
			{ "api", "-X", "PATCH", "repos/owner/repo/issues/42", "-F", "type=null" },
			{ "api", "-X", "PATCH", "repos/owner/repo/issues/42", "-f", "title=Title" },
		}, calls)
	end)
end)
