local CLIENT = "atlas.providers.forgejo.client"
local COMMENTS = "atlas.pulls.providers.forgejo.api.comments"
local PIPELINES = "atlas.pulls.providers.forgejo.api.pipelines"
local PROVIDER = "atlas.pulls.providers.forgejo"
local REVIEWS = "atlas.pulls.providers.forgejo.api.reviews"
local PREFIX = "atlas.pulls.providers.forgejo"

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
		return service
	end
	return require(module)
end

describe("Forgejo pulls", function()
	before_each(cleanup)
	after_each(cleanup)

	it("wires the Forgejo implementation", function()
		local provider = require(PROVIDER)
		local comments = require(COMMENTS)
		local pipelines = require(PIPELINES)
		local reviews = require(REVIEWS)

		assert.equal(comments.add, provider.capabilities.comments.add_comment)
		assert.equal(reviews.start_review, provider.capabilities.reviews.start_review)
		assert.equal(pipelines.fetch_details, provider.capabilities.pipelines.fetch_details)
		assert.equal(require("atlas.pulls.providers.forgejo.actions"), provider.capabilities.actions)
		assert.equal(
			require("atlas.pulls.providers.forgejo.actions.pipelines"),
			provider.capabilities.pipelines.actions
		)
		assert.is_nil(provider.capabilities.comments.set_thread_resolved)
	end)

	it("uses Forgejo multiline pending-review endpoints", function()
		local requests = {}
		local reviews = load_api(REVIEWS, {
			url_encode = tostring,
			request = function(method, endpoint, data, done)
				table.insert(requests, { method = method, endpoint = endpoint, data = data })
				done({
					id = 12,
					path = data and data.path,
					position = data and data.new_position,
					extra_lines_count = data and data.extra_lines_count,
				}, nil)
				return { cancel = function() end }
			end,
		})
		local pr = { id = 3, repo_full_name = "owner/repo", source = { commit_hash = "abc" } }
		local created

		reviews.add(
			pr,
			"Range",
			{ path = "init.lua", start_to = 2, to = 4, commit_hash = "abc" },
			{ pending = true, review = { id = 8, pending = true } },
			function(value)
				created = value
			end
		)
		reviews.delete(pr, created, function() end)

		assert.same({ body = "Range", path = "init.lua", new_position = 2, extra_lines_count = 2 }, requests[1].data)
		assert.equal(2, created.inline.start_to)
		assert.equal(4, created.inline.to)
		assert.equal("/repos/owner/repo/pulls/3/reviews/8/comments", requests[1].endpoint)
		assert.equal("DELETE", requests[2].method)
		assert.equal("/repos/owner/repo/pulls/3/reviews/8/comments/12", requests[2].endpoint)
	end)

	it("cancels a Forgejo Actions run", function()
		local queries, requests = {}, {}
		local pipelines = load_api(PIPELINES, {
			base_url = function()
				return "https://git.example"
			end,
			absolute_url = function(value)
				return value
			end,
			url_encode = tostring,
			query = function(values)
				queries[1] = values
				return "?run"
			end,
			request = function(method, endpoint, _, done)
				table.insert(requests, { method = method, endpoint = endpoint })
				if method == "GET" then
					done({ workflow_runs = { { id = 900, index_in_repo = 42, commit_sha = "abc" } } }, nil)
				else
					done({}, nil)
				end
				return { cancel = function() end }
			end,
		})
		local pr = { repo_full_name = "owner/repo" }
		local pipeline = {
			url = "https://git.example/owner/repo/actions/runs/42",
			commit_hash = "abc",
		}

		pipelines.cancel(pr, pipeline, function() end)

		assert.same({ run_number = "42", head_sha = "abc", limit = 1 }, queries[1])
		assert.same({
			{ method = "GET", endpoint = "/repos/owner/repo/actions/runs?run" },
			{ method = "POST", endpoint = "/repos/owner/repo/actions/runs/900/cancel" },
		}, requests)
	end)
end)
