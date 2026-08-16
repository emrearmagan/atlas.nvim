local CLIENT = "atlas.providers.gitea.gitea.client"
local COMMENTS = "atlas.pulls.providers.gitea.gitea.api.comments"
local PIPELINES = "atlas.pulls.providers.gitea.gitea.api.pipelines"
local PROVIDER = "atlas.pulls.providers.gitea.gitea"
local REVIEWS = "atlas.pulls.providers.gitea.gitea.api.reviews"
local PREFIX = "atlas.pulls.providers.gitea.gitea"

local function cleanup()
	package.loaded[CLIENT] = nil
	package.preload[CLIENT] = nil
	for module in pairs(package.loaded) do
		if module:sub(1, #PREFIX) == PREFIX then
			package.loaded[module] = nil
		end
	end
end

local function load_api(module, service)
	package.loaded[module] = nil
	package.loaded[CLIENT] = nil
	package.preload[CLIENT] = function()
		return { pulls = service }
	end
	return require(module)
end

local function endpoints(requests)
	local result = {}
	for _, request in ipairs(requests) do
		table.insert(result, request.method .. " " .. request.endpoint)
	end
	return result
end

describe("Gitea pulls", function()
	before_each(cleanup)
	after_each(cleanup)

	it("wires the Gitea implementation", function()
		local provider = require(PROVIDER)
		local comments = require(COMMENTS)
		local pipelines = require(PIPELINES)

		assert.equal(comments.add, provider.capabilities.comments.add_comment)
		assert.equal(comments.set_thread_resolved, provider.capabilities.comments.set_thread_resolved)
		assert.equal(pipelines.fetch_details, provider.capabilities.pipelines.fetch_details)
		assert.equal(require("atlas.pulls.providers.gitea.gitea.actions"), provider.capabilities.actions)
		assert.equal(
			require("atlas.pulls.providers.gitea.gitea.actions.pipelines"),
			provider.capabilities.pipelines.actions
		)
	end)

	it("uses the Gitea 1.27 review-thread endpoints", function()
		local requests = {}
		local service = {
			url_encode = tostring,
			request = function(method, endpoint, data, done)
				table.insert(requests, { method = method, endpoint = endpoint, data = data })
				done({ id = 12, body = data and data.body }, nil)
				return { cancel = function() end }
			end,
		}
		local comments = load_api(COMMENTS, service)
		local pr = { id = 3, repo_full_name = "owner/repo" }
		local root = { id = 9, inline = { path = "init.lua", to = 2 } }
		local reply

		comments.add(pr, "Reply", { parent = root }, function(value)
			reply = value
		end)
		comments.set_thread_resolved(pr, root, true, function() end)
		comments.set_thread_resolved(pr, root, false, function() end)

		assert.equal(9, reply.parent_id)
		assert.same({
			"POST /repos/owner/repo/pulls/3/comments/9/replies",
			"POST /repos/owner/repo/pulls/comments/9/resolve",
			"POST /repos/owner/repo/pulls/comments/9/unresolve",
		}, endpoints(requests))
		assert.same({ body = "Reply" }, requests[1].data)

		local reviews = require(REVIEWS)
		local comment
		reviews.create_comment = function(_, _, value, _, _, _, done)
			comment = value
			done({}, nil)
		end
		pr.source = { commit_hash = "abc" }
		reviews.add(pr, "Range", { path = "init.lua", start_to = 2, to = 4 }, nil, function() end)
		assert.equal(2, comment.new_position)
		assert.is_nil(comment.extra_lines_count)
	end)

	it("uses the Gitea Actions rerun and log endpoints", function()
		local requests = {}
		local pipelines = load_api(PIPELINES, {
			base_url = function()
				return "https://git.example"
			end,
			absolute_url = function(value)
				return value
			end,
			url_encode = tostring,
			request = function(method, endpoint, _, done)
				table.insert(requests, { method = method, endpoint = endpoint })
				done({}, nil)
				return { cancel = function() end }
			end,
			request_text = function(method, endpoint, done)
				table.insert(requests, { method = method, endpoint = endpoint })
				done("log", nil)
				return { cancel = function() end }
			end,
		})
		local pr = { repo_full_name = "owner/repo" }
		local pipeline = { url = "https://git.example/owner/repo/actions/runs/42" }
		local job = { id = 91 }

		pipelines.rerun(pr, pipeline, false, function() end)
		pipelines.rerun(pr, pipeline, true, function() end)
		pipelines.rerun_job(pr, pipeline, job, function() end)
		pipelines.fetch_job_log(pr, pipeline, job, function() end)

		assert.same({
			"POST /repos/owner/repo/actions/runs/42/rerun",
			"POST /repos/owner/repo/actions/runs/42/rerun-failed-jobs",
			"POST /repos/owner/repo/actions/runs/42/jobs/91/rerun",
			"GET /repos/owner/repo/actions/jobs/91/logs",
		}, endpoints(requests))
	end)
end)
