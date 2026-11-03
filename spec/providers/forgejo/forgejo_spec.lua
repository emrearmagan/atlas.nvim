local TRANSPORT = "atlas.providers.forge.forgejo.api"
local PIPELINES = "atlas.pulls.providers.forge.forgejo.api.pipelines"
local REVIEWS = "atlas.pulls.providers.forge.forgejo.api.reviews"
local PREFIX = "atlas.pulls.providers.forge.forgejo"

local function cleanup()
	package.loaded[TRANSPORT] = nil
	package.preload[TRANSPORT] = nil
	for module in pairs(package.loaded) do
		if module:sub(1, #PREFIX) == PREFIX or module:match("^atlas%.pulls%.pipelines%.forge%.forgejo") then
			package.loaded[module] = nil
		end
	end
end

local function load_api(module, service)
	package.loaded[module] = nil
	package.loaded[TRANSPORT] = nil
	service.id = "forgejo"
	service.name = "Forgejo"
	service.fetch_all = require("atlas.providers.forge.api.pagination").new(service).fetch_all
	service.notifications = {}
	package.preload[TRANSPORT] = function()
		return service
	end
	return require(module)
end

describe("Forgejo pulls", function()
	before_each(cleanup)
	after_each(cleanup)

	it("preserves multiline pending comments on either side of the diff", function()
		local requests = {}
		local reviews = load_api(REVIEWS, {
			url_encode = tostring,
			request = function(method, endpoint, data, done)
				table.insert(requests, { method = method, endpoint = endpoint, data = data })
				done({
					id = 12,
					path = data.path,
					position = data.new_position,
					original_position = data.old_position,
					extra_lines_count = data.extra_lines_count,
				}, nil)
				return { cancel = function() end }
			end,
		})
		local pr = { id = 3, repo_full_name = "owner/repo", source = { commit_hash = "abc" } }
		for _, side in ipairs({ "to", "from" }) do
			local created
			reviews.add(
				pr,
				"Range",
				{ path = "init.lua", ["start_" .. side] = 2, [side] = 4 },
				{ pending = true, review = { id = 8, pending = true } },
				function(value)
					created = value
				end
			)

			assert.same({
				body = "Range",
				path = "init.lua",
				[side == "to" and "new_position" or "old_position"] = 2,
				extra_lines_count = 2,
			}, requests[#requests].data)
			assert.is_true(created.pending)
			assert.equal(2, created.inline["start_" .. side])
			assert.equal(4, created.inline[side])
		end
	end)

	it("resolves a displayed Actions run number to its internal ID for cancellation", function()
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
		local pr = { repo_full_name = "owner/repo", source = { commit_hash = "abc" } }
		local pipeline = {
			id = "42",
			name = "Actions run #42",
			state = "INPROGRESS",
			url = "https://git.example/owner/repo/actions/runs/42",
			stages = {},
		}

		pipelines.cancel({ repo_full_name = pr.repo_full_name, target = pr }, pipeline, function() end)

		assert.same({ run_number = "42", head_sha = "abc", limit = 1 }, queries[1])
		assert.same({
			{ method = "GET", endpoint = "/repos/owner/repo/actions/runs?run" },
			{ method = "POST", endpoint = "/repos/owner/repo/actions/runs/900/cancel" },
		}, requests)
	end)
end)
