local dependencies = { "atlas.providers.gitlab.client", "atlas.config" }
local previous = { loaded = {}, preload = {} }
local api, client, graphql_widgets, graphql_links, jira_options

local function issue(iid, path)
	path = path or "other/repo"
	return {
		title = "Issue " .. iid,
		webUrl = "https://gitlab.example.com/gitlab/" .. path .. "/-/issues/" .. iid,
		reference = path .. "#" .. iid,
		project = { fullPath = path },
	}
end

describe("GitLab linked items", function()
	before_each(function()
		graphql_widgets, graphql_links, jira_options = {}, {}, {}
		client = {
			base_url = function()
				return "https://gitlab.example.com/gitlab"
			end,
			get_memory_cache = function() end,
			set_memory_cache = function() end,
			graphql = function(query, variables, done)
				assert.same("group/repo", variables.path)
				if query:find("namespace(fullPath:", 1, true) then
					done({ namespace = { workItem = { widgets = graphql_widgets } } })
				else
					done({ project = { mergeRequest = { linkedWorkItems = graphql_links } } })
				end
			end,
		}
		local stubs = {
			["atlas.providers.gitlab.client"] = client,
			["atlas.config"] = {
				provider_options = function()
					return jira_options
				end,
			},
		}
		for name, stub in pairs(stubs) do
			previous.loaded[name] = package.loaded[name]
			previous.preload[name] = package.preload[name]
			package.loaded[name] = nil
			package.preload[name] = function()
				return stub
			end
		end
		package.loaded["atlas.providers.gitlab.links"] = nil
		api = require("atlas.providers.gitlab.links")
	end)

	after_each(function()
		package.loaded["atlas.providers.gitlab.links"] = nil
		for _, name in ipairs(dependencies) do
			package.loaded[name] = previous.loaded[name]
			package.preload[name] = previous.preload[name]
		end
		previous = { loaded = {}, preload = {} }
	end)

	it("deduplicates closing and related issues across projects, preserving the closing relationship", function()
		graphql_links = {
			{ linkType = "CLOSES", workItem = issue(2) },
			{ linkType = "MENTIONED", workItem = issue(2) },
			{ linkType = "MENTIONED", workItem = issue(3) },
		}
		local result
		api.fetch_pullrequest({ repo_full_name = "group/repo", id = 7 }, nil, function(links, err)
			assert.is_nil(err)
			result = links
		end)
		assert.equal(2, #result)
		assert.equal("closes", result[1].relationship)
		assert.equal("other/repo#2", result[1].key)
		assert.equal("issue", result[1].kind)
		assert.equal("relates to", result[2].relationship)
	end)

	it("includes linked merge requests and typed issue relationships", function()
		local mr = {
			reference = "other/repo!5",
			title = "Implementation",
			webUrl = "https://gitlab.example.com/gitlab/other/repo/-/merge_requests/5",
		}
		graphql_widgets = {
			{
				closingMergeRequests = { nodes = { { mergeRequest = mr } } },
				relatedMergeRequests = { nodes = { mr } },
			},
			{ linkedItems = { nodes = { { linkType = "is_blocked_by", workItem = issue(4) } } } },
		}
		local result
		api.fetch_issue({ key = "group/repo#1" }, nil, function(links)
			result = links
		end)
		assert.equal(2, #result)
		assert.equal("pr", result[1].kind)
		assert.equal("other/repo!5", result[1].key)
		assert.equal("closed by", result[1].relationship)
		assert.equal("blocked by", result[2].relationship)
	end)

	it("maps project sub-issues and keeps group epic parents as external links", function()
		local parent = { reference = "group&1", webUrl = "https://gitlab.example.com/groups/group/-/epics/1" }
		local first = {
			reference = "group/repo#2",
			webUrl = "https://gitlab.example.com/gitlab/group/repo/-/work_items/2",
			project = { fullPath = "group/repo" },
		}
		local second = {
			reference = "group/repo#3",
			webUrl = "https://gitlab.example.com/gitlab/group/repo/-/work_items/3",
			project = { fullPath = "group/repo" },
		}
		graphql_widgets = {
			{
				parent = parent,
				children = { nodes = { first, second } },
			},
		}
		local result
		api.fetch_issue({ key = "group/repo#1" }, nil, function(links, err)
			assert.is_nil(err)
			result = links
		end)
		assert.equal(3, #result)
		assert.equal("external", result[1].kind)
		assert.equal("parent", result[1].relationship)
		assert.equal("issue", result[2].kind)
		assert.equal("sub-issue", result[3].relationship)
	end)

	it("preserves both hierarchy and blocking relationships to the same issue", function()
		local blocker = issue(4, "group/repo")
		graphql_widgets = {
			{
				linkedItems = {
					nodes = {
						{ linkType = "is_blocked_by", workItem = blocker },
						{ linkType = "is_blocked_by", workItem = blocker },
					},
				},
			},
			{
				parent = {
					reference = "group/repo#4",
					webUrl = blocker.webUrl,
					project = { fullPath = "group/repo" },
				},
			},
		}
		local result
		api.fetch_issue({ key = "group/repo#1" }, nil, function(links, err)
			assert.is_nil(err)
			result = links
		end)
		assert.equal(2, #result)
		assert.equal(result[1].url, result[2].url)
		assert.equal("blocked by", result[1].relationship)
		assert.equal("parent", result[2].relationship)
	end)

	it("preserves canonical cross-project URLs from GraphQL", function()
		graphql_links = { { linkType = "MENTIONED", workItem = issue(2, "elsewhere/another") } }
		local result
		api.fetch_pullrequest({ repo_full_name = "group/repo", id = 7 }, nil, function(links)
			result = links
		end)
		assert.equal("https://gitlab.example.com/gitlab/elsewhere/another/-/issues/2", result[1].url)
		assert.equal("elsewhere/another#2", result[1].key)
	end)

	it("maps external tracker issue keys using the configured Jira instance", function()
		jira_options.base_url = "https://example.atlassian.net/"
		graphql_links = {
			{ linkType = "MENTIONED", externalIssue = { reference = "PROJ-42", title = "Jira work" } },
			{ linkType = "MENTIONED", externalIssue = { reference = "P-1", title = "Single-letter project" } },
		}
		local result
		api.fetch_pullrequest({ repo_full_name = "group/repo", id = 7 }, nil, function(links)
			result = links
		end)
		assert.equal("PROJ-42", result[1].key)
		assert.equal("https://example.atlassian.net/browse/PROJ-42", result[1].url)
		assert.equal("https://example.atlassian.net/browse/P-1", result[2].url)
	end)
end)
