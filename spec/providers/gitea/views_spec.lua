local config = require("atlas.config")
local git = require("atlas.core.git")

local cases = {
	{
		domain = "issues",
		module = "atlas.issues.providers.gitea",
		expected_query = "repo:local/repo is:closed archived:false sort:updated needle",
		fetch = function(provider, view)
			local api = require("atlas.issues.providers.gitea.api.issues")
			local original = api.list
			local received
			api.list = function(value, _, done)
				received = value
				done({}, nil, true, nil)
			end
			provider.capabilities.core.fetch_issues(view, {}, function() end)
			api.list = original
			return received
		end,
		query = function(provider, view)
			return provider.capabilities.core.search_query(view)
		end,
	},
	{
		domain = "pulls",
		module = "atlas.pulls.providers.gitea",
		expected_query = "repo:local/repo is:open is:merged archived:false sort:updated needle",
		fetch = function(provider, view)
			local api = require("atlas.pulls.providers.gitea.api.pullrequests")
			local original = api.list
			local received, received_opts
			api.list = function(value, opts, done)
				received = value
				received_opts = opts
				done({}, nil)
			end
			provider.capabilities.core.fetch_pullrequests(view, { states = { "merged", "open" } }, function() end)
			api.list = original
			assert.same({ "OPEN", "MERGED" }, received_opts.statuses)
			return received
		end,
		query = function(provider, view)
			return provider.capabilities.core.search_query(view, { states = { "merged", "open" } })
		end,
	},
}

local function with_views(case, configured, repository, callback)
	local original_section = config.options[case.domain]
	local original_local_repository = git.local_repository
	local calls = 0
	config.options[case.domain] = vim.tbl_extend("force", {}, original_section or {}, {
		gitea = { views = configured },
	})
	git.local_repository = function()
		calls = calls + 1
		return repository
	end

	local ok, err = xpcall(function()
		callback(require(case.module), function()
			return calls
		end)
	end, debug.traceback)
	config.options[case.domain] = original_section
	git.local_repository = original_local_repository
	if not ok then
		error(err, 0)
	end
end

describe("Gitea provider views", function()
	for _, case in ipairs(cases) do
		it("resolves all " .. case.domain .. " current-repository views from one snapshot", function()
			local extra_params = { sort = "updated", archived = false }
			local configured = {
				{
					name = "Current one",
					key = "1",
					current_repo = true,
					search = "needle",
					scope = "all",
					state = "closed",
					extra_params = extra_params,
					layout = "compact",
				},
				{ name = "Configured", key = "2", repo = "configured/repo", search = "other" },
				{ name = "Current two", key = "3", current_repo = true, state = "open" },
			}
			with_views(
				case,
				configured,
				{ provider = "gitea", repo_full_name = "local/repo" },
				function(provider, calls)
					assert.equal("function", type(provider.views))
					assert.is_nil(provider.capabilities.core.views)
					local resolved = provider.views()

					assert.equal(1, calls())
					assert.equal("local/repo", resolved[1].repo)
					assert.equal("configured/repo", resolved[2].repo)
					assert.equal("local/repo", resolved[3].repo)
					for index, view in ipairs(configured) do
						assert.is_false(resolved[index] == view)
					end
					assert.is_true(resolved[1].extra_params == extra_params)
					assert.same({ sort = "updated", archived = false }, configured[1].extra_params)
					assert.is_nil(configured[1].repo)
					assert.is_nil(configured[3].repo)

					assert.equal(case.expected_query, case.query(provider, resolved[1]))
					assert.is_true(case.fetch(provider, resolved[1]) == resolved[1])
					assert.equal(1, calls())
				end
			)
		end)
	end
end)
