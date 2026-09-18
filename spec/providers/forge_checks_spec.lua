local function run(provider)
	local transport = "atlas.providers.forge." .. provider .. ".api"
	local api = "atlas.pulls.providers.forge." .. provider .. ".api"
	local loaded = { package.loaded[transport], package.loaded[api] }
	local preloaded = package.preload[transport]
	local endpoints = {}

	package.loaded[transport], package.loaded[api] = nil, nil
	package.preload[transport] = function()
		local service = {
			id = provider,
			name = provider == "gitea" and "Gitea" or "Forgejo",
			url_encode = tostring,
			query = function()
				return "?limit=50&page=1"
			end,
			request = function(_, endpoint, _, done)
				endpoints[endpoint] = true
				if endpoint == "/repos/owner/repo/pulls/7" then
					done({ draft = false, mergeable = true, base = { ref = "main" }, head = { sha = "abc" } }, nil)
				elseif endpoint == "/repos/owner/repo/branches/main" then
					done({
						protected = true,
						required_approvals = 1,
						enable_status_check = true,
						status_check_contexts = { "required" },
					}, nil)
				else
					done({
						statuses = {
							{ context = "required", status = "skipped" },
							{ context = "optional", status = "failure" },
						},
					}, nil)
				end
				return { cancel = function() end }
			end,
		}
		service.notifications = {}
		service.fetch_all = function(endpoint, _, _, done)
			endpoints[endpoint] = true
			done({
				{
					id = 1,
					state = "APPROVED",
					official = true,
					dismissed = false,
					stale = false,
					user = { id = 1 },
				},
			}, nil)
			return { cancel = function() end }
		end
		return service
	end

	local result, result_err
	require(api).checks.fetch({ id = 7, repo_full_name = "owner/repo" }, nil, function(value, err)
		result, result_err = value, err
	end)

	package.loaded[transport], package.loaded[api] = loaded[1], loaded[2]
	package.preload[transport] = preloaded
	return result, result_err, endpoints
end

describe("Gitea and Forgejo merge checks", function()
	it("uses only public merge-check inputs", function()
		for _, provider in ipairs({ "gitea", "forgejo" }) do
			local checks, err, endpoints = run(provider)
			assert.is_nil(err)
			assert.equal("successful", checks[1].state)
			assert.equal("successful", checks[2].state)
			assert.equal("successful", checks[3].state)
			assert.same({
				["/repos/owner/repo/pulls/7"] = true,
				["/repos/owner/repo/branches/main"] = true,
				["/repos/owner/repo/pulls/7/reviews"] = true,
				["/repos/owner/repo/commits/abc/status?limit=50&page=1"] = true,
			}, endpoints)
		end
	end)
end)
