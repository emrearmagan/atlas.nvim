describe("Bitbucket merge checks", function()
	local api, previous_service, previous_api, complete, request, cache
	local handle = { cancel = function() end }
	local pr = { repo_full_name = "workspace/repo", id = 42 }

	before_each(function()
		previous_service = package.loaded["atlas.providers.bitbucket.client"]
		previous_api = package.loaded["atlas.pulls.providers.bitbucket.api.checks"]
		cache, request, complete = {}, nil, nil
		package.loaded["atlas.providers.bitbucket.client"] = {
			get_cache = function(key)
				return cache[key], cache[key] ~= nil
			end,
			set_cache = function(key, value)
				cache[key] = value
			end,
			request = function(method, endpoint, _, _, done)
				request, complete = { method, endpoint }, done
				return handle
			end,
		}
		package.loaded["atlas.pulls.providers.bitbucket.api.checks"] = nil
		api = require("atlas.pulls.providers.bitbucket.api.checks")
	end)

	after_each(function()
		package.loaded["atlas.providers.bitbucket.client"] = previous_service
		package.loaded["atlas.pulls.providers.bitbucket.api.checks"] = previous_api
	end)

	local function fetch(values)
		local result
		api.fetch(pr, { force_refresh = true }, function(value, err)
			assert.is_nil(err)
			result = value
		end)
		complete({ values = values }, nil)
		return result
	end

	it("combines review outcomes while keeping approval counts separate", function()
		local approvals = {
			type = "standard_merge_check",
			check = { kind = "minimum_approvals" },
			observed = { approval_count = 2 },
			requirement = { minimum_approvals = 2 },
			status = "PASSED",
		}
		local defaults = {
			type = "standard_merge_check",
			check = { kind = "minimum_default_reviewer_approvals" },
			observed = { default_reviewer_approval_count = 1 },
			requirement = { minimum_default_reviewer_approvals = 1 },
			status = "PASSED",
		}
		assert.same({
			{
				key = "reviews",
				state = "successful",
				label = "Review requirements met",
				details = { "2 of 2 approvals received", "1 of 1 default reviewer approvals received" },
			},
		}, fetch({ approvals, defaults }))

		for status, state in pairs({ FAILED = "failed", PENDING = "inprogress", UNKNOWN = "warning", SKIPPED = "muted" }) do
			defaults.status = status
			assert.equal(state, fetch({ approvals, defaults })[1].state)
			assert.equal(state, fetch({ defaults, approvals })[1].state)
		end
		approvals.status, defaults.status = "FAILED", "PASSED"
		assert.equal("failed", fetch({ approvals, defaults })[1].state)
		assert.same({ "1 of 1 default reviewer approvals received" }, fetch({ defaults })[1].details)
	end)

	it("combines build checks without repeating successful conditions", function()
		local values = {
			{
				type = "standard_merge_check",
				check = { kind = "minimum_successful_builds" },
				observed = { successful_build_count = 1 },
				requirement = { minimum_successful_builds = 1 },
				status = "PASSED",
			},
			{
				type = "standard_merge_check",
				check = { kind = "failed_builds" },
				observed = { failed_build_count = 0 },
				status = "PASSED",
			},
			{
				type = "standard_merge_check",
				check = { kind = "in_progress_builds" },
				observed = { in_progress_build_count = 0 },
				status = "PASSED",
			},
		}
		assert.same({
			{
				key = "pipelines",
				state = "successful",
				label = "Build requirements met",
				details = { "1 successful build reported; 1 required" },
			},
		}, fetch(values))

		local result = fetch({ values[2], values[3] })
		assert.equal(1, #result)
		assert.equal("successful", result[1].state)
		assert.same({}, result[1].details)

		values[2].status = "FAILED"
		values[2].observed.failed_build_count = 1
		result = fetch(values)
		assert.equal(1, #result)
		assert.equal("failed", result[1].state)
		assert.equal("Build requirements not met", result[1].label)
		assert.same({ "1 successful build reported; 1 required", "1 build reported failures" }, result[1].details)
	end)

	it("shows technical checks, tasks and change requests only when failed", function()
		local values = {
			{ type = "current_user_permission_check" },
			{ type = "git_mergeability_check", reason = "conflicts" },
			{ type = "pullrequest_state_check", state = "DRAFT" },
			{ type = "standard_merge_check", check = { kind = "resolved_tasks" } },
			{ type = "standard_merge_check", check = { kind = "no_changes_requested" } },
		}
		for _, value in ipairs(values) do
			value.status = "PASSED"
		end
		assert.same({}, fetch(values))

		for _, value in ipairs(values) do
			value.status = "FAILED"
		end
		local result = fetch(values)
		assert.equal(#values, #result)
		assert.equal("Merge conflicts must be resolved", result[2].label)
		assert.same({}, result[2].details)
	end)

	it("preserves custom messages and displays unfamiliar checks", function()
		local result = fetch({
			{
				type = "custom_pre_merge_check",
				check = { id = "security", name = "Security scan" },
				message = "Dependency scan failed",
				status = "FAILED",
				blocking = false,
			},
			{ type = "standard_merge_check", check = { kind = "new_policy" }, status = "PENDING" },
		})
		assert.same({
			{
				key = "custom_pre_merge_check:security",
				label = "Security scan",
				state = "failed",
				details = { "Dependency scan failed", "Does not block merging" },
			},
			{
				key = "new_policy",
				label = "New policy",
				state = "inprogress",
				details = { "Check has not completed yet" },
			},
		}, result)
	end)

	it("reuses cached checks and refreshes them when requested", function()
		local result
		assert.equal(
			handle,
			api.fetch(pr, nil, function(value)
				result = value
			end)
		)
		assert.is_nil(result)
		assert.same({ "GET", "/repositories/workspace/repo/pullrequests/42/mergeability/checks" }, request)
		complete({ values = {} }, nil)
		request, result = nil, nil
		assert.is_nil(api.fetch(pr, nil, function(value)
			result = value
		end))
		assert.same({}, result)
		assert.is_nil(request)
		assert.equal(handle, api.fetch(pr, { force_refresh = true }, function() end))
		assert.is_not_nil(request)
	end)

	it("reports request errors without caching a successful result", function()
		local result, err
		api.fetch(pr, nil, function(value, message)
			result, err = value, message
		end)
		complete(nil, "Custom check results unavailable")
		assert.is_nil(result)
		assert.equal("Custom check results unavailable", err)
		assert.same({}, cache)
	end)
end)
