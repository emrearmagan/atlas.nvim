local github_client = require("spec.support.github_client_stub")

local MODULE = "atlas.pulls.providers.github.api.pipelines"

---@return table
local function run(id, workflow, branch, repository)
	return {
		databaseId = id,
		url = "https://github.com/owner/repo/actions/runs/" .. id,
		event = "pull_request",
		workflow = { id = "W_" .. workflow, name = workflow },
		branch = { name = branch or "feature", repository = { nameWithOwner = repository or "owner/repo" } },
	}
end

---@return table
local function check(id, name, workflow_run, conclusion)
	return {
		__typename = "CheckRun",
		databaseId = id,
		name = name,
		status = "COMPLETED",
		conclusion = conclusion,
		detailsUrl = workflow_run.url .. "/job/" .. id,
		checkSuite = { workflowRun = workflow_run, branch = workflow_run.branch },
	}
end

---@return table
local function status(context, state, created_at)
	return { __typename = "StatusContext", context = context, state = state, createdAt = created_at }
end

---@param target PullRequest|string
---@param nodes table[]
---@return PullsPipeline[]
local function fetch(target, nodes)
	local commit = { oid = "abc", messageHeadline = "Fix", statusCheckRollup = { contexts = { nodes = nodes } } }
	local repository = type(target) == "string"
			and { nameWithOwner = "owner/repo", ref = { name = target, target = commit } }
		or {
			pullRequest = {
				headRefName = "feature",
				headRepository = { nameWithOwner = "owner/repo" },
				commits = { nodes = { { commit = commit } } },
			},
		}
	github_client.install({
		gh = function(_, callback)
			callback({ { data = { repository = repository } } }, nil)
		end,
	})
	package.loaded[MODULE] = nil

	local result
	require(MODULE).fetch({ repo_full_name = "owner/repo", target = target }, { force_refresh = true }, function(value)
		result = value
	end)
	return result
end

---@param pipeline PullsPipeline
---@return string[]
local function jobs(pipeline)
	return vim.tbl_map(function(job)
		return job.name .. " " .. job.state
	end, pipeline.stages[1].jobs)
end

describe("GitHub pipelines", function()
	local pr = { id = 1, source = { branch = "feature" } }

	after_each(function()
		github_client.uninstall()
		package.loaded[MODULE] = nil
	end)

	it("keeps only the newest run of a workflow and the newest attempt of each job", function()
		local old, new = run(10, "CI"), run(11, "CI")
		local pipelines = fetch(pr, {
			check(1, "build", old, "FAILURE"),
			check(2, "build", new, "SUCCESS"),
			check(3, "test", new, "FAILURE"),
			check(4, "test", new, "SUCCESS"),
		})

		assert.equal(1, #pipelines)
		assert.equal("11", pipelines[1].id)
		assert.equal("SUCCESSFUL", pipelines[1].state)
		assert.same({ "build SUCCESSFUL", "test SUCCESSFUL" }, jobs(pipelines[1]))
	end)

	it("groups commit statuses as external checks and keeps the latest status per context", function()
		local pipelines = fetch(pr, {
			status("ci/jenkins", "PENDING", "2026-01-01T10:00:00Z"),
			status("lint", "FAILURE", "2026-01-01T10:00:00Z"),
			status("ci/jenkins", "SUCCESS", "2026-01-01T11:00:00Z"),
		})

		assert.equal(1, #pipelines)
		assert.equal("External checks", pipelines[1].name)
		assert.equal("FAILED", pipelines[1].state)
		assert.same({ "ci/jenkins SUCCESSFUL", "lint FAILED" }, jobs(pipelines[1]))
	end)

	it("shows only the branch's own workflow runs on a branch", function()
		local pipelines = fetch("feature", {
			check(1, "build", run(10, "CI"), "SUCCESS"),
			check(2, "build", run(11, "Fork", "feature", "fork/repo"), "FAILURE"),
			check(3, "build", run(12, "Main", "main"), "FAILURE"),
		})

		assert.same(
			{ "CI" },
			vim.tbl_map(function(pipeline)
				return pipeline.name
			end, pipelines)
		)
	end)
end)
