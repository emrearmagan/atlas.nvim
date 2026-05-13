--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------

---@alias AtlasKeymapValue string|string[]|false|nil

---@alias AtlasPullsProviderId "bitbucket"|"github"|"mock"
---@alias AtlasIssuesProviderId "jira"|"github"|"mock"

--------------------------------------------------------------------------------
-- Pulls Provider Config
--------------------------------------------------------------------------------

---@class AtlasPullsViewConfig
---@field name string
---@field key string|nil
---@field layout "compact"|"plain"|nil

---@class AtlasIssuesViewConfig
---@field name string
---@field key string|nil
---@field layout "plain"|"compact"|nil

---@class AtlasPullsRepoConfig
---@field settings table<string, AtlasPullsRepoSettings>|nil
---@field paths table<string, string>|nil

---@class AtlasPullsRepoSettings
---@field readme string|nil
---@field pr_template string|nil

---@class AtlasPullsDiffConfig
---@field open_cmd "DiffviewOpen"|"CodeDiff"|string|nil

---@class AtlasPullsCustomActionContext
---@field repo_path string|nil
---@field pr PullRequest
---@field user PullsUser|nil

---@class AtlasPullsCustomAction
---@field id string
---@field label string
---@field confirmation boolean|nil
---@field run fun(pr: PullRequest, ctx: AtlasPullsCustomActionContext, done: fun(ok: boolean|nil, message: string|nil))

--------------------------------------------------------------------------------
-- Configs
--------------------------------------------------------------------------------

---@class AtlasPullsProviders
---@field bitbucket AtlasBitbucketConfig|nil
---@field github AtlasGitHubConfig|nil

---@class AtlasIssuesProviders
---@field jira AtlasJiraIssuesConfig|nil
---@field github AtlasGitHubIssuesConfig|nil

---@class AtlasPullsConfig
---@field repo_config AtlasPullsRepoConfig|nil
---@field diff AtlasPullsDiffConfig|nil
---@field custom_actions AtlasPullsCustomAction[]|nil
---@field providers AtlasPullsProviders|nil

---@class AtlasIssuesCustomActionContext
---@field issue Issue|nil
---@field user IssueUser|nil

---@class AtlasIssuesCustomAction
---@field id string
---@field label string
---@field confirmation boolean|nil
---@field run fun(issue: Issue, ctx: AtlasIssuesCustomActionContext, done: fun(ok: boolean|nil, message: string|nil))

---@class AtlasIssuesConfig
---@field max_results number|nil
---@field with_relationships boolean|nil
---@field custom_actions AtlasIssuesCustomAction[]|nil
---@field providers AtlasIssuesProviders|nil

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

---@class AtlasConfig
---@field pulls AtlasPullsConfig|nil
---@field issues AtlasIssuesConfig|nil
---@field keymaps AtlasKeymapsConfig|nil  -- see core/keymaps.lua for type

local M = {}

---@type AtlasConfig
M.options = {
	pulls = nil,
	issues = nil,
	keymaps = {
		ui = {
			help = "g?",
			close = "q",
			toggle_panel = "p",
			toggle_fold = "za",
			toggle_all_folds = "zA",
			previous_panel_tab = "<S-Tab>",
			next_panel_tab = "<Tab>",
			open_notifications = "N",
			notifications_mark_read = "r",
			notifications_mark_done = "d",
			notifications_refresh = "R",
			toggle_subscription = "gS",
		},
		pulls = {
			refresh = "r",
			refresh_view = "R",
			open_actions = "A",
			open_in_browser = "gx",
			copy_url = "Y",
			copy_id = "y",
			open_diff = "gd",
			checkout = "gc",
			show_details = "K",
			search = "?",
			pr_files_next_hunk = "]h",
			pr_files_previous_hunk = "[h",
			filter_status_open = "gpo",
			filter_status_merged = "gpm",
			filter_status_declined = "gpd",
		},
		issues = {
			open_actions = "A",
			open_in_browser = "gx",
			copy_url = "Y",
			copy_key = "y",
			show_details = "K",
			search = "?",
			refresh = "r",
			refresh_view = "R",
			transition_issue = "gs",
			change_assignee = "ga",
			change_reporter = "gr",
			edit_issue = "ge",
			create_issue = "c",
		},
	},
}

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function register_commands()
	pcall(vim.api.nvim_del_user_command, "AtlasPulls")
	pcall(vim.api.nvim_del_user_command, "AtlasIssues")
	pcall(vim.api.nvim_del_user_command, "AtlasJqlSearch")
	pcall(vim.api.nvim_del_user_command, "AtlasLogs")
	pcall(vim.api.nvim_del_user_command, "AtlasClearCache")
	pcall(vim.api.nvim_del_user_command, "AtlasCreatePR")
	pcall(vim.api.nvim_del_user_command, "AtlasCreateIssue")

	vim.api.nvim_create_user_command("AtlasLogs", function()
		require("atlas.ui.logs").toggle()
	end, { desc = "Toggle Atlas log viewer" })

	vim.api.nvim_create_user_command("AtlasClearCache", function()
		require("atlas.core.cache").clear_all()
		require("atlas.core.memory_cache").clear_all()
		vim.notify("Atlas cache cleared", vim.log.levels.INFO)
	end, { desc = "Clear Atlas disk and memory cache" })

	local pulls_providers = { "bitbucket", "github", "mock" }
	local issues_providers = { "jira", "github", "mock" }

	vim.api.nvim_create_user_command("AtlasPulls", function(opts)
		local provider_id = opts.fargs[1] and opts.fargs[1]:lower() or nil
		require("atlas").open("pulls", provider_id)
	end, {
		desc = "Open Atlas pulls",
		nargs = "?",
		complete = function(arglead)
			return vim.tbl_filter(function(p)
				return p:find(arglead, 1, true) == 1
			end, pulls_providers)
		end,
	})

	vim.api.nvim_create_user_command("AtlasIssues", function(opts)
		local provider_id = opts.fargs[1] and opts.fargs[1]:lower() or nil
		require("atlas").open("issues", provider_id)
	end, {
		desc = "Open Atlas issues",
		nargs = "?",
		complete = function(arglead)
			return vim.tbl_filter(function(p)
				return p:find(arglead, 1, true) == 1
			end, issues_providers)
		end,
	})

	vim.api.nvim_create_user_command("AtlasCreatePR", function()
		require("atlas.pulls.create.pr").start()
	end, { desc = "Create a pull request from the current branch" })

	vim.api.nvim_create_user_command("AtlasCreateIssue", function()
		require("atlas.issues.create").start()
	end, { desc = "Create an issue" })

	if M.options.issues then
		if M.options.issues.providers and M.options.issues.providers.jira then
			vim.api.nvim_create_user_command("AtlasJqlSearch", function(cmd_opts)
				require("atlas.issues.providers.jira.completion.search").command(cmd_opts)
			end, {
				desc = "Search Jira issues with JQL",
				nargs = "*",
				complete = function(arglead, cmdline, cursorpos)
					return require("atlas.issues.providers.jira.completion.search").complete(
						arglead,
						cmdline,
						cursorpos
					)
				end,
			})
		end
	end
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---@param opts AtlasConfig|table|nil
function M.setup(opts)
	local resolved = opts or {}
	M.options = vim.tbl_deep_extend("force", M.options, resolved)
	register_commands()
end

return M
