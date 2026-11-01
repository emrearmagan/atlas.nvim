describe("Azure repositories and builds", function()
	local saved, requests, repositories, pipelines
	local modules = {
		"atlas.providers.azure.client",
		"atlas.providers.azure.repositories",
		"atlas.pulls.providers.azure.api.pipelines",
	}
	local repo = { id = "Project/Repo", full_name = "Project/Repo", owner = "Project", repo_name = "Repo" }
	local pr = {
		id = 42,
		repo = repo,
		repo_full_name = "Project/Repo",
		repository_id = "repo-id",
		source = { branch = "feature", commit_hash = "source-sha" },
		merge_commit_hash = "merge-sha",
	}
	local context = { provider = "azure", repo_full_name = "Project/Repo", target = pr }

	before_each(function()
		local client = require("atlas.providers.azure.client")
		saved, requests = {}, {}
		for _, name in ipairs(modules) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		package.loaded[modules[1]] = {
			url_encode = client.url_encode,
			build_query = client.build_query,
			get_cache = function() end,
			set_cache = function() end,
			clear_cache = function() end,
			request = function(method, endpoint, payload, done)
				local request = { method = method, endpoint = endpoint, payload = payload, done = done }
				requests[#requests + 1] = request
			end,
			fetch_all = function(endpoint, params, _, done)
				requests[#requests + 1] = { endpoint = endpoint .. client.build_query(params), done = done }
			end,
		}
		repositories = require("atlas.providers.azure.repositories")
		pipelines = require("atlas.pulls.providers.azure.api.pipelines")
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("filters tags and peels annotated tags", function()
		local tags
		repositories.fetch_tags(repo, { search = "v2" }, function(value, err, cursor)
			assert.is_nil(err)
			assert.is_nil(cursor)
			tags = value
		end)
		requests[1].done({
			{ name = "refs/tags/v1", objectId = "one" },
			{ name = "refs/tags/v2", objectId = "tag", peeledObjectId = "commit" },
		})
		assert.same({ { name = "v2", hash = "commit" } }, tags)
	end)

	local function build(id, source)
		return {
			id = id,
			definition = { name = "CI" },
			buildNumber = "1",
			status = "completed",
			result = "succeeded",
			sourceVersion = source,
			queueTime = "2026-01-01",
			_links = { web = { href = "https://example/build/" .. id } },
		}
	end

	local function finish_build_lists()
		for index = 1, 2 do
			local request = requests[index]
			local is_pr = request.endpoint:find("reasonFilter=pullRequest", 1, true)
			request.done(is_pr and { build(5, "merge-sha"), build(9, "old-sha") } or {})
		end
	end

	local function timeline()
		return {
			records = {
				{
					id = "stage",
					type = "Stage",
					name = "Build",
					identifier = "Build",
					state = "completed",
					result = "succeeded",
					order = 1,
				},
				{
					id = "job",
					type = "Job",
					parentId = "stage",
					name = "Test",
					state = "completed",
					result = "succeeded",
					order = 1,
				},
				{ id = "task", type = "Task", parentId = "job", log = { id = 7 }, order = 1 },
			},
		}
	end

	it("filters builds by commit and maps timeline tasks to job logs", function()
		local result
		pipelines.fetch(context, {}, function(value, err)
			assert.is_nil(err)
			result = value
		end)
		finish_build_lists()
		assert.is_nil(result)
		assert.equal("/Project/_apis/build/builds/5/timeline", requests[3].endpoint)
		requests[3].done(timeline())
		assert.equal(1, #result)
		local job = result[1].stages[1].jobs[1]
		assert.same({ 7 }, job.log_ids)
		local log
		pipelines.fetch_job_log(context, result[1], job, function(value, err)
			assert.is_nil(err)
			log = value
		end)
		assert.equal("/Project/_apis/build/builds/5/logs/7", requests[4].endpoint)
		requests[4].done({ value = { "first", "second" } })
		assert.same({ raw = "first\nsecond" }, log)
	end)

	it("propagates a failed timeline when loading PR builds", function()
		local result, err
		pipelines.fetch(context, {}, function(value, message)
			result, err = value, message
		end)
		finish_build_lists()
		requests[3].done(nil, "Forbidden")
		assert.is_nil(result)
		assert.equal("Forbidden", err)
	end)

	it("refreshes the selected build instead of the latest build", function()
		local result
		pipelines.fetch(context, { pipeline = { id = "12" }, force_refresh = true }, function(value, err)
			assert.is_nil(err)
			result = value
		end)
		assert.equal("/Project/_apis/build/builds/12", requests[1].endpoint)
		requests[1].done(build(12, "merge-sha"))
		assert.equal("/Project/_apis/build/builds/12/timeline", requests[2].endpoint)
		requests[2].done(timeline())
		assert.equal(1, #result)
		assert.equal("12", result[1].id)
	end)

	it("sends the Azure cancellation payload and reports rejection", function()
		local ok, err
		pipelines.cancel(context, { id = "5" }, function(value, message)
			ok, err = value, message
		end)
		assert.equal("PATCH", requests[1].method)
		assert.equal("/Project/_apis/build/builds/5", requests[1].endpoint)
		assert.same({ status = "cancelling" }, requests[1].payload)
		requests[1].done(nil, "Forbidden")
		assert.is_false(ok)
		assert.equal("Forbidden", err)
	end)

	it("retries all stage jobs only for the retry operation", function()
		for index, action in ipairs({ "retry", "cancel" }) do
			pipelines.update_stage(context, { id = "5" }, { ref_name = "Build" }, action, function() end)
			assert.equal("PATCH", requests[index].method)
			assert.equal("/Project/_apis/build/builds/5/stages/Build", requests[index].endpoint)
			assert.same({ state = action, forceRetryAllJobs = action == "retry" or nil }, requests[index].payload)
		end
	end)
end)
