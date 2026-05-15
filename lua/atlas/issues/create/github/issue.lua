local M = {}

local form = require("atlas.ui.popups.form")
local spinner = require("atlas.ui.popups.spinner")
local multi_select = require("atlas.ui.popups.multi_select")
local pulls_helper = require("atlas.pulls.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local template_store = require("atlas.issues.templates")

---@class CreateIssueLayout
---@field container_buf integer|nil
---@field container_win integer|nil
---@field title_buf integer|nil
---@field title_win integer|nil
---@field meta_buf integer|nil
---@field meta_win integer|nil
---@field desc_buf integer|nil
---@field desc_win integer|nil

---@class CreateIssueLabel
---@field name string
---@field color string|nil

---@class CreateIssueMilestone
---@field number integer
---@field title string

---@class CreateIssuePickers
---@field list_labels fun(on_done: fun(items: CreateIssueLabel[]|nil, err: string|nil))|nil
---@field list_assignees fun(on_done: fun(items: IssueUser[]|nil, err: string|nil))|nil
---@field list_milestones fun(on_done: fun(items: CreateIssueMilestone[]|nil, err: string|nil))|nil

---@class CreateIssueFields
---@field repo_slug string
---@field title string
---@field body string
---@field labels CreateIssueLabel[]
---@field assignees IssueUser[]
---@field milestone CreateIssueMilestone|nil

---@class CreateIssueState
---@field fields CreateIssueFields
---@field layout CreateIssueLayout
---@field content_width integer
---@field is_submitting boolean
---@field pickers CreateIssuePickers
---@field on_done fun(result: GitHubIssueEditorResult|nil, err: string|nil)|nil

local function notify(level, msg)
	vim.notify("[Atlas] " .. tostring(msg), level)
end

local function notify_info(msg)
	notify(vim.log.levels.INFO, msg)
end

local function notify_warn(msg)
	notify(vim.log.levels.WARN, msg)
end

local function notify_error(msg)
	notify(vim.log.levels.ERROR, msg)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

---@param repo_slug string
---@return CreateIssuePickers
local function default_pickers(repo_slug)
	local issues_api = require("atlas.issues.providers.github.api.issues")
	return {
		list_labels = function(cb)
			issues_api.list_labels(repo_slug, cb)
		end,
		list_assignees = function(cb)
			issues_api.list_assignees(repo_slug, cb)
		end,
		list_milestones = function(cb)
			issues_api.list_milestones(repo_slug, cb)
		end,
	}
end

---@class GitHubIssueEditorResult
---@field url string|nil
---@field number integer|nil

---@param assignees IssueUser[]
---@return string
local function format_assignees(assignees)
	if type(assignees) ~= "table" or #assignees == 0 then
		return icons.general("user") .. " Unassigned"
	end

	local parts = {}
	for _, assignee in ipairs(assignees) do
		table.insert(parts, "@" .. tostring(assignee.account_id or ""))
	end

	return icons.general("user") .. " " .. table.concat(parts, ", ")
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	if type(hex) ~= "string" or not hex:match("^%x%x%x%x%x%x$") then
		return "AtlasTextMuted"
	end

	local name = string.format("AtlasGHLabel_%s", hex:lower())
	vim.api.nvim_set_hl(0, name, { fg = "#000000", bg = "#" .. hex, bold = true })
	return name
end

---@param milestone CreateIssueMilestone|nil
---@return string
local function format_milestone(milestone)
	if type(milestone) ~= "table" then
		return "None"
	end

	return tostring(milestone.title or string.format("#%s", tostring(milestone.number or "")))
end

---@param labels CreateIssueLabel[]
---@return EditorPopupMetaCell
local function labels_cell(labels)
	if type(labels) ~= "table" or #labels == 0 then
		return { text = "None", hl = "AtlasTextMuted" }
	end

	local cursor = 0
	local pieces = {}
	local spans = {}
	for i, label in ipairs(labels) do
		local name = tostring(label.name or "")
		if name ~= "" then
			if i > 1 then
				table.insert(pieces, " ")
				cursor = cursor + 1
			end
			local chip = " " .. name .. " "
			table.insert(pieces, chip)
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #chip,
				hl_group = label_hl(label.color),
			})
			cursor = cursor + #chip
		end
	end

	local text = table.concat(pieces)
	if text == "" then
		return { text = "None", hl = "AtlasTextMuted" }
	end

	return { text = text, spans = spans }
