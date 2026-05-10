local icons = require("atlas.ui.shared.icons")
local panel = require("atlas.pulls.providers.mock.ui.panel")

local SCRIPT_DIR = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

--------------------------------------------------------------------------------
-- Mock data
--------------------------------------------------------------------------------

local BUILD_STATUSES = { "SUCCESSFUL", "FAILED", "INPROGRESS", "STOPPED" }
local BUILD_NAMES = { "ci/build", "ci/lint", "ci/test", "deploy/staging" }

local FAKE_REVIEWERS = {
	{ name = "Alice", nickname = "alice", decision = "approved" },
	{ name = "Bob", nickname = "bob", decision = "changes_requested" },
	{ name = "Charlie", nickname = "charlie", decision = "pending" },
	{ name = "Diana", nickname = "diana", decision = "approved" },
	{ name = "Eve", nickname = "eve", decision = "pending" },
}

local FAKE_ACTIVITY = {
	{
		kind = "update",
		actor = { name = "Alice", nickname = "alice" },
		date = "2026-04-16T10:30:00+00:00",
		changes = { description = { old = "old desc", new = "new desc" } },
	},
	{
		kind = "approval",
		actor = { name = "Diana", nickname = "diana" },
		date = "2026-04-16T09:15:00+00:00",
	},
	{
		kind = "comment",
		actor = { name = "Bob", nickname = "bob" },
		date = "2026-04-15T14:20:00+00:00",
		content_raw = "Looks good overall, just a few nits on the error handling path.",
	},
	{
		kind = "comment",
		actor = { name = "Charlie", nickname = "charlie" },
		date = "2026-04-15T11:00:00+00:00",
		content_raw = "Can we add a test for the edge case?",
	},
	{
		kind = "update",
		actor = { name = "Mock User", nickname = "mockuser" },
		date = "2026-04-14T16:45:00+00:00",
		changes = { title = { old = "WIP: refactor", new = "Refactor panel system" } },
	},
}

local FAKE_COMMENTS_TEMPLATE = {
	{
		id = 1,
		parent_id = nil,
		author = { name = "Bob", nickname = "bob" },
		content_raw = "Looks good overall, just a few nits on the error handling path.",
		created_on = "2026-04-15T14:20:00+00:00",
	},
	{
		id = 2,
		parent_id = 1,
		author = { name = "Mock User", nickname = "mockuser" },
		content_raw = "Good point, I'll fix that in the next push.",
		created_on = "2026-04-15T15:00:00+00:00",
	},
	{
		id = 3,
		parent_id = nil,
		author = { name = "Charlie", nickname = "charlie" },
		content_raw = "Can we add a test for the edge case?",
		created_on = "2026-04-15T11:00:00+00:00",
		inline = { path = "lua/atlas/pulls/ui/panel/init.lua", to = 42 },
	},
	{
		id = 4,
		parent_id = 3,
		author = { name = "Mock User", nickname = "mockuser" },
		content_raw = "Added in the latest commit.",
		created_on = "2026-04-15T12:30:00+00:00",
		inline = { path = "lua/atlas/pulls/ui/panel/init.lua", to = 42 },
	},
	{
		id = 5,
		parent_id = nil,
		author = { name = "Alice", nickname = "alice" },
		content_raw = "Nice refactor! Much cleaner now.",
		created_on = "2026-04-16T10:00:00+00:00",
	},
}

---@type table<string, PullsComment[]>
local comment_store = {}
local next_comment_id = 100

---@param pr PullRequest
---@return PullsComment[]
local function get_comments(pr)
	local key = tostring(pr.repo_full_name) .. "/" .. tostring(pr.id)
	if not comment_store[key] then
		comment_store[key] = vim.deepcopy(FAKE_COMMENTS_TEMPLATE)
	end
	return comment_store[key]
end

