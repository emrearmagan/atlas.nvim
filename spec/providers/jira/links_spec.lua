local config = require("atlas.config")
local text_links = require("atlas.providers.jira.links")

describe("Jira issue references", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = { providers = { jira = { base_url = "https://jira.example/jira/" } } }
	end)

	after_each(function()
		config.options = original_options
	end)

	it("extracts multiple unique keys from PR titles and source branches", function()
		local links = text_links.resolve("KAN-1 KAN_2-30: Fix", "feature/KAN-1-KAN-4-fix")
		assert.equal(3, #links)
		assert.same({ "KAN-1", "KAN_2-30", "KAN-4" }, { links[1].key, links[2].key, links[3].key })
		assert.equal("https://jira.example/jira/browse/KAN-1", links[1].url)
		assert.equal("references", links[1].relationship)
	end)

	it("does not extract partial keys embedded in identifiers", function()
		assert.same({}, text_links.resolve("myKAN-1 KAN-12abc _KAN-1 1KAN-1 kan-1"))
	end)
end)

describe("Jira links API", function()
	local original_options, original_service, original_links
	local api, callbacks

	before_each(function()
		original_options = config.options
		original_service = package.loaded["atlas.providers.jira.client"]
		original_links = package.loaded["atlas.issues.providers.jira.api.links"]
		config.options = {
			providers = {
				jira = { base_url = "https://jira.example/jira" },
				github = {},
				gitlab = { base_url = "https://gitlab.example" },
				bitbucket = {},
			},
		}
		callbacks = {}
		package.loaded["atlas.providers.jira.client"] = {
			base_url = function()
				return "https://jira.example/jira"
			end,
			get_memory_cache = function()
				return nil, false
			end,
			set_memory_cache = function() end,
			request = function(_, endpoint, _, done)
				local source = endpoint:match("/dev%-status/[^/]+/issue/(%w+)")
					or (endpoint:find("remotelink", 1, true) and "remote" or "issues")
				callbacks[source] = done
			end,
		}
		package.loaded["atlas.issues.providers.jira.api.links"] = nil
		api = require("atlas.issues.providers.jira.api.links")
	end)

	after_each(function()
		config.options = original_options
		package.loaded["atlas.providers.jira.client"] = original_service
		package.loaded["atlas.issues.providers.jira.api.links"] = original_links
	end)

	it("preserves parent, sub-issue, and directional issue relationships", function()
		local links = api.issue_links({
			fields = {
				parent = { key = "KAN-1", fields = { summary = "Parent" } },
				subtasks = { { key = "KAN-3" } },
				issuelinks = {
					{ type = { outward = "blocks" }, outwardIssue = { key = "KAN-4" } },
					{ type = { inward = "is blocked by" }, inwardIssue = { key = "KAN-5" } },
				},
			},
		})
		assert.equal(4, #links)
		assert.same({ "parent", "sub-issue", "blocks", "is blocked by" }, {
			links[1].relationship,
			links[2].relationship,
			links[3].relationship,
			links[4].relationship,
		})
		assert.equal("https://jira.example/jira/browse/KAN-1", links[1].url)
		assert.same({}, api.issue_links({ fields = { parent = vim.NIL, subtasks = vim.NIL, issuelinks = vim.NIL } }))
	end)

	it("recognizes PR remote links across GitHub, GitLab and Bitbucket", function()
		local urls = {
			"https://github.com/team/repo/pull/1",
			"https://gitlab.example/group/sub/repo/-/merge_requests/2",
			"https://bitbucket.org/team/repo/pull-requests/3",
			"https://jira.example/jira/browse/KAN-4",
			"https://docs.example/design",
			"javascript:alert(1)",
		}
		local raw = {}
		for _, url in ipairs(urls) do
			table.insert(raw, { relationship = "implements", object = { url = url, title = "Title" } })
		end
		local links = api.remote_links(raw)
		assert.equal(5, #links)
		assert.same({ "pr", "pr", "pr", "issue", "external" }, {
			links[1].kind,
			links[2].kind,
			links[3].kind,
			links[4].kind,
			links[5].kind,
		})
		assert.equal("group/sub/repo!2", links[2].key)
		assert.equal("KAN-4", links[4].key)
	end)

	it("combines issue relationships with remote and development pull requests", function()
		local result
		api.fetch({ id = "10002", key = "KAN-2" }, {}, function(links, err)
			result = links
			assert.is_nil(err)
		end)
		callbacks.detail({
			detail = {
				{
					pullRequests = {
						{ id = "2", name = "Development PR", url = "https://bitbucket.org/team/repo/pull-requests/2" },
					},
				},
			},
		})
		callbacks.issues({ fields = { parent = { key = "KAN-1" } } })
		callbacks.remote({ { object = { url = "https://github.com/team/repo/pull/1" } } })
		assert.equal(3, #result)
		assert.equal("parent", result[1].relationship)
		assert.equal("pr", result[2].kind)
		assert.equal("Development PR", result[3].title)
	end)
end)