end

---@param issue_state CreateIssueState
---@return EditorPopupMetaRow[]
local function meta_rows(issue_state)
	local repo = tostring(issue_state.fields.repo_slug or "")
	local assignees = issue_state.fields.assignees
	local milestone = issue_state.fields.milestone

	local milestone_text = format_milestone(milestone)
	local milestone_hl = milestone and "AtlasText" or "AtlasTextMuted"
	local assignees_text = format_assignees(assignees)
	local assignees_hl = #assignees > 0 and "AtlasText" or "AtlasTextMuted"

	return {
		{
			"Repo:",
			{ text = repo, hl = pulls_helper.repo_hl(repo) },
			"Milestone:",
			{ text = milestone_text, hl = milestone_hl },
		},
		{ "Assignees:", { text = assignees_text, hl = assignees_hl } },
		{ "Labels:", labels_cell(issue_state.fields.labels) },
	}
end

---@param issue_state CreateIssueState
local function get_title(issue_state)
	if not valid_buf(issue_state.layout.title_buf) then
		return ""
	end

	local lines = vim.api.nvim_buf_get_lines(issue_state.layout.title_buf, 0, -1, false)
	return vim.trim(table.concat(lines, " "))
end

---@param issue_state CreateIssueState
local function get_body(issue_state)
	if not valid_buf(issue_state.layout.desc_buf) then
		return ""
	end

	return table.concat(vim.api.nvim_buf_get_lines(issue_state.layout.desc_buf, 0, -1, false), "\n")
end

---@param issue_state CreateIssueState
local function render_meta(issue_state)
	form.render_meta(issue_state, meta_rows(issue_state))
end

---@param issue_state CreateIssueState
local function close(issue_state)
	spinner.stop()
	form.close(issue_state.layout)
end

---@param issue_state CreateIssueState
local function confirm_close(issue_state)
	local title = get_title(issue_state)
	local body = get_body(issue_state)
	if title == "" and body == "" then
		close(issue_state)
		return
	end

	vim.ui.input({ prompt = "Discard issue draft? [y/N]: " }, function(input)
		if type(input) == "string" and input:match("^[yY]") then
			close(issue_state)
		end
	end)
end

---@param issue_state CreateIssueState
local function pick_assignees(issue_state)
	if type(issue_state.pickers.list_assignees) ~= "function" then
		notify_warn("Assignee picker is not available")
		return
	end

	spinner.start("Loading assignees…")
	issue_state.pickers.list_assignees(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then
				notify_error("Failed to load assignees: " .. tostring(err))
				return
			end
			if type(items) ~= "table" or #items == 0 then
				notify_warn("No assignees available")
				return
			end

			multi_select.open({
				items = items,
				selected = issue_state.fields.assignees,
				key = function(item)
					return item.account_id
				end,
				format = function(item)
					return string.format(
						"@%s%s",
						item.account_id,
						item.display_name and item.display_name ~= item.account_id and (" — " .. item.display_name) or ""
					)
				end,
				prompt = "Toggle assignees:",
				on_done = function(selected)
					issue_state.fields.assignees = selected or {}
					render_meta(issue_state)
				end,
			})
		end)
	end)
end

---@param issue_state CreateIssueState
local function pick_labels(issue_state)
	if type(issue_state.pickers.list_labels) ~= "function" then
		notify_warn("Label picker is not available")
		return
	end

	spinner.start("Loading labels…")
	issue_state.pickers.list_labels(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then
				notify_error("Failed to load labels: " .. tostring(err))
				return
			end
			if type(items) ~= "table" or #items == 0 then
				notify_warn("No labels available")
				return
			end

			multi_select.open({
				items = items,
				selected = issue_state.fields.labels,
				key = function(item)
					return item.name
				end,
				format = function(item)
					return tostring(item.name)
				end,
				prompt = "Toggle labels:",
				on_done = function(selected)
					issue_state.fields.labels = selected or {}
					render_meta(issue_state)
				end,
			})
		end)
	end)
