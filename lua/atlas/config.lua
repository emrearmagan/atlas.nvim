-- Keymaps

---@alias AtlasKeymapValue string|string[]|false|nil

-- Pulls Provider Config

---@alias AtlasGitTransport "https"|"ssh"
---@alias AtlasPullsViewLayout "compact"|"grouped"|"plain"
---@alias AtlasIssuesViewLayout "compact"|"plain"

---@class AtlasPullsViewConfig
---@field name string
---@field key string|nil
---@field layout AtlasPullsViewLayout|nil
---@field current_repo boolean|nil
---@field search string|nil
---@field _states PullsStateFilter[]|nil

---@class AtlasIssuesViewConfig
---@field name string
---@field key string|nil
---@field layout AtlasIssuesViewLayout|nil
---@field search string|nil

---@class AtlasPullsRepoConfig
---@field settings table<string, AtlasPullsRepoSettings>|nil
---@field paths table<string, string>|nil

---@class AtlasPullsRepoSettings
---@field readme string|nil
---@field pr_template string|nil
---@field merge_method "merge"|"squash"|nil
---@field delete_source_branch boolean|nil

---@class AtlasPullsDiffExplorerConfig
---@field grouped boolean|nil
---@field hidden boolean|nil
---@field show_commits boolean|nil
---@field width integer|nil
---@field initial_focus "explorer"|"diff"|nil
---@field preview boolean|nil
---@field focus_on_select boolean|nil
---@field ignore string[]|nil

---@class AtlasPullsDiffReviewPanelConfig
---@field hidden boolean|nil
---@field height integer|nil

---@alias AtlasPullsDiffOpenCommand "auto"|"AtlasDiff"|"DiffviewOpen"|"CodeDiff"

-- Backs the diff with a detached worktree at the PR head so the new side is a real file buffer and
-- language servers attach to it. `dir` receives an AtlasWorktreeContext and may return nil to keep
-- the default location. `link` names directories symlinked from the main checkout (node_modules,
-- .venv, ...) so servers can resolve dependencies; they are the same directories on disk.
---@class AtlasPullsDiffLspConfig
---@field enabled boolean|nil
---@field dir string|(fun(ctx: AtlasWorktreeContext): string|nil)|nil
---@field link string[]|nil

---@class AtlasPullsDiffConfig
---@field open_cmd AtlasPullsDiffOpenCommand|string|nil
---@field layout "side-by-side"|"inline"|nil
---@field compact boolean|nil
---@field comment_display "virtual_lines"|"virtual_text"|nil
---@field explorer AtlasPullsDiffExplorerConfig|nil
---@field review_panel AtlasPullsDiffReviewPanelConfig|nil
---@field lsp AtlasPullsDiffLspConfig|nil

---@class AtlasPullsCommentTemplate
---@field label string
---@field text string

---@class AtlasPullsCommentTemplatesConfig
---@field insert_mode boolean|nil
---@field items AtlasPullsCommentTemplate[]

---@class AtlasPullsCustomActionContext
---@field repo_path string|nil
---@field pr PullRequest
---@field user AtlasUser|nil
---@field output fun(title: string): AtlasLiveOutput

---@class AtlasPullsCustomAction
---@field id string
---@field label string
---@field icon string|nil
---@field confirmation boolean|nil
---@field run fun(pr: PullRequest, ctx: AtlasPullsCustomActionContext, done: fun(ok: boolean|nil, message: string|nil))

-- Configs

---@class AtlasProvidersConfig
---@field bitbucket AtlasBitbucketConfig|nil
---@field github AtlasGitHubConfig|nil
---@field gitlab AtlasGitLabConfig|nil
---@field jira AtlasJiraConfig|nil

