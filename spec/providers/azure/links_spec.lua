local dependencies = {
	"atlas.providers.azure.client",
	"atlas.issues.providers.azure.api.issues",
	"atlas.pulls.providers.azure.api.mapper",
}
local previous = { loaded = {}, preload = {} }
local api, responses, endpoints

local function work_item(id)
	return {
		key = tostring(id),
		title = "Item " .. id,
		url = "https://dev.azure.com/acme/Platform/_workitems/edit/" .. id,
	}
end

describe("Azure linked items", function()
	before_each(function()
		responses, endpoints = {}, {}
		local stubs = {
			["atlas.providers.azure.client"] = {
				url_encode = require("atlas.core.utils").url_encode,
				build_query = function(params)
					return "?$expand=" .. params["$expand"]
				end,
				get_cache = function()
					return nil, false
				end,
				set_cache = function() end,
				request = function(_, endpoint, _, done)
					table.insert(endpoints, endpoint)
					done(responses[endpoint], nil)
				end,
			},
			["atlas.issues.providers.azure.api.issues"] = {
				fetch_by_refs = function(refs, _, done)
					done(vim.tbl_map(function(ref)
						return work_item(ref.key)
					end, refs))
				end,
			},
			["atlas.pulls.providers.azure.api.mapper"] = {
				to_pull_request = function(raw)
					return { id = raw.pullRequestId, title = raw.title, link = { html = "https://example.com/pr/17" } }
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
		package.loaded["atlas.providers.azure.links"] = nil
		api = require("atlas.providers.azure.links")
	end)

	after_each(function()
		package.loaded["atlas.providers.azure.links"] = nil
		for _, name in ipairs(dependencies) do
			package.loaded[name] = previous.loaded[name]
			package.preload[name] = previous.preload[name]
		end
		previous = { loaded = {}, preload = {} }
	end)

	it("maps work item relations, linked pull requests and hyperlinks", function()
		local items = "https://dev.azure.com/acme/_apis/wit/workItems/"
		responses["/_apis/wit/workitems/42?$expand=relations"] = {
			relations = {
				{ rel = "System.LinkTypes.Hierarchy-Reverse", url = items .. "1", attributes = { name = "Parent" } },
				{ rel = "System.LinkTypes.Hierarchy-Forward", url = items .. "2", attributes = { name = "Child" } },
				{
					rel = "System.LinkTypes.Dependency-Forward",
					url = items .. "3",
					attributes = { name = "Successor" },
				},
				{ rel = "System.LinkTypes.Remote.Related", url = "https://dev.azure.com/other/_apis/wit/workItems/9" },
				{
					rel = "ArtifactLink",
					url = "vstfs:///Git/PullRequestId/project-id%2Frepo-id%2F17",
					attributes = { name = "Pull Request" },
				},
				{ rel = "ArtifactLink", url = "vstfs:///Git/Ref/project-id%2Frepo-id%2FGBmain" },
				{ rel = "Hyperlink", url = "https://example.com/spec", attributes = { comment = "Spec" } },
			},
		}
		responses["/project-id/_apis/git/pullrequests/17"] = { pullRequestId = 17, title = "Fix login" }

		local result
		api.fetch_issue({ key = "42" }, nil, function(links, err)
			assert.is_nil(err)
			result = links
		end)

		assert.same(
			{ "parent", "child", "successor", "development", "linked" },
			vim.tbl_map(function(link)
				return link.relationship
			end, result)
		)
		assert.same(
			{ "1", "2", "3", "17", "https://example.com/spec" },
			vim.tbl_map(function(link)
				return link.key
			end, result)
		)
		assert.equal("pr", result[4].kind)
		assert.equal("Fix login", result[4].title)
		assert.equal("external", result[5].kind)
		assert.equal("Spec", result[5].title)
	end)

	it("links the work items of a pull request", function()
		local endpoint = "/project-id/_apis/git/repositories/repo-id/pullRequests/17/workitems"
		responses[endpoint] = { value = { { id = "5", url = "https://dev.azure.com/acme/_apis/wit/workItems/5" } } }

		local result
		api.fetch_pullrequest(
			{ id = 17, project_id = "project-id", repository_id = "repo-id", repo_full_name = "Platform/api" },
			nil,
			function(links, err)
				assert.is_nil(err)
				result = links
			end
		)

		assert.same({ endpoint }, endpoints)
		assert.same({
			{
				kind = "issue",
				url = "https://dev.azure.com/acme/Platform/_workitems/edit/5",
				key = "5",
				title = "Item 5",
				relationship = "linked",
			},
		}, result)
	end)
end)
