local github_client = require("spec.support.github_client_stub")

local MODULE = "atlas.providers.github.notifications"

local function raw(subject_type, subject_url, title)
	return {
		id = "1",
		unread = true,
		reason = "mention",
		updated_at = "2026-10-15T10:00:00Z",
		repository = { full_name = "octo/repo" },
		subject = { type = subject_type, url = subject_url, title = title or "Title" },
	}
end

local function fetch(items)
	github_client.install({
		gh = function(_, callback)
			callback(items, nil)
		end,
	})
	package.loaded[MODULE] = nil
	local result
	require(MODULE).fetch({ force_refresh = true }, function(notifications)
		result = notifications
	end)
	return assert(result)
end

describe("GitHub notifications", function()
	local stubbed = {}

	local function stub(name, value)
		if stubbed[name] == nil then
			stubbed[name] = { value = package.loaded[name] }
		end
		package.loaded[name] = value
	end

	after_each(function()
		github_client.uninstall()
		package.loaded[MODULE] = nil
		for name, previous in pairs(stubbed) do
			package.loaded[name] = previous.value
		end
		stubbed = {}
	end)

	it("builds web URLs for every subject type", function()
		local api = "https://api.github.com/repos/octo/repo/"
		local notifications = fetch({
			raw("PullRequest", api .. "pulls/35"),
			raw("Issue", api .. "issues/106"),
			raw("Discussion", api .. "discussions/40"),
			raw("Commit", api .. "commits/8ac653b6"),
			raw("Release", api .. "releases/413897911"),
			raw("CheckSuite", nil),
			raw("RepositoryDependabotAlertsThread", nil),
			raw("RepositoryInvitation", nil),
			raw("SecurityAdvisory", nil),
		})

		local web = "https://github.com/octo/repo"
		assert.are.same(
			{
				web .. "/pull/35",
				web .. "/issues/106",
				web .. "/discussions/40",
				web .. "/commit/8ac653b6",
				web .. "/releases",
				web .. "/actions",
				web .. "/security/dependabot",
				web .. "/invitations",
				web,
			},
			vim.tbl_map(function(notification)
				return notification.url
			end, notifications)
		)
	end)

	it("opens CI runs in the pipelines of the branch named in the title, or the builds page", function()
		local pipelines, repository
		stub("atlas.providers", {
			load = function()
				return {}
			end,
		})
		stub("atlas.pulls.pipelines", {
			open = function(context)
				pipelines = context
			end,
		})
		stub("atlas.ui.repository", {
			open = function(repo, _, opts)
				repository = { repo = repo, opts = opts }
			end,
		})

		local notifications = fetch({
			raw("CheckSuite", nil, "CI workflow run failed for feat/open-notifications branch"),
			raw("CheckSuite", nil, "Dependabot updates run failed"),
		})

		assert.is_true(require(MODULE).open(notifications[1]))
		assert.are.same(
			{ provider = "github", repo_full_name = "octo/repo", target = "feat/open-notifications" },
			pipelines
		)
		assert.is_true(require(MODULE).open(notifications[2]))
		assert.are.same({ repo = "octo/repo", opts = { page = "builds" } }, repository)
	end)

	it("opens releases on the repository releases page", function()
		local opened
		stub("atlas.providers", {
			load = function()
				return {}
			end,
		})
		stub("atlas.ui.repository", {
			open = function(repo, _, opts)
				opened = { repo = repo, opts = opts }
			end,
		})

		local notifications = fetch({
			raw("Release", "https://api.github.com/repos/octo/repo/releases/413897911", "0.8.2"),
		})

		assert.is_true(require(MODULE).open(notifications[1]))
		assert.are.same(
			{ repo = "octo/repo", opts = { page = "releases", ctx = { release_id = "413897911" } } },
			opened
		)
	end)

	it("opens discussions on the repository discussions page", function()
		local opened
		stub("atlas.providers", {
			load = function()
				return {}
			end,
		})
		stub("atlas.ui.repository", {
			open = function(repo, _, opts)
				opened = { repo = repo, opts = opts }
			end,
		})

		local notifications = fetch({
			raw("Discussion", "https://api.github.com/repos/octo/repo/discussions/40"),
		})

		assert.is_true(require(MODULE).open(notifications[1]))
		assert.are.same({ repo = "octo/repo", opts = { page = "discussions", ctx = { number = 40 } } }, opened)
	end)
end)