---@class AtlasPullsConfig
---@field git_transport AtlasGitTransport|nil Git transport for Atlas-managed repositories (default: "https").
---@field repo_config AtlasPullsRepoConfig|nil
---@field diff AtlasPullsDiffConfig|nil
---@field delete_notes boolean|nil
---@field default_merge_method "merge"|"squash"|nil
---@field default_delete_source_branch boolean|nil
---@field comment_templates AtlasPullsCommentTemplatesConfig|nil
---@field custom_actions AtlasPullsCustomAction[]|nil
---@field bitbucket AtlasBitbucketPullsConfig|nil
---@field github AtlasGitHubPullsConfig|nil
---@field gitlab AtlasGitLabPullsConfig|nil

---@class AtlasIssuesCustomActionContext
---@field issue Issue|nil
---@field user AtlasUser|nil
---@field output fun(title: string): AtlasLiveOutput

---@class AtlasIssuesCustomAction
---@field id string
---@field label string
---@field icon string|nil
---@field confirmation boolean|nil
---@field run fun(issue: Issue, ctx: AtlasIssuesCustomActionContext, done: fun(ok: boolean|nil, message: string|nil))

---@class AtlasIssuesConfig
---@field with_relationships boolean|nil
---@field custom_actions AtlasIssuesCustomAction[]|nil
---@field github AtlasGitHubIssuesConfig|nil
---@field gitlab AtlasGitLabIssuesConfig|nil
---@field jira AtlasJiraIssuesConfig|nil

-- Config

---@class AtlasUIStatuslineConfig
---@field atlas? boolean Show the statusline in Atlas's main UI (default: true)
---@field diff? boolean Show the statusline in Atlas-owned diff/review sessions (default: true)

---@class AtlasUIConfig
---@field statusline AtlasUIStatuslineConfig|nil
---@field picker AtlasPickerName|nil
---@field listed_buffer boolean|nil Make the main Atlas dashboard a listed buffer (default: false)

---@class AtlasConfig
---@field ui AtlasUIConfig|nil
---@field providers AtlasProvidersConfig|nil
---@field pulls AtlasPullsConfig|nil
---@field issues AtlasIssuesConfig|nil
---@field keymaps AtlasKeymapsConfig|nil  -- see core/keymaps.lua for type

local M = {}

