-- Keymaps

---@alias AtlasKeymapValue string|string[]|false|nil

-- Pulls Provider Config

---@class AtlasPullsViewConfig
---@field name string
---@field key string|nil
---@field layout "compact"|"plain"|nil

---@class AtlasIssuesViewConfig
---@field name string
---@field key string|nil
---@field layout "plain"|"compact"|nil
---@field search string|nil

---@class AtlasPullsRepoConfig
---@field settings table<string, AtlasPullsRepoSettings>|nil
---@field paths table<string, string>|nil

---@class AtlasPullsRepoSettings
---@field readme string|nil
---@field pr_template string|nil

---@class AtlasPullsDiffExplorerConfig
---@field grouped boolean|nil
---@field hidden boolean|nil
---@field show_commits boolean|nil
---@field width integer|nil
---@field initial_focus "explorer"|"diff"|nil
---@field ignore string[]|nil

---@alias AtlasPullsDiffOpenCommand "AtlasDiff"|"DiffviewOpen"|"CodeDiff"

---@class AtlasPullsDiffConfig
---@field open_cmd AtlasPullsDiffOpenCommand|string|nil
---@field layout "side-by-side"|"inline"|nil
---@field compact boolean|nil
---@field compact_context_lines integer|nil
---@field show_review_panel boolean|nil
---@field explorer AtlasPullsDiffExplorerConfig|nil

---@class AtlasPullsCustomActionContext
---@field repo_path string|nil
---@field pr PullRequest
---@field user PullsUser|nil

---@class AtlasPullsCustomAction
---@field id string
---@field label string
---@field confirmation boolean|nil
---@field run fun(pr: PullRequest, ctx: AtlasPullsCustomActionContext, done: fun(ok: boolean|nil, message: string|nil))

-- Configs

---@alias AtlasPullsProviders table<string, AtlasBitbucketConfig|AtlasGitHubConfig|AtlasGitLabPullsConfig|table>
---@alias AtlasIssuesProviders table<string, AtlasJiraIssuesConfig|AtlasGitHubIssuesConfig|AtlasGitLabIssuesConfig|table>

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

-- Config

---@class AtlasConfig
---@field global_statusline boolean|nil Set one statusline across all windows (default: true)
---@field pulls AtlasPullsConfig|nil
---@field issues AtlasIssuesConfig|nil
---@field keymaps AtlasKeymapsConfig|nil  -- see core/keymaps.lua for type

local M = {}

local notify = require("atlas.core.notify")

---@type AtlasConfig
M.options = {
	global_statusline = true,
	pulls = {
		diff = {
			open_cmd = "AtlasDiff",
			layout = "inline",
			compact = true,
			compact_context_lines = 3,
			show_review_panel = false,
			explorer = {
				grouped = true,
				hidden = false,
				show_commits = false,
				width = 40,
				initial_focus = "explorer",
				ignore = { ".git/**", ".jj/**" },
			},
		},
	},
	issues = nil,
	keymaps = {
		ui = {
			next_item = "j",
			previous_item = "k",
			first_item = "gg",
			last_item = "G",
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
			copy_id = "y",
			copy_url = "Y",
			show_details = "K",
			search = "?",
		},
		pulls = {
			open_diff = "gd",
			checkout = "gc",
			review = {
				toggle_approval = "ga",
				request_changes = "gr",
				submit_review = "gs",
				open_file = "<CR>",
				toggle_explorer_grouping = "T",
				toggle_layout = "t",
				toggle_compact = "u",
				next_hunk = "]h",
				previous_hunk = "[h",
				next_file = { "]f", "<Tab>" },
				previous_file = { "[f", "<S-Tab>" },
				toggle_file_reviewed = "-",
				toggle_commits = "gC",
				toggle_review_panel = "gR",
				next_comment = "]c",
				previous_comment = "[c",
				next_note = "]n",
				previous_note = "[n",
				view_thread = "K",
				edit_comment = "e",
				add_task = "T",
				add_comment = "c",
				submit_comment = "C",
				delete_comment = "dd",
				add_note = "n",
				toggle_resolved = "x",
			},
			filter_status_open = "gpo",
			filter_status_merged = "gpm",
			filter_status_declined = "gpd",
		},
		issues = {
			transition_issue = "gs",
			change_assignee = "ga",
			change_reporter = "gr",
			edit_issue = "ge",
			create_issue = "c",
		},
	},
}