local FAKE_COMMITS = {
	{
		hash = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
		short_hash = "a1b2c3d4",
		message = "Refactor panel system to use provider-based architecture",
		author_name = "Mock User",
		author_nickname = "mockuser",
		date = "2026-04-16T10:30:00+00:00",
	},
	{
		hash = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
		short_hash = "b2c3d4e5",
		message = "Add shared overview tab with reviewers, builds, diffstat",
		author_name = "Mock User",
		author_nickname = "mockuser",
		date = "2026-04-15T16:00:00+00:00",
	},
	{
		hash = "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
		short_hash = "c3d4e5f6",
		message = "Fix build highlights not showing in panel chips",
		author_name = "Mock User",
		author_nickname = "mockuser",
		date = "2026-04-14T14:00:00+00:00",
	},
	{
		hash = "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
		short_hash = "d4e5f6a1",
		message = "Initial panel implementation with mock provider",
		author_name = "Mock User",
		author_nickname = "mockuser",
		date = "2026-04-13T09:00:00+00:00",
	},
}

local FAKE_DIFF = {
	{
		path = "lua/atlas/pulls/ui/panel/init.lua",
		status = "modified",
		hunks = {
			{
				header = "@@ -10,6 +10,12 @@",
				lines = {
					{ kind = "context", text = "local layout = require('atlas.ui.layout')" },
					{ kind = "context", text = "local panel_state = require('atlas.pulls.ui.panel.state')" },
					{ kind = "remove", text = "-local old_renderer = require('atlas.pulls.ui.old_renderer')" },
					{ kind = "add", text = "+local renderer = require('atlas.pulls.ui.panel.renderer')" },
					{ kind = "add", text = "+local icons = require('atlas.ui.shared.icons')" },
					{ kind = "context", text = "" },
					{ kind = "context", text = "local SPINNER_INTERVAL_MS = 100" },
				},
			},
		},
	},
	{
		path = "lua/atlas/pulls/ui/panel/tabs/overview/init.lua",
		status = "added",
		hunks = {
			{
				header = "@@ -0,0 +1,20 @@",
				lines = {
					{ kind = "add", text = "+local M = {}" },
					{ kind = "add", text = "+" },
					{ kind = "add", text = "+local utils = require('atlas.ui.shared.utils')" },
					{ kind = "add", text = "+local icons = require('atlas.ui.shared.icons')" },
					{ kind = "add", text = "+" },
					{ kind = "add", text = "+function M.render(pr, width)" },
					{ kind = "add", text = "+  local lines = {}" },
					{ kind = "add", text = "+  local spans = {}" },
					{ kind = "add", text = "+  return lines, spans, {}" },
					{ kind = "add", text = "+end" },
					{ kind = "add", text = "+" },
					{ kind = "add", text = "+return M" },
				},
			},
		},
	},
	{
		path = "lua/atlas/pulls/old_panel.lua",
		status = "removed",
		hunks = {
			{
				header = "@@ -1,10 +0,0 @@",
				lines = {
					{ kind = "remove", text = "-local M = {}" },
					{ kind = "remove", text = "-" },
					{ kind = "remove", text = "-function M.render()" },
					{ kind = "remove", text = "-  -- old implementation" },
					{ kind = "remove", text = "-end" },
					{ kind = "remove", text = "-" },
					{ kind = "remove", text = "-return M" },
				},
			},
		},
	},
}

local FAKE_DIFFSTAT = {
	{ status = "modified", path = "lua/atlas/pulls/ui/panel/init.lua", lines_added = 42, lines_removed = 18 },
	{
		status = "added",
		path = "lua/atlas/pulls/ui/panel/tabs/overview/init.lua",
		lines_added = 120,
		lines_removed = 0,
	},
	{ status = "removed", path = "lua/atlas/pulls/old_panel.lua", lines_added = 0, lines_removed = 85 },
	{
		status = "renamed",
		path = "lua/atlas/pulls/state.lua",
		old_path = "lua/atlas/pulls/old_state.lua",
		lines_added = 3,
		lines_removed = 1,
	},
	{ status = "modified", path = "lua/atlas/ui/shared/utils.lua", lines_added = 15, lines_removed = 2 },
}

---@param filename string
---@return table
local function load_json(filename)
	local path = SCRIPT_DIR .. "/data/" .. filename
	local file = io.open(path, "r")
	if not file then
		error("mock: cannot open " .. path)
	end
	local content = file:read("*a")
	file:close()
	return vim.json.decode(content)
