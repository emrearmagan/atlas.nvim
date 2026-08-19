-- Keymaps

---@alias AtlasKeymapValue string|string[]|false|nil

-- Pulls Provider Config

---@class AtlasPullsViewConfig
---@field name string
---@field key string|nil
---@field layout "compact"|"grouped"|"plain"|nil
---@field _kind "bookmarks"|"starred"|nil
---@field _bookmarks table<string, any>|nil
---@field _starred { domain: "pulls", provider: string }|nil

---@class AtlasIssuesViewConfig
---@field name string
---@field key string|nil
---@field layout "plain"|"compact"|nil
---@field search string|nil
---@field _kind "bookmarks"|"starred"|nil
---@field _bookmarks table<string, any>|nil
---@field _starred { domain: "issues", provider: string }|nil

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
---@field comment_display "virtual_lines"|"virtual_text"|nil Initial comment and note display mode.
---@field explorer AtlasPullsDiffExplorerConfig|nil

---@class AtlasPullsCustomActionContext
---@field repo_path string|nil
---@field pr PullRequest
---@field user PullsUser|nil
---@field output fun(title: string): AtlasLiveOutput

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
---@field delete_notes boolean|nil
---@field default_merge_method "merge"|"squash"|nil
---@field default_delete_branch boolean|nil
---@field custom_actions AtlasPullsCustomAction[]|nil
---@field providers AtlasPullsProviders|nil

---@class AtlasIssuesCustomActionContext
---@field issue Issue|nil
---@field user IssueUser|nil
---@field output fun(title: string): AtlasLiveOutput

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

---@class AtlasUIConfig
---@field global_statusline boolean|nil Set one statusline across all windows (default: true)
---@field picker AtlasPickerName|nil
---@field listed_buffer boolean|nil Make the main Atlas dashboard a listed buffer (default: false)

---@class AtlasConfig
---@field ui AtlasUIConfig|nil
---@field pulls AtlasPullsConfig|nil
---@field issues AtlasIssuesConfig|nil
---@field keymaps AtlasKeymapsConfig|nil  -- see core/keymaps.lua for type

local M = {}

---@type AtlasConfig
M.options = {
	ui = {
		global_statusline = true,
		picker = "auto",
		listed_buffer = false,
	},
	pulls = {
		delete_notes = false,
		default_merge_method = "merge",
		default_delete_branch = false,
		diff = {
			open_cmd = "AtlasDiff",
			layout = "inline",
			compact = true,
			compact_context_lines = 3,
			show_review_panel = false,
			comment_display = "virtual_lines",
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
			select = "<CR>",
			submit = "<C-s>",
			help = "g?",
			close = "q",
			delete = "dd",
			comments = {
				add = { "a", "i" },
				reply = "c",
				edit = "e",
				react = "gr",
			},
			toggle_panel = "p",
			toggle_fold = "za",
			toggle_all_folds = "zA",
			previous_panel_tab = "<S-Tab>",
			next_panel_tab = "<Tab>",
			notifications = {
				open = "N",
				mark_read = "r",
				mark_done = "d",
			},
			toggle_subscription = "gS",
			toggle_star = "*",
			refresh = "r",
			refresh_view = "R",
			open_actions = "A",
			open_in_browser = "gx",
			copy_id = "y",
			copy_url = "Y",
			show_details = "K",
			search = "?",
		},
		picker = {
			next_item = { "<Down>", "<C-n>", "<C-j>" },
			previous_item = { "<Up>", "<C-p>", "<C-k>" },
			select = { "<CR>", "<C-s>" },
			toggle = "<Tab>",
			close = { "q", "<Esc>" },
		},
		pulls = {
			open_diff = "gd",
			checkout = "gc",
			external_help = "gA", -- Atlas help in external diff viewers.
			toggle_repo_panel = "o",
			toggle_repo_issue_state = "t",
			edit_title = "T",
			edit_description = "D",
			edit_reviewers = "gr",
			edit_assignees = "ga",
			review = {
				focus_item = "gd",
				approve = "ga",
				request_changes = "gr",
				submit_review = "gs",
				add_task = "<leader>t",
				explorer = {
					find_file = "<leader>ff",
					next_file = { "]f", "<Tab>" },
					previous_file = { "[f", "<S-Tab>" },
					next_unreviewed_file = "]u",
					previous_unreviewed_file = "[u",
					toggle_grouping = "T",
					toggle_file_reviewed = "-",
					toggle_commits = "gC",
				},
				diff = {
					toggle_layout = "t",
					toggle_compact = "gc",
					next_hunk = "]h",
					previous_hunk = "[h",
					toggle_review_panel = "gR",
					toggle_comments = "gH",
					next_comment = "]c",
					previous_comment = "[c",
					next_note = "]n",
					previous_note = "[n",
					add_comment = "c",
					submit_comment = "C",
					add_suggestion = "s",
					submit_suggestion = "S",
					add_note = "<leader>n",
					toggle_resolved = "x",
				},
			},
			pipelines = {
				open = "gd",
			},
			filters = {
				open = "gpo",
				merged = "gpm",
				declined = "gpd",
			},
		},
		issues = {
			transition_issue = "gs",
			change_assignee = "ga",
			change_reporter = "gr",
			edit_issue = "ge",
			create_issue = "c",
			toggle_description_mode = "m",
		},
	},
}

-- Setup

---@param opts AtlasConfig|table|nil
function M.setup(opts)
	local resolved = opts or {}
	M.options = vim.tbl_deep_extend("force", M.options, resolved)
	if M.options.ui.global_statusline ~= false then
		vim.opt.laststatus = 3
	end
end

return M
