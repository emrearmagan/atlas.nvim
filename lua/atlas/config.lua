-- Keymaps

---@alias AtlasKeymapValue string|string[]|false|nil

-- Pulls Provider Config

---@alias AtlasGitTransport "https"|"ssh"

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
---@field preview boolean|nil
---@field ignore string[]|nil

---@class AtlasPullsDiffReviewPanelConfig
---@field height integer|nil

---@alias AtlasPullsDiffOpenCommand "AtlasDiff"|"DiffviewOpen"|"CodeDiff"

---@class AtlasPullsDiffConfig
---@field open_cmd AtlasPullsDiffOpenCommand|string|nil
---@field layout "side-by-side"|"inline"|nil
---@field compact boolean|nil
---@field compact_context_lines integer|nil
---@field show_review_panel boolean|nil
---@field comment_display "virtual_lines"|"virtual_text"|nil Initial comment and note display mode.
---@field explorer AtlasPullsDiffExplorerConfig|nil
---@field review_panel AtlasPullsDiffReviewPanelConfig|nil

---@class AtlasPullsCommentTemplate
---@field label string
---@field text string

---@class AtlasPullsCommentTemplatesConfig
---@field insert_mode boolean|nil
---@field items AtlasPullsCommentTemplate[]

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
---@field default_delete_branch boolean|nil
---@field comment_templates AtlasPullsCommentTemplatesConfig|nil
---@field custom_actions AtlasPullsCustomAction[]|nil
---@field bitbucket AtlasBitbucketPullsConfig|nil
---@field github AtlasGitHubPullsConfig|nil
---@field gitlab AtlasGitLabPullsConfig|nil

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
---@field github AtlasGitHubIssuesConfig|nil
---@field gitlab AtlasGitLabIssuesConfig|nil
---@field jira AtlasJiraIssuesConfig|nil

-- Config

---@class AtlasUIConfig
---@field statusline boolean|nil Show the Atlas statusline (default: true)
---@field picker AtlasPickerName|nil
---@field listed_buffer boolean|nil Make the main Atlas dashboard a listed buffer (default: false)

---@class AtlasConfig
---@field ui AtlasUIConfig|nil
---@field providers AtlasProvidersConfig|nil
---@field pulls AtlasPullsConfig|nil
---@field issues AtlasIssuesConfig|nil
---@field keymaps AtlasKeymapsConfig|nil  -- see core/keymaps.lua for type

local M = {}

local notify = require("atlas.core.notify")

---@type AtlasConfig
M.options = {
	ui = {
		statusline = true,
		picker = "auto",
		listed_buffer = false,
	},
	pulls = {
		git_transport = "https",
		delete_notes = false,
		default_merge_method = "merge",
		default_delete_branch = false,
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
			open_cmd = "AtlasDiff",
			layout = "inline",
			compact = true,
			compact_context_lines = 3,
			show_review_panel = false,
			comment_display = "virtual_lines",
			review_panel = {
				height = 10,
			},
			explorer = {
				grouped = true,
				hidden = false,
				show_commits = false,
				width = 40,
				initial_focus = "explorer",
				preview = false,
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
			review = {
				focus_item = "gd",
				approve = "ga",
				request_changes = "gr",
				submit_review = "gs",
				add_task = "<leader>t",
				comment_templates = "gT",
				find_file = "<leader>ff",
				explorer = {
					find_file = { "f", "<leader>ff" },
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

--TODO: Remove with 0.8.0
local function migrate_legacy(opts)
	local migrated = false
	opts.providers = type(opts.providers) == "table" and opts.providers or {}

	for _, domain in ipairs({ "pulls", "issues" }) do
		local section = type(opts[domain]) == "table" and opts[domain] or nil
		local legacy = section and section.providers or nil
		if type(legacy) == "table" then
			migrated = true
			section.providers = nil
			for id, legacy_config in pairs(legacy) do
				if type(legacy_config) == "table" then
					local provider_config = type(opts.providers[id]) == "table" and opts.providers[id] or {}
					local domain_config = type(section[id]) == "table" and section[id] or {}
					opts.providers[id] = provider_config
					section[id] = domain_config

					for key, value in pairs(legacy_config) do
						local domain_scoped = key == "views"
							or key == "bookmarks"
							or (domain == "issues" and id == "jira" and key == "project_config")
						if domain_scoped then
							if domain_config[key] == nil then
								domain_config[key] = value
							end
						elseif provider_config[key] == nil then
							provider_config[key] = value
						end
					end
				end
			end
		end
	end

	local jira_provider = type(opts.providers.jira) == "table" and opts.providers.jira or nil
	if jira_provider and jira_provider.project_config ~= nil then
		local issues = type(opts.issues) == "table" and opts.issues or {}
		local jira_issues = type(issues.jira) == "table" and issues.jira or {}
		if jira_issues.project_config == nil then
			jira_issues.project_config = jira_provider.project_config
		end
		jira_provider.project_config = nil
		issues.jira = jira_issues
		opts.issues = issues
		migrated = true
	end

	if migrated then
		notify.warn("Deprecated Config", { vim_notify = true })
	end
	return opts
end

---@param opts AtlasConfig|table|nil
function M.setup(opts)
	local resolved = migrate_legacy(vim.deepcopy(opts or {}))
	M.options = vim.tbl_deep_extend("force", M.options, resolved)
	if M.options.ui.statusline ~= false then
		vim.opt.laststatus = 3
	end
end

return M
