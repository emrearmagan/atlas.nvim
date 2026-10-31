local module_name = "atlas.pulls.providers.gitlab.api.pullrequests"
local cleared

local function fresh_module()
	package.loaded[module_name] = nil
	return require(module_name)
end

---@param request fun(method: string, endpoint: string, payload: table|nil, callback: function, ctx: table|nil)
local function stub_service(request)
	rawset(package.preload, "atlas.providers.gitlab.client", function()
		return {
			request = request,
			url_encode = function(value)
				return (tostring(value):gsub("/", "%%2F"))
			end,
			delete_memory_cache = function() end,
			clear_cache = function(prefix)
				assert.equal("gitlab_pulls:merge_requests:gql:", prefix)
				cleared = cleared + 1
			end,
		}
	end)
end

describe("gitlab pull request updates", function()
	local calls

	before_each(function()
		calls = {}
		cleared = 0
		package.loaded[module_name] = nil
		package.loaded["atlas.providers.gitlab.client"] = nil
	end)

	after_each(function()
		package.preload["atlas.providers.gitlab.client"] = nil
		package.loaded["atlas.providers.gitlab.client"] = nil
		package.loaded[module_name] = nil
	end)

	it("PUTs descriptions including an empty body and accepts empty responses", function()
		local response
		stub_service(function(method, endpoint, payload, callback)
			table.insert(calls, { method = method, endpoint = endpoint, payload = payload })
			callback(response, nil)
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project" }

		for index, case in ipairs({
			{ body = "New body", response = { iid = 12, description = "Normalized by GitLab" } },
			{ body = "New body" },
			{ body = "", response = { iid = 12, description = "" } },
		}) do
			response = case.response
			local ok, err
			api.update_pr(pr, { body = case.body }, function(success, e)
				ok, err = success, e
			end)
			assert.is_true(ok)
			assert.is_nil(err)
			assert.same({
				method = "PUT",
				endpoint = "/projects/group%2Fproject/merge_requests/12",
				payload = { description = case.body },
			}, calls[index])
		end
		assert.equal(3, #calls)
		assert.equal(3, cleared)
	end)

	it("uses the merge or squash message field", function()
		stub_service(function(_, _, payload, callback)
			table.insert(calls, payload)
			callback({}, nil)
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project" }
		for _, case in ipairs({ { method = "merge", body = "Body" }, { method = "squash", body = "" } }) do
			api.merge(pr, {
				method = case.method,
				delete_source_branch = true,
				subject = "Subject",
				body = case.body,
			}, function() end)
		end
		assert.same(
			{ squash = false, should_remove_source_branch = true, merge_commit_message = "Subject\n\nBody" },
			calls[1]
		)
		assert.same({ squash = true, should_remove_source_branch = true, squash_commit_message = "Subject" }, calls[2])
		assert.equal(2, cleared)
	end)

	it("clears selections and removes draft from a changed title", function()
		stub_service(function(_, _, payload, callback)
			table.insert(calls, payload)
			callback({}, nil)
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project", title = "Draft: Old title", state = "draft" }

		api.update_pr(pr, {
			title = "Draft: New title",
			body = "",
			draft = false,
			labels = {},
			assignees = {},
			reviewers = {},
		}, function(ok, err)
			assert.is_true(ok)
			assert.is_nil(err)
		end)

		assert.same({
			{
				title = "New title",
				description = "",
				labels = "",
				assignee_ids = { 0 },
				reviewer_ids = { 0 },
			},
		}, calls)
		assert.equal("New title", pr.title)
		assert.equal("open", pr.state)
		assert.equal(1, cleared)
	end)
end)
