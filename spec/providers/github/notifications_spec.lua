local github_client = require("spec.support.github_client_stub")

local MODULE = "atlas.providers.github.notifications"

local function raw(subject_type, subject_url, title)
	return {
		id = "1",
		unread = true,
		reason = "mention",
		updated_at = "2026-10-15T10:00:00Z",
		repository = { full_name = "owner/repo" },
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
	after_each(function()
		github_client.uninstall()
		package.loaded[MODULE] = nil
	end)

	it("builds web URLs for every subject type", function()
		local api = "https://api.github.com/repos/owner/repo/"
		local notifications = fetch({
			raw("PullRequest", api .. "pulls/35"),
			raw("Issue", api .. "issues/106"),
			raw("Discussion", api .. "discussions/40"),
			raw("Commit", api .. "commits/8ac653b6"),
			raw("Release", api .. "releases/413897911"),
			raw("CheckSuite", nil),
			raw("CheckSuite", nil, "CI workflow run failed for feat/open-notifications branch"),
			raw("RepositoryDependabotAlertsThread", nil),
			raw("RepositoryInvitation", nil),
			raw("SecurityAdvisory", nil),
		})

		local web = "https://github.com/owner/repo"
		assert.are.same(
			{
				web .. "/pull/35",
				web .. "/issues/106",
				web .. "/discussions/40",
				web .. "/commit/8ac653b6",
				web .. "/releases",
				web .. "/actions",
				web .. "/actions?query=branch:feat/open-notifications",
				web .. "/security/dependabot",
				web .. "/invitations",
				web,
			},
			vim.tbl_map(function(notification)
				return notification.url
			end, notifications)
		)
	end)
end)