---@type AtlasConfig
local defaults = {
	ui = {
		statusline = { atlas = true, diff = true },
		picker = "auto",
		listed_buffer = false,
	},
	pulls = {
		git_transport = "https",
		delete_notes = false,
		default_merge_method = "merge",
		default_delete_source_branch = false,
		comment_templates = {
			insert_mode = true,
			items = {
				{ label = "Praise", text = "praise: " },
				{ label = "Nitpick", text = "nitpick: " },
				{ label = "Suggestion", text = "suggestion: " },
				{ label = "Issue", text = "issue: " },
				{ label = "Todo", text = "todo: " },
				{ label = "Question", text = "question: " },
				{ label = "Thought", text = "thought: " },
				{ label = "Chore", text = "chore: " },
				{ label = "Note", text = "note: " },
			},
		},
		diff = {
			open_cmd = "auto",
			layout = "inline",
			compact = true,
			comment_display = "virtual_lines",
			review_panel = {
				hidden = true,
				height = 10,
			},
			lsp = {
				enabled = false,
				dir = nil,
				-- Keep empty: setup() deep extends, which merges lists element-wise.
				link = {},
			},
			explorer = {
				grouped = true,
				hidden = false,
				show_commits = false,
				width = 40,
				initial_focus = "explorer",
				preview = false,
				focus_on_select = false,
				ignore = { ".git/**", ".jj/**" },
			},
		},
	},
	issues = {
		with_relationships = true,
		jira = {
			project_config = {
				story_points_field = "customfield_10016",
				issue_types = {
					epic = { icon = "", hl_group = "AtlasJiraEpic" },
					story = { icon = "󰃀", hl_group = "AtlasTextPositive" },
					task = { icon = "", hl_group = "AtlasLogInfo" },
					bug = { icon = "", hl_group = "AtlasLogError" },
					subtask = { icon = "󰩊", hl_group = "AtlasLogInfo" },
				},
				status_icons = {
					new = "●",
					indeterminate = "",
					done = "",
				},
			},
		},
	},
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
			toggle_description_mode = "<leader>m",
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
			next_page = "]p",
			previous_page = "[p",
			open_actions = "A",
			open_in_browser = "gx",
			open_references = "gl",
			copy_id = "y",
			copy_url = "Y",
			show_details = "K",
			search = "?",
			edit_search = "i",
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
			open_repository = "o",
			edit_title = "T",
			edit_description = "D",
			pipelines = {
				next_job = { "]j", "<Tab>" },
				previous_job = { "[j", "<S-Tab>" },
				show_history = "gH",
				toggle_raw_logs = "gL",
				toggle_auto_refresh = "gR",
			},
			review = {
				show_details = "K", -- File/commit details.
				toggle_file_reviewed = "-",
				next_comment = "]c",
				prev_comment = "[c",
				next_note = "]n",
				prev_note = "[n",
				add_comment = "c",
				submit_comment = "C",
				add_suggestion = "s",
				submit_suggestion = "S",
				add_note = "<leader>n",
				toggle_resolved = "x",
				approve = "<leader>ga",
				request_changes = "<leader>gr",
				submit_review = "<leader>gs",
				add_task = "<leader>t",
				comment_templates = "gT",
				view = {
					external_help = "gA", -- External diff viewer help.
					toggle_review_panel = "gR",
					toggle_detail_panel = "gD",
					toggle_comments = "gH",
				},
				explorer = {
					toggle_commits = "gC",
					next_unreviewed_file = "]u",
					prev_unreviewed_file = "[u",
					find_file = "<leader>f",
				},
				-- Built-in navigation; external viewers use their own keys.
				atlas = {
					next_file = { "]f", "<Tab>" },
					prev_file = { "[f", "<S-Tab>" },
					toggle_explorer = "<leader>b",
					focus_explorer = "<leader>e",
					open_file = "gf",
					toggle_view_mode = "i",
					next_hunk = "]h",
					prev_hunk = "[h",
					toggle_layout = "t",
					toggle_compact = "gc",
				},
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
		},
	},
}

---@type AtlasConfig
M.options = vim.deepcopy(defaults)

---@param context "atlas"|"diff"
---@return boolean
function M.statusline_enabled(context)
	return M.options.ui.statusline[context] ~= false
end

---@return string
function M.diff_command()
	local command = vim.trim(M.options.pulls.diff.open_cmd or "auto")
	if command ~= "auto" and command ~= "" then
		return command
	end

	for _, candidate in ipairs({ "CodeDiff", "DiffviewOpen" }) do
		if vim.fn.exists(":" .. candidate) == 2 then
			return candidate
		end
	end
	return "AtlasDiff"
end

---@param id AtlasProviderId
---@return table|nil
function M.provider_options(id)
	local providers = type(M.options.providers) == "table" and M.options.providers or nil
	local options = providers and providers[id] or nil
	return type(options) == "table" and options or nil
end

---@param id AtlasProviderId
---@param domain "pulls"|"issues"
---@return table|nil
function M.domain_options(id, domain)
	local section = type(M.options[domain]) == "table" and M.options[domain] or nil
	local options = section and section[id] or nil
	return type(options) == "table" and options or nil
end

-- Setup

---@param opts AtlasConfig|table|nil
function M.setup(opts)
	local resolved = vim.deepcopy(opts or {})
	local project = vim.tbl_get(resolved, "issues", "jira", "project_config")
	if project and project.issue_types then
		local issue_types = {}
		for name, style in pairs(project.issue_types) do
			issue_types[name:lower()] = style
		end
		project.issue_types = issue_types
	end
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), resolved)
	if M.statusline_enabled("atlas") or M.statusline_enabled("diff") then
		vim.opt.laststatus = 3
	end
end

return M
