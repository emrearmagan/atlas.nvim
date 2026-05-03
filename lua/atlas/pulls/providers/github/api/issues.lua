local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local logger = require("atlas.core.logger")

---@class GitHubLabel
---@field name string
---@field color string|nil
---@field description string|nil

---@class GitHubAssignee
---@field login string
---@field name string|nil

---@class GitHubMilestone
---@field number integer
---@field title string
---@field state string|nil
---@field description string|nil

---@class GitHubCreateIssueOpts
---@field repo_slug string
---@field title string
---@field body string|nil
---@field labels string[]|nil
---@field assignees string[]|nil
---@field milestone integer|nil

---@class GitHubCreateIssueResult
---@field number integer|nil
---@field url string|nil

--------------------------------------------------------------------------------
-- Lookups
--------------------------------------------------------------------------------

---List repository labels.
---@param slug string
---@param on_done fun(labels: GitHubLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_labels(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/labels?per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.name) == "string" then
					table.insert(list, {
						name = raw.name,
						color = type(raw.color) == "string" and raw.color or nil,
						description = type(raw.description) == "string" and raw.description or nil,
					})
				end
			end
		end
		on_done(list, nil)
	end)
end

---@param slug string
---@param on_done fun(assignees: GitHubAssignee[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_assignees(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/assignees?per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.login) == "string" then
					table.insert(list, {
						login = raw.login,
						name = type(raw.name) == "string" and raw.name or nil,
					})
				end
			end
		end
		on_done(list, nil)
	end)
end

---@param slug string
---@param on_done fun(milestones: GitHubMilestone[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_milestones(slug, on_done)
	if type(slug) ~= "string" or slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	return cli.gh({
		"api",
		"--paginate",
		string.format("repos/%s/milestones?state=open&per_page=100", slug),
	}, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local list = {}
		if type(result) == "table" then
			for _, raw in ipairs(result) do
				if type(raw) == "table" and type(raw.number) == "number" and type(raw.title) == "string" then
					table.insert(list, {
						number = raw.number,
						title = raw.title,
						state = type(raw.state) == "string" and raw.state or nil,
						description = type(raw.description) == "string" and raw.description or nil,
					})
				end
			end
		end
		on_done(list, nil)
	end)
end

---@param opts GitHubCreateIssueOpts
---@param on_done fun(result: GitHubCreateIssueResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	local slug = tostring(opts.repo_slug or "")
	if slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repository slug")
		end)
		return nil
	end

	local title = tostring(opts.title or "")
	if vim.trim(title) == "" then
		vim.schedule(function()
			on_done(nil, "Title is required")
		end)
		return nil
	end

	local args = {
		"issue",
		"create",
		"--repo",
		slug,
		"--title",
		title,
		"--body",
		tostring(opts.body or ""),
	}

	if type(opts.labels) == "table" then
		for _, label in ipairs(opts.labels) do
			if type(label) == "string" and label ~= "" then
				table.insert(args, "--label")
				table.insert(args, label)
			end
		end
	end

	if type(opts.assignees) == "table" then
		for _, login in ipairs(opts.assignees) do
			if type(login) == "string" and login ~= "" then
				table.insert(args, "--assignee")
				table.insert(args, login)
			end
		end
	end

	if type(opts.milestone) == "number" then
		table.insert(args, "--milestone")
		table.insert(args, tostring(opts.milestone))
	end

	logger.loginfo("github.create_issue", {
		slug = slug,
		labels = opts.labels,
		assignees = opts.assignees,
		milestone = opts.milestone,
	})

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local url = nil
		local number = nil
		if type(result) == "string" then
			url = vim.trim(result)
			local match = url:match("/issues/(%d+)")
			if match then
				number = tonumber(match) or match
			end
		end

		on_done({ number = number, url = url }, nil)
	end)
end

return M
