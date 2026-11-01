local module_name = "atlas.pulls.providers.gitlab.api.pipelines"

describe("gitlab pipelines", function()
	local previous_client

	local function pipeline_node(id, iid, source, jobs)
		return {
			id = "gid://gitlab/Ci::Pipeline/" .. id,
			iid = iid,
			status = "SUCCESS",
			source = source,
			project = { fullPath = "group/project", ciConfigPathOrDefault = ".gitlab-ci.yml" },
			stages = { nodes = { { name = "build", status = "success" }, { name = "deploy", status = "success" } } },
			jobs = { nodes = jobs, pageInfo = { hasNextPage = false } },
		}
	end

	local function job_node(id, name, kind, stage, downstream)
		return {
			id = "gid://gitlab/Ci::Build/" .. id,
			name = name,
			kind = kind,
			status = "SUCCESS",
			stage = { name = stage },
			downstreamPipeline = downstream or vim.NIL,
		}
	end

	before_each(function()
		previous_client = package.loaded["atlas.providers.gitlab.client"]
	end)

	after_each(function()
		package.loaded["atlas.providers.gitlab.client"] = previous_client
		package.loaded[module_name] = nil
	end)

	it("loads downstream pipelines and skips trigger jobs that have none", function()
		local nodes = {
			["20"] = pipeline_node(100, "20", "merge_request_event", {
				job_node(1, "build", "BUILD", "build"),
				job_node(2, "deploy:child", "BRIDGE", "deploy", {
					id = "gid://gitlab/Ci::Pipeline/101",
					iid = "21",
					project = { fullPath = "group/project" },
				}),
				job_node(3, "deploy:manual", "BRIDGE", "deploy"),
			}),
			["21"] = pipeline_node(101, "21", "parent_pipeline", { job_node(4, "generate", "BUILD", "build") }),
		}
		package.loaded[module_name] = nil
		package.loaded["atlas.providers.gitlab.client"] = {
			graphql = function(_, variables, done)
				done({ project = { pipeline = nodes[variables.iid] } }, nil)
			end,
		}
		local api = require(module_name)

		local pipeline
		api.fetch_pipeline({ repo_full_name = "group/project" }, { id = "100", iid = "20" }, function(result, err)
			assert.is_nil(err)
			pipeline = result
		end)

		local deploy = pipeline.stages[2]
		assert.equal(1, #deploy.jobs)
		local child = deploy.jobs[1].downstream
		assert.equal("101", child.id)
		assert.equal("generate", child.stages[1].jobs[1].name)
		assert.is_nil(child.config_path)
	end)
end)