-- Commands

local function register_commands()
	pcall(vim.api.nvim_del_user_command, "AtlasPulls")
	pcall(vim.api.nvim_del_user_command, "AtlasIssues")
	pcall(vim.api.nvim_del_user_command, "AtlasSearch")
	pcall(vim.api.nvim_del_user_command, "AtlasOpen")
	pcall(vim.api.nvim_del_user_command, "AtlasLogs")
	pcall(vim.api.nvim_del_user_command, "AtlasClearCache")
	pcall(vim.api.nvim_del_user_command, "AtlasCreatePR")
	pcall(vim.api.nvim_del_user_command, "AtlasCreateIssue")
	pcall(vim.api.nvim_del_user_command, "AtlasDiff")
	pcall(vim.api.nvim_del_user_command, "AtlasNotes")

	vim.api.nvim_create_user_command("AtlasLogs", function()
		require("atlas.ui.logs").toggle()
	end, { desc = "Toggle Atlas log viewer" })

	vim.api.nvim_create_user_command("AtlasClearCache", function()
		require("atlas.core.cache").clear_all()
		require("atlas.core.memory_cache").clear_all()
		notify.info("Cache cleared")
	end, { desc = "Clear Atlas disk and memory cache" })

	vim.api.nvim_create_user_command("AtlasPulls", function(opts)
		local provider_id = opts.fargs[1] and opts.fargs[1]:lower() or nil
		require("atlas").open("pulls", provider_id)
	end, {
		desc = "Open Atlas pulls",
		nargs = "?",
		complete = function(arglead)
			return vim.tbl_filter(function(p)
				return p:find(arglead, 1, true) == 1
			end, require("atlas.providers").ids("pulls"))
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
			end, require("atlas.providers").ids("issues"))
		end,
	})

	vim.api.nvim_create_user_command("AtlasCreatePR", function()
		require("atlas.pulls.create.pr").start()
	end, { desc = "Create a pull request from the current branch" })

	vim.api.nvim_create_user_command("AtlasCreateIssue", function()
		require("atlas.issues.create").start()
	end, { desc = "Create an issue" })

	vim.api.nvim_create_user_command("AtlasDiff", function(opts)
		require("atlas.pulls.actions").open_atlas_diff(opts.args)
	end, {
		desc = "Open a Git range or pull request in AtlasDiff",
		nargs = 1,
	})

	vim.api.nvim_create_user_command("AtlasNotes", function(opts)
		require("atlas.pulls.notes.ui").open({
			target = opts.args ~= "" and opts.args or nil,
		})
	end, {
		desc = "Open local review notes",
		nargs = "?",
	})

	vim.api.nvim_create_user_command("AtlasSearch", function(opts)
		local provider_id = opts.fargs[1] and opts.fargs[1]:lower() or nil
		require("atlas.commands.search").run(provider_id)
	end, {
		desc = "Search across Atlas providers",
		nargs = "?",
		complete = function(arglead)
			return require("atlas.commands.search").complete(arglead)
		end,
	})

	vim.api.nvim_create_user_command("AtlasOpen", function(opts)
		require("atlas.commands.open").open(opts.args)
	end, {
		desc = "Open a provider URL or reference",
		nargs = 1,
	})
end

-- Setup

---@param opts AtlasConfig|table|nil
function M.setup(opts)
	local resolved = opts or {}
	M.options = vim.tbl_deep_extend("force", M.options, resolved)
	if M.options.global_statusline ~= false then
		vim.opt.laststatus = 3
	end
	register_commands()
end

return M
