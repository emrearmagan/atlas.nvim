local service_name = "atlas.pulls.providers.azure.api.service"
local module_names = {
	service_name,
	"atlas.pulls.providers.azure.api.users",
	"atlas.pulls.providers.azure.api.mapper",
	"atlas.pulls.providers.azure.api.pullrequests",
	"atlas.pulls.providers.azure.init",
}

describe("Azure DevOps dashboard requests", function()
	local original = {}

	before_each(function()
		for _, name in ipairs(module_names) do
			original[name] = package.loaded[name]
			package.loaded[name] = nil
		end
	end)

	after_each(function()
		for _, name in ipairs(module_names) do
			package.loaded[name] = original[name]
		end
	end)

	it("loads a repository view into the dashboard model", function()
		package.loaded[service_name] = {
			base_url = function()
				return "https://dev.azure.com/acme"
			end,
			url_encode = require("atlas.core.utils").url_encode,
			build_query = require(service_name).build_query,
			get_cache = function()
				return nil, false
			end,
			set_cache = function() end,
			request = function(method, endpoint, _, done)
				assert.equal("GET", method)
				assert.equal(
					"/Platform/_apis/git/repositories/api/pullrequests?$skip=0&$top=50&searchCriteria.status=active",
					endpoint
				)
				done({
					value = {
						{
							pullRequestId = 1,
							title = "Add Azure support",
							status = "active",
							mergeStatus = "succeeded",
							createdBy = {
								id = "author-id",
								displayName = "Emre Armagan",
								uniqueName = "emre@example.com",
							},
							creationDate = "2026-09-07T12:00:00Z",
							sourceRefName = "refs/heads/feature/azure",
							targetRefName = "refs/heads/main",
							repository = { name = "api", project = { name = "Platform" } },
						},
					},
				}, nil)
			end,
		}
		local core = require("atlas.pulls.providers.azure.init").capabilities.core
		local completed = false
		core.fetch_pullrequests({ project = "Platform", repository = "api", scope = "all" }, {}, function(page, err)
			completed = true
			assert.is_nil(err)
			assert.equal(1, #page.items)
			assert.equal("Add Azure support", page.items[1].title)
			assert.equal("Platform/api", page.items[1].repo_full_name)
			assert.equal("succeeded", page.items[1].merge_status)
			assert.equal("Emre Armagan", require("atlas.pulls.ui.presentation").user_handle(page.items[1].author))
		end)
		assert.is_true(completed)
	end)
end)
