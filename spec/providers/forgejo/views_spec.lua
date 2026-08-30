local ISSUE_PROVIDER = "atlas.issues.providers.forge.forgejo"
local PULL_PROVIDER = "atlas.pulls.providers.forge.forgejo"

local config = require("atlas.config")
local git = require("atlas.core.git")
local original_domain_options = config.domain_options
local original_local_repository = git.local_repository

local issue_config
local pull_config
local repository
local repository_calls
local issue_list
local pull_list
local pull_search_global

local function unload_providers()
	package.loaded[ISSUE_PROVIDER] = nil
	package.loaded[PULL_PROVIDER] = nil
end

describe("Forgejo provider views", function()
	before_each(function()
		unload_providers()
		issue_config = nil
		pull_config = nil
		repository = nil
		repository_calls = 0
		config.domain_options = function(provider, domain)
			assert.equal("forgejo", provider)
			return domain == "issues" and issue_config or pull_config
		end
		git.local_repository = function()
			repository_calls = repository_calls + 1
			return repository
		end
	end)

	after_each(function()
		config.domain_options = original_domain_options
		git.local_repository = original_local_repository
		if issue_list then
			require("atlas.issues.providers.forge.forgejo.api").issues.list = issue_list
			issue_list = nil
		end
		if pull_list then
			require("atlas.pulls.providers.forge.forgejo.api").pullrequests.list = pull_list
			pull_list = nil
		end
		if pull_search_global then
			require("atlas.pulls.providers.forge.forgejo.api").pullrequests.search_global = pull_search_global
			pull_search_global = nil
		end
		unload_providers()
	end)

	it("resolves every issue current-repository view from one lookup", function()
		local extra_params = { direction = "desc" }
		local configured = {
			{
				name = "Created here",
				key = "1",
				current_repo = true,
				repo = "configured/repo",
				scope = "created",
				state = "closed",
				labels = "bug",
				search = "needle",
				extra_params = extra_params,
				layout = "compact",
			},
			{ name = "Assigned here", key = "2", current_repo = true, scope = "assigned" },
			{ name = "Elsewhere", key = "3", repo = "other/repo" },
		}
		issue_config = { views = configured }
		repository = { provider = "forgejo", repo_full_name = "owner/repo" }

		local provider = require(ISSUE_PROVIDER)
		local views = provider.views()

		assert.equal("function", type(provider.views))
		assert.is_nil(provider.capabilities.core.views)
		assert.equal(1, repository_calls)
		assert.equal("owner/repo", views[1].repo)
		assert.equal("owner/repo", views[2].repo)
		assert.equal("other/repo", views[3].repo)
		assert.equal("configured/repo", configured[1].repo)
		assert.is_nil(configured[2].repo)
		for index, view in ipairs(views) do
			assert.is_false(view == configured[index])
		end
		assert.is_true(views[1].extra_params == extra_params)
		assert.equal("compact", views[1].layout)

		assert.equal(
			"repo:owner/repo is:closed scope:created labels:bug direction:desc needle",
			provider.resolve_search(views[1])
		)
		local issues_api = require("atlas.issues.providers.forge.forgejo.api").issues
		issue_list = issues_api.list
		local fetched_view
		issues_api.list = function(view, _, on_done)
			fetched_view = view
			on_done({}, nil, true, nil)
			return { cancel = function() end }
		end
		provider.capabilities.core.fetch_issues(views[1], {}, function() end)
		assert.is_true(fetched_view == views[1])
		assert.equal(1, repository_calls)
	end)

	it("resolves every pull current-repository view from one lookup", function()
		local extra_params = { sort = "recent" }
		local configured = {
			{
				name = "Repository",
				key = "1",
				current_repo = true,
				repo = "configured/repo",
				extra_params = extra_params,
				layout = "compact",
			},
			{ name = "Second", key = "2", current_repo = true },
			{ name = "Elsewhere", key = "3", repo = "other/repo" },
		}
		pull_config = { views = configured }
		repository = { provider = "forgejo", repo_full_name = "owner/repo" }

		local provider = require(PULL_PROVIDER)
		local views = provider.views()

		assert.equal("function", type(provider.views))
		assert.is_nil(provider.capabilities.core.views)
		assert.equal(1, repository_calls)
		assert.equal("owner/repo", views[1].repo)
		assert.equal("owner/repo", views[2].repo)
		assert.equal("other/repo", views[3].repo)
		assert.equal("configured/repo", configured[1].repo)
		assert.is_nil(configured[2].repo)
		for index, view in ipairs(views) do
			assert.is_false(view == configured[index])
		end
		assert.is_true(views[1].extra_params == extra_params)
		assert.equal("compact", views[1].layout)

		local query, states = provider.resolve_search(views[1])
		assert.equal("repo:owner/repo is:open sort:recent", query)
		assert.same({ "open" }, states)
		local pullrequests_api = require("atlas.pulls.providers.forge.forgejo.api").pullrequests
		pull_list = pullrequests_api.list
		local fetched_view, fetched_opts
		pullrequests_api.list = function(view, opts, on_done)
			fetched_view = view
			fetched_opts = opts
			on_done({}, nil)
			return { cancel = function() end }
		end
		provider.capabilities.core.fetch_pullrequests(views[1], {}, function() end)
		assert.is_false(fetched_view == views[1])
		assert.equal("", fetched_view.search)
		assert.same({ "OPEN" }, fetched_opts.statuses)
		assert.equal(1, repository_calls)
	end)

	it("keeps displayed pull states and API statuses aligned", function()
		local provider = require(PULL_PROVIDER)
		local api = require("atlas.pulls.providers.forge.forgejo.api").pullrequests
		pull_search_global = api.search_global
		local fetched_view, fetched_opts
		api.search_global = function(view, opts, on_done)
			fetched_view = view
			fetched_opts = opts
			on_done({}, nil)
			return { cancel = function() end }
		end

		local view = { name = "Search", search = "is:merged needle" }
		local query, states = provider.resolve_search(view)
		assert.equal("type:pulls is:merged needle", query)
		assert.same({ "merged" }, states)
		provider.capabilities.core.fetch_pullrequests(view, {}, function() end)
		assert.equal("needle", fetched_view.search)
		assert.same({ "MERGED" }, fetched_opts.statuses)

		view._states = { "declined" }
		query, states = provider.resolve_search(view)
		assert.equal("type:pulls is:declined needle", query)
		assert.same({ "declined" }, states)
		provider.capabilities.core.fetch_pullrequests(view, {}, function() end)
		assert.same({ "DECLINED" }, fetched_opts.statuses)
	end)
end)
