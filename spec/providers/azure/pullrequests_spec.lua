local service_name = "atlas.pulls.providers.azure.api.service"
local module_names = {
	service_name,
	"atlas.pulls.providers.azure.api.users",
	"atlas.pulls.providers.azure.api.mapper",
	"atlas.pulls.providers.azure.api.pullrequests",
	"atlas.pulls.providers.azure.api.reviews",
	"atlas.pulls.providers.azure.api.checks",
	"atlas.pulls.providers.azure.api.activity",
	"atlas.pulls.providers.azure.api.changes",
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
	repository = { name = "api", project = { id = "project-id", name = "Platform" } },
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

	it("loads Conversation threads and paginated Commits", function()
		local service = require(service_name)
		local function comment(id, parent, content, kind)
			return {
				id = id,
				parentCommentId = parent,
				content = content,
				commentType = kind or "text",
				author = pull_request.createdBy,
				publishedDate = pull_request.creationDate,
			}
		end
		package.loaded[service_name] = {
			base_url = function()
				return "https://dev.azure.com/acme"
			end,
			url_encode = service.url_encode,
			build_query = service.build_query,
			get_cache = function()
				return nil, false
			end,
			set_cache = function() end,
			request = function(method, endpoint, _, done)
				assert.equal("GET", method)
				local base = "/Platform/_apis/git/repositories/api/pullrequests/1"
				if endpoint == base .. "/threads" then
					done({
						value = {
							{
								id = 1,
								status = "active",
								comments = { comment(1, 0, "Question"), comment(2, 1, "Reply") },
							},
							{ id = 2, status = "fixed", comments = { comment(1, 0, "Resolved") } },
							{ id = 3, comments = { comment(1, 0, "Branch updated", "system") } },
							{
								id = 4,
								threadContext = { filePath = "/main.lua" },
								comments = { comment(1, 0, "Inline") },
							},
						},
					}, nil)
					return
				end
				local first = endpoint == base .. "/commits?$top=100"
				if not first then
					assert.equal(base .. "/commits?$top=100&continuationToken=next%2Fpage", endpoint)
				end
				done({
					value = {
						{
							commitId = string.rep(first and "a" or "b", 40),
							comment = "Add Azure support",
							author = { name = "Emre Armagan", date = pull_request.creationDate },
							remoteUrl = "https://dev.azure.com/acme/Platform/_git/api/commit/example",
						},
					},
				}, nil, first and { ["x-ms-continuationtoken"] = "next/page" } or {})
			end,
		}
		local capabilities = require("atlas.pulls.providers.azure.init").capabilities
		local pr = require("atlas.pulls.providers.azure.api.mapper").to_pull_request(pull_request)
		local completed = 0
		capabilities.comments.fetch_conversation(pr, {}, function(items, err)
			assert.is_nil(err)
			assert.equal(4, #items)
			assert.equal("Emre Armagan", items[1].entity.author.nickname)
			assert.equal("1:1", items[2].entity.parent_id)
			assert.equal("2:1", items[3].entity.id)
			assert.equal("RESOLVED", items[3].entity.state)
			assert.equal("activity", items[4].kind)
			assert.equal("Branch updated", items[4].entity.label)
			completed = completed + 1
		end)
		capabilities.core.fetch_commits(pr, {}, function(commits, err)
			assert.is_nil(err)
			assert.equal(2, #commits)
			assert.equal("aaaaaaaa", commits[1].short_hash)
			assert.equal("bbbbbbbb", commits[2].short_hash)
			assert.equal("Emre Armagan", commits[1].author_name)
			completed = completed + 1
		end)
		assert.equal(2, completed)
	end)

	it("loads reviewers, merge status and branch policies for Overview", function()
		local service = require(service_name)
		local evaluated_at = "2026-09-07T12:00:00Z"
		package.loaded[service_name] = {
			base_url = function()
				return "https://dev.azure.com/acme"
			end,
			url_encode = service.url_encode,
			build_query = service.build_query,
			get_cache = function()
				return nil, false
			end,
			set_cache = function() end,
			request = function(method, endpoint, _, done, _, api_version)
				assert.equal("GET", method)
				if endpoint == "/Platform/_apis/git/repositories/api/pullrequests/1/reviewers" then
					done({
						value = {
							{
								id = "reviewer-id",
								displayName = "Reviewer",
								uniqueName = "reviewer@example.com",
								vote = 10,
							},
						},
					}, nil)
					return
				end
				assert.equal(
					"/Platform/_apis/policy/evaluations?artifactId=vstfs%3A%2F%2F%2FCodeReview%2FCodeReviewId%2Fproject-id%2F1",
					endpoint
				)
				assert.equal("7.1-preview.1", api_version)
				done({
					value = {
						{
							evaluationId = "required",
							status = "rejected",
							startedDate = evaluated_at,
							configuration = {
								isBlocking = true,
								type = { displayName = "Minimum number of reviewers" },
								settings = {},
							},
						},
						{
							evaluationId = "optional",
							status = "rejected",
							completedDate = evaluated_at,
							configuration = {
								isBlocking = false,
								type = { displayName = "Build" },
								settings = { displayName = "Tests" },
							},
						},
					},
				}, nil)
			end,
		}
		local core = require("atlas.pulls.providers.azure.init").capabilities.core
		local pr = require("atlas.pulls.providers.azure.api.mapper").to_pull_request(pull_request)
		pr.merge_status = "conflicts"
		local completed = 0
		core.fetch_reviewers(pr, {}, function(reviewers, err)
			assert.is_nil(err)
			assert.equal("Reviewer", reviewers[1].nickname)
			assert.equal("approved", reviewers[1].decision)
			completed = completed + 1
		end)
		core.fetch_merge_checks(pr, {}, function(checks, err)
			assert.is_nil(err)
			local when = require("atlas.ui.shared.utils").relative_time_text(evaluated_at)
			assert.same({
				{ key = "merge", state = "failed", label = "Merge conflicts must be resolved" },
				{
					key = "required",
					state = "failed",
					label = "Minimum number of reviewers",
					details = { "Evaluation started " .. when },
				},
				{ key = "optional", state = "warning", label = "Build: Tests", details = { "Completed " .. when } },
			}, checks)
			completed = completed + 1
		end)
		assert.equal(2, completed)
	end)
end)
