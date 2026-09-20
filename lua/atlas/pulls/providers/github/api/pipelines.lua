local pipeline_utils = require("atlas.pulls.pipelines.utils")
local cli = require("atlas.providers.github.client")
local json = require("atlas.core.json")
local requests = require("atlas.core.requests")
local url_encode = require("atlas.core.utils").url_encode

local M = {}

local CHECKS_FRAGMENT = [[
fragment PipelineChecks on Commit {
  oid messageHeadline
  statusCheckRollup {
    contexts(first: 100, after: $endCursor) {
      nodes {
        __typename
        ... on CheckRun {
          databaseId name status conclusion startedAt completedAt detailsUrl
          checkSuite {
            branch { name repository { nameWithOwner } }
            workflowRun {
              id databaseId url event runNumber createdAt workflow { id databaseId name }
              file { path repositoryFileUrl }
            }
          }
        }
        ... on StatusContext { context state targetUrl createdAt }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
]]

local PIPELINES_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      headRefName
      headRepository { nameWithOwner }
      commits(last: 1) { nodes { commit { ...PipelineChecks } } }
    }
  }
}
]] .. CHECKS_FRAGMENT

local BRANCH_PIPELINES_QUERY = [[
query($owner: String!, $repo: String!, $ref: String!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    nameWithOwner
    ref(qualifiedName: $ref) { name target { ...PipelineChecks } }
  }
}
]] .. CHECKS_FRAGMENT

