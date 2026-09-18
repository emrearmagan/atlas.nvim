local config = require("atlas.config")
local pipeline_module = require("atlas.pulls.pipelines")

describe("CI backend", function()
	local original_options
	local provider
	local native

	before_each(function()
		original_options = config.options
		config.options = { providers = { bitbucket = {} } }
		native = { fetch = function() end }
		provider = { id = "bitbucket", capabilities = { pipelines = native } }
	end)

	after_each(function()
		config.options = original_options
	end)

	it("uses native CI by default", function()
		assert.equal(native, pipeline_module.get(provider))
	end)

	it("returns the configured backend directly", function()
		local backend = { fetch = function() end }
		config.options.providers.bitbucket.ci = { backend = backend }
		assert.equal(backend, pipeline_module.get(provider))
	end)
end)

describe("Bamboo pipelines", function()
	local backend
	local requests
	local response
	local original
	local pipeline

	before_each(function()
		requests = {}
		response = {}
		pipeline = { id = "native-status", url = "http://ci.example.com/bamboo/browse/PROJ-PLAN-1", state = "FAILED" }
		original = {
			base64 = vim.base64,
			http = package.loaded["atlas.core.http"],
			logger = package.loaded["atlas.core.logger"],
			bamboo = package.loaded["atlas.pulls.pipelines.bamboo"],
			bitbucket = package.loaded["atlas.pulls.pipelines.bitbucket"],
		}
		vim.base64 = {
			encode = function(value)
				return value
			end,
		}
		package.loaded["atlas.core.logger"] = { loginfo = function() end }
		package.loaded["atlas.core.http"] = {
			curl_request = function(method, url, _, _, done)
				table.insert(requests, { method, url })
				done(response, nil)
			end,
			curl_text_request = function(method, url, _, _, done)
				table.insert(requests, { method, url })
				done("build log", nil)
			end,
		}
		package.loaded["atlas.pulls.pipelines.bamboo"] = nil
		package.loaded["atlas.pulls.pipelines.bitbucket"] = {
			fetch = function(_, _, done)
				done({ pipeline, { url = "https://bitbucket.org/team/repo/pipelines/results/1" } }, nil)
			end,
		}
		backend = require("atlas.pulls.pipelines.bamboo").new({
			host = "http://ci.example.com/bamboo",
			user = "user",
			password = "secret",
		})
	end)

	after_each(function()
		vim.base64 = original.base64
		package.loaded["atlas.core.http"] = original.http
		package.loaded["atlas.core.logger"] = original.logger
		package.loaded["atlas.pulls.pipelines.bamboo"] = original.bamboo
		package.loaded["atlas.pulls.pipelines.bitbucket"] = original.bitbucket
	end)

	it("finds linked Bamboo builds and loads their statuses, jobs, and logs", function()
		response = {
			state = "Unknown",
			lifeCycleState = "NotBuilt",
			stages = {
				stage = {
					{
						name = "Build",
						lifeCycleState = "NotBuilt",
						results = {
							result = {
								{ key = "PROJ-PLAN-COMPILE-1", plan = { shortName = "Compile" }, state = "Successful" },
								{ key = "PROJ-PLAN-LINT-1", lifeCycleState = "NotBuilt" },
							},
						},
					},
				},
			},
		}
		local result, log
		backend.fetch({ provider = "bitbucket" }, nil, function(value)
			result = value
		end)
		assert.equal(1, #result)
		assert.equal("PROJ-PLAN-1", result[1].id)
		assert.equal("native-status", pipeline.id)
		backend.fetch_details({}, result[1], nil, function(value)
			result = value
		end)

		assert.matches("/result/PROJ-PLAN-1.json", requests[1][2], 1, true)
		assert.equal("STOPPED", result.state)
		assert.equal("STOPPED", result.stages[1].state)
		assert.equal("Compile", result.stages[1].jobs[1].name)
		assert.equal("SUCCESSFUL", result.stages[1].jobs[1].state)
		assert.equal("STOPPED", result.stages[1].jobs[2].state)

		backend.fetch_job_log({}, result, result.stages[1].jobs[1], function(value)
			log = value
		end)
		assert.equal("build log", log)
		assert.equal(
			"http://ci.example.com/bamboo/download/PROJ-PLAN-COMPILE/build_logs/PROJ-PLAN-COMPILE-1.log",
			requests[2][2]
		)
	end)

	it("runs, retries, and stops using the correct Bamboo keys", function()
		local actions = {}
		for _, action in ipairs(backend.actions) do
			actions[action.id] = action
		end
		local ctx = {
			pr = {},
			pipeline = { id = "PROJ-PLAN-1" },
			job = { id = "PROJ-PLAN-JOB-1" },
		}
		local function done(err)
			assert.is_nil(err)
		end
		actions.run_pipeline.run(ctx, done)
		actions.rerun_failed_jobs.run(ctx, done)
		actions.stop_job.run(ctx, done)

		local queue = "http://ci.example.com/bamboo/rest/api/latest/queue/"
		assert.same({
			{ "POST", queue .. "PROJ-PLAN?os_authType=basic" },
			{ "PUT", queue .. "PROJ-PLAN-1?os_authType=basic" },
			{ "DELETE", queue .. "PROJ-PLAN-JOB-1?os_authType=basic" },
		}, requests)
	end)
end)
