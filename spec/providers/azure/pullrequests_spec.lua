local service_name = "atlas.pulls.providers.azure.api.service"
local module_names = {
	service_name,
	"atlas.pulls.providers.azure.api.users",
	"atlas.pulls.providers.azure.api.mapper",
	"atlas.pulls.providers.azure.api.pullrequests",
	"atlas.pulls.providers.azure.init",
}

local pull_request = {
	pullRequestId = 1,
	title = "Add Azure support",
	description = string.rep("Full description. ", 40),
	status = "active",
	mergeStatus = "succeeded",
	createdBy = { id = "author-id", displayName = "Emre Armagan", uniqueName = "emre@example.com" },
	creationDate = "2026-09-07T12:00:00Z",
	sourceRefName = "refs/heads/feature/azure",
	targetRefName = "refs/heads/main",
	repository = { name = "api", project = { name = "Platform" } },
}

describe("Azure DevOps pull requests", function()
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
				done({ value = { pull_request } }, nil)
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

	it("loads full PR details and updates the title", function()
		local service = require(service_name)
		local cache = {}
		local requests = {}
		package.loaded[service_name] = {
			base_url = function()
				return "https://dev.azure.com/acme"
			end,
			url_encode = service.url_encode,
			get_cache = function(key)
				return cache[key], cache[key] ~= nil
			end,
			set_cache = function(key, value)
				cache[key] = value
			end,
			clear_cache = function()
				cache = {}
			end,
			request = function(method, endpoint, payload, done)
				table.insert(requests, { method = method, payload = payload })
				if endpoint == "/Platform/_apis/git/repositories/api/pullrequests/1/labels" then
					assert.equal("GET", method)
					done({ value = { { name = "test" } } }, nil)
					return
				end
				assert.equal("/Platform/_apis/git/repositories/api/pullrequests/1", endpoint)
				done(pull_request, nil)
			end,
		}
		local capabilities = require("atlas.pulls.providers.azure.init").capabilities
		local core = capabilities.core
		local ref = { id = 1, repo_full_name = "Platform/api" }
		local completed = 0
		core.fetch_by_refs({ ref }, {}, function(pulls, err)
			assert.is_nil(err)
			assert.equal("Add Azure support", pulls[1].title)
			completed = completed + 1
		end)
		core.fetch_pullrequest(ref, {}, function(details, err)
			assert.is_nil(err)
			assert.same({ description = pull_request.description, labels = { { name = "test" } } }, details)
			assert.same(
				{ { label = "test", hl = "AtlasTabInactive" } },
				capabilities.ui.detail.chips(ref, details, false)
			)
			completed = completed + 1
		end)
		core.fetch_description(ref, { force_refresh = true }, function(description, err)
			assert.is_nil(err)
			assert.equal(pull_request.description, description)
			completed = completed + 1
		end)
		core.update_title(ref, "Updated title", function(ok, err)
			assert.is_nil(err)
			assert.is_true(ok)
			completed = completed + 1
		end)
		assert.equal(4, completed)
		assert.same({
			{ method = "GET" },
			{ method = "GET" },
			{ method = "GET" },
			{ method = "PATCH", payload = { title = "Updated title" } },
		}, requests)
		assert.same({}, cache)
	end)
end)
