local dependencies = {
	"atlas.providers.gitlab.client",
	"atlas.pulls.pipelines",
	"atlas.pulls.providers.gitlab.api.pipelines",
}

local previous = { loaded = {}, preload = {} }

local function load_checks(stubs)
	for name, value in pairs(stubs) do
		previous.loaded[name] = package.loaded[name]
		previous.preload[name] = package.preload[name]
		package.loaded[name] = nil
		package.preload[name] = function()
			return value
		end
	end
	package.loaded["atlas.pulls.providers.gitlab.api.checks"] = nil
	return require("atlas.pulls.providers.gitlab.api.checks")
end

describe("GitLab merge checks", function()
	after_each(function()
		package.loaded["atlas.pulls.providers.gitlab.api.checks"] = nil
		for _, name in ipairs(dependencies) do
			package.loaded[name] = previous.loaded[name]
			package.preload[name] = previous.preload[name]
		end
		previous = { loaded = {}, preload = {} }
	end)

	it("fetches merge state and head pipeline together", function()
		local query, variables, merge_done
		local checks = load_checks({
			["atlas.providers.gitlab.client"] = {
				get_memory_cache = function()
					return nil, false
				end,
				set_memory_cache = function() end,
				graphql = function(q, vars, done)
					query, variables, merge_done = q, vars, done
					return { cancel = function() end }
				end,
			},
			["atlas.pulls.pipelines"] = {
				to_merge_check = function()
					return nil
				end,
			},
			["atlas.pulls.providers.gitlab.api.pipelines"] = {
				to_pipeline_state = function()
					return "SUCCESSFUL"
				end,
			},
		})

		local result
		checks.fetch({ id = 7, repo_full_name = "group/project", state = "open" }, nil, function(value)
			result = value
		end)

		assert.same({ path = "group/project", iid = "7" }, variables)
		for _, field in ipairs({ "detailedMergeStatus", "mergeableDiscussionsState", "conflicts", "headPipeline" }) do
			assert.is_truthy(query:find(field, 1, true))
		end
		for _, field in ipairs({ "description", "labels", "assignees", "reviewers" }) do
			assert.is_nil(query:find(field, 1, true))
		end

		merge_done({
			project = {
				mergeRequest = {
					draft = false,
					detailed_merge_status = "mergeable",
					blocking_discussions_resolved = true,
					has_conflicts = false,
					head_pipeline = { status = "SUCCESS" },
				},
			},
		}, nil)

		assert.equal("conflicts", result[1].key)
		assert.equal("successful", result[1].state)
	end)
end)
