local config = require("atlas.config")
local git = require("atlas.core.git")

local cases = {
	{
		domain = "issues",
		module = "atlas.issues.providers.forge.gitea",
		expected_query = "repo:local/repo is:closed archived:false sort:updated needle",
		fetch = function(provider, view)
			local api = require("atlas.issues.providers.forge.gitea.api").issues
			local original = api.list
			local received
			api.list = function(value, _, done)
				received = value
				done({}, nil, true, nil)
			end
			provider.capabilities.core.fetch_issues(view, {}, function() end)
			api.list = original
			assert.is_true(received == view)
		end,
	},
	{
		domain = "pulls",
		module = "atlas.pulls.providers.forge.gitea",
		expected_query = "repo:local/repo is:open archived:false sort:updated",
		fetch = function(provider, view)
			local api = require("atlas.pulls.providers.forge.gitea.api").pullrequests
			local original = api.list
			local received, received_opts
			api.list = function(value, opts, done)
				received = value
				received_opts = opts
				done({}, nil)
			end
			provider.capabilities.core.fetch_pullrequests(view, {}, function() end)
			api.list = original
			assert.is_false(received == view)
			assert.same({ "OPEN" }, received_opts.statuses)
			assert.equal("", received.search)
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
					search = case.domain == "issues" and "needle" or nil,
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

					local query, states = provider.resolve_search(resolved[1])
					assert.equal(case.expected_query, query)
					if case.domain == "pulls" then
						assert.same({ "open" }, states)
					end
					case.fetch(provider, resolved[1])
					assert.equal(1, calls())
				end
			)
		end)
	end

	it("keeps displayed pull states and API statuses aligned", function()
		local provider = require("atlas.pulls.providers.forge.gitea")
		local api = require("atlas.pulls.providers.forge.gitea.api").pullrequests
		local original = api.search_global
		local received_view, received_opts
		api.search_global = function(view, opts, done)
			received_view = view
			received_opts = opts
			done({}, nil)
		end

		local view = { name = "Search", search = "is:merged needle" }
		local ok, err = xpcall(function()
			local query, states = provider.resolve_search(view)
			assert.equal("type:pulls is:merged needle", query)
			assert.same({ "merged" }, states)
			provider.capabilities.core.fetch_pullrequests(view, {}, function() end)
			assert.equal("needle", received_view.search)
			assert.same({ "MERGED" }, received_opts.statuses)

			view._states = { "declined" }
			query, states = provider.resolve_search(view)
			assert.equal("type:pulls is:declined needle", query)
			assert.same({ "declined" }, states)
			provider.capabilities.core.fetch_pullrequests(view, {}, function() end)
			assert.same({ "DECLINED" }, received_opts.statuses)
		end, debug.traceback)
		api.search_global = original
		if not ok then
			error(err, 0)
		end
	end)
end)