end

---@param repo_slug string
---@param pr_num string|number
---@return PullsLink
local function build_link(repo_slug, pr_num)
	return {
		html = "https://github.com/emrearmagan/atlas.nvim/tree/main",
	}
end

---@param groups PullsGroup[]
local function hydrate(groups)
	for _, group in ipairs(groups) do
		for _, pr in ipairs(group.prs) do
			pr.link = build_link(pr.repo_full_name, pr.id)
			pr._raw = nil
		end
	end
end

local MOCK_GROUPS = load_json("pullrequests.json")
hydrate(MOCK_GROUPS)

---@param repo_id string
---@param pr_id string|number
---@return PullRequest|nil
local function find_pr(repo_id, pr_id)
	for _, group in ipairs(MOCK_GROUPS) do
		if group.repo.id == repo_id then
			for _, pr in ipairs(group.prs) do
				if tostring(pr.id) == tostring(pr_id) then
					return pr
				end
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Provider
--------------------------------------------------------------------------------

---@class MockPullsProvider : PullsProvider
local M = {
	id = "mock",
	name = "Mock",
	icon = icons.pulls_provider("mock", "provider"),
	hl_group = "AtlasMockTheme",
	panel = panel,
}

function M.setup()
	require("atlas.pulls.providers.mock.highlights").setup()
end

---@param on_done fun(user: PullsUser|nil, err: string|nil)
function M.fetch_user(on_done)
	vim.defer_fn(function()
		on_done({
			name = "Mock User",
			id = "mock-user-1",
			username = "mockuser",
		}, nil)
	end, 200)
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(groups: PullsGroup[], err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		on_done(MOCK_GROUPS, nil)
	end, 800)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param opts PullsFetchOpts
---@param on_done fun(pr: PullRequest|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local found = find_pr(tostring(pr.repo_full_name or ""), pr.id)
		if found then
			on_done(vim.deepcopy(found), nil)
		else
			on_done(nil, "PR not found")
		end
	end, 500)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param repo PullsRepo
---@param opts PullsFetchOpts
---@param on_done fun(repo: PullsRepoDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_details(repo, opts, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local full_name = tostring(repo.id or repo.name or "")
		local owner = tostring(repo.owner or "mock")
		local repo_name = tostring(repo.repo_name or repo.name or "repo")
		local details = {
			id = tostring(repo.id or repo.name or "mock/repo"),
			name = tostring(repo.name or repo.id or "Mock Repository"),
			full_name = full_name ~= "" and full_name or tostring(repo.name or repo.id or "Mock Repository"),
			owner = owner or "mock",
			repo_name = repo_name or tostring(repo.name or "repo"),
			html_url = tostring(repo.html_url or "https://github.com/emrearmagan/atlas.nvim"),
			description = "Mock repository used for local panel development.",
			size = 1024 * 1024 * 12,
			default_branch = "main",
			is_private = false,
			created_on = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - (60 * 60 * 24 * 30)),
			readme = "# Mock Repository\n\nThis is a mock README loaded through `fetch_repo_details`.\n",
			_raw = { mock = true },
		}
		on_done(details, nil)
	end, 150)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(branches: PullsRepoBranches|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_branches(repo, opts, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		on_done({
			entries = {
				{
					name = tostring(repo.default_branch or "main"),
					hash = "abc1234",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - 3600),
					message = "Initial mock branch commit",
					author = "Mock Author",
				},
				{
					name = "feature/demo",
					hash = "def5678",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - 86400),
					message = "Add repository panel preview",
					author = "Mock Author",
				},
				{
					name = "feature/repo-tabs",
					hash = "98ab321",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - (86400 * 2)),
					message = "Implement repository branches and tags tabs",
					author = "Atlas Dev",
				},
				{
					name = "fix/mock-data",
					hash = "76cd890",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - (86400 * 4)),
					message = "Expand mock provider data for panel testing",
					author = "Atlas Dev",
				},
				{
					name = "release/0.2",
					hash = "45ef123",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - (86400 * 6)),
					message = "Prepare next mock release branch",
					author = "Release Bot",
				},
			},
		}, nil)
	end, 120)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param repo PullsRepoDetails
