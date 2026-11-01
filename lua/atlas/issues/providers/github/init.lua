---@class GitHubIssue : Issue
---@field repo_full_name string
---@field number integer
---@field node_id string|nil
---@field is_pinned boolean

---@class GitHubIssueMilestone : IssueMilestone
---@field number integer|nil
---@field progress_percentage number|nil
---@field open_issues integer|nil
---@field closed_issues integer|nil

---@class GitHubIssueDetails : IssueDetails
---@field milestone GitHubIssueMilestone|nil
---@field sub_issues GitHubIssue[]

local comments_api = require("atlas.issues.providers.github.api.comments")
local config = require("atlas.config")
local github_mapper = require("atlas.providers.github.mapper")
local git = require("atlas.core.git")
local issues_api = require("atlas.issues.providers.github.api.issues")
local links_api = require("atlas.providers.github.links")
local request_scope = require("atlas.core.requests")
local timeline_api = require("atlas.issues.providers.github.api.timeline")
local ui_detail = require("atlas.issues.providers.github.ui.detail")
local ui_repository = require("atlas.providers.github.ui.repository")

---@param view IssuesViewConfig
---@return string
local function resolve_search(view)
	---@cast view AtlasGitHubIssuesViewConfig
	local search = view.search or ""
	if not search:lower():find("is:issue", 1, true) then
		search = vim.trim(search .. " is:issue")
	end
	return search
end

---@param view AtlasGitHubIssuesViewConfig
---@param on_done fun(view: AtlasGitHubIssuesViewConfig)
---@return { cancel: fun() }|nil
local function resolve_view(view, on_done)
	if not view.current_repo then
		on_done(view)
		return nil
	end
	return git.local_repository(vim.fn.getcwd(), function(target)
		local resolved = vim.tbl_extend("force", {}, view)
		local repo = target and target.provider == "github" and target.repo_full_name or nil
		if repo then
			local additional = (view.search and view.search ~= "") and (" " .. view.search) or ""
			resolved.search = string.format("repo:%s%s", repo, additional)
		end
		on_done(resolved)
	end)
end

---@param view AtlasGitHubIssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(page: IssuesPage, err: string|nil)
---@return { cancel: fun() }
local function fetch_issues(view, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_view(view, done)
	end, function(resolved)
		local query = resolve_search(resolved)
		requests.run(function(done)
			return issues_api.search_issues(query, done, {
				force_refresh = opts.force_refresh == true,
				pagelen = opts.pagelen,
				cursor = opts.cursor,
			})
		end, function(page, err)
			if err then
				on_done({ items = {}, query = query }, err)
				return
			end

			local pinned, rest = {}, {}
			for _, issue in ipairs(page.items) do
				---@cast issue GitHubIssue
				if issue.is_pinned == true then
					table.insert(pinned, issue)
				else
					table.insert(rest, issue)
				end
			end
			local sorted = vim.list_extend({}, pinned)
			vim.list_extend(sorted, rest)
			page.items = sorted
			page.query = query
			on_done(page, nil)
		end)
	end)
	return requests
end

---@return AtlasGitHubIssuesViewConfig[]
local function views()
	local cfg = config.domain_options("github", "issues") or {}
	local configured = cfg.views
	if not configured or #configured == 0 then
		configured = {
			{
				name = "Assigned",
				key = "1",
				search = "assignee:@me is:open",
			},
		}
	end
	return vim.tbl_map(function(view)
		return vim.tbl_extend("force", {}, view)
	end, configured)
end

---@param target AtlasTarget
---@return IssueRef|nil
local function issue_ref(target)
	if target.owner and target.repo and target.number then
		return { key = string.format("%s/%s#%d", target.owner, target.repo, target.number) }
	end
end

return {
	views = views,
	issue_ref = issue_ref,
	capabilities = {
		actions = require("atlas.issues.providers.github.actions.registry"),
		core = {
			fetch_issues = fetch_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			fetch_links = links_api.fetch_issue,
		},
		comments = {
			-- fetch_activity = nil,
			fetch_conversation = timeline_api.fetch_conversation,
			add_comment = comments_api.add,
			edit_comment = comments_api.edit,
			delete_comment = comments_api.delete,
			reactions = {
				options = github_mapper.reactions,
				add = comments_api.add_reaction,
				remove = comments_api.remove_reaction,
			},
		},
		ui = {
			detail = ui_detail,
			repository = ui_repository,
		},
	},
}