end

---@param issue_state CreateIssueState
local function pick_milestone(issue_state)
	if type(issue_state.pickers.list_milestones) ~= "function" then
		notify_warn("Milestone picker is not available")
		return
	end

	spinner.start("Loading milestones…")
	issue_state.pickers.list_milestones(function(items, err)
		vim.schedule(function()
			spinner.stop()
			if err then
				notify_error("Failed to load milestones: " .. tostring(err))
				return
			end

			items = type(items) == "table" and items or {}

			local choices = { "(none)" }
			local map = {}
			for _, item in ipairs(items) do
				local label = string.format("#%s · %s", tostring(item.number), tostring(item.title))
				table.insert(choices, label)
				map[label] = item
			end

			vim.ui.select(choices, { prompt = "Select milestone:" }, function(choice)
				if choice == nil then
					return
				end
				if choice == "(none)" then
					issue_state.fields.milestone = nil
				else
					issue_state.fields.milestone = map[choice]
				end
				render_meta(issue_state)
			end)
		end)
	end)
end

---@param issue_state CreateIssueState
---@param content string
local function set_body(issue_state, content)
	if not valid_buf(issue_state.layout.desc_buf) then
		return false
	end
	local lines = vim.split(tostring(content or ""), "\n", { plain = true })
	vim.api.nvim_buf_set_lines(issue_state.layout.desc_buf, 0, -1, false, lines)
	return true
end

---@param issue_state CreateIssueState
local function apply_template_from_picker(issue_state)
	local templates, list_err = template_store.list()
	if list_err then
		notify_error(list_err)
		return
	end

	if templates == nil or #templates == 0 then
		notify_warn("No templates found")
		return
	end

	vim.ui.select(templates, {
		prompt = "Apply template",
		kind = "atlas_github_templates",
		format_item = function(item)
			return tostring((item and item.name) or "")
		end,
	}, function(selected)
		if selected == nil then
			return
		end

		local template_name = tostring(selected.name or "")
		if template_name == "" then
			notify_warn("Invalid template selected")
			return
		end

		local content, read_err = template_store.read(template_name)
		if read_err then
			notify_error(read_err)
			return
		end

		local function apply()
			if not set_body(issue_state, content or "") then
				notify_error("Issue body buffer is not available")
				return
			end
			notify_info(string.format("Applied template: %s", template_name))
		end

		if vim.trim(get_body(issue_state)) == "" then
			apply()
			return
		end

		vim.ui.input({
			prompt = "Description is not empty. Replace with template? [y/N]: ",
		}, function(input)
			if input and vim.trim(tostring(input)):lower() == "y" then
				apply()
			end
		end)
	end)
end

---@param issue_state CreateIssueState
local function save_body_as_template(issue_state)
	local body = vim.trim(get_body(issue_state))
	if body == "" then
		notify_warn("Description is empty")
		return
	end

	vim.ui.input({ prompt = "Template name: " }, function(input)
		if input == nil then
			return
		end

		local name = vim.trim(tostring(input))
		if name == "" then
			notify_warn("Template name is required")
			return
		end

		local ok, write_err, existed, normalized_name = template_store.write(name, body, { overwrite = false })
		if ok then
			notify_info(string.format("Created template %s", tostring(normalized_name or name)))
			return
		end

		if existed then
			vim.ui.input({
				prompt = string.format('Template "%s" exists. Overwrite? [y/N]: ', tostring(normalized_name or name)),
			}, function(confirm)
				if confirm == nil or vim.trim(tostring(confirm)):lower() ~= "y" then
					return
				end
				local overwrite_ok, overwrite_err, _, final_name =
					template_store.write(name, body, { overwrite = true })
				if not overwrite_ok then
					notify_error(overwrite_err or "Failed to overwrite template")
					return
				end
				notify_info(string.format("Updated template %s", tostring(final_name or normalized_name or name)))
			end)
			return
		end

		notify_error(write_err or "Failed to create template")
	end)
end