---@param opts PullsFetchOpts
---@param on_done fun(tags: PullsRepoTags|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_repo_tags(repo, opts, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		on_done({
			entries = {
				{
					name = "v0.1.0",
					hash = "abc1234",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - 172800),
					message = "First mock release",
					author = "Mock Release Bot",
				},
				{
					name = "v0.2.0",
					hash = "def5678",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - (86400 * 5)),
					message = "Add repository overview and tabs",
					author = "Mock Release Bot",
				},
				{
					name = "v0.2.1",
					hash = "98ab321",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - (86400 * 3)),
					message = "Fix repo panel loading indicators",
					author = "Mock Release Bot",
				},
				{
					name = "nightly-2026-04-19",
					hash = "76cd890",
					date = os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() - 43200),
					message = "Nightly build for repo tab development",
					author = "Nightly Bot",
				},
			},
		}, nil)
	end, 120)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
	end
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local count = 2 + math.random(3)
		local result = {}
		for i = 1, math.min(count, #FAKE_REVIEWERS) do
			table.insert(result, FAKE_REVIEWERS[i])
		end
		on_done(result, nil)
	end, 600 + math.random(800))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param on_done fun(builds: PullsBuild[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_builds(pr, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local entries = {}
		local count = 1 + math.random(3)
		for i = 1, count do
			table.insert(entries, {
				name = BUILD_NAMES[((i - 1) % #BUILD_NAMES) + 1],
				state = BUILD_STATUSES[math.random(#BUILD_STATUSES)],
				key = "build-" .. i,
				url = "https://github.com/emrearmagan/atlas.nvim",
			})
		end
		on_done(entries, nil)
	end, 800 + math.random(600))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
	end
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local count = 2 + math.random(#FAKE_DIFFSTAT - 1)
		local result = {}
		for i = 1, math.min(count, #FAKE_DIFFSTAT) do
			result[i] = FAKE_DIFFSTAT[i]
		end
		on_done(result, nil)
	end, 500 + math.random(700))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
	end
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		on_done(vim.deepcopy(FAKE_ACTIVITY), nil)
	end, 500 + math.random(500))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
	end
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		on_done(vim.deepcopy(get_comments(pr)), nil)
	end, 600 + math.random(600))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
	end
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		on_done(vim.deepcopy(FAKE_COMMITS), nil)
	end, 400 + math.random(600))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(files: PullsDiffFile[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diff(pr, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
	end
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		on_done(vim.deepcopy(FAKE_DIFF), nil)
	end, 700 + math.random(500))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param commit PullsCommit
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(status: string|nil, url: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commit_status(pr, commit, opts, on_done)
	if type(opts) == "function" and on_done == nil then
		on_done = opts
	end
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local status = BUILD_STATUSES[math.random(#BUILD_STATUSES)]:lower()
		local url = "https://github.com/emrearmagan/atlas.nvim"
		on_done(status, url, nil)
	end, 300 + math.random(500))
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@return AtlasPullsViewConfig[]
function M.views()
	return {
		{ name = "Compact", key = "1", layout = "compact" },
		{ name = "Plain", key = "2", layout = "plain" },
	}
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

---@param pr PullRequest
---@param on_done fun(ok: boolean)
function M.open_diff(pr, on_done)
	local footer = require("atlas.ui.components.footer")
	footer.notify("info", "Diff view not available for mock provider")
	on_done(false)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean)
function M.checkout(pr, on_done)
	local footer = require("atlas.ui.components.footer")
	footer.notify("info", "Checkout not available for mock provider")
	on_done(false)
end

---@param pr PullRequest|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)
function M.open_actions(pr, source, on_done)
	local footer = require("atlas.ui.components.footer")

	---@type { id: string, label: string, run: fun(done: fun(result: PullsActionResult|nil)) }[]
	local actions = {
		{
			id = "approve",
			label = "Approve",
			run = function(done)
				footer.notify("loading", "Approving PR...")
				vim.defer_fn(function()
					footer.notify("success", "PR approved", 1200)
					done({ changed_pr = true, message = "Approved" })
				end, 300)
			end,
		},
		{
			id = "merge",
			label = "Merge",
			run = function(done)
				vim.ui.input({
					prompt = string.format("Confirm merge PR #%s? [y/N]: ", tostring(pr.id or "")),
				}, function(input)
					if input == nil then
						done({ changed_pr = false, message = "Merge cancelled" })
						return
					end

					local normalized = vim.trim(tostring(input)):lower()
					if normalized ~= "y" and normalized ~= "yes" then
						footer.notify("info", "Merge cancelled")
						done({ changed_pr = false, message = "Merge cancelled" })
						return
					end

					footer.notify("loading", "Merging PR...")
					vim.defer_fn(function()
						footer.notify("success", "Merge succeeded", 1200)
						done({ changed_pr = true, message = "Merged" })
					end, 500)
				end)
			end,
		},
		{
			id = "decline",
			label = "Decline",
			run = function(done)
				vim.ui.input({
					prompt = string.format("Confirm decline PR #%s? [y/N]: ", tostring(pr.id or "")),
				}, function(input)
					if input == nil then
						done({ changed_pr = false, message = "Decline cancelled" })
						return
					end

					local normalized = vim.trim(tostring(input)):lower()
					if normalized ~= "y" and normalized ~= "yes" then
						footer.notify("info", "Decline cancelled")
						done({ changed_pr = false, message = "Decline cancelled" })
						return
					end

					footer.notify("loading", "Declining PR...")
					vim.defer_fn(function()
						footer.notify("success", "PR declined", 1200)
						done({ changed_pr = true, message = "Declined" })
					end, 300)
				end)
			end,
		},
		{
			id = "request_changes",
			label = "Request changes",
			run = function(done)
				footer.notify("loading", "Requesting changes...")
				vim.defer_fn(function()
					footer.notify("success", "Changes requested", 1200)
					done({ changed_pr = true, message = "Changes requested" })
				end, 300)
			end,
		},
	}

	vim.ui.select(actions, {
		prompt = string.format("Choose action for PR #%s", tostring(pr.id or "")),
		format_item = function(action)
			return action.label
		end,
	}, function(action)
		if action == nil then
			on_done({ changed_pr = false, message = "Action cancelled" })
			return
		end

		action.run(on_done)
	end)
end

--------------------------------------------------------------------------------
-- Comment actions
--------------------------------------------------------------------------------

---@param pr PullRequest
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		next_comment_id = next_comment_id + 1
		local comment = {
			id = next_comment_id,
			parent_id = nil,
			author = { name = "Mock User", nickname = "mockuser" },
			content_raw = content,
			created_on = os.date("!%Y-%m-%dT%H:%M:%S+00:00"),
		}
		table.insert(get_comments(pr), comment)
		on_done(vim.deepcopy(comment), nil)
	end, 300)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param parent_id number
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.reply_comment(pr, parent_id, content, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		next_comment_id = next_comment_id + 1
		local comment = {
			id = next_comment_id,
			parent_id = parent_id,
			author = { name = "Mock User", nickname = "mockuser" },
			content_raw = content,
			created_on = os.date("!%Y-%m-%dT%H:%M:%S+00:00"),
		}
		table.insert(get_comments(pr), comment)
		on_done(vim.deepcopy(comment), nil)
	end, 300)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param comment_id number
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment_id, content, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local comments = get_comments(pr)
		for _, c in ipairs(comments) do
			if c.id == comment_id then
				c.content_raw = content
				on_done(vim.deepcopy(c), nil)
				return
			end
		end
		on_done(nil, "Comment not found")
	end, 300)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

---@param pr PullRequest
---@param comment_id number
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment_id, on_done)
	local cancelled = false
	vim.defer_fn(function()
		if cancelled then
			return
		end
		local comments = get_comments(pr)
		for i, c in ipairs(comments) do
			if c.id == comment_id then
				table.remove(comments, i)
				on_done(true, nil)
				return
			end
		end
		on_done(false, "Comment not found")
	end, 300)
	return {
		cancel = function()
			cancelled = true
		end,
	}
end

return M
