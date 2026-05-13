--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------

---@alias AtlasKeymapValue string|string[]|false|nil

---@alias AtlasPullsProviderId "bitbucket"|"github"|"gitlab"
---@alias AtlasIssuesProviderId "jira"|"github"|"gitlab"

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
---@field gitlab AtlasGitLabPullsConfig|nil

---@class AtlasIssuesProviders
---@field jira AtlasJiraIssuesConfig|nil
---@field github AtlasGitHubIssuesConfig|nil
---@field gitlab AtlasGitLabIssuesConfig|nil

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
			refresh = "r",
			refresh_view = "R",
			open_actions = "A",
			open_in_browser = "gx",
			copy_url = "Y",
			show_details = "K",
			search = "?",
		},
		pulls = {
			copy_id = "y",
			open_diff = "gd",
			checkout = "gc",
			next_hunk = "]h",
			previous_hunk = "[h",
			filter_status_open = "gpo",
			filter_status_merged = "gpm",
			filter_status_declined = "gpd",
		},
		issues = {
			copy_key = "y",
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
	pcall(vim.api.nvim_del_user_command, "AtlasSearch")
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

	local pulls_providers = { "bitbucket", "github", "gitlab" }
	local issues_providers = { "jira", "github", "gitlab" }

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

	vim.api.nvim_create_user_command("AtlasSearch", function(opts)
		local provider_id = opts.fargs[1] and opts.fargs[1]:lower() or nil
		require("atlas.search").run(provider_id)
	end, {
		desc = "Search across Atlas providers",
		nargs = "?",
		complete = function(arglead)
			return require("atlas.search").complete(arglead)
		end,
	})
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