---@param issue_state CreateIssueState
local function open_templates_menu(issue_state)
	local items = {
		{ id = "apply", label = "Apply template" },
		{ id = "save", label = "Save current description as template" },
	}

	vim.ui.select(items, {
		prompt = "Issue templates",
		kind = "atlas_github_templates_menu",
		format_item = function(item)
			return tostring((item and item.label) or "")
		end,
	}, function(selected)
		if selected == nil then
			return
		end

		if selected.id == "apply" then
			apply_template_from_picker(issue_state)
			return
		end
		save_body_as_template(issue_state)
	end)
end

---@param issue_state CreateIssueState
local function submit(issue_state)
	if issue_state.is_submitting then
		return
	end

	local title = get_title(issue_state)
	if title == "" then
		notify_warn("Title is required")
		return
	end

	local label_names = {}
	for _, label in ipairs(issue_state.fields.labels) do
		table.insert(label_names, label.name)
	end

	local assignee_logins = {}
	for _, assignee in ipairs(issue_state.fields.assignees) do
		table.insert(assignee_logins, assignee.account_id)
	end

	issue_state.is_submitting = true
	spinner.start("Creating issue…")

	local issues_api = require("atlas.issues.providers.github.api.issues")
	issues_api.create_issue({
		repo_slug = issue_state.fields.repo_slug,
		title = title,
		body = get_body(issue_state),
		labels = label_names,
		assignees = assignee_logins,
		milestone = issue_state.fields.milestone and issue_state.fields.milestone.number or nil,
	}, function(result, err)
		vim.schedule(function()
			issue_state.is_submitting = false
			spinner.stop()

			if err then
				notify_error("Create issue failed: " .. tostring(err))
				if type(issue_state.on_done) == "function" then
					issue_state.on_done(nil, err)
				end
				return
			end

			local url = result and result.url or nil
			if type(url) == "string" and url ~= "" then
				notify_info("Issue created: " .. url)
				pcall(vim.fn.setreg, "+", url)
			else
				notify_info("Issue created")
			end

			if type(issue_state.on_done) == "function" then
				issue_state.on_done(result, nil)
			end

			close(issue_state)
		end)
	end)
end

---@class GitHubIssueEditorOpts
---@field repo_slug string
---@field on_done fun(result: GitHubIssueEditorResult|nil, err: string|nil)|nil

---@param opts GitHubIssueEditorOpts
function M.open(opts)
	if type(opts) ~= "table" then
		notify_warn("create_issue.open: missing options")
		return
	end

	local repo_slug = tostring(opts.repo_slug or "")
	if repo_slug == "" then
		notify_error("create_issue.open: repo_slug is required")
		return
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()

	---@type CreateIssueState
	local issue_state = {
		fields = {
			repo_slug = repo_slug,
			title = "",
			body = "",
			labels = {},
			assignees = {},
			milestone = nil,
		},
		layout = {},
		content_width = 80,
		is_submitting = false,
		pickers = default_pickers(repo_slug),
		on_done = opts.on_done,
	}

	form.open(issue_state, {
		title = " Create Issue ",
		min_height = 22,
		meta_height = 3,
		title_winbar = "Title",
		desc_winbar = "Description",
		initial_title = issue_state.fields.title,
		initial_body = issue_state.fields.body,
		close = function()
			confirm_close(issue_state)
		end,
		submit = function()
			submit(issue_state)
		end,
		meta = function()
			return meta_rows(issue_state)
		end,
		keymaps = {
			{
				key = "ga",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "assignees",
				show_in_footer = true,
				action = function()
					pick_assignees(issue_state)
				end,
			},
			{
				key = "gl",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "labels",
				show_in_footer = true,
				action = function()
					pick_labels(issue_state)
				end,
			},
			{
				key = "gm",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "milestone",
				show_in_footer = true,
				action = function()
					pick_milestone(issue_state)
				end,
			},
			{
				key = "gt",
				mode = "n",
				buffers = { "title", "desc" },
				desc = "templates",
				show_in_footer = true,
				action = function()
					open_templates_menu(issue_state)
				end,
			},
		},
	})

	vim.schedule(function()
		if vim.api.nvim_get_current_buf() == issue_state.layout.title_buf then
			vim.cmd("startinsert!")
		end
	end)
end

return M