local PIPELINE_QUERY = [[
query($id: ID!, $endCursor: String) {
  node(id: $id) {
    ... on WorkflowRun {
      file { path repositoryFileUrl }
      checkSuite {
        status conclusion
        checkRuns(first: 100, after: $endCursor, filterBy: { checkType: LATEST }) {
          nodes { databaseId name status conclusion startedAt completedAt detailsUrl }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
]]

local COMMIT_STATUS_QUERY = [[
query($owner: String!, $repo: String!, $sha: String!) {
  repository(owner: $owner, name: $repo) {
    object(expression: $sha) {
      ... on Commit {
        statusCheckRollup {
          state
          contexts(first: 1) {
            nodes {
              ... on CheckRun { url: detailsUrl }
              ... on StatusContext { url: targetUrl }
            }
          }
        }
      }
    }
  }
}
]]

local COMMIT_STATUS_STATES = {
	ERROR = "failed",
	EXPECTED = "inprogress",
	FAILURE = "failed",
	PENDING = "inprogress",
	SUCCESS = "successful",
}

local CHECK_CONCLUSION_STATES = {
	ACTION_REQUIRED = "FAILED",
	CANCELLED = "CANCELED",
	FAILURE = "FAILED",
	NEUTRAL = "SUCCESSFUL",
	SKIPPED = "SKIPPED",
	STALE = "STOPPED",
	STARTUP_FAILURE = "FAILED",
	SUCCESS = "SUCCESSFUL",
	TIMED_OUT = "FAILED",
}

local INPROGRESS_STATUSES = {
	IN_PROGRESS = true,
	PENDING = true,
	QUEUED = true,
	REQUESTED = true,
	WAITING = true,
}

---@param status string|nil
---@param conclusion string|nil
---@return PullsPipelineState
local function check_state(status, conclusion)
	local state = CHECK_CONCLUSION_STATES[tostring(conclusion or ""):upper()]
	if state then
		return state
	end
	return INPROGRESS_STATUSES[tostring(status or ""):upper()] and "INPROGRESS" or "UNKNOWN"
end

---@param value any
---@return string
local function workflow_name(value)
	local workflow = vim.trim(tostring(value or ""))
	return workflow ~= "" and workflow or "External checks"
end

---@param url string|nil
---@return string|nil run_id
---@return string|nil job_id
---@return string|nil run_url
local function action_ids(url)
	if url == nil or url == "" then
		return nil, nil, nil
	end
	local run_url, run_id = url:match("^(.-/actions/runs/(%d+))")
	return run_id, url:match("/job/(%d+)"), run_url
end

---@param context PullsPipelineContext
---@param endpoint string
---@param action string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_pipeline_action(context, endpoint, action, on_done)
	local repo_slug = tostring(context.repo_full_name or "")
	if repo_slug == "" then
		on_done(false, "Missing repo")
		return nil
	end
	return cli.gh({ "api", "-X", "POST", string.format("repos/%s/%s", repo_slug, endpoint) }, function(_, err)
		on_done(err == nil, err)
	end, {
		action = action,
		repo = repo_slug,
		endpoint = endpoint,
	})
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param failed_only boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun(context, pipeline, failed_only, on_done)
	local run_id = tonumber(pipeline.id)
	if not run_id then
		on_done(false, "Missing workflow run ID")
		return nil
	end
	local action = failed_only and "rerun-failed-jobs" or "rerun"
	return post_pipeline_action(
		context,
		string.format("actions/runs/%d/%s", run_id, action),
		failed_only and "Rerun failed pipeline jobs" or "Rerun pipeline",
		on_done
	)
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel(context, pipeline, on_done)
	local run_id = tonumber(pipeline.id)
	if not run_id then
		on_done(false, "Missing workflow run ID")
		return nil
	end
	return post_pipeline_action(context, string.format("actions/runs/%d/cancel", run_id), "Cancel pipeline", on_done)
end

---@param context PullsPipelineContext
---@param job PullsPipelineJob
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.rerun_job(context, job, on_done)
	local job_id = tonumber(job.id)
	if not job_id then
		on_done(false, "Missing workflow job ID")
		return nil
	end
	return post_pipeline_action(context, string.format("actions/jobs/%d/rerun", job_id), "Rerun pipeline job", on_done)
end

---@param pages table[]
---@param context PullsPipelineContext
---@return table[]|nil, string|nil, table|nil
local function collect_checks(pages, context)
	local is_pr = type(context.target) == "table" and context.target.source ~= nil
	local checks = {}
	local metadata
	for _, page in ipairs(pages) do
		local repository = json.safe_table(json.safe_table(page.data).repository)
		local commit, branch, source_repository
		if is_pr then
			local pr = json.nilify(repository.pullRequest)
			if type(pr) ~= "table" then
				return nil, "Pull request not found"
			end
			local commits = json.safe_table(json.safe_table(pr.commits).nodes)
			commit = json.safe_table(json.safe_table(commits[1]).commit)
			branch = json.safe_str(pr.headRefName)
			source_repository = json.safe_str(json.safe_table(pr.headRepository).nameWithOwner)
		else
			local ref = json.nilify(repository.ref)
			if type(ref) ~= "table" then
				return nil, "Branch not found"
			end
			commit = json.safe_table(ref.target)
			branch = json.safe_str(ref.name)
			source_repository = json.safe_str(repository.nameWithOwner)
		end
		metadata = {
			commit = json.safe_str(commit.oid),
			title = json.safe_str(commit.messageHeadline),
			branch = branch,
			source_repository = source_repository,
		}
		local rollup = json.safe_table(commit.statusCheckRollup)
		local contexts = json.safe_table(rollup.contexts)
		for _, check in ipairs(json.safe_table(contexts.nodes)) do
			local suite = json.safe_table(check.checkSuite)
			if is_pr or not json.nilify(suite.workflowRun) then
				checks[#checks + 1] = check
			else
				local ref = json.safe_table(suite.branch)
				local repository_name = json.safe_str(json.safe_table(ref.repository).nameWithOwner)
				if
					ref.name == branch
					and repository_name
					and source_repository
					and repository_name:lower() == source_repository:lower()
				then
					metadata.source_repository = repository_name
					checks[#checks + 1] = check
				end
			end
		end
	end
	return checks, nil, metadata
end

---@param check table
---@param previous table
---@return boolean
local function is_newer(check, previous)
	if check.__typename == "StatusContext" then
		return (json.safe_str(check.createdAt) or "") > (json.safe_str(previous.createdAt) or "")
	end
	-- Queued check runs have an ID before they have a start time.
	return (tonumber(json.nilify(check.databaseId)) or 0) > (tonumber(json.nilify(previous.databaseId)) or 0)
end

---@param checks table[]
---@return table[]
local function latest_checks(checks)
	local newest_runs = {}
	local workflows = {}
	for _, check in ipairs(checks) do
		local run = json.safe_table(json.safe_table(check.checkSuite).workflowRun)
		local workflow = json.safe_table(run.workflow)
		if workflow.id then
			local key = workflow.id .. "\0" .. run.event
			local id = tonumber(json.nilify(run.databaseId)) or tonumber(action_ids(json.safe_str(run.url))) or 0
			workflows[check] = { key = key, id = id }
			newest_runs[key] = math.max(newest_runs[key] or 0, id)
		end
	end

	local latest, positions = {}, {}
	for _, check in ipairs(checks) do
		local workflow = workflows[check]
		if not workflow or workflow.id == newest_runs[workflow.key] then
			local key = check.__typename == "StatusContext" and ("status:" .. tostring(check.context))
				or (check.name .. "\0" .. (workflow and workflow.key or ""))
			local position = positions[key] or #latest + 1
			local previous = latest[position]
			if not previous or is_newer(check, previous) then
				latest[position] = check
				positions[key] = position
			end
		end
	end
	return latest
end

---@param steps table[]|nil
---@return PullsPipelineStep[]
local function map_steps(steps)
	local mapped = {}
	for _, step in ipairs(json.safe_table(steps)) do
		local started_at = json.safe_str(step.startedAt or step.started_at)
		local completed_at = json.safe_str(step.completedAt or step.completed_at)
		mapped[#mapped + 1] = {
			name = step.name,
			state = check_state(step.status, step.conclusion),
			started_at = started_at,
			duration = pipeline_utils.duration(started_at, completed_at),
		}
	end
	return mapped
end

---@param check table
---@param pipeline_id string
---@param job_id string|nil
---@param index integer
---@return PullsPipelineJob
local function map_job(check, pipeline_id, job_id, index)
	local is_status = check.__typename == "StatusContext"
	local name = json.safe_str(is_status and check.context or check.name) or "Check"
	local state = is_status and (COMMIT_STATUS_STATES[check.state] or "unknown"):upper()
		or check_state(check.status, check.conclusion)

	return {
		id = job_id or string.format("check:%s:%s:%d", pipeline_id, name, index),
		name = name,
		state = state,
		url = json.safe_str(check.detailsUrl or check.targetUrl),
		started_at = json.safe_str(check.startedAt or check.createdAt),
		duration = pipeline_utils.duration(check.startedAt, check.completedAt),
	}
end

---@param checks table[]
---@param metadata table|nil
---@return PullsPipeline[]
local function map_pipelines(checks, metadata)
	local pipelines = {}
	local pipelines_by_id = {}
	for index, check in ipairs(checks) do
		local run = json.safe_table(json.safe_table(check.checkSuite).workflowRun)
		local url = json.safe_str(check.detailsUrl or check.targetUrl)
		local _, job_id, run_url = action_ids(url)
		local run_id = json.safe_str(run.databaseId) or action_ids(json.safe_str(run.url) or url)
		local name = workflow_name(json.safe_table(run.workflow).name)
		local pipeline_id = run_id or ("external:" .. name)
		local pipeline = pipelines_by_id[pipeline_id]
		if not pipeline then
			pipeline = vim.tbl_extend("force", {}, metadata or {}, {
				id = pipeline_id,
				node_id = json.safe_str(run.id),
				workflow_id = json.safe_str(json.safe_table(run.workflow).databaseId),
				event = json.safe_str(run.event),
				name = run_id and (name ~= "External checks" and name or "GitHub Actions") or name,
				number = tonumber(json.nilify(run.runNumber)),
				started_at = json.safe_str(run.createdAt),
				state = "UNKNOWN",
				url = json.safe_str(run.url) or run_url or url,
				workflow_file = json.nilify(run.file),
				job_count = 0,
				stages = { { state = "UNKNOWN", jobs = {} } },
			})
			pipelines_by_id[pipeline_id] = pipeline
			table.insert(pipelines, pipeline)
		end

		table.insert(pipeline.stages[1].jobs, map_job(check, pipeline_id, run_id and job_id or nil, index))
	end

	for _, pipeline in ipairs(pipelines) do
		local stage = pipeline.stages[1]
		local state = pipeline_utils.aggregate_state(stage.jobs)
		stage.state = state
		pipeline.state = state
		pipeline.job_count = #stage.jobs
	end

	return pipelines
end

---@param run table
---@param previous GitHubPipeline|nil
---@return GitHubPipeline
local function map_run(run, previous)
	previous = previous or {}
	return {
		id = tostring(run.id),
		node_id = json.safe_str(run.node_id),
		workflow_id = json.safe_str(run.workflow_id),
		event = json.safe_str(run.event),
		source_repository = previous.source_repository or json.safe_str(json.safe_table(run.head_repository).full_name),
		name = json.safe_str(run.name) or previous.name or "GitHub Actions",
		number = tonumber(json.nilify(run.run_number)),
		commit = json.safe_str(run.head_sha),
		branch = json.safe_str(run.head_branch),
		started_at = json.safe_str(run.run_started_at) or json.safe_str(run.created_at),
		title = json.safe_str(run.display_title),
		state = check_state(run.status, run.conclusion),
		url = json.safe_str(run.html_url),
		stages = {},
	}
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_run(context, pipeline, on_done)
	---@cast pipeline GitHubPipeline
	if not pipeline.node_id then
		local run_id = tonumber(pipeline.id)
		if not run_id then
			on_done(nil, "Missing workflow run ID")
			return nil
		end
		local scope = requests.new()
		scope.run(function(done)
			local endpoint = string.format("repos/%s/actions/runs/%d", context.repo_full_name, run_id)
			return cli.gh({ "api", endpoint }, done, {
				action = "Fetch workflow run",
				repo = context.repo_full_name,
				pipeline_id = pipeline.id,
			})
		end, function(run, err)
			if err or type(run) ~= "table" then
				on_done(nil, err or "Failed to fetch workflow run")
				return
			end
			local result = map_run(run)
			if not result.node_id then
				on_done(nil, "Missing workflow run node ID")
				return
			end
			scope.run(function(done)
				return fetch_run(context, result, done)
			end, on_done)
		end)
		return scope
	end

	return cli.gh({
		"api",
		"graphql",
		"--paginate",
		"--slurp",
		"-f",
		"query=" .. PIPELINE_QUERY,
		"-f",
		"id=" .. pipeline.node_id,
	}, function(pages, err)
		if err or type(pages) ~= "table" then
			on_done(nil, err or "Failed to fetch workflow run")
			return
		end

		local result = vim.deepcopy(pipeline)
		local jobs = {}
		for _, page in ipairs(pages) do
			local run = json.safe_table(json.safe_table(page.data).node)
			if not json.nilify(run.checkSuite) then
				on_done(nil, "Workflow run not found")
				return
			end
			local suite = json.safe_table(run.checkSuite)
			result.workflow_file = json.nilify(run.file)
			result.state = check_state(suite.status, suite.conclusion)
			for _, check in ipairs(json.safe_table(json.safe_table(suite.checkRuns).nodes)) do
				local _, job_id = action_ids(json.safe_str(check.detailsUrl))
				jobs[#jobs + 1] = map_job(check, pipeline.id, job_id or json.safe_str(check.databaseId), #jobs + 1)
			end
		end
		result.job_count = #jobs
		result.stages = { { state = result.state, jobs = jobs } }
		on_done({ result }, nil)
	end, { action = "Fetch workflow run", repo = context.repo_full_name, pipeline_id = pipeline.id })
end

---@param context PullsPipelineContext
---@param opts { force_refresh?: boolean|nil, pipeline?: PullsPipeline }|nil
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(context, opts, on_done)
	opts = opts or {}
	local owner, repo = (context.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	if not owner then
		on_done(nil, "Missing repo")
		return nil
	end

	local target = context.target
	local pipeline = opts.pipeline or (type(target) == "table" and target.stages and target or nil)
	if pipeline then
		---@cast pipeline PullsPipeline
		return fetch_run(context, pipeline, on_done)
	end
	local pr = type(target) == "table" and target.source and target or nil
	local branch = type(target) == "string" and target or nil
	if not pr and (not branch or branch == "") then
		on_done(nil, "Missing branch")
		return nil
	end

	local selector = pr and ("pr:" .. tostring(pr.id)) or ("branch:" .. branch)
	local cache_key = string.format("github:pipelines:%s:%s", context.repo_full_name, selector)
	if not opts.force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local args = {
		"api",
		"graphql",
		"--paginate",
		"--slurp",
		"-f",
		"query=" .. (pr and PIPELINES_QUERY or BRANCH_PIPELINES_QUERY),
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
	}
	if pr then
		vim.list_extend(args, { "-F", "number=" .. tostring(pr.id) })
	else
		vim.list_extend(args, { "-f", "ref=refs/heads/" .. branch })
	end
	return cli.gh(args, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch pipelines")
			return
		end

		local checks, parse_error, metadata = collect_checks(result, context)
		if not checks then
			on_done(nil, parse_error)
			return
		end

		local pipelines = map_pipelines(latest_checks(checks), metadata)
		cli.set_mem(cache_key, pipelines)
		on_done(pipelines, nil)
	end, {
		action = pr and "Fetch PR pipelines" or "Fetch branch pipelines",
		repo = context.repo_full_name,
		number = pr and pr.id or nil,
		branch = not pr and branch or nil,
	})
end

---@param context PullsPipelineContext
---@param pipeline GitHubPipeline
---@param run table
---@return boolean
local function matches_history(context, pipeline, run)
	if
		json.safe_str(run.workflow_id) ~= pipeline.workflow_id
		or run.event ~= pipeline.event
		or run.head_branch ~= pipeline.branch
	then
		return false
	end

	local target = context.target
	if type(target) == "table" and target.source then
		local pull_requests = json.safe_table(run.pull_requests)
		for _, pull in ipairs(pull_requests) do
			if tostring(pull.number) == tostring(target.id) then
				return true
			end
		end
		if #pull_requests > 0 then
			return false
		end
	end

	-- Fork runs may omit pull_requests; branch names alone cannot identify their source.
	local repository = json.safe_str(json.safe_table(run.head_repository).full_name)
	return repository ~= nil
		and pipeline.source_repository ~= nil
		and repository:lower() == pipeline.source_repository:lower()
end

---@param context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(pipelines: PullsPipeline[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_history(context, pipeline, on_done)
	---@cast pipeline GitHubPipeline
	local repo = context.repo_full_name or ""
	if repo == "" or not pipeline.workflow_id or not pipeline.event or not pipeline.branch then
		on_done(nil, "Build history is unavailable for this pipeline")
		return nil
	end

	local endpoint = string.format(
		"repos/%s/actions/workflows/%s/runs?per_page=30&branch=%s&event=%s",
		repo,
		url_encode(pipeline.workflow_id),
		url_encode(pipeline.branch),
		url_encode(pipeline.event)
	)
	return cli.gh({ "api", endpoint }, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Failed to fetch build history")
			return
		end

		local pipelines = {}
		for _, run in ipairs(json.safe_table(result.workflow_runs)) do
			if matches_history(context, pipeline, run) then
				pipelines[#pipelines + 1] = map_run(run, pipeline)
			end
		end
		on_done(pipelines, nil)
	end, { action = "Fetch workflow history", repo = repo, pipeline_id = pipeline.id })
end

---@param _context PullsPipelineContext
---@param pipeline PullsPipeline
---@param on_done fun(file: { path: string, content: string }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_config(_context, pipeline, on_done)
	---@cast pipeline GitHubPipeline
	local file = pipeline.workflow_file
	local repo, ref = (file and file.repositoryFileUrl or ""):match("^https?://[^/]+/([^/]+/[^/]+)/blob/([^/]+)/")
	if not file or not repo then
		on_done(nil, "No workflow file available for this pipeline")
		return nil
	end

	local path = file.path:gsub("[^/]+", url_encode)
	local endpoint = string.format("repos/%s/contents/%s?ref=%s", repo, path, url_encode(ref))
	return cli.gh_text({ "api", endpoint, "-H", "Accept: application/vnd.github.raw+json" }, function(content, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done({ path = file.path, content = content or "" }, nil)
	end, { action = "Fetch workflow file", repo = repo, pipeline_id = pipeline.id })
end

---@param context PullsPipelineContext
---@param _pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(job: PullsPipelineJob|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job(context, _pipeline, job, on_done)
	local repo_slug = tostring(context.repo_full_name or "")
	local job_id = tonumber(job.id)
	if repo_slug == "" then
		on_done(nil, "Missing repo")
		return nil
	end
	if not job_id then
		on_done(job, nil)
		return nil
	end

	local endpoint = string.format("repos/%s/actions/jobs/%d", repo_slug, job_id)
	return cli.gh({ "api", endpoint }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done({
			id = tostring(result.id),
			name = result.name,
			state = check_state(result.status, result.conclusion),
			url = json.safe_str(result.html_url),
			started_at = json.safe_str(result.started_at),
			duration = pipeline_utils.duration(result.started_at, result.completed_at),
			steps = map_steps(result.steps),
		}, nil)
	end, { action = "Fetch workflow job", repo = repo_slug, job_id = job_id })
end

---@param context PullsPipelineContext
---@param _pipeline PullsPipeline
---@param job PullsPipelineJob
---@param on_done fun(log: PullsLog|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(context, _pipeline, job, on_done)
	local repo_slug = tostring(context.repo_full_name or "")
	local job_id = tonumber(job.id)
	if repo_slug == "" or job_id == nil then
		vim.schedule(function()
			on_done(nil, repo_slug == "" and "Missing repo" or "Missing workflow job ID")
		end)
		return nil
	end

	local endpoint = string.format("repos/%s/actions/jobs/%d/logs", repo_slug, job_id)
	return cli.gh_text({ "api", "--allow-escape-sequences", endpoint }, function(raw, err)
		on_done(raw and { raw = raw } or nil, err)
	end, { action = "Fetch workflow job log", repo = repo_slug, job_id = job_id })
end

---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(commit, opts, on_done)
	local owner, repo = (commit.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	if not owner then
		on_done(nil, nil, "Missing repo")
		return nil
	end

	local cache_key = string.format("github:commit:statuses:%s:%s", commit.repo_full_name, commit.hash)
	if not (opts or {}).force_refresh then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			---@cast cached { status: string, url?: string }
			on_done(cached.status, cached.url, nil)
			return nil
		end
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"query=" .. COMMIT_STATUS_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. repo,
		"-f",
		"sha=" .. commit.hash,
	}, function(result, err)
		if err then
			on_done(nil, nil, err)
			return
		end

		local repository = json.safe_table(json.safe_table(result.data).repository)
		local raw_commit = json.safe_table(repository.object)
		local rollup = json.safe_table(raw_commit.statusCheckRollup)
		local contexts = json.safe_table(rollup.contexts)
		local context = json.safe_table(json.safe_table(contexts.nodes)[1])
		local status = COMMIT_STATUS_STATES[rollup.state] or "unknown"
		local url = json.safe_str(context.url)
		cli.set_mem(cache_key, { status = status, url = url })
		on_done(status, url, nil)
	end, {
		action = "Fetch commit status",
		repo = commit.repo_full_name,
		commit_hash = commit.hash,
	})
end

return M
